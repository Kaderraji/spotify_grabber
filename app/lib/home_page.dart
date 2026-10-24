import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'audio_format.dart';
import 'device_downloader.dart';
import 'models.dart';
import 'share_intake.dart';
import 'spotify_meta.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _urlController = TextEditingController();
  final DeviceDownloader _downloader = DeviceDownloader();
  final ShareIntake _share = ShareIntake();
  StreamSubscription<String>? _sharedLinks;
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
  String? _banner;
  int _busyDone = 0;
  int _busyTotal = 0;

  @override
  void initState() {
    super.initState();
    _events = _downloader.events.listen(_onEvent);
    _sharedLinks = _share.links.listen(_acceptShared);
    _prepare();
    _restoreFormat();
    _takeLaunchLink();
  }

  /// The app may have been opened by "Share → Spotify Grabber".
  Future<void> _takeLaunchLink() async {
    final link = await _share.launchLink();
    if (!mounted || link == null) return;
    _acceptShared(link);
  }

  /// Fills the field with a shared link and, when nothing is in flight, reads
  /// it straight away so the shared song is what the user sees.
  void _acceptShared(String link) {
    if (!mounted) return;
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
    _sharedLinks?.cancel();
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
        _error = null;
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
      setState(() => _urlController.text = text);
    }
  }

  Future<void> _fetch() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Paste a Spotify link first.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _resolving = true;
      _error = null;
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

    var saved = 0;
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
          await _downloader.download(
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
          saved++;
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
      await _downloader.stopQueue(saved);
    }

    if (!mounted) return;
    final failed = tracks.where((track) => _states[track.id] == 'failed').length;
    setState(() {
      _busy = false;
      _banner = saved == 0
          ? 'Nothing was saved — see the errors on each track.'
          : 'Saved $saved track${saved == 1 ? '' : 's'} to Music/SpotifyGrabber'
              '${failed > 0 ? ' · $failed failed' : ''}';
    });
    if (saved > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          content: Text(
            'Saved $saved track${saved == 1 ? '' : 's'} · ${_format.label}',
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
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          children: [
            _Header(
              ready: _ready,
              status: _engineStatus,
              version: _engineVersion,
              onRetry: _prepare,
            ),
            const SizedBox(height: 20),
            _linkCard(theme),
            if (_error != null) ...[
              const SizedBox(height: 14),
              _ErrorBanner(message: _error!),
            ],
            if (_banner != null) ...[
              const SizedBox(height: 14),
              _SavedBanner(message: _banner!),
            ],
            if (link == null) ...[
              const SizedBox(height: 20),
              const _HowItWorks(),
            ] else ...[
              const SizedBox(height: 18),
              _LinkSummary(
                link: link,
                selected: _selected.length,
                onAll: () => setState(() {
                  _selected
                    ..clear()
                    ..addAll(tracks.map((track) => track.id));
                }),
                onNone: () => setState(_selected.clear),
              ),
              const SizedBox(height: 12),
              _formatTile(theme),
              const SizedBox(height: 12),
              _trackList(theme, tracks),
            ],
          ],
        ),
      ),
      bottomNavigationBar: link == null ? null : _bottomBar(theme),
    );
  }

  Widget _linkCard(ThemeData theme) {
    return _Panel(
      padding: const EdgeInsets.fromLTRB(16, 6, 10, 10),
      child: Column(
        children: [
          TextField(
            controller: _urlController,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.go,
            enabled: !_busy,
            onSubmitted: (_) => _fetch(),
            style: theme.textTheme.bodyLarge,
            decoration: InputDecoration(
              hintText: 'Paste a Spotify track, album or playlist link',
              hintStyle: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              prefixIcon: const Icon(Icons.link_rounded, size: 20),
              suffixIcon: IconButton(
                tooltip: 'Paste from clipboard',
                icon: const Icon(Icons.content_paste_rounded, size: 20),
                onPressed: _busy ? null : _pasteFromClipboard,
              ),
              border: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 16),
            ),
          ),
          Row(
            children: [
              if (_link != null)
                TextButton(
                  onPressed: _busy ? null : _clearLink,
                  child: const Text('Clear'),
                ),
              const Spacer(),
              FilledButton.icon(
                onPressed: _resolving || _busy ? null : _fetch,
                icon: _resolving
                    ? const SizedBox(
                        height: 16,
                        width: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.arrow_forward_rounded, size: 20),
                label: Text(_resolving ? 'Reading link…' : 'Fetch tracks'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _formatTile(ThemeData theme) {
    return _Panel(
      padding: EdgeInsets.zero,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        onTap: _busy ? null : _pickFormat,
        leading: Container(
          height: 42,
          width: 42,
          decoration: BoxDecoration(
            color: theme.colorScheme.secondaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            _format.icon,
            size: 22,
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
        title: Text('Format · ${_format.label}',
            style: theme.textTheme.titleSmall),
        subtitle: Text(
          '${_format.size} · tap to change',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: const Icon(Icons.unfold_more_rounded, size: 20),
      ),
    );
  }

  Widget _trackList(ThemeData theme, List<Track> tracks) {
    return _Panel(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          for (var i = 0; i < tracks.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                indent: 16,
                endIndent: 16,
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
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
      ),
    );
  }

  Widget _bottomBar(ThemeData theme) {
    final canDownload = !_busy &&
        !_resolving &&
        _selected.isNotEmpty &&
        _ready != false;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6),
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_busy) ...[
                Row(
                  children: [
                    Text(
                      'Downloading ${math.min(_busyDone + 1, _busyTotal)} of '
                      '$_busyTotal',
                      style: theme.textTheme.bodySmall,
                    ),
                    const Spacer(),
                    Text(
                      '${_busyTotal == 0 ? 0 : (_busyDone * 100 / _busyTotal).round()}%',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: LinearProgressIndicator(
                    value: _busyTotal == 0 ? null : _busyDone / _busyTotal,
                    minHeight: 6,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _stopRequested
                        ? null
                        : () => setState(() => _stopRequested = true),
                    icon: Icon(
                      _stopRequested
                          ? Icons.hourglass_top_rounded
                          : Icons.stop_rounded,
                      size: 20,
                    ),
                    label: Text(
                      _stopRequested
                          ? 'Finishing this track…'
                          : 'Stop after this track',
                    ),
                  ),
                ),
              ] else
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton.icon(
                    onPressed: canDownload ? _downloadSelected : null,
                    icon: const Icon(Icons.download_rounded, size: 20),
                    label: Text(
                      _selected.isEmpty
                          ? 'Select tracks to download'
                          : 'Download ${_selected.length} · ${_format.shortLabel}',
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.ready,
    required this.status,
    required this.version,
    required this.onRetry,
  });

  final bool? ready;
  final String status;
  final String version;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pillColor = ready == false
        ? theme.colorScheme.errorContainer
        : theme.colorScheme.surfaceContainerHigh;
    final dotColor = ready == true
        ? const Color(0xFF1DB954)
        : ready == false
            ? theme.colorScheme.error
            : theme.colorScheme.tertiary;

    final label = ready == true
        ? 'On this phone · yt-dlp ${version.isEmpty ? 'ready' : version.split('.').take(3).join('.')}'
        : status;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              height: 46,
              width: 46,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFF25D366), Color(0xFF128C3E)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.graphic_eq_rounded,
                color: Colors.white,
                size: 26,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Spotify Grabber',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                    ),
                  ),
                  Text(
                    'Songs land in your music library',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          decoration: BoxDecoration(
            color: pillColor,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: 8,
                width: 8,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: ready == false
                        ? theme.colorScheme.onErrorContainer
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (ready == false)
                TextButton(
                  onPressed: onRetry,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  child: const Text('Retry'),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _LinkSummary extends StatelessWidget {
  const _LinkSummary({
    required this.link,
    required this.selected,
    required this.onAll,
    required this.onNone,
  });

  final ResolvedLink link;
  final int selected;
  final VoidCallback onAll;
  final VoidCallback onNone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = link.coverUrl;
    return _Panel(
      child: Column(
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  height: 72,
                  width: 72,
                  child: cover == null
                      ? Container(
                          color: theme.colorScheme.surfaceContainerHighest,
                          child: const Icon(Icons.music_note_rounded),
                        )
                      : Image.network(
                          cover,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.music_note_rounded),
                          ),
                        ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      link.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${link.kind} · ${link.tracks.length} '
                      'track${link.tracks.length == 1 ? '' : 's'} · '
                      '$selected selected',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerRight,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(
                  onPressed: onAll,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('Select all'),
                ),
                TextButton(
                  onPressed: onNone,
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  child: const Text('None'),
                ),
              ],
            ),
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
        padding: const EdgeInsets.fromLTRB(6, 6, 16, 6),
        child: Row(
          children: [
            Checkbox(
              value: selected,
              onChanged: locked ? null : (value) => onToggle(value ?? false),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
            ),
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
            const SizedBox(width: 10),
            _status(context),
          ],
        ),
      ),
    );
  }

  Widget _status(BuildContext context) {
    final theme = Theme.of(context);
    switch (state) {
      case 'done':
        return const Icon(
          Icons.check_circle_rounded,
          color: Color(0xFF1DB954),
          size: 22,
        );
      case 'failed':
        return Tooltip(
          message: error ?? 'Download failed',
          triggerMode: TooltipTriggerMode.tap,
          child: Icon(
            Icons.error_rounded,
            color: theme.colorScheme.error,
            size: 22,
          ),
        );
      case 'downloading':
        return SizedBox(
          height: 24,
          width: 24,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                strokeWidth: 2.5,
                value: progress,
                backgroundColor:
                    theme.colorScheme.surfaceContainerHighest,
              ),
            ],
          ),
        );
      case 'queued':
        return Icon(
          Icons.schedule_rounded,
          size: 20,
          color: theme.colorScheme.onSurfaceVariant,
        );
      default:
        return Icon(
          Icons.circle_outlined,
          size: 20,
          color: theme.colorScheme.outlineVariant,
        );
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
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Audio format',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Picked once, remembered for next time.',
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: selected
            ? theme.colorScheme.secondaryContainer
            : theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 16, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 40,
                  width: 40,
                  decoration: BoxDecoration(
                    color: selected
                        ? theme.colorScheme.surface
                        : theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(format.icon, size: 21),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              format.label,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (format.recommended) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primaryContainer,
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                'Default',
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color:
                                      theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        format.tagline,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        format.size,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.circle_outlined,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  const _HowItWorks();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    const steps = <(IconData, String, String)>[
      (
        Icons.copy_rounded,
        'Copy a link in Spotify',
        'Tap ••• → Share → Copy link on any song, album or playlist.',
      ),
      (
        Icons.tune_rounded,
        'Pick a format',
        'M4A by default; MP3, Opus or FLAC if you prefer.',
      ),
      (
        Icons.phone_android_rounded,
        'Download on the phone',
        'Files are saved to Music/SpotifyGrabber — no PC involved.',
      ),
    ];

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'How it works',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          for (final (icon, title, body) in steps)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 20, color: theme.colorScheme.primary),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(title, style: theme.textTheme.bodyMedium),
                        Text(
                          body,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          Text(
            'Audio comes from YouTube, so a track has to exist there. Spotify '
            'metadata stays exact; artist and title tags are written into the file.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.child, this.padding});

  final Widget child;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: child,
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.error_outline_rounded,
            size: 20,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SavedBanner extends StatelessWidget {
  const _SavedBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.library_music_rounded,
            size: 20,
            color: theme.colorScheme.onSecondaryContainer,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
