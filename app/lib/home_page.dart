import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_info.dart';
import 'app_theme.dart';
import 'audio_format.dart';
import 'device_downloader.dart';
import 'history_page.dart';
import 'models.dart';
import 'network_status.dart';
import 'share_intake.dart';
import 'spotify_meta.dart';
import 'store.dart';
import 'update_check.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    this.themeMode = ThemeMode.system,
    this.onThemeMode,
    this.resolveLink = resolveSpotifyLink,
    this.network,
    this.appInfo,
    this.updates,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeMode;

  /// Overridable so tests can say whether the phone is on Wi-Fi.
  final NetworkStatus? network;

  /// Overridable so tests do not need Android, or GitHub, for the version line.
  final AppInfo? appInfo;
  final UpdateService? updates;

  /// Overridable so tests can answer with a link instead of the network.
  final Future<ResolvedLink> Function(String link) resolveLink;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final TextEditingController _urlController = TextEditingController();
  final DeviceDownloader _downloader = DeviceDownloader();
  final ShareIntake _share = ShareIntake();
  final Store _store = Store();
  late final NetworkStatus _network = widget.network ?? NetworkStatus();
  late final AppInfo _appInfo = widget.appInfo ?? const AppInfo();
  late final UpdateService _updates = widget.updates ?? UpdateService();
  StreamSubscription<bool>? _networkSub;
  StreamSubscription<ShareEvent>? _sharedEvents;
  final Set<String> _selected = <String>{};

  /// Per-track state: 'queued', 'downloading', 'done' or 'failed'.
  final Map<String, String> _states = <String, String>{};
  final Map<String, double> _progress = <String, double>{};
  final Map<String, String> _trackErrors = <String, String>{};

  StreamSubscription<Map<String, dynamic>>? _events;
  ResolvedLink? _link;
  AudioFormat _format = AudioFormat.all.first;

  bool _resolving = false;
  bool _busy = false;
  bool _stopRequested = false;
  bool _cancelRequested = false;
  bool _autoDownload = false;
  bool _wifiOnly = false;
  bool _startWhenVisible = false;

  /// A queue wants to run but the phone is on mobile data, so nothing has
  /// started yet.
  bool _waitingForWifi = false;

  /// A running queue is paused between two tracks for the same reason.
  Completer<void>? _wifiWait;

  /// Tracked here as well as in the observer, because the retry below has to
  /// know whether the app is on screen without waiting for a lifecycle event.
  bool _inForeground = true;
  Timer? _startRetry;
  bool? _ready;
  bool _urlHasText = false;
  String _engineStatus = 'Starting downloader…';
  String? _engineError;
  String? _error;
  String? _shareNotice;
  int _busyDone = 0;
  int _busyTotal = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _urlController.addListener(_onUrlChanged);
    _events = _downloader.events.listen(_onEvent);
    _sharedEvents = _share.events.listen(_applyShare);
    _prepare();
    _restoreFormat();
    _restoreAutoDownload();
    _restoreWifiOnly();
    // An error here (no native side in tests) just means no Wi-Fi events.
    _networkSub = _network.changes.listen(_onNetworkChanged, onError: (_) {});
    _startUp();
  }

  /// A share that opened the app gets first say; then a queue left over from
  /// the last run carries on where it stopped; with neither, the list that was
  /// on screen comes back without starting anything.
  Future<void> _startUp() async {
    await _takeLaunchShare();
    await _restorePendingQueue();
    await _restoreViewing();
  }

  /// Only the clear button depends on the text, so rebuild on that one flip.
  void _onUrlChanged() {
    final hasText = _urlController.text.isNotEmpty;
    if (hasText != _urlHasText) setState(() => _urlHasText = hasText);
  }

  /// The app may have been opened by "Share → Spotify Grabber".
  Future<void> _takeLaunchShare() async {
    final share = await _share.launchShare();
    if (!mounted || share == null) return;
    _applyShare(share);
  }

  /// Uses a shared link, or explains why the shared text could not be used.
  void _applyShare(ShareEvent share) {
    if (!mounted) return;
    final link = share.link;
    if (link == null || link.isEmpty) {
      setState(() {
        _shareNotice = "That share had no Spotify link in it. Copy the link "
            'from the track’s ••• menu and paste it here instead.';
        _error = null;
      });
      return;
    }
    setState(() => _shareNotice = null);
    _urlController.text = link;
    if (_busy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Link received. Fetch it when this download finishes.'),
        ),
      );
      return;
    }
    _fetch();
  }

  /// A queue that Android would not let us hold open starts on its own as soon
  /// as the app is back on screen, where a foreground service is allowed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inForeground = state == AppLifecycleState.resumed;
    if (!_inForeground || !_startWhenVisible) return;
    _startRetry?.cancel();
    setState(() => _startWhenVisible = false);
    _downloadSelected();
  }

  /// Coming back to the foreground is handled by the observer. These bounded
  /// retries cover the other case: a refusal while the app is already on
  /// screen, where the resume that would have retried has already happened
  /// and waiting for another one would mean waiting for the user to leave.
  static const List<Duration> _startRetryDelays = <Duration>[
    Duration(milliseconds: 400),
    Duration(seconds: 1),
    Duration(seconds: 3),
  ];

  void _retryStart(int attempt) {
    _startRetry?.cancel();
    if (!_inForeground || attempt >= _startRetryDelays.length) return;
    _startRetry = Timer(_startRetryDelays[attempt], () {
      if (!mounted || !_startWhenVisible || _busy || !_inForeground) return;
      _downloadSelected(attempt: attempt + 1);
    });
  }

  /// Wi-Fi arriving is what a queue waiting for it was waiting for: start it,
  /// or let a paused one carry on.
  void _onNetworkChanged(bool wifi) {
    if (!wifi || !mounted) return;
    if (_wifiWait?.isCompleted == false) _wifiWait!.complete();
    if (!_waitingForWifi || _busy) return;
    setState(() => _waitingForWifi = false);
    _downloadSelected();
  }

  @override
  void dispose() {
    _startRetry?.cancel();
    _networkSub?.cancel();
    if (_wifiWait?.isCompleted == false) _wifiWait!.complete();
    WidgetsBinding.instance.removeObserver(this);
    _urlController.removeListener(_onUrlChanged);
    _events?.cancel();
    _sharedEvents?.cancel();
    _share.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _restoreFormat() async {
    final saved = await _downloader.savedFormat();
    if (!mounted) return;
    setState(() => _format = saved);
  }

  Future<void> _restoreAutoDownload() async {
    final enabled = await _store.autoDownload();
    if (!mounted || enabled == _autoDownload) return;
    setState(() => _autoDownload = enabled);
  }

  Future<void> _setAutoDownload(bool enabled) async {
    setState(() => _autoDownload = enabled);
    await _store.saveAutoDownload(enabled);
  }

  Future<void> _restoreWifiOnly() async {
    final enabled = await _store.wifiOnly();
    if (!mounted || enabled == _wifiOnly) return;
    setState(() => _wifiOnly = enabled);
  }

  Future<void> _setWifiOnly(bool enabled) async {
    setState(() => _wifiOnly = enabled);
    await _store.saveWifiOnly(enabled);
  }

  void _onEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final status = event['status'] as String?;
    if (status != null) {
      setState(() => _engineStatus = status);
      return;
    }
    final id = event['id'] as String?;
    final progress = event['progress'];
    if (id != null && progress is num) {
      setState(() => _progress[id] = progress.toDouble());
    }
  }

  /// Preparations can overlap — the one at launch runs while a restored queue
  /// waits for it — and starting the engines twice would race with itself.
  Future<void>? _preparing;

  Future<void> _prepare() async {
    final inFlight = _preparing;
    if (inFlight != null) {
      await inFlight;
      return;
    }
    final run = _prepareOnce();
    _preparing = run;
    try {
      await run;
    } finally {
      _preparing = null;
    }
  }

  Future<void> _prepareOnce() async {
    setState(() {
      _ready = null;
      _engineStatus = 'Starting downloader…';
      _engineError = null;
    });
    try {
      await _downloader.prepare();
      if (!mounted) return;
      setState(() {
        _ready = true;
        _engineStatus = 'Ready';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _ready = false;
        _engineStatus = 'Downloader unavailable';
        _engineError = error.toString();
      });
    }
  }

  /// A queue Android interrupted — the process was killed, or the service was
  /// refused and the app closed before it could try again. Only the tracks that
  /// are still left are downloaded, and it starts on its own: asking the user to
  /// paste the link again is what this exists to avoid.
  Future<void> _restorePendingQueue() async {
    final pending = await _store.pendingQueue();
    if (!mounted || pending == null) return;
    // A link from the share sheet, or one being fetched, wins over older work.
    if (_link != null || _resolving || _busy) return;

    final remaining = pending.remaining.toSet();
    if (remaining.isEmpty || pending.link.tracks.isEmpty) {
      await _store.clearPendingQueue();
      return;
    }

    setState(() {
      _link = pending.link;
      _format = AudioFormat.byId(pending.format);
      _selected
        ..clear()
        ..addAll(remaining);
      for (final track in pending.link.tracks) {
        if (!remaining.contains(track.id)) _states[track.id] = 'done';
      }
    });
    _urlController.text = pending.link.url;
    await _downloadSelected();
  }

  /// The list from the last run, with the ticks it had. Nothing downloads:
  /// the user only gets their selection back.
  Future<void> _restoreViewing() async {
    if (_link != null || _resolving || _busy) return;
    final viewing = await _store.viewing();
    if (!mounted || viewing == null) return;
    // The link may have resolved while this was reading the store.
    if (_link != null || _resolving || _busy) return;

    final tracks = viewing.link.tracks;
    if (tracks.isEmpty) {
      await _store.clearViewing();
      return;
    }
    final ids = tracks.map((track) => track.id).toSet();
    final selected = viewing.selected.where(ids.contains).toSet();
    setState(() {
      _link = viewing.link;
      _selected
        ..clear()
        ..addAll(selected.isEmpty ? ids : selected);
    });
    _urlController.text = viewing.link.url;
  }

  /// Keeps the restore point in step with what is on screen.
  void _rememberViewing() {
    final link = _link;
    if (link == null) return;
    unawaited(
      _store.saveViewing(
        ViewingLink(link: link, selected: _selected.toList()),
      ),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim();
    if (text != null && text.isNotEmpty) {
      setState(() {
        _urlController.text = text;
        _shareNotice = null;
      });
    }
  }

  Future<void> _fetch() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _error = 'Paste a Spotify link first.';
        _shareNotice = null;
      });
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _resolving = true;
      _error = null;
      _shareNotice = null;
      _startWhenVisible = false;
      _link = null;
      _selected.clear();
      _states.clear();
      _progress.clear();
      _trackErrors.clear();
    });
    // The link this replaces had its own queue, if any.
    await _store.clearPendingQueue();
    try {
      final link = await widget.resolveLink(url);
      if (!mounted) return;
      setState(() {
        _link = link;
        _selected.addAll(link.tracks.map((track) => track.id));
        _resolving = false;
      });
      _rememberViewing();
      if (_autoDownload) await _downloadSelected();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _error = error.toString();
      });
    }
  }

  /// Waits between two tracks until the phone is back on Wi-Fi. Stop and
  /// Cancel release it too, so neither leaves the queue parked forever.
  Future<void> _pauseForWifi() async {
    final wait = _wifiWait = Completer<void>();
    if (mounted) setState(() {});
    try {
      // The connection may have come back between the check and this line.
      if (await _network.isWifi() && !wait.isCompleted) wait.complete();
      await wait.future;
    } finally {
      _wifiWait = null;
      if (mounted) setState(() {});
    }
  }

  /// The strong one of the two stop controls: it drops the queue and the
  /// stored record, so a killed process cannot bring the rest back on the next
  /// launch, and it returns to the empty screen instead of leaving a list whose
  /// download was abandoned half way.
  void _cancelQueue() {
    if (!_busy && !_startWhenVisible && !_waitingForWifi) return;
    _startRetry?.cancel();
    if (_wifiWait?.isCompleted == false) _wifiWait!.complete();
    // Before anything else: a process killed from here on must not resume.
    _store.clearPendingQueue();
    setState(() {
      _cancelRequested = true;
      _stopRequested = true;
    });
    // Nothing is downloading yet, so there is no queue to wind down first.
    if (!_busy) _abandonQueue();
  }

  void _abandonQueue() {
    setState(() {
      _cancelRequested = false;
      _stopRequested = false;
      _startWhenVisible = false;
      _waitingForWifi = false;
      _busy = false;
    });
    _clearLink();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Download cancelled.')),
    );
  }

  void _clearLink() {
    _store.clearPendingQueue();
    _store.clearViewing();
    _urlController.clear();
    setState(() {
      _link = null;
      _error = null;
      _shareNotice = null;
      _startWhenVisible = false;
      _selected.clear();
      _states.clear();
      _progress.clear();
      _trackErrors.clear();
    });
  }

  Future<void> _pickFormat() async {
    final picked = await showModalBottomSheet<AudioFormat>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => _FormatSheet(selected: _format),
    );
    if (picked == null || !mounted) return;
    setState(() => _format = picked);
    await _downloader.rememberFormat(picked);
  }

  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => _SettingsSheet(
        autoDownload: _autoDownload,
        onAutoDownload: _setAutoDownload,
        wifiOnly: _wifiOnly,
        onWifiOnly: _setWifiOnly,
        version: _appInfo.version,
        fetchLatest: _updates.latest,
        openUrl: _appInfo.openUrl,
      ),
    );
  }

  Future<void> _openHistory() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const HistoryPage()),
    );
  }

  /// Tracks whose download ended in an error, in playlist order. They are what
  /// a second attempt is for; the ones that already saved are left alone.
  List<Track> get _failedTracks => (_link?.tracks ?? const <Track>[])
      .where((track) => _states[track.id] == 'failed')
      .toList(growable: false);

  void _retryFailed() {
    final failed = _failedTracks;
    if (failed.isEmpty || _busy) return;
    setState(() {
      _selected
        ..clear()
        ..addAll(failed.map((track) => track.id));
    });
    _downloadSelected();
  }

  Future<void> _downloadSelected({int attempt = 0}) async {
    final link = _link;
    if (link == null || _selected.isEmpty || _busy) return;
    // A restored queue can get here while the engines are still starting up.
    if (_ready != true) {
      await _prepare();
      if (_ready != true) return;
    }

    final tracks = link.tracks
        .where((track) => _selected.contains(track.id))
        .toList(growable: false);

    setState(() {
      _busy = true;
      _stopRequested = false;
      _cancelRequested = false;
      _startWhenVisible = false;
      _error = null;
      _busyDone = 0;
      _busyTotal = tracks.length;
      for (final track in tracks) {
        _states[track.id] = 'queued';
        _trackErrors.remove(track.id);
      }
    });

    // Written down before the queue is started and updated after each track, so
    // work Android interrupts — a refused service, a killed process — is picked
    // up on the next launch instead of waiting for the link to be pasted again.
    final remaining = tracks.map((track) => track.id).toList();
    await _store.savePendingQueue(
      PendingQueue(
        link: link,
        remaining: List<String>.of(remaining),
        format: _format.id,
      ),
    );

    // Wi-Fi-only: the record is already written, so the queue waits rather
    // than starting, and the next launch checks the connection again.
    if (_wifiOnly && !await _network.isWifi()) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _waitingForWifi = true;
        for (final track in tracks) {
          _states.remove(track.id);
        }
      });
      return;
    }

    var savedCount = 0;
    // Holds the phone awake for the whole queue, so the screen going off or
    // the app moving to the background does not pause it. Android 12+ only
    // allows this while the app is visible; if it refuses, nothing is
    // downloaded yet — the queue waits for the next resume.
    if (!await _downloader.startQueue(tracks.length)) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _startWhenVisible = true;
        for (final track in tracks) {
          _states.remove(track.id);
        }
      });
      _retryStart(attempt);
      return;
    }
    try {
      for (final track in tracks) {
        if (_stopRequested) break;
        // Wi-Fi dropping mid-queue pauses it here, between two files, rather
        // than finishing the rest over mobile data.
        if (_wifiOnly && !await _network.isWifi()) {
          await _pauseForWifi();
          if (!mounted || _stopRequested) break;
        }
        setState(() {
          _states[track.id] = 'downloading';
          _progress.remove(track.id);
        });
        try {
          final result = await _downloader.download(
            id: track.id,
            query: '${track.artists} - ${track.title}',
            title: track.title,
            artist: track.artists,
            duration: track.duration,
            name: _fileBaseName(track),
            format: _format,
            position: _busyDone + 1,
            total: tracks.length,
          );
          savedCount++;
          await _store.addSaved(
            SavedTrack(
              title: track.title,
              artist: track.artists,
              format: _format.shortLabel,
              bytes: result.size,
              savedAt: DateTime.now(),
              path: result.path,
            ),
          );
          if (!mounted) return;
          setState(() => _states[track.id] = 'done');
        } catch (error) {
          if (!mounted) return;
          setState(() {
            _states[track.id] = 'failed';
            _trackErrors[track.id] = error.toString();
          });
        }
        if (!mounted) return;
        setState(() => _busyDone++);
        remaining.remove(track.id);
        // A cancelled queue is not written down again: the next launch has
        // nothing to pick up.
        if (!_cancelRequested) {
          await _store.savePendingQueue(
            PendingQueue(
              link: link,
              remaining: List<String>.of(remaining),
              format: _format.id,
            ),
          );
        }
      }
    } finally {
      await _downloader.stopQueue(savedCount);
      // If the widget went away mid-queue the record stays, so the rest of the
      // queue is still downloaded on the next launch.
      if (mounted) await _store.clearPendingQueue();
    }

    if (!mounted) return;
    if (_cancelRequested) {
      _abandonQueue();
      return;
    }
    final failed =
        tracks.where((track) => _states[track.id] == 'failed').length;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          savedCount == 0
              ? 'Nothing was saved. See the error on each track.'
              : 'Saved $savedCount track${savedCount == 1 ? '' : 's'} to '
                  'Music/SpotifyGrabber'
                  '${failed > 0 ? ' · $failed failed' : ''}',
        ),
        action: SnackBarAction(label: 'History', onPressed: _openHistory),
      ),
    );
  }

  String _fileBaseName(Track track) {
    final raw = '${track.artists} - ${track.title}';
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]+'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final clipped =
        cleaned.length > 90 ? cleaned.substring(0, 90).trim() : cleaned;
    return clipped.isEmpty ? 'Spotify track' : clipped;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = _link;
    final tracks = link?.tracks ?? const <Track>[];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Spotify Grabber'),
        actions: [
          IconButton(
            tooltip: 'Settings',
            onPressed: _openSettings,
            icon: const Icon(Icons.tune_rounded),
          ),
          _ThemeMenu(mode: widget.themeMode, onChanged: widget.onThemeMode),
          IconButton(
            tooltip: 'Saved tracks',
            onPressed: _openHistory,
            icon: const Icon(Icons.history_rounded),
          ),
          const SizedBox(width: kSpace4),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            kSpace16,
            kSpace16,
            kSpace16,
            kSpace32,
          ),
          children: [
            _linkField(theme),
            if (_ready != true) ...[
              const SizedBox(height: kSpace12),
              _engineStatusLine(theme),
            ],
            if (_error != null) ...[
              const SizedBox(height: kSpace12),
              _Notice(
                icon: Icons.error_outline_rounded,
                message: _error!,
                tone: _NoticeTone.error,
              ),
            ] else if (_shareNotice != null) ...[
              const SizedBox(height: kSpace12),
              _Notice(
                icon: Icons.link_off_rounded,
                message: _shareNotice!,
              ),
            ] else if (_waitingForWifi || _wifiWait != null) ...[
              const SizedBox(height: kSpace12),
              _Notice(
                icon: Icons.wifi_off_rounded,
                message: 'Waiting for Wi-Fi. Nothing is downloaded on mobile '
                    'data.',
                action: _busy
                    ? null
                    : TextButton(
                        onPressed: _cancelQueue,
                        child: const Text('Cancel'),
                      ),
              ),
            ] else if (_startWhenVisible) ...[
              const SizedBox(height: kSpace12),
              _Notice(
                icon: Icons.downloading_rounded,
                message: 'Downloads start as soon as the app is back on screen.',
                action: TextButton(
                  onPressed: _cancelQueue,
                  child: const Text('Cancel'),
                ),
              ),
            ],
            if (_resolving) ...[
              const SizedBox(height: kSpace32),
              _fetching(theme),
            ] else if (link == null) ...[
              const SizedBox(height: kSpace32),
              _emptyState(theme),
            ] else ...[
              const SizedBox(height: kSpace24),
              _linkSummary(theme, link, tracks),
              const SizedBox(height: kSpace24),
              _formatRow(theme),
              const SizedBox(height: kSpace24),
              _tracksHeader(theme, tracks),
              const SizedBox(height: kSpace8),
              const Divider(),
              for (var i = 0; i < tracks.length; i++) ...[
                if (i > 0) const Divider(),
                _TrackRow(
                  track: tracks[i],
                  selected: _selected.contains(tracks[i].id),
                  state: _states[tracks[i].id],
                  progress: _progress[tracks[i].id],
                  error: _trackErrors[tracks[i].id],
                  locked: _busy,
                  onToggle: (value) {
                    setState(() {
                      if (value) {
                        _selected.add(tracks[i].id);
                      } else {
                        _selected.remove(tracks[i].id);
                      }
                    });
                    _rememberViewing();
                  },
                ),
              ],
            ],
          ],
        ),
      ),
      bottomNavigationBar: link == null ? null : _downloadBar(theme),
    );
  }

  Widget _linkField(ThemeData theme) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            enabled: !_busy,
            onSubmitted: (_) => _fetch(),
            style: theme.textTheme.bodyMedium,
            decoration: InputDecoration(
              hintText: 'Paste a Spotify link',
              prefixIcon: Icon(
                Icons.link_rounded,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              prefixIconConstraints: const BoxConstraints(minWidth: 42),
              suffixIcon: _urlHasText
                  ? IconButton(
                      tooltip: 'Clear link',
                      icon: const Icon(Icons.close_rounded, size: 18),
                      onPressed: _busy ? null : _clearLink,
                    )
                  : null,
            ),
          ),
        ),
        const SizedBox(width: kSpace8),
        FilledButton(
          onPressed: _resolving || _busy ? null : _fetch,
          child: _resolving
              ? const SizedBox(
                  height: 16,
                  width: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Fetch'),
        ),
      ],
    );
  }

  /// Only appears while the engine is starting or broken; a version string is
  /// not something the user needs once downloads work.
  Widget _engineStatusLine(ThemeData theme) {
    if (_ready == false) {
      return _Notice(
        icon: Icons.error_outline_rounded,
        message: _engineError ?? 'The downloader could not start.',
        tone: _NoticeTone.error,
        action: TextButton(
          onPressed: _prepare,
          child: const Text('Retry'),
        ),
      );
    }
    return Row(
      children: [
        const SizedBox(
          height: 13,
          width: 13,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        ),
        const SizedBox(width: kSpace8),
        Expanded(
          child: Text(
            _engineStatus,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  /// Spotify answers in a second or two; say what is happening meanwhile
  /// instead of leaving the screen looking empty.
  Widget _fetching(ThemeData theme) {
    return Row(
      children: [
        const SizedBox(
          height: 14,
          width: 14,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        ),
        const SizedBox(width: kSpace8),
        Text(
          'Fetching tracks from Spotify…',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Start with a Spotify link', style: theme.textTheme.titleSmall),
        const SizedBox(height: kSpace4),
        Text(
          'Paste one above, or share it from Spotify and pick Spotify '
          'Grabber. Tracks are saved to Music/SpotifyGrabber.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: kSpace16),
        FilledButton.tonal(
          onPressed: _busy ? null : _pasteFromClipboard,
          child: const Text('Paste from clipboard'),
        ),
      ],
    );
  }

  Widget _linkSummary(ThemeData theme, ResolvedLink link, List<Track> tracks) {
    final cover = link.coverUrl;
    final kind = switch (link.kind) {
      'track' => 'Track',
      'album' => 'Album',
      _ => 'Playlist',
    };
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(kSpace8),
          child: SizedBox(
            height: 64,
            width: 64,
            child: cover == null
                ? _coverFallback(theme)
                : Image.network(
                    cover,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _coverFallback(theme),
                  ),
          ),
        ),
        const SizedBox(width: kSpace12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                link.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall,
              ),
              const SizedBox(height: kSpace4),
              Text(
                '$kind · ${tracks.length} track${tracks.length == 1 ? '' : 's'}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _coverFallback(ThemeData theme) => Container(
        color: theme.colorScheme.surfaceContainerHigh,
        child: Icon(
          Icons.music_note_rounded,
          size: 24,
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );

  Widget _formatRow(ThemeData theme) {
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(kRadius),
      child: InkWell(
        onTap: _busy ? null : _pickFormat,
        borderRadius: BorderRadius.circular(kRadius),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(kSpace12, kSpace12, kSpace8, kSpace12),
          child: Row(
            children: [
              Text(
                'Format',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: kSpace12),
              Expanded(
                child: Text(
                  _format.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              Text(
                _format.shortSize,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tracksHeader(ThemeData theme, List<Track> tracks) {
    final allSelected =
        tracks.isNotEmpty && _selected.length == tracks.length;
    return Row(
      children: [
        Text(
          'Tracks',
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const Spacer(),
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  setState(() {
                    if (allSelected) {
                      _selected.clear();
                    } else {
                      _selected.addAll(tracks.map((track) => track.id));
                    }
                  });
                  _rememberViewing();
                },
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, 32),
          ),
          child: Text(allSelected ? 'Clear' : 'Select all'),
        ),
      ],
    );
  }

  Widget _downloadBar(ThemeData theme) {
    final canDownload =
        !_busy && !_resolving && _selected.isNotEmpty && _ready != false;
    final count = _selected.length;
    final failed = _failedTracks;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            kSpace16,
            kSpace12,
            kSpace16,
            kSpace12,
          ),
          child: _busy
              ? _progressBar(theme)
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: canDownload ? _downloadSelected : null,
                        child: Text(
                          count == 0
                              ? 'Select a track to download'
                              : 'Download $count track${count == 1 ? '' : 's'} · '
                                  '${_format.shortLabel}',
                        ),
                      ),
                    ),
                    if (failed.isNotEmpty) ...[
                      const SizedBox(height: kSpace4),
                      TextButton(
                        onPressed: _resolving ? null : _retryFailed,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          minimumSize: const Size(0, 32),
                        ),
                        child: Text(
                          'Retry ${failed.length} failed '
                          'track${failed.length == 1 ? '' : 's'}',
                        ),
                      ),
                    ],
                  ],
                ),
        ),
      ),
    );
  }

  Widget _progressBar(ThemeData theme) {
    final percent =
        _busyTotal == 0 ? 0 : (_busyDone * 100 / _busyTotal).round();
    final numberStyle = theme.textTheme.bodySmall?.copyWith(
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              'Downloading ${math.min(_busyDone + 1, _busyTotal)} of '
              '$_busyTotal',
              style: numberStyle,
            ),
            const Spacer(),
            Text('$percent%', style: numberStyle),
          ],
        ),
        const SizedBox(height: kSpace8),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: _busyTotal == 0 ? null : _busyDone / _busyTotal,
            minHeight: 3,
          ),
        ),
        const SizedBox(height: kSpace12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _stopRequested
                    ? null
                    : () {
                        setState(() => _stopRequested = true);
                        if (_wifiWait?.isCompleted == false) {
                          _wifiWait!.complete();
                        }
                      },
                child: Text(
                  _stopRequested
                      ? 'Finishing this track…'
                      : 'Stop after this track',
                ),
              ),
            ),
            const SizedBox(width: kSpace8),
            TextButton(
              onPressed: _cancelRequested ? null : _cancelQueue,
              child: const Text('Cancel'),
            ),
          ],
        ),
      ],
    );
  }
}

