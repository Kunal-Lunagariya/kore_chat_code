import 'dart:ui';
import 'package:flutter/material.dart';
import '../../services/notification_service.dart';
import 'call_screen.dart';

class IncomingCallOverlay extends StatefulWidget {
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

  @override
  State<IncomingCallOverlay> createState() => _IncomingCallOverlayState();
}

class _IncomingCallOverlayState extends State<IncomingCallOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _slide;
  late Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _slide = Tween<Offset>(
      begin: const Offset(0, -1.2),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));

    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    await _ctrl.reverse();
    widget.onDismiss();
  }

  void _decline() {
    NotificationService().endCall();
    _dismiss();
  }

  void _accept() {
    NotificationService().endCall();
    _dismiss();
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          myUserId: widget.myUserId,
          remoteUserId: widget.callerUserId,
          remoteUserName: widget.callerName,
          callType: widget.callType,
          isOutgoing: false,
          incomingOffer: widget.offer,
        ),
      ),
    );
  }

  String _initials(String name) {
    final parts =
    name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '?';
  }

  Color _avatarColor(String name) {
    const colors = [
      Color(0xFF5C6BC0), Color(0xFF26A69A), Color(0xFFEF5350),
      Color(0xFFAB47BC), Color(0xFF42A5F5), Color(0xFFFF7043),
      Color(0xFF66BB6A), Color(0xFFEC407A),
    ];
    return colors[name.length % colors.length];
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;

    return SlideTransition(
      position: _slide,
      child: FadeTransition(
        opacity: _fade,
        child: Material(
          color: Colors.transparent,
          child: Padding(
            padding: EdgeInsets.fromLTRB(12, topPad + 8, 12, 0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF1C1C2E).withOpacity(0.88),
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: Colors.white.withOpacity(0.10),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.45),
                        blurRadius: 32,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ── Top accent bar ──
                      Container(
                        height: 3,
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Color(0xFF7C3AED),
                              Color(0xFF9333EA),
                              Color(0xFF6366F1),
                            ],
                          ),
                          borderRadius: BorderRadius.vertical(
                            top: Radius.circular(24),
                          ),
                        ),
                      ),

                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                        child: Row(
                          children: [
                            // ── Avatar with pulse ring ──
                            _PulsingAvatar(
                              initials: _initials(widget.callerName),
                              color: _avatarColor(widget.callerName),
                            ),

                            const SizedBox(width: 14),

                            // ── Name + call type ──
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.callerName,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: -0.3,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 3),
                                  Row(
                                    children: [
                                      Icon(
                                        widget.callType == 'video'
                                            ? Icons.videocam_rounded
                                            : Icons.call_rounded,
                                        size: 13,
                                        color: const Color(0xFF9333EA),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Incoming ${widget.callType == 'video' ? 'video' : 'audio'} call',
                                        style: TextStyle(
                                          color:
                                          Colors.white.withOpacity(0.55),
                                          fontSize: 12,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(width: 12),

                            // ── Decline button ──
                            _OverlayActionBtn(
                              icon: Icons.call_end_rounded,
                              color: const Color(0xFFE53935),
                              onTap: _decline,
                              tooltip: 'Decline',
                            ),

                            const SizedBox(width: 10),

                            // ── Accept button ──
                            _OverlayActionBtn(
                              icon: widget.callType == 'video'
                                  ? Icons.videocam_rounded
                                  : Icons.call_rounded,
                              color: const Color(0xFF43A047),
                              onTap: _accept,
                              tooltip: 'Accept',
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Pulsing avatar with soft ring animation ──────────────────────

class _PulsingAvatar extends StatefulWidget {
  final String initials;
  final Color color;

  const _PulsingAvatar({required this.initials, required this.color});

  @override
  State<_PulsingAvatar> createState() => _PulsingAvatarState();
}

class _PulsingAvatarState extends State<_PulsingAvatar>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _scale;
  late Animation<double> _opacity;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();

    _scale = Tween(begin: 1.0, end: 1.5).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
    _opacity = Tween(begin: 0.5, end: 0.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Pulse ring
          AnimatedBuilder(
            animation: _ctrl,
            builder: (_, __) => Transform.scale(
              scale: _scale.value,
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: widget.color.withOpacity(_opacity.value),
                    width: 2,
                  ),
                ),
              ),
            ),
          ),
          // Avatar
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color,
              boxShadow: [
                BoxShadow(
                  color: widget.color.withOpacity(0.4),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Center(
              child: Text(
                widget.initials,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Accept / Decline round button ───────────────────────────────

class _OverlayActionBtn extends StatelessWidget {
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  final String tooltip;

  const _OverlayActionBtn({
    required this.icon,
    required this.color,
    required this.onTap,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.4),
              blurRadius: 12,
              spreadRadius: 1,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(icon, color: Colors.white, size: 22),
      ),
    );
  }
}