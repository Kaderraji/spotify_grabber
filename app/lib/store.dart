import 'dart:convert';

import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';

import 'models.dart';

/// One track the app saved to the phone, kept so the history screen can show
/// what was downloaded and when.
class SavedTrack {
  SavedTrack({
    required this.title,
    required this.artist,
    required this.format,
    required this.bytes,
    required this.savedAt,
    this.path = '',
  });

  final String title;
  final String artist;
  final String format;
  final int bytes;
  final DateTime savedAt;
  final String path;

  String get sizeLabel => formatBytes(bytes);

  Map<String, dynamic> toJson() => {
        'title': title,
        'artist': artist,
        'format': format,
        'bytes': bytes,
        'savedAt': savedAt.millisecondsSinceEpoch,
        'path': path,
      };

  factory SavedTrack.fromJson(Map<String, dynamic> json) {
    return SavedTrack(
      title: json['title'] as String? ?? 'Untitled',
      artist: json['artist'] as String? ?? '',
      format: json['format'] as String? ?? '',
      bytes: (json['bytes'] as num?)?.toInt() ?? 0,
      savedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['savedAt'] as num?)?.toInt() ?? 0,
      ),
      path: json['path'] as String? ?? '',
    );
  }
}

/// A queue the app has started but not finished: the link it came from, the
/// tracks still to download, and the format to save them in. Written before
/// the first track and rewritten after each one, so a queue survives Android
/// killing the app and starts again on the next launch instead of leaving the
/// user to fetch the link a second time.
class PendingQueue {
  PendingQueue({
    required this.link,
    required this.remaining,
    required this.format,
  });

  final ResolvedLink link;

  /// Ids of the tracks that have not been saved yet, in playlist order.
  final List<String> remaining;
  final String format;

  Map<String, dynamic> toJson() => {
        'link': link.toJson(),
        'remaining': remaining,
        'format': format,
      };

  factory PendingQueue.fromJson(Map<String, dynamic> json) {
    return PendingQueue(
      link: ResolvedLink.fromJson(
        Map<String, dynamic>.from(json['link'] as Map? ?? const {}),
      ),
      remaining: (json['remaining'] as List<dynamic>? ?? const [])
          .map((id) => id as String)
          .toList(),
      format: json['format'] as String? ?? 'm4a',
    );
  }
}

/// "11.5 MB" / "820 KB" — sizes people can compare at a glance.
String formatBytes(int bytes) {
  if (bytes <= 0) return '—';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  final mb = bytes / (1024 * 1024);
  if (mb >= 100) return '${mb.round()} MB';
  final exact = mb.toStringAsFixed(1);
  return '${exact.endsWith('.0') ? exact.substring(0, exact.length - 2) : exact} MB';
}

/// The heading a saved track falls under: Today, Yesterday, or 24 Oct.
String historyDayLabel(DateTime when, {DateTime? now}) {
  final today = now ?? DateTime.now();
  final day = DateTime(when.year, when.month, when.day);
  final current = DateTime(today.year, today.month, today.day);
  final difference = current.difference(day).inDays;
  if (difference == 0) return 'Today';
  if (difference == 1) return 'Yesterday';
  return '${when.day} ${_months[when.month - 1]}';
}

const _months = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// Small key/value store backed by the app's native preferences, so both
/// choices survive a restart without a database.
class Store {
  Store({this._channel = const MethodChannel('grabber/store')});

  static const int maxHistory = 200;

  final MethodChannel _channel;

  Future<String?> _read(String key) async {
    try {
      return await _channel.invokeMethod<String>('read', {'key': key});
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<void> _write(String key, String value) async {
    try {
      await _channel.invokeMethod<void>('write', {'key': key, 'value': value});
    } on PlatformException {
      // A lost preference is not worth interrupting the user for.
    } on MissingPluginException {
      // Same when the native side is not there (widget tests).
    }
  }

  Future<ThemeMode> themeMode() async {
    final saved = await _read('theme');
    return switch (saved) {
      'light' => ThemeMode.light,
      'dark' => ThemeMode.dark,
      _ => ThemeMode.system,
    };
  }

  Future<void> saveThemeMode(ThemeMode mode) => _write(
        'theme',
        switch (mode) {
          ThemeMode.light => 'light',
          ThemeMode.dark => 'dark',
          ThemeMode.system => 'system',
        },
      );

  /// Starts the queue by itself after a link is fetched or shared.
  Future<bool> autoDownload() async => await _read('auto_download') == '1';

  Future<void> saveAutoDownload(bool enabled) =>
      _write('auto_download', enabled ? '1' : '0');

  Future<List<SavedTrack>> history() async {
    final raw = await _read('history');
    if (raw == null || raw.isEmpty) return const <SavedTrack>[];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((entry) => SavedTrack.fromJson(entry as Map<String, dynamic>))
          .toList(growable: false);
    } on FormatException {
      return const <SavedTrack>[];
    } on TypeError {
      return const <SavedTrack>[];
    }
  }

  /// Puts [track] at the top of the history and returns the new list.
  Future<List<SavedTrack>> addSaved(SavedTrack track) async {
    final current = await history();
    final updated = <SavedTrack>[track, ...current].take(maxHistory).toList();
    await _write(
      'history',
      jsonEncode(updated.map((entry) => entry.toJson()).toList()),
    );
    return updated;
  }

  Future<void> clearHistory() => _write('history', '[]');

  /// The queue that was still running the last time the app was alive.
  Future<PendingQueue?> pendingQueue() async {
    final raw = await _read('pending');
    if (raw == null || raw.isEmpty) return null;
    try {
      return PendingQueue.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> savePendingQueue(PendingQueue queue) =>
      _write('pending', jsonEncode(queue.toJson()));

  Future<void> clearPendingQueue() => _write('pending', '');
}
