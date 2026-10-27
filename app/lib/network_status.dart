import 'dart:async';

import 'package:flutter/services.dart';

/// Whether the phone's default connection is Wi-Fi, for the Wi-Fi-only
/// setting: asked before a queue starts and watched while it runs.
///
/// Anything unknown — no native side (widget tests), a platform error — counts
/// as Wi-Fi, so a broken check can never strand a download.
class NetworkStatus {
  static const MethodChannel _channel = MethodChannel('grabber/network');
  static const EventChannel _events = EventChannel('grabber/network/status');

  Future<bool> isWifi() async {
    try {
      return await _channel.invokeMethod<bool>('isWifi') ?? true;
    } on PlatformException {
      return true;
    } on MissingPluginException {
      return true;
    }
  }

  /// The current state first, then every change of the default connection.
  Stream<bool> get changes =>
      _events.receiveBroadcastStream().map((value) => value != false);
}
