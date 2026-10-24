import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_grabber/models.dart';

void main() {
  test('parses a resolved playlist', () {
    final link = ResolvedLink.fromJson({
      'url': 'https://open.spotify.com/playlist/abc',
      'kind': 'playlist',
      'title': 'Late Night',
      'cover_url': 'https://example.com/cover.jpg',
      'tracks': [
        {'id': 't1', 'title': 'One', 'artists': 'A', 'duration': 181},
        {
          'id': 't2',
          'title': 'Two',
          'artists': 'B, C',
          'album': 'Album',
          'duration': 95,
        },
      ],
    });

    expect(link.title, 'Late Night');
    expect(link.kind, 'playlist');
    expect(link.coverUrl, 'https://example.com/cover.jpg');
    expect(link.tracks, hasLength(2));
    expect(link.tracks.first.displayName, 'A - One');
    expect(link.tracks[1].album, 'Album');
  });

  test('parses a single track and tolerates missing fields', () {
    final link = ResolvedLink.fromJson({
      'kind': 'track',
      'tracks': [
        {'id': 'one'},
      ],
    });

    expect(link.title, 'Untitled');
    expect(link.coverUrl, isNull);
    expect(link.tracks.single.title, '');
    expect(link.tracks.single.duration, 0);
  });

  test('formats durations', () {
    expect(formatDuration(181), '3:01');
    expect(formatDuration(59), '0:59');
    expect(formatDuration(3600), '60:00');
  });
}
