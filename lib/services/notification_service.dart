import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../screens/chat/call_screen.dart';
import '../socket/socket_events.dart';
import '../socket/socket_index.dart';
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
  String? _voipToken;
  String? get voipToken => _voipToken;
  String? _currentCallUuid;

  // Pending call — set by socket when app is foreground
  Map<String, dynamic>? _pendingOffer;
  int? _pendingCallerId;
  String? _pendingCallerName;
  String? _pendingCallType;
  int? _pendingMessageId;
  int? _pendingRoomId;
  int? _pendingConversationId;
  int? _myUserId;
  bool _callAcceptBroadcast = false;

  static final _incomingCallController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get onForegroundCall =>
      _incomingCallController.stream;

  static final _callAcceptedController =
      StreamController<Map<String, dynamic>>.broadcast();
  static Stream<Map<String, dynamic>> get onCallAccepted =>
      _callAcceptedController.stream;

  // ── Public setters ─────────────────────────────────────────────

  void setMyUserId(int userId) => _myUserId = userId;

  void setPendingCall({
    required int callerId,
    required String callerName,
    required String callType,
    required Map<String, dynamic> offer,
    int? messageId,
    int? roomId,
    int? conversationId,
  }) {
    _pendingCallerId = callerId;
    _pendingCallerName = callerName;
    _pendingCallType = callType;
    _pendingOffer = offer;
    _pendingMessageId = messageId;
    _pendingRoomId = roomId;
    _pendingConversationId = conversationId;
  }

  void clearPendingCall() {
    _pendingOffer = null;
    _pendingCallerId = null;
    _pendingCallerName = null;
    _pendingCallType = null;
    _pendingMessageId = null;
    _pendingRoomId = null;
    _pendingConversationId = null;
    _callAcceptBroadcast = false;
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

    if (Platform.isIOS) {
      final voip = await FlutterCallkitIncoming.getDevicePushTokenVoIP();
      _voipToken = voip;
      debugPrint("📱 VoIP Token Saved: $_voipToken");
    }

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
        final call = (calls).first as Map;
        final extra = call['extra'] as Map? ?? {};
        final callerId =
            int.tryParse(extra['callerId']?.toString() ?? '0') ?? 0;
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

    debugPrint('📨 FCM foreground type: $type');

    if (type == 'call') {
      // Store offer from FCM as fallback (socket usually arrives first)
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

      // Only store if socket hasn't already set it
      if (_pendingOffer == null || _pendingOffer!.isEmpty) {
        setPendingCall(
          callerId: callerId,
          callerName: callerName,
          callType: callType,
          offer: offer,
        );
        debugPrint('📞 FCM stored pending call offer as fallback');
      }

      // Don't show any UI here — socket onIncomingCall handles it
      return;
    }

    // Messages — iOS handled natively by Firebase, Android handled below
    if (Platform.isAndroid) {
      final conversationId = int.tryParse(data['conversationId'] ?? '0') ?? 0;
      final messageText = data['message'] ?? '';
      final senderName = data['senderName'] ?? '';
      if (senderName.isEmpty && messageText.isEmpty) return;

      await showMessageNotification(
        conversationId: conversationId,
        senderName: senderName.isEmpty ? 'New Message' : senderName,
        message: messageText,
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
      case Event.actionDidUpdateDevicePushTokenVoip:
        _voipToken = event.body['devicePushTokenVoip'];
        debugPrint('📱 VoIP Token: $_voipToken');
        break;

      case Event.actionCallAccept:
        _onCallAccepted(event.body);
        break;

      case Event.actionCallDecline:
        _onCallDeclined(event.body);
        break;

      case Event.actionCallEnded:
      case Event.actionCallTimeout:
        // ← ADD: emit missed to caller if we didn't answer
        if (_myUserId != null && _pendingCallerId != null) {
          try {
            SocketEvents.emitEndCall(
              toUserId: _pendingCallerId!,
              fromUserId: _myUserId!,
              statusId: 1, // 1 = missed
            );
          } catch (_) {}
        }
        _currentCallUuid = null;
        clearPendingCall();
        break;

      default:
        break;
    }
  }

  Future<void> _onCallAccepted(dynamic body) async {
    if (_callAcceptBroadcast) {
      debugPrint('⚠️ _onCallAccepted already fired — ignoring duplicate');
      return;
    }
    _callAcceptBroadcast = true;

    debugPrint('✅ CallKit accepted: $body');

    Map<String, dynamic>? offer = _pendingOffer;
    int? callerId = _pendingCallerId;
    String callerName = _pendingCallerName ?? '';
    String callType = _pendingCallType ?? 'audio';

    // Always try to read from extra first — most reliable on cold start
    try {
      final extra = (body is Map)
          ? Map<String, dynamic>.from(body['extra'] as Map? ?? {})
          : <String, dynamic>{};

      // Offer
      if (offer == null || offer.isEmpty) {
        final offerStr =
            extra['offerJson']?.toString() ?? extra['offer']?.toString() ?? '';
        if (offerStr.isNotEmpty) {
          try {
            offer = Map<String, dynamic>.from(jsonDecode(offerStr) as Map);
          } catch (e) {
            debugPrint('⚠️ offer decode failed: $e');
          }
        }
      }

      // Caller info from extra (fallback if socket didn't set pending)
      if (callerId == null || callerId == 0) {
        callerId = int.tryParse(extra['callerId']?.toString() ?? '0') ?? 0;
      }
      if (callerName.isEmpty) {
        callerName = extra['callerName']?.toString() ?? 'Unknown';
      }
      callType = extra['callType']?.toString().isNotEmpty == true
          ? extra['callType'].toString()
          : callType;
    } catch (e) {
      debugPrint('⚠️ Could not parse extra: $e');
    }

    if (offer == null || offer.isEmpty) {
      debugPrint('⚠️ No WebRTC offer — cannot start call');
      await endAllCalls();
      return;
    }

    if (callerId == null || callerId == 0) {
      debugPrint('⚠️ Missing callerId');
      await endAllCalls();
      return;
    }

    // ── KEY FIX: Read myUserId from prefs if not set (cold start) ──
    if (_myUserId == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        _myUserId = prefs.getInt('user_id');
        debugPrint('📱 Loaded myUserId from prefs: $_myUserId');
      } catch (e) {
        debugPrint('⚠️ Could not read user_id from prefs: $e');
      }
    }

    if (_myUserId == null) {
      debugPrint('⚠️ myUserId still null — cannot start call');
      await endAllCalls();
      return;
    }

    debugPrint('📞 Broadcasting call accept: caller=$callerName id=$callerId');

    _callAcceptedController.add({
      'callerId': callerId,
      'callerName': callerName,
      'callType': callType,
      'offer': offer,
      'myUserId': _myUserId!,
      'messageId': _pendingMessageId,
      'roomId': _pendingRoomId,
      'conversationId': _pendingConversationId,
    });
  }

  // ── ADDED: Wait for socket to connect (up to 8 seconds) ──────────
  Future<void> _ensureSocketConnected() async {
    try {
      // If already connected, nothing to do
      if (SocketIndex.isConnected) {
        debugPrint('✅ Socket already connected');
        return;
      }

      debugPrint('🔄 Socket not connected — attempting connect before call...');

      // Try to get/reconnect existing socket
      try {
        SocketIndex.getSocket(); // triggers reconnect inside getSocket()
      } catch (e) {
        // Socket not initialized (killed state) — need token from prefs
        debugPrint('⚠️ Socket not initialized, reading token from prefs...');
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('auth_token');
        final userId = prefs.getInt('user_id');
        if (token != null) {
          SocketIndex.connectSocket(token, userId: userId);
        } else {
          debugPrint('⚠️ No auth token in prefs — cannot connect socket');
          return;
        }
      }

      // Wait up to 8 seconds for socket to connect
      const maxWaitMs = 8000;
      const stepMs = 200;
      int waited = 0;
      while (!SocketIndex.isConnected && waited < maxWaitMs) {
        await Future.delayed(const Duration(milliseconds: stepMs));
        waited += stepMs;
        debugPrint('⏳ Waiting for socket... ${waited}ms');
      }

      if (SocketIndex.isConnected) {
        debugPrint('✅ Socket connected after ${waited}ms');
        // Small extra delay for server-side room setup
        await Future.delayed(const Duration(milliseconds: 300));
      } else {
        debugPrint(
          '⚠️ Socket still not connected after ${waited}ms — proceeding anyway',
        );
      }
    } catch (e) {
      debugPrint('⚠️ _ensureSocketConnected error: $e');
    }
  }

  void _onCallDeclined(dynamic body) {
    debugPrint('❌ CallKit declined');

    // ← ADD: emit end_call so caller's screen closes
    if (_pendingCallerId != null && _myUserId != null) {
      try {
        SocketEvents.emitEndCall(
          toUserId: _pendingCallerId!,
          fromUserId: _myUserId!,
          statusId: 2, // 2 = declined
        );
        debugPrint('📞 Decline emitted to callerId: $_pendingCallerId');
      } catch (e) {
        debugPrint('⚠️ decline socket error: $e');
      }
    }

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
        // ← REMOVE sound lines — file doesn't exist
        enableVibration: true,
      ),
    );
  }

  Future<void> showMessageNotification({
    required int conversationId,
    required String senderName,
    required String message,
    bool isGroup = false,
    String? groupName,
  }) async {
    final title = isGroup ? '${groupName ?? 'Group'}: $senderName' : senderName;
    final body = message.isEmpty ? '📎 Media' : message;

    if (Platform.isAndroid) {
      final androidDetails = AndroidNotificationDetails(
        'kore_messages',
        'Messages',
        channelDescription: 'New chat message notifications',
        importance: Importance.high,
        priority: Priority.high,
        // ← REMOVE: sound: const RawResourceAndroidNotificationSound('kore_message'),
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

  // ── Show incoming call (CallKit) ───────────────────────────────

  Future<void> showIncomingCall({
    required int callerId,
    required String callerName,
    required String callType,
    Map<String, dynamic>? offer,
  }) async {
    if (_callAcceptBroadcast) {
      debugPrint('⚠️ showIncomingCall blocked — call already accepted');
      return;
    }

    await FlutterCallkitIncoming.endAllCalls();

    _currentCallUuid = const Uuid().v4();

    // Store offer as JSON string in extra so killed-app accept can use it
    final offerJson = offer != null ? jsonEncode(offer) : '';

    final params = CallKitParams(
      id: _currentCallUuid,
      nameCaller: callerName,
      appName: 'Kore Circle',
      type: callType == 'video' ? 1 : 0,
      duration: 30000,
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
        isShowLogo: false, // ← change to false
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0955FA',
        actionColor: '#4CAF50',
        textColor: '#ffffff',
        incomingCallNotificationChannelName: 'Incoming Call',
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
    if (_currentCallUuid != null) {
      try {
        await FlutterCallkitIncoming.endCall(_currentCallUuid!);
      } catch (_) {}
    }
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

  Future<void> cancelAll() async {
    await _plugin.cancelAll();
    await endAllCalls();
  }
}
