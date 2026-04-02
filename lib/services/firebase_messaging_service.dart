import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';

// ── Must be top-level function ──────────────────────────────────
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final plugin = FlutterLocalNotificationsPlugin();

  const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
  await plugin.initialize(const InitializationSettings(android: androidSettings));

  await _createChannels(plugin);

  final data = message.data;
  final type = data['type'] ?? 'message';

  if (type == 'call') {
    final callerName = data['callerName'] ?? 'Unknown';
    final callType = data['callType'] ?? 'audio';
    final icon = callType == 'video' ? '📹' : '📞';

    // Play ringtone in background
    FlutterRingtonePlayer().playRingtone(looping: false, asAlarm: false);

    await plugin.show(
      9999,
      '$icon Incoming ${callType == 'video' ? 'Video' : 'Audio'} Call',
      callerName,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'kore_calls',
          'Incoming Calls',
          importance: Importance.max,
          priority: Priority.max,
          fullScreenIntent: true,
          ongoing: true,
          autoCancel: false,
          category: AndroidNotificationCategory.call,
          sound: const RawResourceAndroidNotificationSound('kore_ringtone'),
          actions: const [
            AndroidNotificationAction('decline_call', 'Decline', cancelNotification: true),
            AndroidNotificationAction('accept_call', 'Accept', cancelNotification: true),
          ],
        ),
      ),
      payload: 'call_${data['callerId']}',
    );
  } else {
    final senderName = data['senderName'] ?? 'New Message';
    final messageText = data['message'] ?? '';
    final conversationId = int.tryParse(data['conversationId'] ?? '0') ?? 0;

    await plugin.show(
      conversationId,
      senderName,
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

Future<void> _createChannels(FlutterLocalNotificationsPlugin plugin) async {
  final androidImpl = plugin
      .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  await androidImpl?.createNotificationChannel(
    const AndroidNotificationChannel(
      'kore_messages', 'Messages',
      importance: Importance.high,
      sound: RawResourceAndroidNotificationSound('kore_message'),
      playSound: true,
      enableVibration: true,
    ),
  );

  await androidImpl?.createNotificationChannel(
    const AndroidNotificationChannel(
      'kore_calls', 'Incoming Calls',
      importance: Importance.max,
      sound: RawResourceAndroidNotificationSound('kore_ringtone'),
      playSound: true,
      enableVibration: true,
    ),
  );
}