/// The choices that are about the app rather than about one link.
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.autoDownload,
    required this.onAutoDownload,
    required this.wifiOnly,
    required this.onWifiOnly,
    required this.version,
    required this.fetchLatest,
    required this.openUrl,
  });

  final bool autoDownload;
  final ValueChanged<bool> onAutoDownload;
  final bool wifiOnly;
  final ValueChanged<bool> onWifiOnly;
  final Future<AppVersion> Function() version;
  final Future<Update?> Function() fetchLatest;
  final Future<bool> Function(String url) openUrl;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late bool _autoDownload = widget.autoDownload;
  late bool _wifiOnly = widget.wifiOnly;
  AppVersion? _version;
  bool _checking = false;
  Update? _update;
  String? _updateMessage;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final version = await widget.version();
    if (!mounted) return;
    setState(() => _version = version);
  }

  /// Asks GitHub for the newest release and compares it with what is installed.
  Future<void> _check() async {
    setState(() {
      _checking = true;
      _update = null;
      _updateMessage = null;
    });
    try {
      final latest = await widget.fetchLatest();
      if (!mounted) return;
      if (latest == null) {
        setState(() {
          _checking = false;
          _updateMessage = 'No release to compare with yet.';
        });
        return;
      }
      final installed = _version ?? await widget.version();
      if (!mounted) return;
      final newer = isNewerVersion(latest.version, installed.name);
      setState(() {
        _checking = false;
        _version = installed;
        if (newer) {
          _update = latest;
        } else {
          _updateMessage = 'You are on the latest version.';
        }
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _updateMessage = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      // Scrollable: on a short screen, or with large text, the version and
      // update rows do not fit under the switches.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(kSpace16, 0, kSpace16, kSpace16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Settings', style: theme.textTheme.titleMedium),
            const SizedBox(height: kSpace8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _autoDownload,
              onChanged: (value) {
                setState(() => _autoDownload = value);
                widget.onAutoDownload(value);
              },
              title: Text('Auto-download', style: theme.textTheme.bodyLarge),
              subtitle: Text(
                'Start the queue as soon as a link is fetched or shared.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _wifiOnly,
              onChanged: (value) {
                setState(() => _wifiOnly = value);
                widget.onWifiOnly(value);
              },
              title: Text('Wi-Fi only', style: theme.textTheme.bodyLarge),
              subtitle: Text(
                'Never download on mobile data. A running queue waits for '
                'Wi-Fi instead.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            const Divider(height: kSpace32),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Version ${_version?.label ?? '…'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _checking ? null : _check,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    minimumSize: const Size(0, 32),
                  ),
                  child: Text(
                    _checking ? 'Checking…' : 'Check for updates',
                  ),
                ),
              ],
            ),
            if (_update != null) ...[
              const SizedBox(height: kSpace8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Version ${_update!.version} is available.',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                  FilledButton.tonal(
                    onPressed: () => widget.openUrl(_update!.url),
                    child: const Text('Get it'),
                  ),
                ],
              ),
            ] else if (_updateMessage != null) ...[
              const SizedBox(height: kSpace8),
              Text(
                _updateMessage!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ThemeMenu extends StatelessWidget {
  const _ThemeMenu({required this.mode, required this.onChanged});

  final ThemeMode mode;
  final ValueChanged<ThemeMode>? onChanged;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<ThemeMode>(
      tooltip: 'Appearance',
      icon: Icon(switch (mode) {
        ThemeMode.light => Icons.light_mode_rounded,
        ThemeMode.dark => Icons.dark_mode_rounded,
        ThemeMode.system => Icons.brightness_auto_rounded,
      }),
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (final (value, label) in const [
          (ThemeMode.system, 'Match system'),
          (ThemeMode.light, 'Light'),
          (ThemeMode.dark, 'Dark'),
        ])
          CheckedPopupMenuItem<ThemeMode>(
            value: value,
            checked: mode == value,
            child: Text(label),
          ),
      ],
    );
  }
}

class _TrackRow extends StatelessWidget {
  const _TrackRow({
    required this.track,
    required this.selected,
    required this.state,
    required this.progress,
    required this.error,
    required this.locked,
    required this.onToggle,
  });

  final Track track;
  final bool selected;
  final String? state;
  final double? progress;
  final String? error;
  final bool locked;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: locked ? null : () => onToggle(!selected),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(kSpace4, kSpace8, kSpace8, kSpace8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: selected,
              onChanged: locked ? null : (value) => onToggle(value ?? false),
            ),
            const SizedBox(width: kSpace8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${track.artists} · ${formatDuration(track.duration)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (state == 'failed' && error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: kSpace4),
                      child: Text(
                        error!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: kSpace8),
            SizedBox(height: 24, width: 24, child: _status(theme)),
          ],
        ),
      ),
    );
  }

  Widget _status(ThemeData theme) {
    switch (state) {
      case 'done':
        return const Icon(Icons.check_rounded, size: 20, color: kAccent);
      case 'failed':
        return Icon(
          Icons.error_outline_rounded,
          size: 20,
          color: theme.colorScheme.error,
        );
      case 'downloading':
        return Padding(
          padding: const EdgeInsets.all(2),
          child: CircularProgressIndicator(strokeWidth: 2, value: progress),
        );
      case 'queued':
        return Icon(
          Icons.schedule_rounded,
          size: 18,
          color: theme.colorScheme.outline,
        );
      default:
        return const SizedBox.shrink();
    }
  }
}

