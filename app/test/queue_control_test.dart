import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_grabber/home_page.dart';
import 'package:spotify_grabber/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final prefs = <String, String>{};
  final downloadQueries = <String>[];
  String? launchShare;

  /// Android 12+ refuses a foreground service started from the background.
  var serviceAllowed = true;

  /// When set, the track in flight waits for it, so the queue can be left
  /// running while the test taps a button.
  Completer<void>? gate;

  const playlist = 'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M';

  Future<ResolvedLink> fakeResolve(String url) async => ResolvedLink(
        url: url,
        kind: 'playlist',
        title: 'Two tracks',
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
      );

  setUp(() {
    prefs
      ..clear()
      ..['auto_download'] = '1';
    downloadQueries.clear();
    launchShare = playlist;
    serviceAllowed = true;
    gate = null;
    messenger
      ..setMockMethodCallHandler(
        const MethodChannel('grabber/on_device'),
        (call) async {
          if (call.method == 'download') {
            downloadQueries.add((call.arguments as Map)['query'] as String);
            final waiting = gate;
            if (waiting != null) await waiting.future;
            return {'path': 'Music/SpotifyGrabber/song.m4a', 'size': 1024};
          }
          if (call.method == 'startQueue' && !serviceAllowed) {
            throw PlatformException(code: 'foreground_service_blocked');
          }
          return switch (call.method) {
            'prepare' => 'test-engine',
            'getFormat' => 'm4a',
            'startQueue' => true,
            _ => null,
          };
        },
      )
      ..setMockMethodCallHandler(
        const MethodChannel('grabber/share'),
        (call) async => call.method == 'getInitialShare' && launchShare != null
            ? {'link': launchShare, 'rejected': null}
            : null,
      )
      ..setMockMethodCallHandler(
        const MethodChannel('grabber/store'),
        (call) async {
          final key = (call.arguments as Map)['key'] as String;
          if (call.method == 'read') return prefs[key];
          prefs[key] = (call.arguments as Map)['value'] as String;
          return null;
        },
      )
      ..setMockStreamHandler(
        const EventChannel('grabber/on_device/progress'),
        MockStreamHandler.inline(onListen: (arguments, events) {}),
      );
  });

  tearDown(() {
    messenger
      ..setMockMethodCallHandler(const MethodChannel('grabber/on_device'), null)
      ..setMockMethodCallHandler(const MethodChannel('grabber/share'), null)
      ..setMockMethodCallHandler(const MethodChannel('grabber/store'), null)
      ..setMockStreamHandler(
        const EventChannel('grabber/on_device/progress'),
        null,
      );
  });

  /// A track in flight keeps a spinner turning, so the screen never "settles"
  /// while the gate is closed.
  Future<void> pumpSteps(WidgetTester tester, [int steps = 8]) async {
    for (var i = 0; i < steps; i++) {
      await tester.pump();
    }
  }

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HomePage(resolveLink: fakeResolve)),
    );
    await pumpSteps(tester);
  }

  testWidgets('cancel drops the queue and the stored record at once',
      (tester) async {
    gate = Completer<void>();
    await pumpHome(tester);

    expect(downloadQueries, ['Daft Punk - One More Time']);
    expect(find.text('Downloading 1 of 2'), findsOneWidget);
    // The queue is on disk while its first track is still in flight.
    expect(prefs['pending'], contains('Aerodynamic'));

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await pumpSteps(tester);

    // Cleared before the current file finishes: a kill from here on must not
    // bring the queue back.
    expect(prefs['pending'], '');

    gate!.complete();
    await tester.pumpAndSettle();

    expect(find.text('Download cancelled.'), findsOneWidget);
    // The second track never started, and the list is gone.
    expect(downloadQueries, ['Daft Punk - One More Time']);
    expect(find.text('Start with a Spotify link'), findsOneWidget);
    expect(prefs['pending'], '');
  });

  testWidgets('a queue waiting for the app can be cancelled too',
      (tester) async {
    serviceAllowed = false;
    await pumpHome(tester);

    expect(find.textContaining('back on screen'), findsOneWidget);
    expect(prefs['pending'], contains('Aerodynamic'));

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(find.textContaining('back on screen'), findsNothing);
    expect(find.text('Start with a Spotify link'), findsOneWidget);
    expect(prefs['pending'], '');

    // Nothing was waiting to retry in the background either.
    serviceAllowed = true;
    await tester.pump(const Duration(seconds: 5));
    await pumpSteps(tester);
    expect(downloadQueries, isEmpty);
    expect(prefs['pending'], '');
  });

  testWidgets('stop after this track keeps the list and never resumes',
      (tester) async {
    gate = Completer<void>();
    await pumpHome(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Stop after this track'));
    await pumpSteps(tester);

    gate!.complete();
    await tester.pumpAndSettle();

    expect(downloadQueries, ['Daft Punk - One More Time']);
    // The link is still there, the rest was not started, and a relaunch has
    // nothing to pick up.
    expect(find.text('Aerodynamic'), findsOneWidget);
    expect(find.text('Download cancelled.'), findsNothing);
    expect(prefs['pending'], '');
  });
}
