import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_grabber/home_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// The share Android hands over when the app is opened from the share sheet.
  Map<String, String?> launchShare = const {};

  setUp(() {
    launchShare = const {};
    messenger
      ..setMockMethodCallHandler(
        const MethodChannel('grabber/on_device'),
        (call) async => switch (call.method) {
          'prepare' => 'test-engine',
          'getFormat' => 'm4a',
          _ => null,
        },
      )
      ..setMockMethodCallHandler(
        const MethodChannel('grabber/share'),
        (call) async => switch (call.method) {
          'getInitialShare' => launchShare,
          _ => null,
        },
      )
      ..setMockMethodCallHandler(
        const MethodChannel('grabber/store'),
        (call) async => null,
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
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pumpAndSettle();
  }

  testWidgets('opens on the link field with one clear first step',
      (tester) async {
    await pumpHome(tester);

    expect(find.text('Spotify Grabber'), findsOneWidget);
    expect(find.text('Start with a Spotify link'), findsOneWidget);
    expect(
      find.widgetWithText(FilledButton, 'Paste from clipboard'),
      findsOneWidget,
    );
    expect(find.byTooltip('Appearance'), findsOneWidget);
    expect(find.byTooltip('Saved tracks'), findsOneWidget);
  });

  testWidgets('a share without a Spotify link says so instead of silently '
      'opening', (tester) async {
    launchShare = const {'link': null, 'rejected': 'hello there'};

    await pumpHome(tester);

    expect(
      find.textContaining('no Spotify link'),
      findsOneWidget,
    );
    expect(find.text('Start with a Spotify link'), findsOneWidget);
  });

  testWidgets('a shared link fills the field', (tester) async {
    launchShare = const {
      'link': 'https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT',
      'rejected': null,
    };

    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(
      field.controller?.text,
      'https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT',
    );
    expect(find.textContaining('no Spotify link'), findsNothing);
  });
}
