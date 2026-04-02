import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // Pending call — set by socket when app is foreground
  Map<String, dynamic>? _pendingOffer;
  int? _pendingCallerId;
  String? _pendingCallerName;
  String? _pendingCallType;
  int? _myUserId;

  static final _incomingCallController = StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get onForegroundCall => _incomingCallController.stream;


  // ── Public setters ─────────────────────────────────────────────

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

  // ── Init ───────────────────────────────────────────────────────

  Future<void> init() async {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
      criticalAlert: true,
    );

    // flutter_local_notifications init (Android only for messages)
    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: false, // Firebase handles iOS permissions
      requestBadgePermission: false,
      requestSoundPermission: false,
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

    // iOS: let Firebase show notifications natively in foreground
    await _fcm.setForegroundNotificationPresentationOptions(
      alert: true,
      badge: true,
      sound: true,
    );

    _fcmToken = await _getTokenWithRetry();
    debugPrint('📱 FCM Token: $_fcmToken');

    _fcm.onTokenRefresh.listen((token) {
      _fcmToken = token;
      debugPrint('📱 FCM Token Refreshed: $token');
    });

    // Foreground FCM messages
    FirebaseMessaging.onMessage.listen(_handleForegroundMessage);

    // App opened from background by tapping notification
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessageOpenedApp);

    // App opened from killed state by tapping notification
    final initial = await _fcm.getInitialMessage();
    if (initial != null) _handleMessageOpenedApp(initial);

    // CallKit events
    FlutterCallkitIncoming.onEvent.listen(_onCallKitEvent);
  }


  Future<void> startForegroundRinging({
    required int callerId,
    required String callerName,
    required String callType,
    Map<String, dynamic>? offer,
  }) async {
    // On iOS foreground: don't show CallKit (it covers the banner)
    // Just store the call data — banner is already showing
    // Vibration handles attention
    if (Platform.isIOS) {
      // Vibrate to alert user — no CallKit UI in foreground
      HapticFeedback.heavyImpact();
      _startVibration();
      return;
    }

    // Android: use CallKit notification normally
    await showIncomingCall(
      callerId: callerId,
      callerName: callerName,
      callType: callType,
      offer: offer,
    );
  }

  Timer? _vibrationTimer;

  void _startVibration() {
    _vibrationTimer?.cancel();
    _vibrationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      HapticFeedback.heavyImpact();
    });
  }

  Future<void> stopForegroundRinging() async {
    _vibrationTimer?.cancel();
    _vibrationTimer = null;
    // Only end CallKit calls on Android foreground
    if (!Platform.isIOS) {
      await endAllCalls();
    }
  }

  Future<void> checkForMissedCallOnResume() async {
    if (!Platform.isIOS) return;
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      debugPrint('📞 Active calls on resume: $calls');
      if (calls != null && (calls as List).isNotEmpty) {
        final call = (calls as List).first as Map;
        final extra = call['extra'] as Map? ?? {};
        final callerId = int.tryParse(extra['callerId']?.toString() ?? '0') ?? 0;
        final callerName = extra['callerName']?.toString() ?? 'Unknown';
        final callType = extra['callType']?.toString() ?? 'audio';
        final offerStr = extra['offerJson']?.toString() ?? '';

        Map<String, dynamic> offer = {};
        if (offerStr.isNotEmpty) {
          try {
            offer = Map<String, dynamic>.from(jsonDecode(offerStr) as Map);
          } catch (_) {}
        }

        if (callerId > 0) {
          setPendingCall(
            callerId: callerId,
            callerName: callerName,
            callType: callType,
            offer: offer,
          );
          _incomingCallController.add({
            'callerId': callerId,
            'callerName': callerName,
            'callType': callType,
            'offer': offer,
          });
        }
      }
    } catch (e) {
      debugPrint('⚠️ checkForMissedCallOnResume error: $e');
    }
  }

  // ── Token retry (iOS APNs) ─────────────────────────────────────

  Future<String?> _getTokenWithRetry({int maxAttempts = 15}) async {
    for (int i = 0; i < maxAttempts; i++) {
      try {
        if (Platform.isIOS) {
          final apns = await _fcm.getAPNSToken();
          if (apns == null) {
            debugPrint('⏳ APNs token not ready, attempt ${i + 1}/$maxAttempts');
            await Future.delayed(Duration(seconds: i < 3 ? 1 : 2));
            continue;
          }
          debugPrint('✅ APNs token ready');
        }
        final token = await _fcm.getToken();
        return token;
      } catch (e) {
        debugPrint('⚠️ FCM getToken attempt ${i + 1} failed: $e');
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    return null;
  }

  // ── FCM handlers ───────────────────────────────────────────────

  Future<void> _handleForegroundMessage(RemoteMessage message) async {
    final data = message.data;
    final type = data['type'] ?? 'message';

    debugPrint('📨 FCM foreground message type: $type');

    if (type == 'call') {
      final callerId = int.tryParse(data['callerId'] ?? '0') ?? 0;
      final callerName = data['callerName'] ?? 'Unknown';
      final callType = data['callType'] ?? 'audio';
      final offerStr = data['offerJson'] ?? data['offer'] ?? '';

      Map<String, dynamic> offer = {};
      if (offerStr.isNotEmpty) {
        try {
          offer = Map<String, dynamic>.from(jsonDecode(offerStr) as Map);
        } catch (_) {}
      }

      debugPrint('📞 FCM call — callerId: $callerId, callerName: $callerName');

      setPendingCall(
        callerId: callerId,
        callerName: callerName,
        callType: callType,
        offer: offer,
      );

      // Emit to stream — home_screen will show banner
      _incomingCallController.add({
        'callerId': callerId,
        'callerName': callerName,
        'callType': callType,
        'offer': offer,
      });

      // Show CallKit for lock screen ring
      await showIncomingCall(
        callerId: callerId,
        callerName: callerName,
        callType: callType,
        offer: offer,
      );
      return;
    }

    if (Platform.isAndroid) {
      final conversationId = int.tryParse(data['conversationId'] ?? '0') ?? 0;
      await showMessageNotification(
        conversationId: conversationId,
        senderName: data['senderName'] ?? 'New Message',
        message: data['message'] ?? '',
        isGroup: data['isGroup'] == 'true',
        groupName: data['groupName'] as String?,
      );
    }
  }

  void _handleMessageOpenedApp(RemoteMessage message) {
    final data = message.data;
    debugPrint('📲 App opened from notification: ${data['type']}');
    // Navigate to chat if needed — wire up later
  }

  void _onNotificationTap(NotificationResponse response) {
    debugPrint('🔔 Notification tapped: ${response.payload}');
  }

  // ── CallKit event handler ──────────────────────────────────────

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
        clearPendingCall();
        break;
      default:
        break;
    }
  }

  Future<void> _onCallAccepted(dynamic body) async {
    debugPrint('✅ CallKit accepted: $body');

    // Wait for navigator to be ready (app may be launching)
    NavigatorState? navigator;
    for (int i = 0; i < 20; i++) {
      navigator = NavigationService.navigatorKey.currentState;
      if (navigator != null) break;
      debugPrint('⏳ Waiting for navigator... attempt ${i + 1}');
      await Future.delayed(const Duration(milliseconds: 300));
    }

    if (navigator == null) {
      debugPrint('⚠️ Navigator never became ready');
      await endAllCalls();
      return;
    }

    // Priority 1: offer stored by socket (foreground/background)
    Map<String, dynamic>? offer = _pendingOffer;
    int? callerId = _pendingCallerId;
    String callerName = _pendingCallerName ?? 'Unknown';
    String callType = _pendingCallType ?? 'audio';

    // Priority 2: offer from CallKit extra (app was killed)
    if (offer == null || offer.isEmpty) {
      try {
        final extra = (body is Map)
            ? Map<String, dynamic>.from(body['extra'] as Map? ?? {})
            : <String, dynamic>{};
        final offerStr = extra['offerJson']?.toString() ?? '';
        if (offerStr.isNotEmpty) {
          final decoded = jsonDecode(offerStr);
          offer = Map<String, dynamic>.from(decoded as Map);
        }
        callerId ??= int.tryParse(extra['callerId']?.toString() ?? '0') ?? 0;
        callerName = extra['callerName']?.toString() ?? callerName;
        callType = extra['callType']?.toString() ?? callType;
        debugPrint('📦 Offer from CallKit extra: ${offer?.keys}');
      } catch (e) {
        debugPrint('⚠️ Could not parse offer from extra: $e');
      }
    }

    if (offer == null || offer.isEmpty) {
      debugPrint('⚠️ No WebRTC offer — cannot start call');
      await endAllCalls();
      return;
    }

    if (_myUserId == null || callerId == null || callerId == 0) {
      debugPrint('⚠️ Missing userId (${_myUserId}) or callerId ($callerId)');
      await endAllCalls();
      return;
    }

    final finalOffer = Map<String, dynamic>.from(offer);
    final finalCallerId = callerId;
    final finalCallerName = callerName;
    final finalCallType = callType;
    final finalMyUserId = _myUserId!;

    navigator
        .push(
          MaterialPageRoute(
            builder: (_) => CallScreen(
              myUserId: finalMyUserId,
              remoteUserId: finalCallerId,
              remoteUserName: finalCallerName,
              callType: finalCallType,
              isOutgoing: false,
              incomingOffer: finalOffer,
            ),
          ),
        )
        .then((_) {
          clearPendingCall();
          endAllCalls();
        });
  }

  void _onCallDeclined(dynamic body) {
    debugPrint('❌ CallKit declined');
    clearPendingCall();
    endAllCalls();
  }

  // ── Android message channel ────────────────────────────────────

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

  // ── Show incoming call (CallKit) ───────────────────────────────

  Future<void> showIncomingCall({
    required int callerId,
    required String callerName,
    required String callType,
    Map<String, dynamic>? offer,
  }) async {
    _currentCallUuid = const Uuid().v4();

    // Store offer as JSON string in extra so killed-app accept can use it
    final offerJson = offer != null ? jsonEncode(offer) : '';

    final params = CallKitParams(
      id: _currentCallUuid,
      nameCaller: callerName,
      appName: 'Kore Circle',
      type: callType == 'video' ? 1 : 0,
      duration: 45000,
      textAccept: 'Accept',
      textDecline: 'Decline',
      extra: <String, dynamic>{
        'callerId': callerId.toString(),
        'callerName': callerName,
        'callType': callType,
        'offerJson': offerJson,
      },
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
        audioSessionMode: 'voiceChat',
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

  // ── End call ───────────────────────────────────────────────────

  Future<void> endCall() async {
    if (_currentCallUuid == null) return;
    await FlutterCallkitIncoming.endCall(_currentCallUuid!);
    _currentCallUuid = null;
  }

  Future<void> endAllCalls() async {
    await FlutterCallkitIncoming.endAllCalls();
    _currentCallUuid = null;
  }

  // Compat aliases
  Future<void> stopRinging() async => endAllCalls();
  Future<void> cancelCallNotification() async => endAllCalls();
  Future<void> startRinging() async {}
  Future<void> showIncomingCallNotification({
    required int callerId,
    required String callerName,
    required String callType,
  }) async => showIncomingCall(
    callerId: callerId,
    callerName: callerName,
    callType: callType,
  );

  // ── Message notification (Android only) ───────────────────────

  Future<void> showMessageNotification({
    required int conversationId,
    required String senderName,
    required String message,
    bool isGroup = false,
    String? groupName,
  }) async {
    final title = isGroup ? '${groupName ?? 'Group'}: $senderName' : senderName;
    final body = message.isEmpty ? '📎 Media' : message;

    // Android only — iOS handled natively by Firebase
    if (Platform.isAndroid) {
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
      await _plugin.show(
        conversationId,
        title,
        body,
        NotificationDetails(android: androidDetails),
        payload: 'chat_$conversationId',
      );
    }
  }

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
    await endAllCalls();
  }
}
