import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:spotify_grabber/update_check.dart';

void main() {
  test('a later version wins, a missing part counts as zero', () {
    expect(isNewerVersion('1.2.0', '1.1.9'), isTrue);
    expect(isNewerVersion('2.0.0', '1.99.99'), isTrue);
    expect(isNewerVersion('1.2.1', '1.2'), isTrue);
    expect(isNewerVersion('1.2', '1.2.0'), isFalse);
    expect(isNewerVersion('1.1.9', '1.2.0'), isFalse);
    expect(isNewerVersion('1.0.0-beta', '1.0.0'), isFalse);
  });

  test('the release tag loses its v', () {
    final update = parseRelease({
      'tag_name': 'v1.3.0',
      'html_url': 'https://github.com/x/y/releases/tag/v1.3.0',
    });
    expect(update!.version, '1.3.0');
  });

  test('the APK asset is what Get it opens', () {
    final update = parseRelease({
      'tag_name': 'v1.3.0',
      'html_url': 'https://github.com/x/y/releases/tag/v1.3.0',
      'assets': [
        {
          'name': 'notes.txt',
          'browser_download_url': 'https://example.com/notes.txt',
        },
        {
          'name': 'app-release.apk',
          'browser_download_url': 'https://example.com/app.apk',
        },
      ],
    });

    expect(update!.url, 'https://example.com/app.apk');
  });

  test('without an APK the release page is used', () {
    final update = parseRelease({
      'tag_name': '1.3.0',
      'html_url': 'https://github.com/x/y/releases/tag/1.3.0',
      'assets': const [],
    });

    expect(update!.url, 'https://github.com/x/y/releases/tag/1.3.0');
  });

  test('a release with no version or no link is ignored', () {
    expect(parseRelease({'tag_name': '', 'html_url': 'https://x'}), isNull);
    expect(parseRelease({'tag_name': 'v1.0.0'}), isNull);
  });

  group('UpdateService', () {
    test('reads the newest release', () async {
      final service = UpdateService(
        client: MockClient((request) async {
          expect(
            request.url.path,
            '/repos/Kaderraji/spotify_grabber/releases/latest',
          );
          return http.Response(
            jsonEncode({
              'tag_name': 'v1.1.0',
              'html_url': 'https://example.com/release',
            }),
            200,
          );
        }),
      );

      final update = await service.latest();

      expect(update!.version, '1.1.0');
      expect(update.url, 'https://example.com/release');
    });

    test('a repository without releases is explained', () async {
      final service = UpdateService(
        client: MockClient((_) async => http.Response('{}', 404)),
      );

      await expectLater(service.latest(), throwsA(isA<UpdateException>()));
    });

    test('an unreachable GitHub is explained', () async {
      final service = UpdateService(
        client: MockClient((_) async => throw http.ClientException('offline')),
      );

      await expectLater(service.latest(), throwsA(isA<UpdateException>()));
    });
  });
}
