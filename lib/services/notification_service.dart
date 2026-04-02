import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:vibration/vibration.dart';
import 'firebase_messaging_service.dart';

// ── Must be top-level — handles action buttons in background ────
@pragma('vm:entry-point')
void _onBackgroundNotificationTap(NotificationResponse response) {
  final actionId = response.actionId;
  final payload = response.payload ?? '';

  if (actionId == 'decline_call') {
    // Cancel notification and stop ringing
    NotificationService().stopRinging();
    NotificationService().cancelCallNotification();
  } else if (actionId == 'accept_call') {
    // Stop ringing — app will open via payload
    NotificationService().stopRinging();
    NotificationService().cancelCallNotification();
    // Navigation handled by onDidReceiveNotificationResponse when app opens
  }
}

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin =
  FlutterLocalNotificationsPlugin();
  final FirebaseMessaging _fcm = FirebaseMessaging.instance;

  bool _isRinging = false;
  String? _fcmToken;
  String? get fcmToken => _fcmToken;

  // ── Init ────────────────────────────────────────────────────────

  Future<void> init() async {
    // 1. Register background handler
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // 2. Request permissions
    await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      criticalAlert: true,
    );

    // 3. Init local notifications
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    await _createChannels();

    if (Platform.isAndroid) {
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      await androidImpl?.requestNotificationsPermission();
    }

    // 4. Get FCM token
    _fcmToken = await _fcm.getToken();
    debugPrint('📱 FCM Token: $_fcmToken');

    // 5. Token refresh
    _fcm.onTokenRefresh.listen((token) {
      _fcmToken = token;
      debugPrint('📱 FCM Token Refreshed: $token');
      // TODO: Send updated token to your backend
    });

    // 6. Foreground FCM messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // 7. App opened from notification (background → foreground)
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

    // 8. iOS foreground display
    await _fcm.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );
  }

  // ── Channels ────────────────────────────────────────────────────

  Future<void> _createChannels() async {
    if (!Platform.isAndroid) return;

    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        'kore_messages', 'Messages',
        description: 'New chat message notifications',
        importance: Importance.high,
        sound: RawResourceAndroidNotificationSound('kore_message'),
        playSound: true,
        enableVibration: true,
      ),
    );

    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        'kore_calls', 'Incoming Calls',
        description: 'Incoming call notifications',
        importance: Importance.max,
        sound: RawResourceAndroidNotificationSound('kore_ringtone'),
        playSound: true,
        enableVibration: true,
        showBadge: true,
      ),
    );
  }

  // ── FCM Foreground Handler ──────────────────────────────────────

  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    final data = message.data;
    final type = data['type'] ?? 'message';

    if (type == 'call') {
      await startRinging();
      await showIncomingCallNotification(
        callerId: int.tryParse(data['callerId'] ?? '0') ?? 0,
        callerName: data['callerName'] ?? 'Unknown',
        callType: data['callType'] ?? 'audio',
      );
    } else {
      final conversationId = int.tryParse(data['conversationId'] ?? '0') ?? 0;
      await showMessageNotification(
        conversationId: conversationId,
        senderName: data['senderName'] ?? 'New Message',
        message: data['message'] ?? '',
        isGroup: data['isGroup'] == 'true',
        groupName: data['groupName'],
      );
    }
  }

  void _handleNotificationTap(RemoteMessage message) {
    debugPrint('Notification opened app: ${message.data}');
    // TODO: Navigate using global navigator key
  }

  void _onNotificationTap(NotificationResponse response) {
    debugPrint('Notification tapped: ${response.payload}, action: ${response.actionId}');

    final actionId = response.actionId;

    if (actionId == 'decline_call') {
      stopRinging();
      cancelCallNotification();
      return;
    }

    if (actionId == 'accept_call' || response.payload?.startsWith('call_') == true) {
      stopRinging();
      cancelCallNotification();
      // TODO: Navigate to call screen using global navigator key
      // NavigationService.navigatorKey.currentState?.push(...)
    }

    if (response.payload?.startsWith('chat_') == true) {
      // TODO: Navigate to chat screen using global navigator key
    }
  }

  // ── Message Notification ────────────────────────────────────────

  Future<void> showMessageNotification({
    required int conversationId,
    required String senderName,
    required String message,
    bool isGroup = false,
    String? groupName,
  }) async {
    final title = isGroup ? '${groupName ?? 'Group'}: $senderName' : senderName;
    final body = message.isEmpty ? '📎 Media' : message;

    final androidDetails = AndroidNotificationDetails(
      'kore_messages',
      'Messages',
      channelDescription: 'New chat message notifications',
      importance: Importance.high,
      priority: Priority.high,
      sound: const RawResourceAndroidNotificationSound('kore_message'),
      styleInformation: BigTextStyleInformation(body),
      groupKey: 'kore_chat_$conversationId',
      autoCancel: true,
      ticker: 'New message',
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'kore_message.aiff',
    );

    await _plugin.show(
      conversationId,
      title,
      body,
      NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: 'chat_$conversationId',
    );
  }

  // ── Call Notification ───────────────────────────────────────────

  Future<void> showIncomingCallNotification({
    required int callerId,
    required String callerName,
    required String callType,
  }) async {
    final icon = callType == 'video' ? '📹' : '📞';

    final androidDetails = AndroidNotificationDetails(
      'kore_calls',
      'Incoming Calls',
      channelDescription: 'Incoming call notifications',
      importance: Importance.max,
      priority: Priority.max,
      sound: const RawResourceAndroidNotificationSound('kore_ringtone'),
      fullScreenIntent: true,
      ongoing: true,
      autoCancel: false,
      showWhen: false,              // ← add
      enableLights: true,           // ← add
      enableVibration: true,        // ← add
      playSound: true,              // ← add
      category: AndroidNotificationCategory.call,
      visibility: NotificationVisibility.public,  // ← add (shows on lock screen)
      actions: const [
        AndroidNotificationAction(
          'decline_call',
          'Decline',
          cancelNotification: true,
          showsUserInterface: true,  // ← add
        ),
        AndroidNotificationAction(
          'accept_call',
          'Accept',
          cancelNotification: true,
          showsUserInterface: true,  // ← add
        ),
      ],
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'kore_ringtone.aiff',
      interruptionLevel: InterruptionLevel.timeSensitive,
    );

    await _plugin.show(
      9999,
      '$icon Incoming ${callType == 'video' ? 'Video' : 'Audio'} Call',
      callerName,
      NotificationDetails(android: androidDetails, iOS: iosDetails),
      payload: 'call_$callerId',
    );
  }

  Future<void> cancelCallNotification() async {
    await _plugin.cancel(9999);
  }

  // ── Ringtone ────────────────────────────────────────────────────

  Future<void> startRinging() async {
    if (_isRinging) return;
    _isRinging = true;
    FlutterRingtonePlayer().playRingtone(looping: true, asAlarm: false);
    if (await Vibration.hasVibrator() ?? false) {
      Vibration.vibrate(pattern: [0, 500, 1000, 500], repeat: 2);
    }
  }

  Future<void> stopRinging() async {
    if (!_isRinging) return;
    _isRinging = false;
    FlutterRingtonePlayer().stop();
    Vibration.cancel();
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
    await stopRinging();
  }
}