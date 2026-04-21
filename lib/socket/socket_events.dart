import 'package:flutter/cupertino.dart';

import 'socket_index.dart';

class SocketEvents {
  /// Join a conversation room
  static void joinConversation(
    String conversationId, {
    Function(dynamic)? callback,
  }) {
    final socket = SocketIndex.getSocket();
    SocketIndex.setActiveConversation(conversationId);

    socket.emitWithAck(
      'join_conversation',
      {'conversationId': conversationId},
      ack: (response) {
        if (callback != null) callback(response);
      },
    );
  }

  /// Leave conversation.
  static void leaveConversation(String conversationId) {
    final socket = SocketIndex.getSocket();
    socket.emit('leave_conversation', {'conversationId': conversationId});
    SocketIndex.setActiveConversation(null);
  }

  /// Send message
  static void sendMessage(
    Map<String, dynamic> payload, {
    Function(dynamic)? callback,
  }) {
    final socket = SocketIndex.getSocket();

    socket.emitWithAck(
      'send_message',
      payload,
      ack: (response) {
        if (callback != null) callback(response);
      },
    );
  }

  /// Typing indicator
  static void sendTyping(String conversationId) {
    final socket = SocketIndex.getSocket();
    socket.emit('typing', {'conversationId': conversationId});
  }

  /// Stop typing
  static void stopTyping(String conversationId) {
    final socket = SocketIndex.getSocket();
    socket.emit('stop_typing', {'conversationId': conversationId});
  }

  /// Listen for incoming messages
  static void onReceiveMessage(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('receive_message', handler);
  }

  /// Remove receive_message listener (call on screen dispose)
  static void offReceiveMessage() {
    final socket = SocketIndex.getSocket();
    socket.off('receive_message');
  }

  /// Listen for new messages (server broadcasts to both sender + receiver)
  static void onNewMessage(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('new_message', handler);
  }

  /// Remove new_message listener
  static void offNewMessage() {
    final socket = SocketIndex.getSocket();
    socket.off('new_message');
  }

  static void onUpdatedMessageStatus(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('updated_message_status', handler);
  }

  static void offUpdatedMessageStatus() {
    final socket = SocketIndex.getSocket();
    socket.off('updated_message_status');
  }

  static void onUpdatedMultiMessageStatus(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    // Both events use same handler — matches React
    socket.on('updated_multi_message_status', handler);
    socket.on('updated_multi_message_status_user_room', handler);
  }

  static void offUpdatedMultiMessageStatus() {
    final socket = SocketIndex.getSocket();
    socket.off('updated_multi_message_status');
    socket.off('updated_multi_message_status_user_room');
  }

  static void emitMultiMessageStatus({
    required int receiverId,
    required int conversationId,
  }) {
    final socket = SocketIndex.getSocket();
    socket.emit('multi_message_status', {
      'receiverId': receiverId,
      'conversationId': conversationId,
      'status': 'read',
    });
  }

  /// Emit delivered status for a single incoming message
  static void emitMessageStatus({
    required int receiverId,
    required int senderId,
    required int conversationId,
    required int messageId,
    String status = 'delivered',
  }) {
    final socket = SocketIndex.getSocket();
    socket.emit('message_status', {
      'receiverId': receiverId,
      'senderId': senderId,
      'conversationId': conversationId,
      'messageId': messageId,
      'status': status,
    });
  }

  /// Emit delivered for all unread (call on chat list load)
  static void emitMultiMessageStatusDelivered({required int receiverId}) {
    final socket = SocketIndex.getSocket();
    socket.emit('multi_message_status', {
      'receiverId': receiverId,
      'status': 'delivered',
    });
  }

  static void emitStartTyping({required int conversationId}) {
    final socket = SocketIndex.getSocket();
    socket.emit('start_typing', {'conversationId': conversationId});
  }

  static void emitStopTyping({required int conversationId}) {
    final socket = SocketIndex.getSocket();
    socket.emit('stop_typing', {'conversationId': conversationId});
  }

