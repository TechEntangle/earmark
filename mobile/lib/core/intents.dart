// Siri, Shortcuts, the Action button and Spotlight (iOS): actions arrive here from the system,
// and conversations are listed in Spotlight.
import 'dart:io';

import 'package:flutter/services.dart';

class Intents {
  static const _ch = MethodChannel('earmark/intents');
  static bool get supported => Platform.isIOS;

  /// [f] gets each action: {action: earmark | pause | resume | ask | open | conversation, at, q?, tab?, id?}
  static Future<void> listen(void Function(Map<String, dynamic>) f) async {
    if (!supported) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'intent') f(Map<String, dynamic>.from(call.arguments as Map));
      return null;
    });
    try {
      for (final m in (await _ch.invokeMethod('drain') as List? ?? [])) {
        f(Map<String, dynamic>.from(m as Map));
      }
    } catch (_) {}
  }

  static Future<void> index(List<Map<String, Object?>> items) async {
    if (!supported || items.isEmpty) return;
    try {
      await _ch.invokeMethod('index', {'items': items});
    } catch (_) {}
  }

  static Future<void> unindex(List<String> ids) async {
    if (!supported || ids.isEmpty) return;
    try {
      await _ch.invokeMethod('unindex', {'ids': ids});
    } catch (_) {}
  }
}
