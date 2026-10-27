import 'package:flutter/material.dart' show ThemeMode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_grabber/models.dart';
import 'package:spotify_grabber/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('labels', () {
    test('bytes read as MB or KB', () {
      expect(formatBytes(0), '—');
      expect(formatBytes(820 * 1024), '820 KB');
      expect(formatBytes(3 * 1024 * 1024 + 512 * 1024), '3.5 MB');
      expect(formatBytes(47 * 1024 * 1024), '47 MB');
    });

    test('days group as Today, Yesterday, then the date', () {
      final now = DateTime(2026, 10, 24, 15);
      expect(historyDayLabel(DateTime(2026, 10, 24, 9), now: now), 'Today');
      expect(historyDayLabel(DateTime(2026, 10, 23, 23), now: now), 'Yesterday');
      expect(historyDayLabel(DateTime(2026, 10, 20), now: now), '20 Oct');
    });
  });

  test('a saved track survives a JSON round trip', () {
    final track = SavedTrack(
      title: 'Never Gonna Give You Up',
      artist: 'Rick Astley',
      format: 'M4A',
      bytes: 12058624,
      savedAt: DateTime(2026, 10, 24, 12, 30),
      path: 'Music/SpotifyGrabber/Rick Astley - Never Gonna Give You Up.m4a',
    );

    final copy = SavedTrack.fromJson(track.toJson());

    expect(copy.title, track.title);
    expect(copy.artist, track.artist);
    expect(copy.format, track.format);
    expect(copy.bytes, track.bytes);
    expect(copy.path, track.path);
    expect(copy.savedAt, track.savedAt);
    expect(copy.sizeLabel, '11.5 MB');
  });

  group('Store', () {
    final values = <String, String>{};

    setUp(() {
      values.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('grabber/store'),
        (call) async {
          final key = (call.arguments as Map)['key'] as String;
          if (call.method == 'read') return values[key];
          values[key] = (call.arguments as Map)['value'] as String;
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('grabber/store'), null);
    });

    test('theme mode defaults to the system and round trips', () async {
      final store = Store();
      expect(await store.themeMode(), ThemeMode.system);

      await store.saveThemeMode(ThemeMode.dark);
      expect(await store.themeMode(), ThemeMode.dark, reason: values['theme']);

      await store.saveThemeMode(ThemeMode.light);
      expect(await store.themeMode(), ThemeMode.light);
    });

    test('new saves go on top and the list is capped', () async {
      final store = Store();
      for (var i = 0; i < Store.maxHistory + 10; i++) {
        await store.addSaved(
          SavedTrack(
            title: 'Track $i',
            artist: 'Artist',
            format: 'M4A',
            bytes: 1024,
            savedAt: DateTime(2026, 10, 24),
          ),
        );
      }

      final history = await store.history();
      expect(history.length, Store.maxHistory);
      expect(history.first.title, 'Track ${Store.maxHistory + 9}');
    });

    test('clearing empties the list', () async {
      final store = Store();
      await store.addSaved(
        SavedTrack(
          title: 'Track',
          artist: 'Artist',
          format: 'MP3',
          bytes: 1024,
          savedAt: DateTime(2026, 10, 24),
        ),
      );
      await store.clearHistory();
      expect(await store.history(), isEmpty);
    });

    test('broken stored JSON reads as an empty history', () async {
      values['history'] = 'not json';
      expect(await Store().history(), isEmpty);
    });

    test('a pending queue round trips and can be cleared', () async {
      final store = Store();
      expect(await store.pendingQueue(), isNull);

      await store.savePendingQueue(
        PendingQueue(
          link: ResolvedLink(
            url: 'https://open.spotify.com/album/1',
            kind: 'album',
            title: 'Discovery',
            coverUrl: 'https://i.scdn.co/image/abc',
            tracks: [
              Track(
                id: 'one',
                title: 'One More Time',
                artists: 'Daft Punk',
                album: 'Discovery',
                duration: 320,
              ),
            ],
          ),
          remaining: ['one'],
          format: 'flac',
        ),
      );

      final pending = await store.pendingQueue();
      expect(pending, isNotNull);
      expect(pending!.link.title, 'Discovery');
      expect(pending.link.coverUrl, 'https://i.scdn.co/image/abc');
      expect(pending.link.tracks.single.title, 'One More Time');
      expect(pending.link.tracks.single.duration, 320);
      expect(pending.remaining, ['one']);
      expect(pending.format, 'flac');

      await store.clearPendingQueue();
      expect(await store.pendingQueue(), isNull);
    });

    test('broken stored JSON reads as no pending queue', () async {
      values['pending'] = '{"link": 3}';
      expect(await Store().pendingQueue(), isNull);
    });

    test('the link on screen round trips and can be cleared', () async {
      final store = Store();
      expect(await store.viewing(), isNull);

      await store.saveViewing(
        ViewingLink(
          link: ResolvedLink(
            url: 'https://open.spotify.com/album/1',
            kind: 'album',
            title: 'Discovery',
            tracks: [
              Track(
                id: 'one',
                title: 'One More Time',
                artists: 'Daft Punk',
                duration: 320,
              ),
              Track(
                id: 'two',
                title: 'Aerodynamic',
                artists: 'Daft Punk',
                duration: 210,
              ),
            ],
          ),
          selected: ['two'],
        ),
      );

      final viewing = await store.viewing();
      expect(viewing, isNotNull);
      expect(viewing!.link.title, 'Discovery');
      expect(viewing.link.tracks, hasLength(2));
      expect(viewing.selected, ['two']);

      await store.clearViewing();
      expect(await store.viewing(), isNull);
    });

    test('broken stored JSON reads as no link on screen', () async {
      values['viewing'] = '{"link": 3}';
      expect(await Store().viewing(), isNull);
    });
  });
}
