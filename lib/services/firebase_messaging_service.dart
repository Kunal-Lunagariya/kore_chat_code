import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import 'debug_logger.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();

  final data = message.data;
  final type = data['type'] ?? '';

  await DebugLogger.log(
    'BGHandler',
    'FIRED ▶ type=$type keys=${data.keys.toList()} '
        'hasNotif=${message.notification != null}',
  );

  // ── 1-to-1 incoming call ──────────────────────────────────────
  if (type == 'call') {
    await FlutterCallkitIncoming.endAllCalls();

    final uuid = const Uuid().v4();
    final callerName = data['callerName'] ?? 'Unknown';
    final callType = data['callType'] ?? 'audio';
    final callerId = data['callerId'] ?? '0';
    // Offer may be absent (FCM 4KB limit) — will arrive via socket on accept
    final offerJson = data['offerJson'] ?? data['offer'] ?? '';
    final roomId = data['roomId'] ?? '';
    final conversationId = data['conversationId'] ?? '';

    await DebugLogger.log(
      'BGHandler',
      'call ▶ caller=$callerName type=$callType id=$callerId '
          'offerLen=${offerJson.length} roomId=$roomId',
    );

    // Persist call metadata so NotificationService can read it after cold start
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('pending_call_caller_id', callerId);
      await prefs.setString('pending_call_caller_name', callerName);
      await prefs.setString('pending_call_type', callType);
      await prefs.setString('pending_call_offer_json', offerJson);
      await prefs.setString('pending_call_room_id', roomId);
      await prefs.setString('pending_call_conversation_id', conversationId);
      await prefs.setInt(
        'pending_call_timestamp',
        DateTime.now().millisecondsSinceEpoch,
      );
      await DebugLogger.log('BGHandler', 'call ▶ saved pending call to prefs');
    } catch (e) {
      await DebugLogger.log('BGHandler', 'call ▶ prefs save error: $e');
    }

    final params = CallKitParams(
      id: uuid,
      nameCaller: callerName,
      appName: 'Kore Circle',
      type: callType == 'video' ? 1 : 0,
      duration: 45000,
      textAccept: 'Accept',
      textDecline: 'Decline',
      extra: <String, dynamic>{
        'isGroupCall': 'false',
        'callerId': callerId,
        'callerName': callerName,
        'callType': callType,
        'offerJson': offerJson,
        'roomId': roomId,
        'callTimestamp': DateTime.now().millisecondsSinceEpoch.toString(),
      },
      android: AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0955FA',
        actionColor: '#4CAF50',
        textColor: '#ffffff',
        incomingCallNotificationChannelName: 'Incoming Call',
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
        audioSessionActive: false,
        audioSessionPreferredSampleRate: 44100.0,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: false,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );

    try {
      await FlutterCallkitIncoming.showCallkitIncoming(params);
      await DebugLogger.log('BGHandler', 'call ▶ showCallkitIncoming OK');
    } catch (e) {
      await DebugLogger.log('BGHandler', 'call ▶ showCallkitIncoming ERROR: $e');
    }
    return;
  }

  // ── Group incoming call ───────────────────────────────────────
  if (type == 'group_call') {
    await FlutterCallkitIncoming.endAllCalls();

    final uuid = const Uuid().v4();
    final callerName = data['callerName'] ?? 'Unknown';
    final callType = data['callType'] ?? 'audio';
    final conversationId = data['conversationId'] ?? '0';
    final groupName = data['groupName'] ?? 'Group';

    await DebugLogger.log(
      'BGHandler',
      'group_call ▶ group=$groupName caller=$callerName convId=$conversationId',
    );

    final params = CallKitParams(
      id: uuid,
      nameCaller: groupName,
      appName: 'Kore Circle',
      type: callType == 'video' ? 1 : 0,
      duration: 30000,
      textAccept: 'Join',
      textDecline: 'Decline',
      extra: <String, dynamic>{
        'isGroupCall': 'true',
        'conversationId': conversationId,
        'callerName': callerName,
        'callType': callType,
        'groupName': groupName,
        'callTimestamp': DateTime.now().millisecondsSinceEpoch.toString(),
      },
      android: AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#0955FA',
        actionColor: '#4CAF50',
        textColor: '#ffffff',
        incomingCallNotificationChannelName: 'Incoming Call',
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
        audioSessionActive: false,
        audioSessionPreferredSampleRate: 44100.0,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: false,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );

    try {
      await FlutterCallkitIncoming.showCallkitIncoming(params);
      await DebugLogger.log('BGHandler', 'group_call ▶ showCallkitIncoming OK');
    } catch (e) {
      await DebugLogger.log(
        'BGHandler',
        'group_call ▶ showCallkitIncoming ERROR: $e',
      );
    }
    return;
  }

  // ── Message notification ──────────────────────────────────────
  if (message.notification != null) {
    await DebugLogger.log(
      'BGHandler',
      'message ▶ skipped (has notification block, let system handle)',
    );
    return;
  }

  final senderName = data['senderName'] ?? '';
  final messageText = data['message'] ?? '';

  if (senderName.isEmpty && messageText.isEmpty) return;
  if (messageText.isEmpty && type != 'message') return;

  await DebugLogger.log('BGHandler', 'message ▶ from=$senderName');

  final plugin = FlutterLocalNotificationsPlugin();
  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  await plugin.initialize(
    const InitializationSettings(android: androidSettings),
  );

  final androidImpl = plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  await androidImpl?.createNotificationChannel(
    const AndroidNotificationChannel(
      'kore_messages',
      'Messages',
      importance: Importance.high,
      enableVibration: true,
    ),
  );

  final conversationId = int.tryParse(data['conversationId'] ?? '0') ?? 0;
  final isGroup = data['isGroup'] == 'true';
  final groupName = data['groupName'] as String?;
  final title = isGroup ? '${groupName ?? 'Group'}: $senderName' : senderName;

  await plugin.show(
    conversationId,
    title,
    messageText.isEmpty ? '📎 Attachment' : messageText,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'kore_messages',
        'Messages',
        importance: Importance.high,
        priority: Priority.high,
        autoCancel: true,
      ),
    ),
    payload: 'chat_$conversationId',
  );
}
