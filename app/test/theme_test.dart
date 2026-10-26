import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_grabber/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final values = <String, String>{};

  setUp(() {
    values.clear();
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
        (call) async => null,
      )
      ..setMockMethodCallHandler(
        const MethodChannel('grabber/store'),
        (call) async {
          final key = (call.arguments as Map)['key'] as String;
          if (call.method == 'read') return values[key];
          values[key] = (call.arguments as Map)['value'] as String;
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

  ThemeMode modeOf(WidgetTester tester) =>
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;

  testWidgets('following the system by default, then overriding it',
      (tester) async {
    await tester.pumpWidget(const GrabberApp());
    await tester.pump();
    expect(modeOf(tester), ThemeMode.system);
    // The app starts on the home screen, not the history list.
    expect(find.text('Spotify Grabber'), findsOneWidget);
    expect(find.text('Saved tracks'), findsNothing);

    await tester.tap(find.byTooltip('Appearance'));
    await tester.pumpAndSettle();
    // The menu label is wrapped in an IgnorePointer, so the tap reports a
    // miss even though the menu row takes it.
    await tester.tap(find.text('Dark'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(modeOf(tester), ThemeMode.dark);
    expect(values['theme'], 'dark');
  });

  testWidgets('a saved choice wins on the next launch', (tester) async {
    values['theme'] = 'light';

    await tester.pumpWidget(const GrabberApp());
    await tester.pump();

    expect(modeOf(tester), ThemeMode.light);
  });
}
