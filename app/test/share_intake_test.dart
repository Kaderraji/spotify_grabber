import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:spotify_grabber/home_page.dart';

const _link = 'https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  Map<String, dynamic> initialShare = <String, dynamic>{};

  setUp(() {
    initialShare = <String, dynamic>{};
    messenger.setMockMethodCallHandler(
      const MethodChannel('grabber/on_device'),
      (call) async {
        switch (call.method) {
          case 'prepare':
            return 'test-engine';
          case 'getFormat':
            return 'm4a';
          case 'download':
            return {'path': '/tmp/file.m4a', 'size': 1};
          default:
            return null;
        }
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('grabber/store'),
      (call) async => null,
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('grabber/share'),
      (call) async =>
          call.method == 'getInitialShare' ? initialShare : null,
    );
    // The app listens for progress the native side never sends in a test.
    messenger.setMockStreamHandler(
      const EventChannel('grabber/on_device/progress'),
      MockStreamHandler.inline(onListen: (arguments, events) {}),
    );
  });

  tearDown(() {
    messenger
      ..setMockMethodCallHandler(const MethodChannel('grabber/on_device'), null)
      ..setMockMethodCallHandler(const MethodChannel('grabber/store'), null)
      ..setMockMethodCallHandler(const MethodChannel('grabber/share'), null)
      ..setMockStreamHandler(
        const EventChannel('grabber/on_device/progress'),
        null,
      );
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));
    await tester.pump();
  }

  String fieldText(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).controller!.text;

  Future<void> pushShare(String method, Object? argument) async {
    await messenger.handlePlatformMessage(
      'grabber/share',
      const StandardMethodCodec()
          .encodeMethodCall(MethodCall(method, argument)),
      (_) {},
    );
  }

  testWidgets('a share that launched the app fills the link field',
      (tester) async {
    initialShare = {'link': _link};

    await pumpApp(tester);
    await tester.pump();

    expect(fieldText(tester), _link);
  });

  testWidgets('a share while the app is open fills the link field',
      (tester) async {
    await pumpApp(tester);
    expect(fieldText(tester), isEmpty);

    await pushShare('sharedLink', _link);
    await tester.pump();

    expect(fieldText(tester), _link);
  });

  testWidgets('a share without a Spotify link says so', (tester) async {
    initialShare = {'rejected': 'Just some text from another app'};

    await pumpApp(tester);
    await tester.pump();

    expect(fieldText(tester), isEmpty);
    expect(
      find.textContaining('no Spotify link'),
      findsOneWidget,
    );
  });

  testWidgets('a rejected share while open says so', (tester) async {
    await pumpApp(tester);

    await pushShare('sharedRejected', 'Nothing to do with music');
    await tester.pump();

    expect(find.textContaining('no Spotify link'), findsOneWidget);
  });
}
