import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'home_page.dart';
import 'store.dart';

void main() {
  runApp(const GrabberApp());
}

class GrabberApp extends StatefulWidget {
  const GrabberApp({super.key});

  @override
  State<GrabberApp> createState() => _GrabberAppState();
}

class _GrabberAppState extends State<GrabberApp> {
  final Store _store = Store();
  ThemeMode _mode = ThemeMode.system;

  @override
  void initState() {
    super.initState();
    _restoreTheme();
  }

  Future<void> _restoreTheme() async {
    final saved = await _store.themeMode();
    if (!mounted || saved == _mode) return;
    setState(() => _mode = saved);
  }

  Future<void> _setThemeMode(ThemeMode mode) async {
    setState(() => _mode = mode);
    await _store.saveThemeMode(mode);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spotify Grabber',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: _mode,
      home: HomePage(themeMode: _mode, onThemeMode: _setThemeMode),
    );
  }
}
