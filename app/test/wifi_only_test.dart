import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_grabber/home_page.dart';
import 'package:spotify_grabber/models.dart';
import 'package:spotify_grabber/network_status.dart';

/// Stands in for the phone's connection: [wifi] is what the app is told, and
/// [drop] / [restore] are what the system would push at it.
class FakeNetwork extends NetworkStatus {
  FakeNetwork(this.wifi);

  bool wifi;
  final StreamController<bool> _changes = StreamController<bool>.broadcast();

  @override
  Future<bool> isWifi() async => wifi;

  @override
  Stream<bool> get changes => _changes.stream;

  void restore() {
    wifi = true;
    _changes.add(true);
  }

  void drop() {
    wifi = false;
    _changes.add(false);
  }

  Future<void> close() => _changes.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final prefs = <String, String>{};
  final downloadQueries = <String>[];
  late FakeNetwork network;

  /// When set, the track in flight waits for it, so the connection can be
  /// dropped in the middle of a queue.
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
    network = FakeNetwork(true);
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
        (call) async => call.method == 'getInitialShare'
            ? {'link': playlist, 'rejected': null}
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
    network.close();
    messenger
      ..setMockMethodCallHandler(const MethodChannel('grabber/on_device'), null)
      ..setMockMethodCallHandler(const MethodChannel('grabber/share'), null)
      ..setMockMethodCallHandler(const MethodChannel('grabber/store'), null)
      ..setMockStreamHandler(
        const EventChannel('grabber/on_device/progress'),
        null,
      );
  });

  Future<void> pumpSteps(WidgetTester tester, [int steps = 8]) async {
    for (var i = 0; i < steps; i++) {
      await tester.pump();
    }
  }

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(resolveLink: fakeResolve, network: network),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('with the setting off, mobile data downloads as usual',
      (tester) async {
    network.drop();

    await pumpHome(tester);

    expect(downloadQueries, hasLength(2));
  });

  testWidgets('Wi-Fi only holds the queue until Wi-Fi is back', (tester) async {
    prefs['wifi_only'] = '1';
    network.drop();

    await pumpHome(tester);

    expect(downloadQueries, isEmpty);
    expect(find.textContaining('Waiting for Wi-Fi'), findsOneWidget);
    // Written down, so a killed app does not lose the queue either.
    expect(prefs['pending'], contains('Aerodynamic'));

    // Ten seconds on mobile data is still no download.
    await tester.pump(const Duration(seconds: 10));
    expect(downloadQueries, isEmpty);
    expect(prefs['pending'], contains('Aerodynamic'));

    network.restore();
    await tester.pumpAndSettle();

    expect(
      downloadQueries,
      ['Daft Punk - One More Time', 'Daft Punk - Aerodynamic'],
    );
    expect(find.textContaining('Waiting for Wi-Fi'), findsNothing);
    expect(prefs['pending'], '');
  });

  testWidgets('a drop to mobile data pauses the queue between tracks',
      (tester) async {
    prefs['wifi_only'] = '1';
    gate = Completer<void>();

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(resolveLink: fakeResolve, network: network),
      ),
    );
    await pumpSteps(tester);

    // The first track is in flight when the phone leaves Wi-Fi.
    expect(downloadQueries, ['Daft Punk - One More Time']);
    network.drop();
    gate!.complete();
    await pumpSteps(tester);

    // The queue is still running, but the next file waits.
    expect(downloadQueries, ['Daft Punk - One More Time']);
    expect(find.textContaining('Waiting for Wi-Fi'), findsOneWidget);
    expect(prefs['pending'], contains('Aerodynamic'));

    network.restore();
    await tester.pumpAndSettle();

    expect(
      downloadQueries,
      ['Daft Punk - One More Time', 'Daft Punk - Aerodynamic'],
    );
    expect(find.textContaining('Waiting for Wi-Fi'), findsNothing);
    expect(prefs['pending'], '');
  });
}
