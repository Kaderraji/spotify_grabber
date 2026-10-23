import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'device_downloader.dart';
import 'models.dart';
import 'spotify_meta.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _urlController = TextEditingController();
  final DeviceDownloader _downloader = DeviceDownloader();
  final Set<String> _selected = <String>{};

  StreamSubscription<Map<String, dynamic>>? _events;
  ResolvedLink? _link;

  /// Per-track state: 'downloading', 'done' or 'failed'. Missing means idle.
  final Map<String, String> _states = <String, String>{};
  final Map<String, double> _progress = <String, double>{};
  final Map<String, String> _trackErrors = <String, String>{};

  bool _resolving = false;
  bool _busy = false;
  bool _stopRequested = false;
  bool? _ready;
  String _engineStatus = 'Starting downloader…';
  String _engineVersion = '';
  String? _error;
  String? _banner;

  @override
  void initState() {
    super.initState();
    _events = _downloader.events.listen(_onEvent);
    _prepare();
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

  @override
  void dispose() {
    _events?.cancel();
    _urlController.dispose();
    super.dispose();
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

  Future<void> _downloadSelected() async {
    final link = _link;
    if (link == null || _selected.isEmpty || _busy) return;
    if (_ready == false) {
      await _prepare();
      if (_ready != true) return;
    }

    final ids = link.tracks
        .where((track) => _selected.contains(track.id))
        .map((track) => track.id)
        .toList();

    setState(() {
      _busy = true;
      _stopRequested = false;
      _banner = null;
      _error = null;
      for (final id in ids) {
        _states[id] = 'queued';
        _trackErrors.remove(id);
      }
    });

    var saved = 0;
    for (final id in ids) {
      if (_stopRequested) break;
      final track = link.tracks.firstWhere((item) => item.id == id);
      setState(() {
        _states[id] = 'downloading';
        _progress.remove(id);
      });
      try {
        await _downloader.download(
          id: id,
          query: '${track.artists} - ${track.title}',
          title: track.title,
          artist: track.artists,
          duration: track.duration,
          name: _fileBaseName(track),
        );
        saved++;
        if (!mounted) return;
        setState(() => _states[id] = 'done');
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _states[id] = 'failed';
          _trackErrors[id] = error.toString();
        });
      }
    }

    if (!mounted) return;
    final failed = ids.where((id) => _states[id] == 'failed').length;
    setState(() {
      _busy = false;
      _banner = saved == 0
          ? 'Nothing was saved. Check the errors below.'
          : 'Saved $saved track(s) to Music/SpotifyGrabber'
              '${failed > 0 ? ' · $failed failed' : ''}';
    });
    if (saved > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved $saved track(s) to Music/SpotifyGrabber'),
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

    return Scaffold(
      appBar: AppBar(title: const Text('Spotify Grabber')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _engineBanner(theme),
            const SizedBox(height: 12),
            TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _fetch(),
              decoration: InputDecoration(
                labelText: 'Spotify link',
                hintText: 'Track, album or playlist',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste),
                  onPressed: _pasteFromClipboard,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _resolving || _busy ? null : _fetch,
                    icon: _resolving
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    label: Text(_resolving ? 'Reading link…' : 'Fetch tracks'),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: _busy
                      ? null
                      : () {
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
                        },
                  child: const Text('Clear'),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _ErrorBanner(message: _error!),
            ],
            if (_banner != null) ...[
              const SizedBox(height: 12),
              Card(
                color: theme.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.library_music,
                        color: theme.colorScheme.onSecondaryContainer,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _banner!,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (link != null) ...[
              const SizedBox(height: 20),
              _LinkHeader(link: link, selected: _selected.length),
              const SizedBox(height: 8),
              _TrackList(
                tracks: link.tracks,
                selected: _selected,
                states: _states,
                progress: _progress,
                errors: _trackErrors,
                locked: _busy,
                onToggle: (id, value) {
                  setState(() {
                    if (value) {
                      _selected.add(id);
                    } else {
                      _selected.remove(id);
                    }
                  });
                },
              ),
              const SizedBox(height: 8),
              if (_busy)
                OutlinedButton.icon(
                  onPressed: _stopRequested
                      ? null
                      : () => setState(() => _stopRequested = true),
                  icon: _stopRequested
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.stop_circle_outlined),
                  label: Text(
                    _stopRequested ? 'Stopping…' : 'Stop after this track',
                  ),
                )
              else
                FilledButton.icon(
                  onPressed: _selected.isEmpty ? null : _downloadSelected,
                  icon: const Icon(Icons.download),
                  label: Text(
                    _selected.isEmpty
                        ? 'Nothing selected'
                        : 'Download ${_selected.length} track(s) to this phone',
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                'Files are saved to Music/SpotifyGrabber on this phone.',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _engineBanner(ThemeData theme) {
    final down = _ready == false;
    if (down) {
      return _ErrorBanner(
        message: 'Downloader failed: $_error',
        action: TextButton(
          onPressed: _prepare,
          child: const Text('Retry'),
        ),
      );
    }
    final ready = _ready == true;
    return Row(
      children: [
        Icon(
          ready ? Icons.check_circle : Icons.sync,
          size: 16,
          color: ready ? Colors.green : theme.colorScheme.primary,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            ready
                ? 'Phone downloader ready'
                    '${_engineVersion.isEmpty ? '' : ' · yt-dlp $_engineVersion'}'
                : _engineStatus,
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message, this.action});

  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
            if (action != null) action!,
          ],
        ),
      ),
    );
  }
}

class _LinkHeader extends StatelessWidget {
  const _LinkHeader({required this.link, required this.selected});

  final ResolvedLink link;
  final int selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cover = link.coverUrl;
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: 64,
            width: 64,
            child: cover == null
                ? Container(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.music_note),
                  )
                : Image.network(
                    cover,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.music_note),
                    ),
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
                style: theme.textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              Text(
                '${link.kind} · ${link.tracks.length} track(s) · '
                '$selected selected',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TrackList extends StatelessWidget {
  const _TrackList({
    required this.tracks,
    required this.selected,
    required this.states,
    required this.progress,
    required this.errors,
    required this.locked,
    required this.onToggle,
  });

  final List<Track> tracks;
  final Set<String> selected;
  final Map<String, String> states;
  final Map<String, double> progress;
  final Map<String, String> errors;
  final bool locked;
  final void Function(String id, bool value) onToggle;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final track in tracks)
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: selected.contains(track.id),
            onChanged: locked
                ? null
                : (value) => onToggle(track.id, value ?? false),
            title: Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            subtitle: Text(
              '${track.artists} · ${formatDuration(track.duration)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            secondary: _stateIcon(context, track),
          ),
      ],
    );
  }

  Widget? _stateIcon(BuildContext context, Track track) {
    final theme = Theme.of(context);
    final state = states[track.id];
    if (state == 'done') {
      return const Icon(Icons.check_circle, color: Colors.green);
    }
    if (state == 'failed') {
      return Tooltip(
        message: errors[track.id] ?? 'Download failed',
        triggerMode: TooltipTriggerMode.tap,
        child: Icon(Icons.error, color: theme.colorScheme.error),
      );
    }
    if (state == 'downloading' || state == 'queued') {
      final value = progress[track.id];
      return SizedBox(
        height: 20,
        width: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: state == 'downloading' ? value : null,
        ),
      );
    }
    return null;
  }
}
