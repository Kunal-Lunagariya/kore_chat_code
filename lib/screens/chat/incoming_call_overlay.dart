import 'package:flutter/material.dart';
import '../../theme/app_theme.dart';
import 'call_screen.dart';

class IncomingCallOverlay extends StatelessWidget {
  final String callerName;
  final String callType;
  final Map<String, dynamic> offer;
  final int myUserId;
  final int callerUserId;
  final VoidCallback onDismiss;

  const IncomingCallOverlay({
    super.key,
    required this.callerName,
    required this.callType,
    required this.offer,
    required this.myUserId,
    required this.callerUserId,
    required this.onDismiss,
  });

  String _initials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '?';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Material(
      color: Colors.transparent,
      child: Container(
        margin: EdgeInsets.fromLTRB(
            16, MediaQuery.of(context).padding.top + 8, 16, 0),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E2E) : const Color(0xFF1A1A2E),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 20,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 48,
              height: 48,
              decoration: const BoxDecoration(
                color: Color(0xFF7C3AED),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  _initials(callerName),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    callerName,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Incoming ${callType == 'video' ? 'video' : 'audio'} call',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
            // Decline
            GestureDetector(
              onTap: onDismiss,
              child: Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                    color: AppTheme.redAccent, shape: BoxShape.circle),
                child: const Icon(Icons.call_end_rounded,
                    color: Colors.white, size: 20),
              ),
            ),
            const SizedBox(width: 8),
            // Accept
            GestureDetector(
              onTap: () {
                onDismiss();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CallScreen(
                      myUserId: myUserId,
                      remoteUserId: callerUserId,
                      remoteUserName: callerName,
                      callType: callType,
                      isOutgoing: false,
                      incomingOffer: offer,
                    ),
                  ),
                );
              },
              child: Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                    color: Color(0xFF4CAF50), shape: BoxShape.circle),
                child: Icon(
                  callType == 'video'
                      ? Icons.videocam_rounded
                      : Icons.call_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}