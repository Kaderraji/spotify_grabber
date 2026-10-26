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
  final deviceCalls = <String>[];

  /// Android 12+ refuses a foreground service started from the background.
  var serviceAllowed = true;

  const link = 'https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT';

  Future<ResolvedLink> fakeResolve(String url) async => ResolvedLink(
        url: url,
        kind: 'track',
        title: 'Never Gonna Give You Up',
        tracks: [
          Track(
            id: '4cOdK2wGLETKBW3PvgPWqT',
            title: 'Never Gonna Give You Up',
            artists: 'Rick Astley',
            duration: 213,
          ),
        ],
      );

  setUp(() {
    prefs.clear();
    deviceCalls.clear();
    serviceAllowed = true;
    messenger
      ..setMockMethodCallHandler(
        const MethodChannel('grabber/on_device'),
        (call) async {
          deviceCalls.add(call.method);
          if (call.method == 'startQueue' && !serviceAllowed) {
            throw PlatformException(code: 'foreground_service_blocked');
          }
          return switch (call.method) {
            'prepare' => 'test-engine',
            'getFormat' => 'm4a',
            'startQueue' => true,
            'download' => {'path': 'Music/SpotifyGrabber/song.m4a', 'size': 3072},
            _ => null,
          };
        },
      )
      ..setMockMethodCallHandler(
        const MethodChannel('grabber/share'),
        (call) async =>
            call.method == 'getInitialShare' ? {'link': link, 'rejected': null} : null,
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

  /// Android delivers the steps in order; jumping straight to paused trips an
  /// assertion in the framework's own lifecycle listener.
  void lifecycleTo(WidgetTester tester, List<AppLifecycleState> states) {
    for (final state in states) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
  }

  void goToBackground(WidgetTester tester) => lifecycleTo(tester, const [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]);

  void comeToForeground(WidgetTester tester) => lifecycleTo(tester, const [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]);

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: HomePage(resolveLink: fakeResolve)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('auto-download is off until it is turned on', (tester) async {
    await pumpHome(tester);

    // The shared link was fetched and listed, but nothing was downloaded.
    expect(find.text('Never Gonna Give You Up'), findsWidgets);
    expect(deviceCalls, isNot(contains('download')));
  });

  testWidgets('turning auto-download on is remembered', (tester) async {
    await pumpHome(tester);

    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.text('Auto-download'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(prefs['auto_download'], '1');
  });

  testWidgets('a saved auto-download starts the queue for a shared link',
      (tester) async {
    prefs['auto_download'] = '1';

    await pumpHome(tester);

    expect(deviceCalls, contains('download'));
    expect(prefs['history'], contains('Never Gonna Give You Up'));
  });

  testWidgets('a queue refused while the app is on screen starts by itself',
      (tester) async {
    prefs['auto_download'] = '1';
    serviceAllowed = false;

    await pumpHome(tester);

    expect(deviceCalls, isNot(contains('download')));
    expect(find.textContaining('back on screen'), findsOneWidget);

    // No lifecycle event: the app never left, so the refusal is retried on its
    // own once Android is willing to start the service.
    serviceAllowed = true;
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();

    expect(deviceCalls, contains('download'));
    expect(find.textContaining('back on screen'), findsNothing);
  });

  testWidgets('a queue refused in the background waits for the app',
      (tester) async {
    prefs['auto_download'] = '1';
    serviceAllowed = false;

    // The link resolves behind another app, so the refusal happens while the
    // app is not on screen and no resume has happened yet.
    Future<ResolvedLink> resolveInBackground(String url) async {
      final resolved = await fakeResolve(url);
      goToBackground(tester);
      return resolved;
    }

    await tester.pumpWidget(
      MaterialApp(home: HomePage(resolveLink: resolveInBackground)),
    );
    await tester.pumpAndSettle();

    expect(deviceCalls, isNot(contains('download')));
    expect(find.textContaining('back on screen'), findsOneWidget);

    // Nothing retries while the app is away, however long it waits.
    serviceAllowed = true;
    await tester.pump(const Duration(seconds: 5));
    expect(deviceCalls, isNot(contains('download')));

    comeToForeground(tester);
    await tester.pumpAndSettle();

    expect(deviceCalls, contains('download'));
    expect(find.textContaining('back on screen'), findsNothing);
  });
}
