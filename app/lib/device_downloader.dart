import 'package:flutter/services.dart';

class DeviceDownloadException implements Exception {
  DeviceDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Bridge to the native yt-dlp/ffmpeg downloader that runs on the phone.
class DeviceDownloader {
  static const MethodChannel _channel = MethodChannel('grabber/on_device');
  static const EventChannel _events =
      EventChannel('grabber/on_device/progress');

  /// Prepares yt-dlp/ffmpeg and updates yt-dlp when it is older than a month.
  Future<String> prepare() async {
    try {
      return await _channel.invokeMethod<String>('prepare') ?? 'unknown';
    } on PlatformException catch (error) {
      throw DeviceDownloadException(
        error.message ?? 'Could not start the downloader.',
      );
    }
  }

  /// Status lines ("Updating downloader…") and per-track progress percentages.
  Stream<Map<String, dynamic>> get events => _events
      .receiveBroadcastStream()
      .map((event) => Map<String, dynamic>.from(event as Map));

  /// Searches YouTube for [query] and saves the best match to the phone.
  Future<({String path, int size})> download({
    required String id,
    required String query,
    required String title,
    required String artist,
    required int duration,
    required String name,
  }) async {
    try {
      final result =
          await _channel.invokeMapMethod<String, dynamic>('download', {
        'id': id,
        'query': query,
        'title': title,
        'artist': artist,
        'duration': duration,
        'name': name,
      });
      if (result == null) {
        throw DeviceDownloadException('The downloader returned nothing.');
      }
      return (
        path: result['path'] as String? ?? '',
        size: (result['size'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException catch (error) {
      throw DeviceDownloadException(_clean(error.message));
    }
  }

  /// yt-dlp errors arrive as multi-line logs; keep the readable last line.
  String _clean(String? message) {
    if (message == null || message.trim().isEmpty) {
      return 'Download failed (no match found).';
    }
    final lines = message
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    final errorLine = lines.lastWhere(
      (line) => line.startsWith('ERROR'),
      orElse: () => lines.last,
    );
    return errorLine.replaceFirst(RegExp(r'^ERROR:\s*'), '');
  }
}
