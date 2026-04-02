import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:uuid/uuid.dart';
import '../screens/chat/call_screen.dart';
import 'firebase_messaging_service.dart';
import 'navigation_service.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final FirebaseMessaging _fcm = FirebaseMessaging.instance;

  String? _fcmToken;
  String? get fcmToken => _fcmToken;
  String? _currentCallUuid;

  Map<String, dynamic>? _pendingOffer;
  int? _pendingCallerId;
  String? _pendingCallerName;
  String? _pendingCallType;
  int? _myUserId;

  void setMyUserId(int userId) => _myUserId = userId;

  void setPendingCall({
    required int callerId,
    required String callerName,
    required String callType,
    required Map<String, dynamic> offer,
  }) {
    _pendingCallerId = callerId;
    _pendingCallerName = callerName;
    _pendingCallType = callType;
    _pendingOffer = offer;
  }

  void clearPendingCall() {
    _pendingOffer = null;
    _pendingCallerId = null;
    _pendingCallerName = null;
    _pendingCallType = null;
  }

  void _onCallAccepted(dynamic body) async {
    debugPrint('✅ CallKit accepted: $body');

    final navigator = NavigationService.navigatorKey.currentState;
    if (navigator == null) {
      debugPrint('⚠️ Navigator not ready');
      return;
    }

    // Try getting offer from pending (set by socket in foreground)
    Map<String, dynamic>? offer = _pendingOffer;
    int? callerId = _pendingCallerId;
    String? callerName = _pendingCallerName;
    String? callType = _pendingCallType;

    // If no pending offer (app was killed), try reading from last FCM message
    if (offer == null) {
      try {
        final extra = body?['extra'] as Map?;
        if (extra != null) {
          final offerStr = extra['offerJson'] as String?;
          if (offerStr != null && offerStr.isNotEmpty) {
            offer = Map<String, dynamic>.from(
              (offerStr.isNotEmpty) ? _parseJson(offerStr) : {},
            );
          }
          callerId = int.tryParse(extra['callerId']?.toString() ?? '0') ?? 0;
          callerName = extra['callerName'] as String? ?? 'Unknown';
          callType = extra['callType'] as String? ?? 'audio';
        }
      } catch (e) {
        debugPrint('⚠️ Could not read offer from CallKit body: $e');
      }
    }

    if (offer == null ||
        offer.isEmpty ||
        callerId == null ||
        _myUserId == null) {
      debugPrint('⚠️ No offer available — cannot open CallScreen');
      clearPendingCall();
      return;
    }

    navigator
        .push(
          MaterialPageRoute(
            builder: (_) => CallScreen(
              myUserId: _myUserId!,
              remoteUserId: callerId!,
              remoteUserName: callerName ?? 'Unknown',
              callType: callType ?? 'audio',
              isOutgoing: false,
              incomingOffer: offer!,
            ),
          ),
        )
        .then((_) {
          clearPendingCall();
          endAllCalls();
        });
  }

  Map<String, dynamic> _parseJson(String raw) {
    // Simple JSON decode
    try {
      // Use dart:convert
      return Map<String, dynamic>.from(
        // ignore: avoid_dynamic_calls
        (raw.startsWith('{')) ? _jsonDecode(raw) : {},
      );
    } catch (_) {
      return {};
    }
  }

  // Add dart:convert import at top of file
  dynamic _jsonDecode(String s) {
    // Will use dart:convert json.decode
    return null; // placeholder — see Fix 3 below
  }

  void _onCallDeclined(dynamic body) {
    debugPrint('❌ CallKit declined');
    clearPendingCall();
    endAllCalls();
  }

  // ── Init ──────────────────────────────────────────────────────

  Future<void> init() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      criticalAlert: true,
    );

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    await _plugin.initialize(
      const InitializationSettings(android: androidSettings, iOS: iosSettings),
      onDidReceiveNotificationResponse: _onNotificationTap,
    );

    await _createMessageChannel();

    if (Platform.isAndroid) {
      final androidImpl = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      await androidImpl?.requestNotificationsPermission();
    }

    _fcmToken = await _fcm.getToken();
    debugPrint('📱 FCM Token: $_fcmToken');

    _fcm.onTokenRefresh.listen((token) {
      _fcmToken = token;
      debugPrint('📱 FCM Token Refreshed: $token');
    });

    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_handleNotificationTap);

    await _fcm.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    FlutterCallkitIncoming.onEvent.listen(_onCallKitEvent);
  }

  // ── CallKit events ────────────────────────────────────────────

  void _onCallKitEvent(CallEvent? event) {
    if (event == null) return;
    debugPrint('📞 CallKit event: ${event.event}');
    switch (event.event) {
      case Event.actionCallAccept:
        _onCallAccepted(event.body);
        break;
      case Event.actionCallDecline:
        _onCallDeclined(event.body);
        break;
      case Event.actionCallEnded:
      case Event.actionCallTimeout:
        _currentCallUuid = null;
        break;
      default:
        break;
    }
  }

  // ── Message channel ───────────────────────────────────────────

  Future<void> _createMessageChannel() async {
    if (!Platform.isAndroid) return;
    final androidImpl = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        'kore_messages',
        'Messages',
        description: 'New chat message notifications',
        importance: Importance.high,
        sound: RawResourceAndroidNotificationSound('kore_message'),
        playSound: true,
        enableVibration: true,
      ),
    );
  }

  // ── FCM foreground ────────────────────────────────────────────

  // FIND _handleForegroundMessage and REPLACE:
  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    final data = message.data;
    final type = data['type'] ?? 'message';

    if (type == 'call') {
      // When app is foreground, socket already handles the incoming call UI.
      // FCM foreground message is a duplicate — skip it.
      debugPrint('📞 FCM call in foreground — handled by socket, skipping.');
      return;
    }

    final conversationId = int.tryParse(data['conversationId'] ?? '0') ?? 0;
    await showMessageNotification(
      conversationId: conversationId,
      senderName: data['senderName'] ?? 'New Message',
      message: data['message'] ?? '',
      isGroup: data['isGroup'] == 'true',
      groupName: data['groupName'] as String?,
    );
  }

  void _handleNotificationTap(RemoteMessage message) {
    debugPrint('Notification opened app: ${message.data}');
  }

  void _onNotificationTap(NotificationResponse response) {
    debugPrint('Notification tapped: ${response.payload}');
  }

  // ── Incoming call ─────────────────────────────────────────────

  Future<void> showIncomingCall({
    required int callerId,
    required String callerName,
    required String callType,
  }) async {
    _currentCallUuid = const Uuid().v4();

    final params = CallKitParams(
      id: _currentCallUuid,
      nameCaller: callerName,
      appName: 'Kore Circle',
      type: callType == 'video' ? 1 : 0,
      duration: 45000,
      textAccept: 'Accept',
      textDecline: 'Decline',
      extra: <String, dynamic>{'callerId': callerId, 'callType': callType},
      headers: <String, dynamic>{},
      android: AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#1E1E2E',
        backgroundUrl: null,
        actionColor: '#7C3AED',
        textColor: '#FFFFFF',
        incomingCallNotificationChannelName: 'Incoming Calls',
        missedCallNotificationChannelName: 'Missed Calls',
        isShowCallID: false,
      ),
      ios: IOSParams(
        iconName: 'AppIcon',
        handleType: 'generic',
        supportsVideo: callType == 'video',
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
        audioSessionPreferredSampleRate: 44100.0,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: false,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );

    await FlutterCallkitIncoming.showCallkitIncoming(params);
  }

  // ── Compat methods (used in home_screen.dart) ─────────────────

  // home_screen.dart calls these — keep them working
  Future<void> startRinging() async {
    // flutter_callkit_incoming handles ringing natively
    // Nothing needed here — call showIncomingCall() instead
  }

  Future<void> showIncomingCallNotification({
    required int callerId,
    required String callerName,
    required String callType,
  }) async {
    // Redirect to the new unified method
    await showIncomingCall(
      callerId: callerId,
      callerName: callerName,
      callType: callType,
    );
  }

  Future<void> stopRinging() async => endCall();
  Future<void> cancelCallNotification() async => endCall();

  Future<void> endCall() async {
    if (_currentCallUuid == null) return;
    await FlutterCallkitIncoming.endCall(_currentCallUuid!);
    _currentCallUuid = null;
  }

  Future<void> endAllCalls() async {
    await FlutterCallkitIncoming.endAllCalls();
    _currentCallUuid = null;
  }

  // ── Message notification ──────────────────────────────────────

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

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
    await endAllCalls();
  }
}
