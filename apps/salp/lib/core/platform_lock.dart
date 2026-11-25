import 'package:flutter/services.dart';

/// OS unlock only restores sessions that had no application password lock.
/// The UI decides whether a separate master-password check is still required.
class PlatformLock {
  static const channel = MethodChannel('dev.salp/session-lock');
  static void listen(void Function(bool locked) onChange) {
    channel.setMethodCallHandler((call) async {
      if (call.method == 'lock') onChange(true);
      if (call.method == 'unlock') onChange(false);
    });
  }

  static void stop() => channel.setMethodCallHandler(null);
}
