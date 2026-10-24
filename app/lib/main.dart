import 'package:flutter/material.dart';

import 'audio_format.dart';
import 'device_downloader.dart';
import 'home_page.dart';
import 'spotify_meta.dart';

const Color _seed = Color(0xFF1DB954);

// Temporary verification hook: --dart-define=AUTOTEST_URL=<link>
// [&AUTOTEST_FORMAT=mp3|opus|flac|all] runs the real download path headlessly.
const String _autotestUrl = String.fromEnvironment('AUTOTEST_URL');
const String _autotestFormat = String.fromEnvironment('AUTOTEST_FORMAT');

void main() {
  if (_autotestUrl.isNotEmpty) {
    _runAutotest(_autotestUrl, _autotestFormat);
    return;
  }
  runApp(const GrabberApp());
}

Future<void> _runAutotest(String url, String formatId) async {
  WidgetsFlutterBinding.ensureInitialized();
  final downloader = DeviceDownloader();
  downloader.events.listen((event) => debugPrint('AUTOTEST event $event'));
  final formats = formatId == 'all'
      ? AudioFormat.all
      : <AudioFormat>[AudioFormat.byId(formatId)];
  try {
    debugPrint('AUTOTEST prepare=${await downloader.prepare()}');
    final link = await resolveSpotifyLink(url);
    for (final track in link.tracks.take(1)) {
      for (final format in formats) {
        final saved = await downloader.download(
          id: track.id,
          query: '${track.artists} - ${track.title}',
          title: track.title,
          artist: track.artists,
          duration: track.duration,
          name: '${track.artists} - ${track.title}',
          format: format,
        );
        debugPrint(
          'AUTOTEST ${format.id} saved path=${saved.path} size=${saved.size}',
        );
      }
    }
  } catch (error) {
    debugPrint('AUTOTEST FAILED $error');
  }
  debugPrint('AUTOTEST DONE');
}

class GrabberApp extends StatelessWidget {
  const GrabberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spotify Grabber',
      debugShowCheckedModeBanner: false,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }

  ThemeData _theme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: _seed,
      brightness: brightness,
    );
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);

    return base.copyWith(
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 48),
          padding: const EdgeInsets.symmetric(horizontal: 20),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: scheme.primary,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        showDragHandle: true,
      ),
    );
  }
}
