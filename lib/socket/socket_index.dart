import 'package:flutter/cupertino.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;

class SocketIndex {
  static IO.Socket? _socket;
  static String? _token;
  static int? _userId;
  static String? _activeConversationId;
  static VoidCallback? _onReconnectCallback;

  static void setReconnectCallback(VoidCallback callback) {
    _onReconnectCallback = callback;
  }

  static void setActiveConversation(String? id) {
    _activeConversationId = id;
  }

  static bool get isConnected => _socket?.connected ?? false;

  /// Call after login AND after splash auth check (token already exists)
  static IO.Socket connectSocket(String token, {int? userId}) {
    _token = token;
    if (userId != null) _userId = userId;

    // Already connected — nothing to do
    if (_socket != null && _socket!.connected) return _socket!;

    // Socket instance exists but disconnected — just reconnect it
    if (_socket != null && !_socket!.connected) {
      _socket!.connect();
      return _socket!;
    }

    _socket = IO.io(
      'https://chatapi.koremobiles.in',
      IO.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .disableAutoConnect()
          .enableReconnection()
          .setReconnectionAttempts(double.infinity)
          .setReconnectionDelay(500)
          .setReconnectionDelayMax(3000)
          .setRandomizationFactor(0.2)
          .setTimeout(8000)
          .build(),
    );

    _socket!.onConnect((_) {
      print('🟢 Socket Connected: ${_socket!.id}');
      if (_activeConversationId != null) {
        _socket!.emit('join_conversation', {
          'conversationId': _activeConversationId,
        });
      }
      // ← Tell server this user is online
      if (_userId != null) {
        _socket!.emit('user_online', {'userId': _userId});
      }
    });

    _socket!.on('reconnect', (attemptNumber) {
      print('🔁 Socket Reconnected (attempt $attemptNumber)');
      if (_activeConversationId != null) {
        _socket!.emit('join_conversation', {
          'conversationId': _activeConversationId,
        });
      }
      if (_userId != null) {
        _socket!.emit('user_online', {'userId': _userId});
      }
      _onReconnectCallback?.call();
    });

    _socket!.onDisconnect((reason) {
      print('🔴 Socket Disconnected: $reason');
      // Server-forced disconnect — manually trigger reconnect
      if (reason == 'io server disconnect') {
        _socket!.connect();
      }
    });

    _socket!.onConnectError((err) {
      print('❌ Socket Connection Error: $err');
    });

    _socket!.connect();
    return _socket!;
  }

  /// Safe getter — auto-reconnects if socket dropped
  static IO.Socket getSocket() {
    if (_socket == null) {
      throw Exception('Socket not initialized. Call connectSocket() first.');
    }
    if (!_socket!.connected) {
      debugPrint('🔄 Socket not connected — forcing reconnect');
      _socket!.connect();
    }
    return _socket!;
  }

  /// Call on logout only
  static void disconnectSocket() {
    _activeConversationId = null;
    _token = null;
    _userId = null;
    _socket?.disconnect();
    _socket?.dispose();
    _socket = null;
  }
}
