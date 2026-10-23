import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class ApiException implements Exception {
  ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

String formatDuration(int seconds) {
  final m = seconds ~/ 60;
  final s = (seconds % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

class Track {
  Track({
    required this.id,
    required this.title,
    required this.artists,
    required this.duration,
    required this.url,
    this.album = '',
    this.state = 'queued',
    this.error,
    this.file,
    this.size,
  });

  final String id;
  final String title;
  final String artists;
  final String album;
  final int duration;
  final String url;
  String state;
  String? error;
  String? file;
  int? size;

  bool get isDownloaded => state == 'done' || state == 'present';
  bool get isFailed => state == 'failed';

  factory Track.fromJson(Map<String, dynamic> json) {
    return Track(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      artists: json['artists'] as String? ?? '',
      album: json['album'] as String? ?? '',
      duration: (json['duration'] as num?)?.toInt() ?? 0,
      url: json['url'] as String? ?? '',
      state: json['state'] as String? ?? 'queued',
      error: json['error'] as String?,
      file: json['file'] as String?,
      size: (json['size'] as num?)?.toInt(),
    );
  }
}

class ResolvedLink {
  ResolvedLink({
    required this.url,
    required this.kind,
    required this.title,
    required this.tracks,
    this.coverUrl,
  });

  final String url;
  final String kind;
  final String title;
  final List<Track> tracks;
  final String? coverUrl;

  int get alreadyDownloaded => tracks.where((t) => t.isDownloaded).length;

  factory ResolvedLink.fromJson(Map<String, dynamic> json) {
    return ResolvedLink(
      url: json['url'] as String? ?? '',
      kind: json['kind'] as String? ?? 'playlist',
      title: json['title'] as String? ?? 'Untitled',
      coverUrl: json['cover_url'] as String?,
      tracks: (json['tracks'] as List<dynamic>? ?? [])
          .map((e) => Track.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class JobInfo {
  JobInfo({
    required this.id,
    required this.title,
    required this.status,
    required this.tracks,
    required this.total,
    required this.done,
    required this.failed,
    this.error,
    this.phoneOnly = false,
  });

  final String id;
  final String title;
  final String status;
  final List<Track> tracks;
  final int total;
  final int done;
  final int failed;
  final String? error;
  final bool phoneOnly;

  bool get isFinished => status == 'done' || status == 'failed';
  List<Track> get ready => tracks.where((t) => t.isDownloaded && t.file != null).toList();

  factory JobInfo.fromJson(Map<String, dynamic> json) {
    final counts = json['counts'] as Map<String, dynamic>? ?? const {};
    return JobInfo(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      status: json['status'] as String? ?? 'queued',
      error: json['error'] as String?,
      phoneOnly: json['phone_only'] as bool? ?? false,
      total: (counts['total'] as num?)?.toInt() ?? 0,
      done: (counts['done'] as num?)?.toInt() ?? 0,
      failed: (counts['failed'] as num?)?.toInt() ?? 0,
      tracks: (json['tracks'] as List<dynamic>? ?? [])
          .map((e) => Track.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class GrabberApi {
  GrabberApi(this.baseUrl);

  final String baseUrl;

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  Map<String, dynamic> _decode(http.Response response) {
    Map<String, dynamic> body;
    try {
      body = jsonDecode(response.body) as Map<String, dynamic>;
    } on FormatException {
      throw ApiException(
        'The server answered ${response.statusCode} but not with JSON. '
        'Check the server address.',
      );
    }
    if (response.statusCode >= 400) {
      throw ApiException(body['detail'] as String? ?? 'Request failed (${response.statusCode}).');
    }
    return body;
  }

  Future<Map<String, dynamic>> health() async {
    try {
      final response = await http
          .get(_uri('/health'))
          .timeout(const Duration(seconds: 8));
      return _decode(response);
    } on TimeoutException {
      throw ApiException('The PC did not answer. Is the server running?');
    } on SocketException {
      throw ApiException('Could not reach $baseUrl. Same Wi-Fi, and the server running?');
    }
  }

  Future<ResolvedLink> resolve(String url) async {
    final response = await _post('/resolve', {'url': url});
    return ResolvedLink.fromJson(response);
  }

  Future<JobInfo> createJob(
    String url,
    List<String> trackIds, {
    bool phoneOnly = false,
  }) async {
    final response = await _post('/jobs', {
      'url': url,
      'track_ids': trackIds,
      'phone_only': phoneOnly,
    });
    return JobInfo.fromJson(response);
  }

  /// Deletes a phone-only job's files from the PC after they were copied.
  Future<int> release(String jobId) async {
    final response = await _post('/jobs/$jobId/release', const {});
    return (response['removed'] as num?)?.toInt() ?? 0;
  }

  Future<JobInfo> job(String jobId) async {
    final response = await http
        .get(_uri('/jobs/$jobId'))
        .timeout(const Duration(seconds: 20));
    return JobInfo.fromJson(_decode(response));
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    try {
      final response = await http
          .post(
            _uri(path),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 60));
      return _decode(response);
    } on TimeoutException {
      throw ApiException('Timed out talking to the PC. Check the server log.');
    } on SocketException {
      throw ApiException('Could not reach $baseUrl. Is the server running?');
    }
  }

  /// Streams one finished track from the PC to [target] on the phone.
  Future<void> saveFile({
    required String jobId,
    required String trackId,
    required File target,
    void Function(int received, int total)? onProgress,
  }) async {
    final client = http.Client();
    try {
      final request = http.Request('GET', _uri('/jobs/$jobId/files/$trackId'));
      final response = await client.send(request).timeout(const Duration(seconds: 60));
      if (response.statusCode != 200) {
        final text = await response.stream.bytesToString();
        throw ApiException(_errorFromBody(text, response.statusCode));
      }
      await target.parent.create(recursive: true);
      final sink = target.openWrite();
      var received = 0;
      final total = response.contentLength ?? 0;
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
    } on SocketException {
      throw ApiException('Connection dropped while copying a file.');
    } finally {
      client.close();
    }
  }

  String _errorFromBody(String body, int code) {
    try {
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      return decoded['detail'] as String? ?? 'Copy failed ($code).';
    } on FormatException {
      return 'Copy failed ($code).';
    }
  }
}