  static void onStartTyping(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('start_typing', handler);
  }

  static void onStopTyping(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('stop_typing', handler);
  }

  static void offStartTyping() {
    final socket = SocketIndex.getSocket();
    socket.off('start_typing');
  }

  static void offStopTyping() {
    final socket = SocketIndex.getSocket();
    socket.off('stop_typing');
  }

  // ── WebRTC 1-to-1 call events ──────────────────────────────────

  static void emitCallUser({
    required int toUserId,
    required dynamic offer,
    required String callType, // 'audio' or 'video'
  }) {
    final socket = SocketIndex.getSocket();
    socket.emit('call_user', {
      'toUserId': toUserId,
      'offer': offer,
      'callType': callType,
    });
  }

  static void emitAnswerCall({
    required int toUserId,
    required dynamic answer,
    required String callType,
    int? roomId,
    int? conversationId,
  }) {
    final socket = SocketIndex.getSocket();
    socket.emit('answer_call', {
      'toUserId': toUserId,
      'answer': answer,
      'callType': callType,
      if (roomId != null) 'roomId': roomId,
      if (conversationId != null) 'conversationId': conversationId,
    });
  }

  static void emitEndCall({
    required int toUserId,
    required int fromUserId,
    int statusId = 5,
    int? roomId,
    int? conversationId,
  }) {
    try {
      final socket = SocketIndex.getSocket();
      socket.emit('end_call', {
        'toUserId': toUserId,
        'fromUserId': fromUserId,
        'statusId': statusId,
        if (roomId != null) 'roomId': roomId,
        if (conversationId != null) 'conversationId': conversationId,
      });
    } catch (e) {
      debugPrint('⚠️ emitEndCall failed: $e');
    }
  }

  static void emitIceCandidate({
    required int toUserId,
    required dynamic candidate,
  }) {
    final socket = SocketIndex.getSocket();
    socket.emit('ice_candidate', {
      'toUserId': toUserId,
      'candidate': candidate,
    });
  }

  static void onIncomingCall(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('incoming_call', handler);
  }

  static void offIncomingCall() {
    final socket = SocketIndex.getSocket();
    socket.off('incoming_call');
  }

  static void onCallAnswered(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('call_answered', handler);
  }

  static void offCallAnswered() {
    final socket = SocketIndex.getSocket();
    socket.off('call_answered');
  }

  static void onCallEnded(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('call_ended', handler);
  }

  static void offCallEnded() {
    final socket = SocketIndex.getSocket();
    socket.off('call_ended');
  }

  static void onIceCandidate(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('ice_candidate', handler);
  }

  static void offIceCandidate() {
    final socket = SocketIndex.getSocket();
    socket.off('ice_candidate');
  }

  static void offUserOnline() {
    final socket = SocketIndex.getSocket();
    socket.off('user_online');
  }

  static void emitCallRinging({required int toUserId}) {
    try {
      final socket = SocketIndex.getSocket();
      socket.emit('call_ringing', {'toUserId': toUserId});
    } catch (_) {}
  }

  static void onCallRinging(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('call_ringing', handler);
  }

  static void offCallRinging() {
    final socket = SocketIndex.getSocket();
    socket.off('call_ringing');
  }

  static void onOnlineUsers(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('online_users', handler);
  }

  static void offOnlineUsers() {
    final socket = SocketIndex.getSocket();
    socket.off('online_users');
  }

  static void onUserStatus(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('user_status', handler);
  }

  static void offUserStatus() {
    final socket = SocketIndex.getSocket();
    socket.off('user_status');
  }

  static void onCallUnavailableWait(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('call_unavailable_wait', handler);
  }

  static void offCallUnavailableWait() {
    final socket = SocketIndex.getSocket();
    socket.off('call_unavailable_wait');
  }

  static void onCallRingingNow(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('call_ringing_now', handler);
  }

