import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_grabber/api.dart';

void main() {
  test('parses a resolved playlist', () {
    final link = ResolvedLink.fromJson({
      'url': 'https://open.spotify.com/playlist/abc',
      'kind': 'playlist',
      'title': 'Late Night',
      'cover_url': 'https://example.com/cover.jpg',
      'total': 2,
      'tracks': [
        {
          'id': 't1',
          'title': 'One',
          'artists': 'A',
          'duration': 181,
          'state': 'queued',
        },
        {
          'id': 't2',
          'title': 'Two',
          'artists': 'B, C',
          'duration': 95,
          'state': 'present',
          'file': 'B, C - Two.m4a',
          'size': 1024,
        },
      ],
    });

    expect(link.title, 'Late Night');
    expect(link.tracks, hasLength(2));
    expect(link.alreadyDownloaded, 1);
    expect(link.tracks[1].isDownloaded, isTrue);
    expect(link.tracks[0].isDownloaded, isFalse);
  });

  test('parses job progress and exposes finished files', () {
    final job = JobInfo.fromJson({
      'id': 'job1',
      'title': 'Late Night',
      'status': 'done',
      'counts': {'total': 3, 'done': 2, 'failed': 1, 'pending': 0},
      'tracks': [
        {'id': 'a', 'title': 'A', 'artists': 'X', 'duration': 60, 'state': 'done', 'file': 'X - A.m4a'},
        {'id': 'b', 'title': 'B', 'artists': 'Y', 'duration': 61, 'state': 'failed', 'error': 'no match'},
        {'id': 'c', 'title': 'C', 'artists': 'Z', 'duration': 62, 'state': 'present', 'file': 'Z - C.m4a'},
      ],
    });

    expect(job.isFinished, isTrue);
    expect(job.done, 2);
    expect(job.failed, 1);
    expect(job.ready.map((t) => t.id), ['a', 'c']);
    expect(job.tracks[1].isFailed, isTrue);
  });

  test('formats durations', () {
    expect(formatDuration(181), '3:01');
    expect(formatDuration(59), '0:59');
    expect(formatDuration(3600), '60:00');
  });
}
