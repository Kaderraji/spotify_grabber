import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_grabber/home_page.dart';
import 'package:spotify_grabber/models.dart';
import 'package:spotify_grabber/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final prefs = <String, String>{};
  final deviceCalls = <String>[];
  String? launchShare;

  const playlist = 'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M';

  ResolvedLink twoTracks(String url) => ResolvedLink(
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

  List<String> selectedInStore() {
    final raw = prefs['viewing'] ?? '';
    if (raw.isEmpty) return const [];
    return ((jsonDecode(raw) as Map)['selected'] as List).cast<String>();
  }

  setUp(() {
    prefs.clear();
    deviceCalls.clear();
    launchShare = null;
    messenger
      ..setMockMethodCallHandler(
        const MethodChannel('grabber/on_device'),
        (call) async {
          deviceCalls.add(call.method);
          return switch (call.method) {
            'prepare' => 'test-engine',
            'getFormat' => 'm4a',
            'startQueue' => true,
            'download' => {'path': 'Music/SpotifyGrabber/song.m4a', 'size': 1024},
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

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HomePage(resolveLink: (url) async => twoTracks(url))),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a cold launch reopens the list with the ticks it had',
      (tester) async {
    prefs['viewing'] = jsonEncode(
      ViewingLink(link: twoTracks(playlist), selected: ['two']).toJson(),
    );

    await pumpHome(tester);

    expect(find.text('One More Time'), findsOneWidget);
    expect(find.text('Aerodynamic'), findsOneWidget);
    // Only the track that was ticked is still selected.
    expect(find.text('Download 1 track · M4A'), findsOneWidget);
    // Reopening the list is not a download.
    expect(deviceCalls, isNot(contains('download')));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller?.text, playlist);
  });

  testWidgets('a fetched link is kept, and clearing it forgets it',
      (tester) async {
    launchShare = playlist;

    await pumpHome(tester);

    expect(prefs['viewing'], contains(playlist));

    await tester.tap(find.byTooltip('Clear link'));
    await tester.pumpAndSettle();

    expect(prefs['viewing'], '');
    expect(find.text('Start with a Spotify link'), findsOneWidget);
  });

  testWidgets('unticking a track is remembered for the next launch',
      (tester) async {
    launchShare = playlist;
    await pumpHome(tester);
    expect(selectedInStore(), ['one', 'two']);

    await tester.tap(find.text('Aerodynamic'));
    await tester.pumpAndSettle();

    expect(selectedInStore(), ['one']);
    expect(find.text('Download 1 track · M4A'), findsOneWidget);
  });
}
