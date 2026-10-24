import 'dart:async';

import 'package:flutter/services.dart';

/// What arrived from Android's share sheet: either a Spotify link to use, or
/// the shared text that had no link in it, which the app explains instead of
/// opening silently.
class ShareEvent {
  const ShareEvent({this.link, this.rejected});

  final String? link;
  final String? rejected;

  bool get hasLink => link != null && link!.isNotEmpty;
}

/// Links handed over by Android's share sheet.
///
/// The native side picks the Spotify link out of the shared text, so a link
/// arrives bare. Two paths exist because Android delivers a share either as
/// the intent that launched the app or, when the app is already open, as a new
/// intent on the running activity.
class ShareIntake {
  static const MethodChannel _channel = MethodChannel('grabber/share');

  final StreamController<ShareEvent> _events =
      StreamController<ShareEvent>.broadcast();

  ShareIntake() {
    _channel.setMethodCallHandler(_onCall);
  }

  /// Shares that arrived while the app was already running.
  Stream<ShareEvent> get events => _events.stream;

  /// The share that launched the app, if it was opened from the share sheet.
  Future<ShareEvent?> launchShare() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'getInitialShare',
      );
      if (result == null) return null;
      final link = result['link'] as String?;
      final rejected = result['rejected'] as String?;
      if ((link == null || link.isEmpty) &&
          (rejected == null || rejected.isEmpty)) {
        return null;
      }
      return ShareEvent(link: link, rejected: rejected);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  Future<dynamic> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'sharedLink':
        final link = call.arguments as String?;
        if (link != null && link.isNotEmpty) {
          _events.add(ShareEvent(link: link));
        }
      case 'sharedRejected':
        _events.add(ShareEvent(rejected: call.arguments as String? ?? ''));
    }
    return null;
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    _events.close();
  }
}
