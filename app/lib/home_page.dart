import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_theme.dart';
import 'audio_format.dart';
import 'device_downloader.dart';
import 'history_page.dart';
import 'models.dart';
import 'share_intake.dart';
import 'spotify_meta.dart';
import 'store.dart';

// TEMPORARY: drives a download without a tap while testing on the phone.
const _autostart = true;

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.themeMode = ThemeMode.system, this.onThemeMode});

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeMode;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _urlController = TextEditingController();
  final DeviceDownloader _downloader = DeviceDownloader();
  final ShareIntake _share = ShareIntake();
  final Store _store = Store();
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
  bool? _ready;
  String _engineStatus = 'Starting downloader…';
  String _engineVersion = '';
  String? _error;
  String? _shareNotice;
  String? _banner;
  int _busyDone = 0;
  int _busyTotal = 0;

  @override
  void initState() {
    super.initState();
    _events = _downloader.events.listen(_onEvent);
    _sharedEvents = _share.events.listen(_applyShare);
    _prepare();
    _restoreFormat();
    _takeLaunchShare();
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
            'from Spotify’s ••• menu and paste it here.';
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

  @override
  void dispose() {
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

  Future<void> _prepare() async {
    setState(() {
      _ready = null;
      _engineStatus = 'Starting downloader…';
    });
    try {
      final version = await _downloader.prepare();
      if (!mounted) return;
      setState(() {
        _ready = true;
        _engineVersion = version;
        _engineStatus = 'Ready';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _ready = false;
        _engineStatus = 'Downloader unavailable';
        _error = error.toString();
      });
    }
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
      _banner = null;
      _link = null;
      _selected.clear();
      _states.clear();
      _progress.clear();
      _trackErrors.clear();
    });
    try {
      final link = await resolveSpotifyLink(url);
      if (!mounted) return;
      setState(() {
        _link = link;
        _selected.addAll(link.tracks.map((track) => track.id));
        _resolving = false;
      });
      if (_autostart) _downloadSelected();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _error = error.toString();
      });
    }
  }

  void _clearLink() {
    _urlController.clear();
    setState(() {
      _link = null;
      _error = null;
      _shareNotice = null;
      _banner = null;
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

  Future<void> _openHistory() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const HistoryPage()),
    );
  }

  Future<void> _downloadSelected() async {
    final link = _link;
    if (link == null || _selected.isEmpty || _busy) return;
    if (_ready == false) {
      await _prepare();
      if (_ready != true) return;
    }

    final tracks = link.tracks
        .where((track) => _selected.contains(track.id))
        .toList(growable: false);

    setState(() {
      _busy = true;
      _stopRequested = false;
      _banner = null;
      _error = null;
      _busyDone = 0;
      _busyTotal = tracks.length;
      for (final track in tracks) {
        _states[track.id] = 'queued';
        _trackErrors.remove(track.id);
      }
    });

    var savedCount = 0;
    // Holds the phone awake for the whole queue, so the screen going off or
    // the app moving to the background does not pause it.
    await _downloader.startQueue(tracks.length);
    try {
      for (final track in tracks) {
        if (_stopRequested) break;
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
      }
    } finally {
      await _downloader.stopQueue(savedCount);
    }

    if (!mounted) return;
    final failed = tracks.where((track) => _states[track.id] == 'failed').length;
    setState(() {
      _busy = false;
      _banner = savedCount == 0
          ? 'Nothing was saved — see the errors on each track.'
          : 'Saved $savedCount track${savedCount == 1 ? '' : 's'} to '
              'Music/SpotifyGrabber'
              '${failed > 0 ? ' · $failed failed' : ''}';
    });
    if (savedCount > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Saved $savedCount track${savedCount == 1 ? '' : 's'} · ${_format.label}',
          ),
        ),
      );
    }
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
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _TopBar(
              themeMode: widget.themeMode,
              onThemeMode: widget.onThemeMode,
              onHistory: _openHistory,
            ),
            const Divider(),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  _linkField(theme),
                  const SizedBox(height: 10),
                  _statusLine(theme),
                  if (_shareNotice != null) ...[
                    const SizedBox(height: 14),
                    _Notice(
                      icon: Icons.link_off_rounded,
                      message: _shareNotice!,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 14),
                    _Notice(
                      icon: Icons.error_outline_rounded,
                      message: _error!,
                      tone: _NoticeTone.error,
                    ),
                  ],
                  if (_banner != null) ...[
                    const SizedBox(height: 14),
                    _Notice(
                      icon: Icons.library_music_rounded,
                      message: _banner!,
                      action: TextButton(
                        onPressed: _openHistory,
                        child: const Text('History'),
                      ),
                    ),
                  ],
                  if (link == null) ...[
                    const SizedBox(height: 28),
                    _emptyState(theme),
                  ] else ...[
                    const SizedBox(height: 28),
                    _linkSummary(theme, link, tracks),
                    const SizedBox(height: 20),
                    _formatRow(theme),
                    const SizedBox(height: 12),
                    _selectionRow(theme, tracks),
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
                        },
                      ),
                    ],
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: link == null ? null : _bottomBar(theme),
    );
  }

  Widget _linkField(ThemeData theme) {
    final canFetch = !_resolving && !_busy;
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
              prefixIcon: const Icon(Icons.link_rounded, size: 20),
              prefixIconConstraints: const BoxConstraints(minWidth: 40),
              suffixIcon: _link == null
                  ? IconButton(
                      tooltip: 'Paste from clipboard',
                      icon: const Icon(Icons.content_paste_rounded, size: 20),
                      onPressed: _busy ? null : _pasteFromClipboard,
                    )
                  : IconButton(
                      tooltip: 'Clear link',
                      icon: const Icon(Icons.close_rounded, size: 20),
                      onPressed: _busy ? null : _clearLink,
                    ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.tonal(
          onPressed: canFetch ? _fetch : null,
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

  Widget _statusLine(ThemeData theme) {
    final failed = _ready == false;
    final label = switch (_ready) {
      true => 'yt-dlp ${_engineVersion.isEmpty ? 'ready' : _engineVersion.split('.').take(3).join('.')}'
          ' · on this phone',
      false => 'Downloader unavailable',
      null => _engineStatus,
    };
    return Row(
      children: [
        Container(
          height: 6,
          width: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: failed
                ? theme.colorScheme.error
                : _ready == true
                    ? kAccent
                    : theme.colorScheme.outline,
          ),
        ),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (failed)
          TextButton(
            onPressed: _prepare,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              minimumSize: const Size(0, 32),
            ),
            child: const Text('Retry'),
          ),
      ],
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Nothing loaded', style: theme.textTheme.titleSmall),
        const SizedBox(height: 4),
        Text(
          'Paste a link above, or share one from Spotify and pick '
          'Spotify Grabber.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: _busy ? null : _pasteFromClipboard,
          icon: const Icon(Icons.content_paste_rounded, size: 18),
          label: const Text('Paste from clipboard'),
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
          ),
        ),
      ],
    );
  }

  Widget _linkSummary(ThemeData theme, ResolvedLink link, List<Track> tracks) {
    final cover = link.coverUrl;
    final kind = link.kind == 'track'
        ? 'Track'
        : link.kind == 'album'
            ? 'Album'
            : 'Playlist';
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 56,
            width: 56,
            child: cover == null
                ? _coverFallback(theme)
                : Image.network(
                    cover,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => _coverFallback(theme),
                  ),
          ),
        ),
        const SizedBox(width: 12),
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
              const SizedBox(height: 3),
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
    return InkWell(
      onTap: _busy ? null : _pickFormat,
      borderRadius: BorderRadius.circular(kRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            Text(
              'Format',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 10),
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
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right_rounded,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectionRow(ThemeData theme, List<Track> tracks) {
    return Row(
      children: [
        Text(
          '${_selected.length} of ${tracks.length} selected',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        const Spacer(),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                    _selected
                      ..clear()
                      ..addAll(tracks.map((track) => track.id));
                  }),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, 36),
          ),
          child: const Text('All'),
        ),
        TextButton(
          onPressed: _busy ? null : () => setState(_selected.clear),
          style: TextButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, 36),
          ),
          child: const Text('None'),
        ),
      ],
    );
  }

  Widget _bottomBar(ThemeData theme) {
    final canDownload =
        !_busy && !_resolving && _selected.isNotEmpty && _ready != false;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: _busy
              ? _progressBar(theme)
              : SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton(
                    onPressed: canDownload ? _downloadSelected : null,
                    child: Text(
                      _selected.isEmpty
                          ? 'Select a track to download'
                          : 'Download ${_selected.length} · '
                              '${_format.shortLabel}',
                    ),
                  ),
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
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: _busyTotal == 0 ? null : _busyDone / _busyTotal,
            minHeight: 3,
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _stopRequested
                ? null
                : () => setState(() => _stopRequested = true),
            child: Text(
              _stopRequested
                  ? 'Finishing this track…'
                  : 'Stop after this track',
            ),
          ),
        ),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.themeMode,
    required this.onThemeMode,
    required this.onHistory,
  });

  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeMode;
  final VoidCallback onHistory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
      child: Row(
        children: [
          Text('Spotify Grabber', style: theme.textTheme.titleMedium),
          const Spacer(),
          PopupMenuButton<ThemeMode>(
            tooltip: 'Theme',
            icon: Icon(switch (themeMode) {
              ThemeMode.light => Icons.light_mode_rounded,
              ThemeMode.dark => Icons.dark_mode_rounded,
              ThemeMode.system => Icons.brightness_auto_rounded,
            }),
            onSelected: onThemeMode,
            itemBuilder: (context) => [
              for (final (mode, label) in const [
                (ThemeMode.system, 'System'),
                (ThemeMode.light, 'Light'),
                (ThemeMode.dark, 'Dark'),
              ])
                CheckedPopupMenuItem<ThemeMode>(
                  value: mode,
                  checked: themeMode == mode,
                  child: Text(label),
                ),
            ],
          ),
          IconButton(
            tooltip: 'Saved tracks',
            onPressed: onHistory,
            icon: const Icon(Icons.history_rounded),
          ),
        ],
      ),
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
        padding: const EdgeInsets.fromLTRB(4, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Checkbox(
              value: selected,
              onChanged: locked ? null : (value) => onToggle(value ?? false),
            ),
            const SizedBox(width: 4),
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
                    ),
                  ),
                  if (state == 'failed' && error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
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
            const SizedBox(width: 8),
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
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Audio format', style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              'Remembered for next time.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
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
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
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
                  ? const Icon(Icons.check_circle_rounded,
                      size: 20, color: kAccent)
                  : Icon(
                      Icons.circle_outlined,
                      size: 20,
                      color: theme.colorScheme.outlineVariant,
                    ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(format.label,
                            style: theme.textTheme.titleSmall),
                      ),
                      if (format.recommended) ...[
                        const SizedBox(width: 8),
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
                  const SizedBox(height: 4),
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
    final background =
        error ? theme.colorScheme.errorContainer : theme.colorScheme.surfaceContainerLow;
    final foreground =
        error ? theme.colorScheme.onErrorContainer : theme.colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(kRadius),
        border: error
            ? null
            : Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(
            icon,
            size: 18,
            color: error ? theme.colorScheme.onErrorContainer : foreground,
          ),
          const SizedBox(width: 10),
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
