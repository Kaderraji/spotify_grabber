import 'dart:convert';

import 'package:http/http.dart' as http;

/// Where the app's builds are published.
const String releasesRepo = 'Kaderraji/spotify_grabber';

class UpdateException implements Exception {
  UpdateException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A release that is newer than the installed build.
class Update {
  const Update({required this.version, required this.url});

  /// The tag without its leading `v`.
  final String version;

  /// The release's APK when it has one, otherwise its page.
  final String url;
}

/// Asks GitHub for the newest release of [releasesRepo]. The repository has to
/// be public: there is no token to authenticate with.
class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<Update?> latest() async {
    final http.Response response;
    try {
      response = await _client
          .get(
            Uri.parse('https://api.github.com/repos/$releasesRepo/releases/latest'),
            headers: const {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      throw UpdateException('Could not reach GitHub. Check your connection.');
    }
    if (response.statusCode == 404) {
      throw UpdateException('No release is published for this repository.');
    }
    if (response.statusCode != 200) {
      throw UpdateException('GitHub answered ${response.statusCode}.');
    }
    try {
      return parseRelease(jsonDecode(response.body) as Map<String, dynamic>);
    } on FormatException {
      throw UpdateException('GitHub returned unexpected data.');
    }
  }
}

/// Reads a release payload. Null when it names no version to compare with.
Update? parseRelease(Map<String, dynamic> json) {
  final tag = (json['tag_name'] as String? ?? '').trim();
  if (tag.isEmpty) return null;

  String? apk;
  for (final asset in (json['assets'] as List<dynamic>? ?? const [])) {
    if (asset is! Map<String, dynamic>) continue;
    final name = (asset['name'] as String? ?? '').toLowerCase();
    final url = asset['browser_download_url'] as String?;
    if (name.endsWith('.apk') && url != null && url.isNotEmpty) {
      apk = url;
      break;
    }
  }
  final page = json['html_url'] as String? ?? '';
  final url = apk ?? (page.isEmpty ? null : page);
  if (url == null) return null;

  return Update(
    version: tag.startsWith('v') || tag.startsWith('V') ? tag.substring(1) : tag,
    url: url,
  );
}

/// True when [latest] is a later version than [current]: 1.2.0 beats 1.1.9.
/// A missing part counts as zero, so 1.2 equals 1.2.0.
bool isNewerVersion(String latest, String current) {
  final newer = _parts(latest);
  final installed = _parts(current);
  for (var i = 0; i < 3; i++) {
    final a = i < newer.length ? newer[i] : 0;
    final b = i < installed.length ? installed[i] : 0;
    if (a != b) return a > b;
  }
  return false;
}

/// "1.2.0-beta" → [1, 2, 0]; anything that is not a number counts as 0.
List<int> _parts(String version) => version
    .trim()
    .split(RegExp(r'[.+-]'))
    .map((part) => int.tryParse(part) ?? 0)
    .toList();
