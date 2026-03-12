import 'package:flutter/material.dart';

class CustomToast {
  static OverlayEntry? _currentToast;

  static void showError(BuildContext context, String message) {
    _showToast(context, message, isError: true);
  }

  static void showSuccess(BuildContext context, String message) {
    _showToast(context, message, isError: false);
  }

  static void showInfo(BuildContext context, String message) {
    _showToast(context, message, isError: false, isInfo: true);
  }

  static void _showToast(
    BuildContext context,
    String message, {
    required bool isError,
    bool isInfo = false,
  }) {
    // Remove existing toast if any
    _currentToast?.remove();
    _currentToast = null;

    // Get root overlay to show above dialogs
    final overlay = Overlay.of(context, rootOverlay: true);

    _currentToast = OverlayEntry(
      builder: (context) {
        final bottomInset = MediaQuery.of(context).viewInsets.bottom;

        return Positioned(
          left: 16,
          right: 16,
          bottom: bottomInset > 0
              ? bottomInset +
                    16 // 🔥 above keyboard
              : 80, // normal position
          child: Material(
            color: Colors.transparent,
            child: _ToastWidget(
              message: message,
              isError: isError,
              isInfo: isInfo,
              duration: const Duration(seconds: 3),
              onDismiss: () {
                _currentToast?.remove();
                _currentToast = null;
              },
            ),
          ),
        );
      },
    );

    overlay.insert(_currentToast!);

    // Auto remove after duration
    Future.delayed(const Duration(seconds: 3), () {
      _currentToast?.remove();
      _currentToast = null;
    });
  }
}

class _ToastWidget extends StatefulWidget {
  final String message;
  final bool isError;
  final bool isInfo;
  final Duration duration;
  final VoidCallback onDismiss;

  const _ToastWidget({
    required this.message,
    required this.isError,
    required this.isInfo,
    required this.duration,
    required this.onDismiss,
  });

  @override
  State<_ToastWidget> createState() => _ToastWidgetState();
}

class _ToastWidgetState extends State<_ToastWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 1), // Slide up from bottom
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _controller.forward();

    // Start fade out animation before removal
    Future.delayed(widget.duration - const Duration(milliseconds: 300), () {
      if (mounted) {
        _controller.reverse().then((_) {
          widget.onDismiss();
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color get _backgroundColor {
    if (widget.isError) return const Color(0xFFDC2626); // Red
    if (widget.isInfo) return const Color(0xFF2563EB); // Blue
    return const Color(0xFF16A34A); // Green
  }

  IconData get _icon {
    if (widget.isError) return Icons.error_outline;
    if (widget.isInfo) return Icons.info_outline;
    return Icons.check_circle_outline;
  }

  @override
  Widget build(BuildContext context) {
    return SlideTransition(
      position: _slideAnimation,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 16),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: _backgroundColor,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.2),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            children: [
              Icon(_icon, color: Colors.white, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.message,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
