import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_grabber/history_page.dart';
import 'package:spotify_grabber/store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final values = <String, String>{};

  setUp(() {
    values.clear();
    messenger.setMockMethodCallHandler(
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
    messenger.setMockMethodCallHandler(const MethodChannel('grabber/store'), null);
  });

  void seed(List<SavedTrack> tracks) {
    values['history'] =
        jsonEncode(tracks.map((track) => track.toJson()).toList());
  }

  Future<void> pumpHistory(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HistoryPage(store: Store())),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists saved tracks under the day they were saved',
      (tester) async {
    final now = DateTime.now();
    seed([
      SavedTrack(
        title: 'Never Gonna Give You Up',
        artist: 'Rick Astley',
        format: 'M4A',
        bytes: 12058624,
        savedAt: now,
      ),
      SavedTrack(
        title: 'Blinding Lights',
        artist: 'The Weeknd',
        format: 'FLAC',
        bytes: 49283072,
        savedAt: now,
      ),
    ]);

    await pumpHistory(tester);

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Never Gonna Give You Up'), findsOneWidget);
    expect(find.text('Rick Astley · M4A · 11.5 MB'), findsOneWidget);
    expect(find.text('The Weeknd · FLAC · 47 MB'), findsOneWidget);
  });

  testWidgets('an empty history offers the next action', (tester) async {
    await pumpHistory(tester);

    expect(find.text('Nothing saved yet'), findsOneWidget);
    expect(find.text('Grab a link'), findsOneWidget);
  });

  testWidgets('clearing asks first, then empties the list', (tester) async {
    seed([
      SavedTrack(
        title: 'Blinding Lights',
        artist: 'The Weeknd',
        format: 'M4A',
        bytes: 1024,
        savedAt: DateTime.now(),
      ),
    ]);
    await pumpHistory(tester);
    expect(find.text('Blinding Lights'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear history'));
    await tester.pumpAndSettle();
    expect(find.text('Clear history?'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(find.text('Blinding Lights'), findsNothing);
    expect(find.text('Nothing saved yet'), findsOneWidget);
    expect(values['history'], '[]');
  });
}
