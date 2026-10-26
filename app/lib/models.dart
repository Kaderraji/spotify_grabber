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
    this.album = '',
  });

  final String id;
  final String title;
  final String artists;
  final String album;
  final int duration;

  String get displayName => '$artists - $title';

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'artists': artists,
        'album': album,
        'duration': duration,
      };

  factory Track.fromJson(Map<String, dynamic> json) {
    return Track(
      id: json['id'] as String,
      title: json['title'] as String? ?? '',
      artists: json['artists'] as String? ?? '',
      album: json['album'] as String? ?? '',
      duration: (json['duration'] as num?)?.toInt() ?? 0,
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

  Map<String, dynamic> toJson() => {
        'url': url,
        'kind': kind,
        'title': title,
        'cover_url': coverUrl,
        'tracks': tracks.map((track) => track.toJson()).toList(),
      };

  factory ResolvedLink.fromJson(Map<String, dynamic> json) {
    return ResolvedLink(
      url: json['url'] as String? ?? '',
      kind: json['kind'] as String? ?? 'playlist',
      title: json['title'] as String? ?? 'Untitled',
      coverUrl: json['cover_url'] as String?,
      tracks: (json['tracks'] as List<dynamic>? ?? [])
          .map((entry) => Track.fromJson(entry as Map<String, dynamic>))
          .toList(),
    );
  }
}
