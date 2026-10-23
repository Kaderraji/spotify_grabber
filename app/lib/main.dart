import 'package:flutter/material.dart';

import 'home_page.dart';

void main() {
  runApp(const GrabberApp());
}

class GrabberApp extends StatelessWidget {
  const GrabberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Spotify Grabber',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF1DB954),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}
