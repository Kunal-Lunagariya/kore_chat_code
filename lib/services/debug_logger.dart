import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class DebugLogger {
  static const String _key = 'debug_log_entries';
  static const int _maxEntries = 200;

  static Future<void> log(String tag, String message) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key) ?? [];
      final entry = jsonEncode({
        'ts': DateTime.now().toIso8601String(),
        'tag': tag,
        'msg': message,
      });
      raw.add(entry);
      // Keep only last N entries to avoid bloat
      final trimmed = raw.length > _maxEntries
          ? raw.sublist(raw.length - _maxEntries)
          : raw;
      await prefs.setStringList(_key, trimmed);
    } catch (_) {}
  }

  static Future<List<Map<String, String>>> getEntries() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_key) ?? [];
      return raw.reversed.map((e) {
        try {
          final m = jsonDecode(e) as Map;
          return {
            'ts': m['ts']?.toString() ?? '',
            'tag': m['tag']?.toString() ?? '',
            'msg': m['msg']?.toString() ?? '',
          };
        } catch (_) {
          return {'ts': '', 'tag': 'ERR', 'msg': e};
        }
      }).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