class _FormatSheet extends StatelessWidget {
  const _FormatSheet({required this.selected});

  final AudioFormat selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          kSpace16,
          0,
          kSpace16,
          kSpace16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Audio format', style: theme.textTheme.titleMedium),
            const SizedBox(height: kSpace4),
            Text(
              'Remembered for next time.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: kSpace12),
            for (final format in AudioFormat.all)
              _FormatOption(
                format: format,
                selected: format.id == selected.id,
                onTap: () => Navigator.of(context).pop(format),
              ),
          ],
        ),
      ),
    );
  }
}

class _FormatOption extends StatelessWidget {
  const _FormatOption({
    required this.format,
    required this.selected,
    required this.onTap,
  });

  final AudioFormat format;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(kRadius),
      child: Container(
        padding: const EdgeInsets.symmetric(
          vertical: kSpace8,
          horizontal: kSpace8,
        ),
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.surfaceContainerHigh : null,
          borderRadius: BorderRadius.circular(kRadius),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 22,
              width: 22,
              child: selected
                  ? const Icon(
                      Icons.check_circle_rounded,
                      size: 20,
                      color: kAccent,
                    )
                  : Icon(
                      Icons.circle_outlined,
                      size: 20,
                      color: theme.colorScheme.outlineVariant,
                    ),
            ),
            const SizedBox(width: kSpace8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          format.label,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (format.recommended) ...[
                        const SizedBox(width: kSpace8),
                        Text(
                          'default',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    format.tagline,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: kSpace4),
                  Text(
                    format.size,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _NoticeTone { neutral, error }

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.message,
    this.tone = _NoticeTone.neutral,
    this.action,
  });

  final IconData icon;
  final String message;
  final _NoticeTone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = tone == _NoticeTone.error;
    final background = error
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.surfaceContainerLow;
    final foreground =
        error ? theme.colorScheme.onErrorContainer : theme.colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        kSpace12,
        kSpace8,
        kSpace8,
        kSpace8,
      ),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(kRadius),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 18,
            color: error ? theme.colorScheme.onErrorContainer : foreground,
          ),
          const SizedBox(width: kSpace8),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(color: foreground),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}
