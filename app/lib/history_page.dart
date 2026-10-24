import 'package:flutter/material.dart';

import 'store.dart';

/// Everything the app saved to the phone, newest first, grouped by day.
class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key, this.store});

  final Store? store;

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  late final Store _store = widget.store ?? Store();
  late Future<List<SavedTrack>> _history = _store.history();

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear history?'),
        content: const Text(
          'The list is emptied. Files already in Music/SpotifyGrabber stay on '
          'the phone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store.clearHistory();
    if (!mounted) return;
    setState(() {
      _history = _store.history();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved tracks'),
        actions: [
          IconButton(
            tooltip: 'Clear history',
            onPressed: _clearHistory,
            icon: const Icon(Icons.delete_outline_rounded),
          ),
        ],
      ),
      body: FutureBuilder<List<SavedTrack>>(
        future: _history,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            );
          }
          final tracks = snapshot.data ?? const <SavedTrack>[];
          if (tracks.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('Nothing saved yet', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 4),
                    Text(
                      'Tracks you download show up here with their format, '
                      'size and date.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Text('Grab a link'),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: _grouped(theme, tracks),
          );
        },
      ),
    );
  }

  /// Inserts a day heading whenever the day changes.
  List<Widget> _grouped(ThemeData theme, List<SavedTrack> tracks) {
    final widgets = <Widget>[];
    String? currentDay;
    for (var i = 0; i < tracks.length; i++) {
      final track = tracks[i];
      final day = historyDayLabel(track.savedAt);
      if (day != currentDay) {
        currentDay = day;
        widgets.add(
          Padding(
            padding: EdgeInsets.only(top: i == 0 ? 8 : 20, bottom: 4),
            child: Text(
              day,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        );
      } else {
        widgets.add(const Divider());
      }
      widgets.add(_HistoryRow(track: track));
    }
    return widgets;
  }
}

class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.track});

  final SavedTrack track;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = [
      if (track.artist.isNotEmpty) track.artist,
      if (track.format.isNotEmpty) track.format,
      track.sizeLabel,
    ].join(' · ');
    final time = track.savedAt;
    final clock = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
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
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            clock,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
