import 'dart:convert';
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
    final uuid = const Uuid().v4();
    final callerName = data['callerName'] ?? 'Unknown';
    final callType = data['callType'] ?? 'audio';
    final callerId = data['callerId'] ?? '0';
    // Offer comes as JSON string in FCM payload
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
        'offerJson': offerJson, // ← passed through so accept can use it
      },
      android: AndroidParams(
        isCustomNotification: true,
        isShowLogo: false,
        ringtonePath: 'system_ringtone_default',
        backgroundColor: '#1E1E2E',
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
  } else {
    final plugin = FlutterLocalNotificationsPlugin();
    const androidSettings =
    AndroidInitializationSettings('@mipmap/ic_launcher');
    await plugin.initialize(
        const InitializationSettings(android: androidSettings));

    final androidImpl = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        'kore_messages',
        'Messages',
        importance: Importance.high,
        sound: RawResourceAndroidNotificationSound('kore_message'),
        playSound: true,
        enableVibration: true,
      ),
    );

    final senderName = data['senderName'] ?? 'New Message';
    final messageText = data['message'] ?? '';
    final conversationId =
        int.tryParse(data['conversationId'] ?? '0') ?? 0;
    final isGroup = data['isGroup'] == 'true';
    final groupName = data['groupName'] as String?;
    final title =
    isGroup ? '${groupName ?? 'Group'}: $senderName' : senderName;

    await plugin.show(
      conversationId,
      title,
      messageText.isEmpty ? '📎 Media' : messageText,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'kore_messages',
          'Messages',
          importance: Importance.high,
          priority: Priority.high,
          sound: const RawResourceAndroidNotificationSound('kore_message'),
          autoCancel: true,
        ),
      ),
      payload: 'chat_$conversationId',
    );
  }
}