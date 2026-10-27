import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_grabber/app_info.dart';
import 'package:spotify_grabber/home_page.dart';
import 'package:spotify_grabber/update_check.dart';

class FakeAppInfo implements AppInfo {
  FakeAppInfo(this.installed);

  final AppVersion installed;
  final opened = <String>[];

  @override
  Future<AppVersion> version() async => installed;

  @override
  Future<bool> openUrl(String url) async {
    opened.add(url);
    return true;
  }
}

class FakeUpdates extends UpdateService {
  FakeUpdates(this.result);

  final Update? result;

  @override
  Future<Update?> latest() async => result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
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

  Future<void> openSettings(
    WidgetTester tester, {
    required AppInfo appInfo,
    required UpdateService updates,
  }) async {
    await tester.pumpWidget(
      MaterialApp(home: HomePage(appInfo: appInfo, updates: updates)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
  }

  testWidgets('settings shows the installed version and finds a newer one',
      (tester) async {
    final info = FakeAppInfo(const AppVersion(name: '1.0.0', code: 7));

    await openSettings(
      tester,
      appInfo: info,
      updates: FakeUpdates(
        const Update(version: '1.1.0', url: 'https://example.com/app.apk'),
      ),
    );

    expect(find.text('Version 1.0.0 (7)'), findsOneWidget);

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(find.text('Version 1.1.0 is available.'), findsOneWidget);

    // The sheet scrolls on a short screen, so bring the button into view.
    await tester.ensureVisible(find.text('Get it'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Get it'));
    await tester.pumpAndSettle();

    expect(info.opened, ['https://example.com/app.apk']);
  });

  testWidgets('a build that is up to date says so', (tester) async {
    await openSettings(
      tester,
      appInfo: FakeAppInfo(const AppVersion(name: '1.0.0', code: 7)),
      updates: FakeUpdates(
        const Update(version: '1.0.0', url: 'https://example.com/app.apk'),
      ),
    );

    await tester.tap(find.text('Check for updates'));
    await tester.pumpAndSettle();

    expect(find.text('You are on the latest version.'), findsOneWidget);
    expect(find.text('Get it'), findsNothing);
  });
}
