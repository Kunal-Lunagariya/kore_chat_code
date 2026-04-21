import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:uuid/uuid.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final data = message.data;
  final type = data['type'] ?? 'message';

  if (type == 'call') {
    await FlutterCallkitIncoming.endAllCalls();

    final uuid = const Uuid().v4();
    final callerName = data['callerName'] ?? 'Unknown';
    final callType = data['callType'] ?? 'audio';
    final callerId = data['callerId'] ?? '0';
    // ← Backend sends 'offer' not 'offerJson' — fix this
    final offerJson = data['offerJson'] ?? data['offer'] ?? '';

    final params = CallKitParams(
      id: uuid,
      nameCaller: callerName,
      appName: 'Kore Circle',
      type: callType == 'video' ? 1 : 0,
      duration: 45000,
      textAccept: 'Accept',
      textDecline: 'Decline',
      extra: <String, dynamic>{
        'callerId': callerId,
        'callerName': callerName,
        'callType': callType,
        'offerJson': offerJson, // ← store as offerJson internally
      },
      android: AndroidParams(
        isCustomNotification: false,
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
    return;
  }

  // Message — only handle data-only (no notification block)
  if (message.notification != null) return;

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

  final senderName = data['senderName'] ?? 'New Message';
  final messageText = data['message'] ?? '';
  final conversationId = int.tryParse(data['conversationId'] ?? '0') ?? 0;
  final isGroup = data['isGroup'] == 'true';
  final groupName = data['groupName'] as String?;
  final title = isGroup ? '${groupName ?? 'Group'}: $senderName' : senderName;

  if (messageText.isEmpty && senderName == 'New Message') return;

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
