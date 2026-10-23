import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

class SpotifyLinkException implements Exception {
  SpotifyLinkException(this.message);
  final String message;
  @override
  String toString() => message;
}

const _userAgent =
    'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36';

final _linkPattern = RegExp(
  r'(?:open\.spotify\.com/(?:intl-[a-z-]+/)?(track|playlist|album)/'
  r'|spotify:(track|playlist|album):)([A-Za-z0-9]{22})',
);

/// Reads a track/album/playlist straight from Spotify's public embed page.
/// No account, no developer credentials, no server.
Future<ResolvedLink> resolveSpotifyLink(String link) async {
  final match = _linkPattern.firstMatch(link.trim());
  if (match == null) {
    throw SpotifyLinkException(
      'That is not a Spotify track, album or playlist link.',
    );
  }
  final kind = match.group(1) ?? match.group(2)!;
  final id = match.group(3)!;

  final http.Response response;
  try {
    response = await http
        .get(
          Uri.parse('https://open.spotify.com/embed/$kind/$id'),
          headers: {'User-Agent': _userAgent, 'Accept-Language': 'en'},
        )
        .timeout(const Duration(seconds: 25));
  } catch (error) {
    throw SpotifyLinkException('Could not reach Spotify. Check your connection.');
  }
  if (response.statusCode != 200) {
    throw SpotifyLinkException('Spotify answered ${response.statusCode}.');
  }

  final blob = RegExp(
    r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',
    dotAll: true,
  ).firstMatch(response.body);
  if (blob == null) {
    throw SpotifyLinkException('Spotify returned an unexpected page.');
  }

  final Map<String, dynamic> entity;
  try {
    final decoded = jsonDecode(blob.group(1)!) as Map<String, dynamic>;
    entity =
        (((decoded['props']?['pageProps']?['state']?['data'] ?? {})
                    as Map<String, dynamic>)['entity'] ??
                {}) as Map<String, dynamic>;
  } on FormatException {
    throw SpotifyLinkException('Spotify returned broken data.');
  }
  if (entity.isEmpty) {
    throw SpotifyLinkException('This link is private, region-locked or empty.');
  }

  final rawTracks = (entity['trackList'] as List<dynamic>?) ?? [entity];
  final tracks = rawTracks
      .map((raw) => _trackFrom(raw as Map<String, dynamic>))
      .whereType<Track>()
      .toList();
  if (tracks.isEmpty) {
    throw SpotifyLinkException('Spotify listed no playable tracks.');
  }

  return ResolvedLink(
    url: link.trim(),
    kind: kind,
    title: entity['name'] as String? ?? entity['title'] as String? ?? id,
    coverUrl: _coverFrom(entity),
    tracks: tracks,
  );
}

Track? _trackFrom(Map<String, dynamic> raw) {
  final uri = raw['uri'] as String?;
  if (uri == null) return null;
  final id = uri.split(':').last;
  final artists = _artists(raw);
  return Track(
    id: id,
    title: raw['title'] as String? ?? raw['name'] as String? ?? '',
    artists: artists.join(', '),
    duration: ((raw['duration'] as num?)?.toInt() ?? 0) ~/ 1000,
  );
}

List<String> _artists(Map<String, dynamic> raw) {
  final list = raw['artists'] as List<dynamic>?;
  final names = <String>[];
  if (list != null) {
    for (final entry in list) {
      final name = (entry as Map<String, dynamic>?)?['name'];
      if (name is String && name.isNotEmpty) names.add(name);
    }
  }
  if (names.isEmpty) {
    final subtitle = raw['subtitle'];
    if (subtitle is String) {
      names.addAll(
        subtitle.split(',').map((part) => part.trim()).where((p) => p.isNotEmpty),
      );
    }
  }
  return names.isEmpty ? ['Unknown artist'] : names;
}

String? _coverFrom(Map<String, dynamic> entity) {
  final sources = (entity['coverArt'] as Map<String, dynamic>?)?['sources'];
  if (sources is List && sources.isNotEmpty) {
    final url = (sources.last as Map<String, dynamic>)['url'];
    if (url is String) return url;
  }
  final images = (entity['visualIdentity'] as Map<String, dynamic>?)?['image'];
  if (images is List && images.isNotEmpty) {
    final best = images
        .cast<Map<String, dynamic>>()
        .reduce((a, b) => ((a['maxHeight'] as num?) ?? 0) >=
                ((b['maxHeight'] as num?) ?? 0)
            ? a
            : b);
    return best['url'] as String?;
  }
  return null;
}
