import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'api.dart';
import 'settings_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.serverUrl,
    required this.onServerChanged,
  });

  final String serverUrl;
  final ValueChanged<String> onServerChanged;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final TextEditingController _urlController = TextEditingController();
  final Set<String> _selected = <String>{};

  ResolvedLink? _link;
  JobInfo? _job;
  Timer? _poller;

  bool _loading = false;
  bool _saving = false;
  bool _phoneOnly = true;
  String? _error;
  String? _savedPath;
  int _savedCount = 0;
  int _removedFromPc = 0;

  @override
  void dispose() {
    _poller?.cancel();
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
    _poller?.cancel();
    setState(() {
      _loading = true;
      _error = null;
      _link = null;
      _job = null;
      _savedPath = null;
      _savedCount = 0;
      _selected.clear();
    });

    try {
      final link = await GrabberApi(widget.serverUrl).resolve(url);
      if (!mounted) return;
      setState(() {
        _link = link;
        _selected.addAll(
          link.tracks.where((t) => !t.isDownloaded).map((t) => t.id),
        );
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _startDownload() async {
    final link = _link;
    if (link == null || _selected.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _savedPath = null;
    });
    try {
      final job = await GrabberApi(widget.serverUrl)
          .createJob(link.url, _selected.toList(), phoneOnly: _phoneOnly);
      if (!mounted) return;
      setState(() {
        _job = job;
        _loading = false;
      });
      _startPolling();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  void _startPolling() {
    _poller?.cancel();
    _poller = Timer.periodic(const Duration(seconds: 2), (_) => _refreshJob());
    _refreshJob();
  }

  Future<void> _refreshJob() async {
    final job = _job;
    if (job == null) return;
    try {
      final fresh = await GrabberApi(widget.serverUrl).job(job.id);
      if (!mounted) return;
      setState(() => _job = fresh);
      if (fresh.isFinished) {
        _poller?.cancel();
      }
    } catch (_) {
      // Keep polling: a single failed poll usually means the phone lost Wi-Fi
      // for a moment, not that the download stopped.
    }
  }

  Future<void> _copyToPhone() async {
    final job = _job;
    final link = _link;
    if (job == null || link == null) return;

    final ready = job.ready;
    if (ready.isEmpty) {
      setState(() => _error = 'Nothing on the PC finished downloading yet.');
      return;
    }

    setState(() {
      _saving = true;
      _savedCount = 0;
      _removedFromPc = 0;
      _error = null;
      _savedPath = null;
    });

    try {
      final base = await getExternalStorageDirectory();
      if (base == null) {
        throw ApiException('This device has no writable storage for the app.');
      }
      final folder = Directory(
        '${base.path}/spotify_grabber/${_safeName(link.title)}',
      );
      final api = GrabberApi(widget.serverUrl);

      var copied = 0;
      for (final track in ready) {
        await api.saveFile(
          jobId: job.id,
          trackId: track.id,
          target: File('${folder.path}/${track.file}'),
        );
        copied++;
        if (!mounted) return;
        setState(() => _savedCount = copied);
      }

      var removed = 0;
      if (job.phoneOnly) {
        removed = await api.release(job.id);
      }

      if (!mounted) return;
      setState(() {
        _saving = false;
        _savedPath = folder.path;
        _removedFromPc = removed;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            job.phoneOnly
                ? 'Copied $copied file(s) to the phone, removed $removed from the PC'
                : 'Copied $copied file(s) to the phone',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error.toString();
      });
    }
  }

  String _safeName(String text) {
    final cleaned = text.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    final trimmed = cleaned.replaceAll(RegExp(r'^[._-]+|[._-]+$'), '');
    return trimmed.isEmpty ? 'playlist' : trimmed;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = _link;
    final job = _job;
    final tracks = job?.tracks ?? link?.tracks ?? const <Track>[];
    final finished = job?.isFinished ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Spotify Grabber'),
        actions: [
          IconButton(
            tooltip: 'Server settings',
            icon: const Icon(Icons.settings),
            onPressed: () async {
              final updated = await Navigator.of(context).push<String>(
                MaterialPageRoute(
                  builder: (_) => SettingsPage(serverUrl: widget.serverUrl),
                ),
              );
              if (updated != null) {
                widget.onServerChanged(updated);
                setState(() {
                  _link = null;
                  _job = null;
                  _error = null;
                });
              }
            },
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
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
                    onPressed: _loading ? null : _fetch,
                    icon: _loading
                        ? const SizedBox(
                            height: 16,
                            width: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search),
                    label: Text(_loading ? 'Reading link…' : 'Fetch tracks'),
                  ),
                ),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () {
                    _poller?.cancel();
                    _urlController.clear();
                    setState(() {
                      _link = null;
                      _job = null;
                      _error = null;
                      _savedPath = null;
                      _selected.clear();
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
            if (link != null) ...[
              const SizedBox(height: 20),
              _LinkHeader(link: link, selected: _selected.length),
              const SizedBox(height: 8),
              _TrackList(
                tracks: tracks,
                selected: _selected,
                locked: job != null,
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
              if (job == null) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _phoneOnly,
                  onChanged: (value) => setState(() => _phoneOnly = value),
                  title: const Text('Phone only'),
                  subtitle: const Text(
                    'Delete each file from the PC once it is copied to this phone. '
                    'Turn off to keep a copy in the PC library too.',
                  ),
                ),
                const SizedBox(height: 8),
              ],
              const SizedBox(height: 8),
              if (job == null)
                FilledButton.icon(
                  onPressed: _selected.isEmpty || _loading ? null : _startDownload,
                  icon: const Icon(Icons.download),
                  label: Text(
                    _selected.isEmpty
                        ? 'Nothing selected'
                        : 'Download ${_selected.length} track(s) to the PC',
                  ),
                ),
            ],
            if (job != null) ...[
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _statusLine(job),
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        value: job.total == 0 ? 0 : (job.done + job.failed) / job.total,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${job.done} downloaded · ${job.failed} failed · '
                        '${job.total} total',
                        style: theme.textTheme.bodySmall,
                      ),
                      if (job.status == 'running' || job.status == 'queued')
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text(
                            'Keep the app open. Files are saved on the PC.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (finished) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _saving ? null : _copyToPhone,
                  icon: _saving
                      ? const SizedBox(
                          height: 16,
                          width: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.phone_android),
                  label: Text(
                    _saving
                        ? 'Copying $_savedCount of ${job.ready.length}…'
                        : 'Copy ${job.ready.length} file(s) to this phone',
                  ),
                ),
              ],
              if (_savedPath != null) ...[
                const SizedBox(height: 12),
                Card(
                  color: theme.colorScheme.secondaryContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Saved $_savedCount file(s) on this phone',
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          _savedPath!,
                          style: theme.textTheme.bodySmall,
                        ),
                        if (_removedFromPc > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              'Removed $_removedFromPc file(s) from the PC.',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              if (job.tracks.any((t) => t.isFailed)) ...[
                const SizedBox(height: 16),
                Text('Could not download', style: theme.textTheme.titleSmall),
                const SizedBox(height: 4),
                for (final track in job.tracks.where((t) => t.isFailed))
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      '${track.artists} – ${track.title}: ${track.error ?? 'no match found'}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  String _statusLine(JobInfo job) {
    switch (job.status) {
      case 'queued':
        return 'Waiting for the server…';
      case 'running':
        return 'Downloading on the PC…';
      case 'done':
        return job.failed == 0 ? 'All done' : 'Finished with some failures';
      case 'failed':
        return 'Download failed';
      default:
        return job.status;
    }
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

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
                '$selected selected'
                '${link.alreadyDownloaded > 0 ? ' · ${link.alreadyDownloaded} already on PC' : ''}',
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
    required this.locked,
    required this.onToggle,
  });

  final List<Track> tracks;
  final Set<String> selected;
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
            value: track.isDownloaded || selected.contains(track.id),
            onChanged: locked || track.isDownloaded
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
    if (track.isDownloaded) {
      return const Icon(Icons.check_circle, color: Colors.green);
    }
    if (track.isFailed) {
      return Icon(Icons.error, color: Theme.of(context).colorScheme.error);
    }
    if (track.state == 'downloading') {
      return const SizedBox(
        height: 18,
        width: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    return null;
  }
}
