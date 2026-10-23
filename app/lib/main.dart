import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'home_page.dart';

/// Address of the downloader running on the PC. Change it in Settings if your
/// router hands out a different address.
const String kDefaultServer = String.fromEnvironment(
  'GRABBER_SERVER',
  defaultValue: 'http://192.168.11.147:8787',
);
const String _serverKey = 'server_url';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(GrabberApp(initialServer: prefs.getString(_serverKey) ?? kDefaultServer));
}

class GrabberApp extends StatefulWidget {
  const GrabberApp({super.key, required this.initialServer});

  final String initialServer;

  @override
  State<GrabberApp> createState() => _GrabberAppState();
}

class _GrabberAppState extends State<GrabberApp> {
  late String _server = widget.initialServer;

  Future<void> _saveServer(String url) async {
    setState(() => _server = url);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverKey, url);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spotify Grabber',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1DB954),
        useMaterial3: true,
      ),
      home: HomePage(
        key: ValueKey(_server),
        serverUrl: _server,
        onServerChanged: _saveServer,
      ),
    );
  }
}
