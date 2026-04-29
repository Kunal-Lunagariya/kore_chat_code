import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/debug_logger.dart';

class DebugLogScreen extends StatefulWidget {
  const DebugLogScreen({super.key});

  @override
  State<DebugLogScreen> createState() => _DebugLogScreenState();
}

class _DebugLogScreenState extends State<DebugLogScreen> {
  List<Map<String, String>> _entries = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final entries = await DebugLogger.getEntries();
    if (mounted) setState(() { _entries = entries; _loading = false; });
  }

  Future<void> _clear() async {
    await DebugLogger.clear();
    await _load();
  }

  void _copyAll() {
    final buf = StringBuffer();
    for (final e in _entries.reversed) {
      buf.writeln('[${e['ts']}] [${e['tag']}] ${e['msg']}');
    }
    Clipboard.setData(ClipboardData(text: buf.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Copied to clipboard')),
    );
  }

  Color _tagColor(String tag) {
    switch (tag) {
      case 'BGHandler': return Colors.orange;
      case 'NotifService': return Colors.cyan;
      case 'Main': return Colors.green;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        title: const Text('Debug Log', style: TextStyle(color: Colors.white, fontSize: 16)),
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.white),
            onPressed: _load,
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.copy_all, color: Colors.white),
            onPressed: _entries.isEmpty ? null : _copyAll,
            tooltip: 'Copy all',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
            onPressed: _entries.isEmpty ? null : _clear,
            tooltip: 'Clear',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? const Center(
                  child: Text(
                    'No logs yet.\nKill the app, send a call, then reopen.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, fontSize: 14),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(8),
                  itemCount: _entries.length,
                  separatorBuilder: (_, __) => const Divider(
                    color: Colors.white10,
                    height: 1,
                  ),
                  itemBuilder: (_, i) {
                    final e = _entries[i];
                    final ts = e['ts'] ?? '';
                    final tag = e['tag'] ?? '';
                    final msg = e['msg'] ?? '';
                    // Show only time portion for readability
                    final timePart = ts.length > 10 ? ts.substring(11, 23) : ts;
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            timePart,
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 11,
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                            decoration: BoxDecoration(
                              color: _tagColor(tag).withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(4),
                              border: Border.all(color: _tagColor(tag).withValues(alpha: 0.5)),
                            ),
                            child: Text(
                              tag,
                              style: TextStyle(
                                color: _tagColor(tag),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              msg,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
    );
  }
}