  static void offCallRingingNow() {
    final socket = SocketIndex.getSocket();
    socket.off('call_ringing_now');
  }

  // ── Group call events ──────────────────────────────────────────

  static void emitGroupCallInitiate({
    required int conversationId,
    required int callerId,
    required String callType,
  }) {
    final socket = SocketIndex.getSocket();
    socket.emit('group_call_initiate', {
      'conversationId': conversationId,
      'callerId': callerId,
      'callType': callType,
    });
  }

  static void emitGroupCallJoin({
    required int conversationId,
    required int userId,
  }) {
    final socket = SocketIndex.getSocket();
    socket.emit('group_call_join', {
      'conversationId': conversationId,
      'userId': userId,
    });
  }

  static void emitGroupCallLeave({
    required int conversationId,
    required int userId,
  }) {
    try {
      final socket = SocketIndex.getSocket();
      socket.emit('group_call_leave', {
        'conversationId': conversationId,
        'userId': userId,
      });
    } catch (_) {}
  }

  static void emitGroupCallEnd({
    required int conversationId,
    required int userId,
  }) {
    try {
      final socket = SocketIndex.getSocket();
      socket.emit('group_call_end', {
        'conversationId': conversationId,
        'userId': userId,
      });
    } catch (_) {}
  }

  static void emitGroupCallOffer({
    required int toUserId,
    required int conversationId,
    required Map<String, dynamic> offer,
    required String callType,
  }) {
    final socket = SocketIndex.getSocket();
    socket.emit('group_call_offer', {
      'toUserId': toUserId,
      'conversationId': conversationId,
      'offer': offer,
      'callType': callType,
    });
  }

  static void emitGroupCallAnswer({
    required int toUserId,
    required int conversationId,
    required Map<String, dynamic> answer,
  }) {
    final socket = SocketIndex.getSocket();
    socket.emit('group_call_answer', {
      'toUserId': toUserId,
      'conversationId': conversationId,
      'answer': answer,
    });
  }

  static void emitGroupCallIceCandidate({
    required int toUserId,
    required int conversationId,
    required Map<String, dynamic> candidate,
  }) {
    final socket = SocketIndex.getSocket();
    socket.emit('group_call_ice_candidate', {
      'toUserId': toUserId,
      'conversationId': conversationId,
      'candidate': candidate,
    });
  }

  static void onGroupCallIncoming(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('group_call_incoming', handler);
  }

  static void offGroupCallIncoming() {
    final socket = SocketIndex.getSocket();
    socket.off('group_call_incoming');
  }

  static void onGroupCallUserJoined(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('group_call_user_joined', handler);
  }

  static void offGroupCallUserJoined() {
    final socket = SocketIndex.getSocket();
    socket.off('group_call_user_joined');
  }

  static void onGroupCallUserLeft(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('group_call_user_left', handler);
  }

  static void offGroupCallUserLeft() {
    final socket = SocketIndex.getSocket();
    socket.off('group_call_user_left');
  }

  static void onGroupCallOffer(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('group_call_offer', handler);
  }

  static void offGroupCallOffer() {
    final socket = SocketIndex.getSocket();
    socket.off('group_call_offer');
  }

  static void onGroupCallAnswer(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('group_call_answer', handler);
  }

  static void offGroupCallAnswer() {
    final socket = SocketIndex.getSocket();
    socket.off('group_call_answer');
  }

  static void onGroupCallIceCandidate(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('group_call_ice_candidate', handler);
  }

  static void offGroupCallIceCandidate() {
    final socket = SocketIndex.getSocket();
    socket.off('group_call_ice_candidate');
  }

  static void onGroupCallEnded(Function(dynamic) handler) {
    final socket = SocketIndex.getSocket();
    socket.on('group_call_ended', handler);
  }

  static void offGroupCallEnded() {
    final socket = SocketIndex.getSocket();
    socket.off('group_call_ended');
  }
}
