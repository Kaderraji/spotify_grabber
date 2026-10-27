import 'package:flutter/services.dart';

/// The version Android has installed, and a way to send the user to a link
/// the app cannot show itself.
class AppInfo {
  const AppInfo();

  static const MethodChannel _channel = MethodChannel('grabber/app');

  Future<AppVersion> version() async {
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>('version');
      return AppVersion(
        name: result?['name'] as String? ?? '1.0.0',
        code: (result?['code'] as num?)?.toInt() ?? 0,
      );
    } on PlatformException {
      return AppVersion.unknown;
    } on MissingPluginException {
      return AppVersion.unknown;
    }
  }

  /// Opens [url] in the browser. False when the phone has nothing to open it.
  Future<bool> openUrl(String url) async {
    try {
      return await _channel.invokeMethod<bool>('openUrl', {'url': url}) ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }
}

class AppVersion {
  const AppVersion({required this.name, required this.code});

  /// Used when the native side cannot answer (widget tests, a broken plugin).
  static const AppVersion unknown = AppVersion(name: '1.0.0', code: 0);

  final String name;
  final int code;

  String get label => '$name ($code)';
}
