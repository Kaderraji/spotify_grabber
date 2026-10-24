import 'dart:async';

import 'package:flutter/services.dart';

/// Links handed over by Android's share sheet.
///
/// The native side picks the Spotify link out of the shared text, so what
/// arrives here is always a bare link. Two paths exist because Android
/// delivers a share either as the intent that launched the app or, when the
/// app is already open, as a new intent on the running activity.
class ShareIntake {
  static const MethodChannel _channel = MethodChannel('grabber/share');

  final StreamController<String> _links = StreamController<String>.broadcast();

  ShareIntake() {
    _channel.setMethodCallHandler(_onCall);
  }

  /// Links shared while the app was already running.
  Stream<String> get links => _links.stream;

  /// The link that launched the app, if it was opened from a share.
  Future<String?> launchLink() async {
    try {
      return await _channel.invokeMethod<String>('getInitialLink');
    } on PlatformException {
      return null;
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    if (call.method == 'sharedLink') {
      final link = call.arguments as String?;
      if (link != null && link.isNotEmpty) _links.add(link);
    }
    return null;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _links.close();
  }
}
