import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/api_call_service.dart';
import '../../services/notification_service.dart';
import '../../socket/socket_index.dart';
import '../../theme/app_theme.dart';
import '../home/home_screen.dart';
import '../login/login_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  static const String _prefToken = 'auth_token';
  static const String _prefUserId = 'user_id';
  static const String _prefUserName = 'user_name';

  @override
  void initState() {
    super.initState();
    _checkLoginStatus();
  }

  Future<bool> _hasActiveCalls() async {
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      return calls != null && (calls as List).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> _requestPermissions() async {
    final mic = await Permission.microphone.status;
    final cam = await Permission.camera.status;

    final needsRequest = [
      if (!mic.isGranted && !mic.isPermanentlyDenied) Permission.microphone,
      if (!cam.isGranted && !cam.isPermanentlyDenied) Permission.camera,
    ];

    if (needsRequest.isNotEmpty) {
      await needsRequest.request();
    }

    final micFinal = await Permission.microphone.status;
    final camFinal = await Permission.camera.status;

    debugPrint('🎤 Mic: $micFinal');
    debugPrint('📷 Cam: $camFinal');

    if ((micFinal.isPermanentlyDenied || camFinal.isPermanentlyDenied) &&
        mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Permissions Required'),
          content: const Text(
            'Microphone and Camera access are required for calls.\n\n'
            'Please enable them in Settings → Kore Circle.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Skip'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.pop(ctx);
                await openAppSettings();
              },
              child: const Text('Open Settings'),
            ),
          ],
        ),
      );
    }
  }

  Future<void> _checkLoginStatus() async {
    // Skip the splash delay when app was launched by a CallKit accept —
    // every extra millisecond here delays reaching HomeScreen and the call.
    final launchedByCall = NotificationService.pendingAcceptedCall != null ||
        await _hasActiveCalls();
    if (!launchedByCall) {
      await Future.delayed(const Duration(milliseconds: 1200));
    }

    await _requestPermissions();

    final prefs = await SharedPreferences.getInstance();
    final token = prefs.getString(_prefToken);

    if (!mounted) return;

    if (token != null && token.isNotEmpty) {
      ApiCall.setAuthToken(token);
      final userId = prefs.getInt(_prefUserId) ?? 0;
      final userName = prefs.getString(_prefUserName) ?? '';
      SocketIndex.connectSocket(token, userId: userId);
      // Re-register device tokens every launch — token may have rotated
      _registerDeviceTokens(userId: userId);
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => HomeScreen(userId: userId, userName: userName),
        ),
      );
    } else {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
      );
    }
  }

  Future<void> _registerDeviceTokens({required int userId}) async {
    try {
      final fcmToken = NotificationService().fcmToken;
      final voipToken = NotificationService().voipToken;
      if (fcmToken == null || fcmToken.isEmpty) return;
      await ApiCall.post(
        'v1/user/user-device',
        data: {
          'userId': userId,
          'deviceType': Platform.isIOS ? 'ios' : 'android',
          'fcmToken': fcmToken,
          'voIpToken': voipToken,
        },
      );
      debugPrint('✅ Device tokens re-registered on auto-login');
    } catch (e) {
      debugPrint('⚠️ Token registration failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      ),
    );

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.redAccent, AppTheme.redDark],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(24),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.redAccent.withValues(alpha: 0.4),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: const Icon(
                Icons.chat_bubble_rounded,
                color: Colors.white,
                size: 40,
              ),
            ),
            const SizedBox(height: 20),
            RichText(
              text: TextSpan(
                children: [
                  TextSpan(
                    text: 'KORE ',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.darkTextPrimary
                          : AppTheme.lightTextPrimary,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                    ),
                  ),
                  const TextSpan(
                    text: 'CIRCLE',
                    style: TextStyle(
                      color: AppTheme.redAccent,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 48),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.redAccent),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
