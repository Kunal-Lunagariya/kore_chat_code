import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/api_call_service.dart';
import '../../services/notification_service.dart';
import '../../socket/socket_events.dart';
import '../../socket/socket_index.dart';
import '../../theme/app_theme.dart';
import '../chat/call_screen.dart';
import '../chat/group_call_screen.dart';
import '../chat/incoming_call_overlay.dart';
import '../login/login_screen.dart';
import '../chat/chat_screen.dart';

// ─────────────────────────────────────────────
// Models
// ─────────────────────────────────────────────

class ChatUser {
  final int value;
  final String label;

  ChatUser({required this.value, required this.label});

  factory ChatUser.fromJson(Map<String, dynamic> json) {
    return ChatUser(
      value: (json['value'] as num?)?.toInt() ?? 0,
      label: (json['label'] as String?) ?? 'Unknown',
    );
  }

  String get initials => _initials(label);
}

class RecentChat {
  final int conversationId;
  final bool myIsMuted;
  final int themUserId;
  final String themUserName;
  final String themUserRole;
  final bool themIsOnline;
  final String? groupName;
  final int conversationType;
  final int createdBy;
  final String createdByName;
  final DateTime createdAt;
  final int? lastMessageId;
  final DateTime? lastMessageTime;
  final String lastMessageText;
  final int lastMessageSenderId;
  final String lastMessageType;
  final int? lastMessageMediaId;
  final int unRead;
  final String? fileUrl;
  final String? fileType;
  final String? fileMimeType;
  final String? fileName;
  final int? callId;
  final int? callType;
  final String? callStatus;
  final List<Map<String, dynamic>> groupMembers;

  RecentChat({
    required this.conversationId,
    required this.myIsMuted,
    required this.themUserId,
    required this.themUserName,
    required this.themUserRole,
    required this.themIsOnline,
    this.groupName,
    required this.conversationType,
    required this.createdBy,
    required this.createdByName,
    required this.createdAt,
    this.lastMessageId,
    this.lastMessageTime,
    required this.lastMessageText,
    required this.lastMessageSenderId,
    required this.lastMessageType,
    this.lastMessageMediaId,
    required this.unRead,
    this.fileUrl,
    this.fileType,
    this.fileMimeType,
    this.fileName,
    this.callId,
    this.callType,
    this.callStatus,
    this.groupMembers = const [],
  });

  factory RecentChat.fromJson(Map<String, dynamic> json) {
    return RecentChat(
      conversationId: (json['conversationId'] as num?)?.toInt() ?? 0,
      myIsMuted: json['myIsMuted'] as bool? ?? false,
      themUserId: (json['themUserId'] as num?)?.toInt() ?? 0,
      themUserName: (json['themUserName'] as String?) ?? 'Unknown',
      themUserRole: (json['themUserRole'] as String?) ?? '',
      themIsOnline: json['themIsOnline'] as bool? ?? false,
      groupName: json['groupName'] as String?,
      conversationType: (json['conversationType'] as num?)?.toInt() ?? 1,
      createdBy: (json['createdBy'] as num?)?.toInt() ?? 0,
      createdByName: (json['createdByName'] as String?) ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      lastMessageId: (json['lastMessageId'] as num?)?.toInt(),
      lastMessageTime: json['lastMessageTime'] != null
          ? DateTime.tryParse(json['lastMessageTime'] as String)
          : null,
      lastMessageText: (json['lastMessageText'] as String?) ?? '',
      lastMessageSenderId: (json['lastMessageSenderId'] as num?)?.toInt() ?? 0,
      lastMessageType: (json['lastMessageType'] as String?) ?? 'text',
      lastMessageMediaId: (json['lastMessageMediaId'] as num?)?.toInt(),
      unRead: (json['unRead'] as num?)?.toInt() ?? 0,
      fileUrl: json['fileUrl'] as String?,
      fileType: json['fileType'] as String?,
      fileMimeType: json['fileMimeType'] as String?,
      fileName: json['fileName'] as String?,
      callId: (json['callId'] as num?)?.toInt(),
      callType: (json['callType'] as num?)?.toInt(),
      callStatus: json['callStatus'] as String?,
      groupMembers: (json['groupMembers'] as List<dynamic>? ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList(),
    );
  }

  bool get isMediaMessage =>
      lastMessageText.isEmpty &&
      (fileUrl != null || lastMessageMediaId != null) &&
      callId == null;

  String get previewText {
    // Call message takes priority
    if (callId != null) {
      final type = callType == 2 ? 'Video call' : 'Audio call';
      final status = callStatus == 'Ended' ? 'Ended' : callStatus ?? '';
      return '$type · $status';
    }
    if (isMediaMessage) {
      if (fileType == 'image') return 'Photo';
      if (fileType == 'video') return 'Video';
      if (fileType == 'audio') return 'Audio';
      return 'File';
    }
    return lastMessageText.isNotEmpty ? lastMessageText : 'No messages yet';
  }

  String get displayName =>
      conversationType == 2 ? (groupName ?? 'Group') : themUserName;

  // ── FIX: Use UTC directly — no toLocal() ──
  String get formattedTime {
    if (lastMessageTime == null) return '';
    final nowUtc = DateTime.now().toUtc();
    final msgUtc = lastMessageTime!; // already parsed as UTC from ISO string
    final diffDays = DateTime.utc(
      nowUtc.year,
      nowUtc.month,
      nowUtc.day,
    ).difference(DateTime.utc(msgUtc.year, msgUtc.month, msgUtc.day)).inDays;

    if (diffDays == 0) {
      final h = msgUtc.hour;
      final m = msgUtc.minute.toString().padLeft(2, '0');
      final period = h >= 12 ? 'pm' : 'am';
      final hour = h > 12 ? h - 12 : (h == 0 ? 12 : h);
      return '$hour:$m $period';
    } else if (diffDays == 1) {
      return 'Yesterday';
    } else if (diffDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[msgUtc.weekday - 1];
    }
    return '${msgUtc.day}/${msgUtc.month}/${msgUtc.year.toString().substring(2)}';
  }
}

// ─────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────

String _initials(String name) {
  final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
  if (parts.length >= 2) return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
  if (parts.length == 1) return parts[0][0].toUpperCase();
  return '?';
}

Color _avatarColor(String name) {
  const colors = [
    Color(0xFF5C6BC0),
    Color(0xFF26A69A),
    Color(0xFFEF5350),
    Color(0xFFAB47BC),
    Color(0xFF42A5F5),
    Color(0xFFFF7043),
    Color(0xFF66BB6A),
    Color(0xFFEC407A),
  ];
  return colors[name.length % colors.length];
}

// ─────────────────────────────────────────────
// Home Screen
// ─────────────────────────────────────────────

class HomeScreen extends StatefulWidget {
  final int userId;
  final String userName;

  const HomeScreen({super.key, required this.userId, required this.userName});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  int? _openConversationId;

  List<RecentChat> _chats = [];
  bool _isLoading = true;
  bool _hasError = false;
  Timer? _refreshTimer;
  StreamSubscription? _callAcceptedSub;
  bool _isNavigatingToCall = false;

  OverlayEntry? _callOverlayEntry;

  final Set<int> _onlineUserIds = {};

  @override
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    NotificationService().setMyUserId(widget.userId);

    _fetchRecentChats();
    _listenToNewMessages();
    _registerCallListener();

    SocketIndex.setReconnectCallback(() {
      if (mounted) _registerCallListener();
    });

    // Listen for CallKit accept events (foreground / background)
    _callAcceptedSub = NotificationService.onCallAccepted.listen((data) {
      if (!mounted) return;
      _handleCallKitAccepted(data);
    });

    // ── KEY FIX: Check if CallKit accept fired before HomeScreen built ──
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkPendingCallKitAccept();
    });

    try {
      SocketIndex.getSocket().onAny((event, data) {
        debugPrint('📡 SOCKET EVENT: $event');
      });
    } catch (e) {}
  }

  // Add this new method:
  Future<void> _checkPendingCallKitAccept() async {
    if (_isNavigatingToCall) return;
    try {
      final calls = await FlutterCallkitIncoming.activeCalls();
      if (calls == null || (calls as List).isEmpty) return;

      // There's an active call — check if it was already accepted
      // (i.e. we're in the accepted state, app just finished building)
      debugPrint('📞 Found active CallKit call on HomeScreen build: $calls');

      final call = (calls).first as Map;
      final extra = Map<String, dynamic>.from(call['extra'] as Map? ?? {});

      final offerStr =
          extra['offerJson']?.toString() ?? extra['offer']?.toString() ?? '';
      if (offerStr.isEmpty) return; // still ringing, not accepted yet

      Map<String, dynamic> offer = {};
      try {
        offer = Map<String, dynamic>.from(jsonDecode(offerStr) as Map);
      } catch (_) {
        return;
      }

      final callerId = int.tryParse(extra['callerId']?.toString() ?? '0') ?? 0;
      final callerName = extra['callerName']?.toString() ?? 'Unknown';
      final callType = extra['callType']?.toString() ?? 'audio';

      if (callerId == 0 || offer.isEmpty) return;

      if (_isNavigatingToCall) return;

      // Only navigate if we're not already in a call screen
      debugPrint('📞 Resuming pending accepted call from cold start');
      await _handleCallKitAccepted({
        'callerId': callerId,
        'callerName': callerName,
        'callType': callType,
        'offer': offer,
        'myUserId': widget.userId,
      });
    } catch (e) {
      debugPrint('⚠️ _checkPendingCallKitAccept error: $e');
    }
  }

  Future<void> _handleCallKitAccepted(Map<String, dynamic> data) async {
    if (_isNavigatingToCall) {
      debugPrint('⚠️ Already navigating to call — ignoring duplicate accept');
      return;
    }
    _isNavigatingToCall = true;
    final callerId = data['callerId'] as int;
    final callerName = data['callerName'] as String;
    final callType = data['callType'] as String;
    final offer = Map<String, dynamic>.from(data['offer'] as Map);
    final myUserId = data['myUserId'] as int;
    final roomId = data['roomId'] as int?; // ← add
    final conversationId = data['conversationId'] as int?; // ← add

    await _ensureSocketConnected();
    if (!mounted) return;

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          myUserId: myUserId,
          remoteUserId: callerId,
          remoteUserName: callerName,
          callType: callType,
          isOutgoing: false,
          incomingOffer: offer,
          autoAnswer: true,
          roomId: roomId,
          conversationId: conversationId,
        ),
      ),
    ).then((_) {
      _isNavigatingToCall = false;
      NotificationService().clearPendingCall();
      NotificationService().endAllCalls();
    });
  }

  Future<void> _ensureSocketConnected() async {
    try {
      if (SocketIndex.isConnected) {
        debugPrint('✅ Socket already connected');
        return;
      }

      debugPrint('🔄 Socket not connected — connecting before call...');

      try {
        SocketIndex.getSocket();
      } catch (e) {
        // Not initialized — read token from prefs
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('auth_token');
        final userId = prefs.getInt('user_id');
        if (token != null) {
          SocketIndex.connectSocket(token, userId: userId);
        } else {
          debugPrint('⚠️ No auth token — cannot connect socket');
          return;
        }
      }

      // Poll up to 8 seconds
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
        await Future.delayed(const Duration(milliseconds: 300));
      } else {
        debugPrint(
          '⚠️ Socket not connected after ${waited}ms — proceeding anyway',
        );
      }
    } catch (e) {
      debugPrint('⚠️ _ensureSocketConnected error: $e');
    }
  }

  void _registerCallListener() {
    SocketEvents.offIncomingCall();

    SocketEvents.onIncomingCall((data) {
      if (!mounted) return;

      // ← If we're already in a call, ignore new incoming_call socket events
      if (_isNavigatingToCall) {
        debugPrint('⚠️ Already in call — ignoring incoming_call socket event');
        return;
      }

      final map = Map<String, dynamic>.from(data as Map);
      final fromUserId = (map['callerId'] as num?)?.toInt() ?? 0;
      final fromUserName = (map['callerName'] as String?) ?? 'Unknown';
      final callType = (map['callType'] as String?) ?? 'audio';
      final messageId = map['messageId'] != null
          ? int.tryParse(map['messageId'].toString())
          : null;
      final roomId = map['roomId'] != null
          ? int.tryParse(map['roomId'].toString())
          : null;
      final conversationId = map['conversationId'] != null
          ? int.tryParse(map['conversationId'].toString())
          : null;

      final offerRaw = map['offer'];
      Map<String, dynamic> offer = {};
      if (offerRaw is Map) {
        offer = Map<String, dynamic>.from(offerRaw);
      } else if (offerRaw is String && offerRaw.isNotEmpty) {
        try {
          offer = Map<String, dynamic>.from(jsonDecode(offerRaw) as Map);
        } catch (_) {}
      }

      debugPrint(
        '📞 incoming_call: fromUserId=$fromUserId fromUserName=$fromUserName',
      );

      NotificationService().setPendingCall(
        callerId: fromUserId,
        callerName: fromUserName,
        callType: callType,
        offer: offer,
        messageId: messageId,
        roomId: roomId,
        conversationId: conversationId,
      );

      NotificationService().showIncomingCall(
        callerId: fromUserId,
        callerName: fromUserName,
        callType: callType,
        offer: offer,
      );
    });

    SocketEvents.onGroupCallIncoming((data) {
      if (!mounted) return;
      final map = Map<String, dynamic>.from(data as Map);
      final conversationId = (map['conversationId'] as num?)?.toInt() ?? 0;
      final callerId = (map['callerId'] as num?)?.toInt() ?? 0;
      final callerName = (map['callerName'] as String?) ?? 'Unknown';
      final callType = (map['callType'] as String?) ?? 'audio';

      // Find the group chat from our chats list
      final chat = _chats.firstWhere(
        (c) => c.conversationId == conversationId,
        orElse: () => _chats.first,
      );

      debugPrint(
        '📞 Incoming group call from $callerName in conversation $conversationId',
      );

      // Show incoming call overlay / navigate
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => GroupCallScreen(
            myUserId: widget.userId,
            conversationId: conversationId,
            groupName: chat.displayName,
            callType: callType,
            isInitiator: false,
            groupMembers: chat.groupMembers,
            callerId: callerId,
            callerName: callerName,
          ),
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    debugPrint('📱 App lifecycle: $state');

    if (state == AppLifecycleState.resumed) {
      if (!SocketIndex.isConnected) {
        SocketIndex.getSocket();
      }
      _registerCallListener();

      // ← Don't check for missed calls if we just accepted one
      if (!_isNavigatingToCall) {
        NotificationService().checkForMissedCallOnResume();
      }

      _fetchRecentChats(silent: true);
    }
  }

  void _listenToNewMessages() {
    try {
      final socket = SocketIndex.getSocket();

      socket.on('recent_chat_update', (data) {
        if (!mounted) return;
        try {
          final msg = Map<String, dynamic>.from(data as Map);
          final conversationId = (msg['conversationId'] as num?)?.toInt() ?? 0;
          final senderId = (msg['senderId'] as num?)?.toInt() ?? 0;
          final messageId = (msg['id'] as num?)?.toInt() ?? 0;
          final isMine = senderId == widget.userId;
          final isOpenConversation = _openConversationId == conversationId;

          // ← Emit delivered if not mine and chat not open
          if (!isMine && !isOpenConversation) {
            SocketEvents.emitMessageStatus(
              receiverId: widget.userId,
              senderId: senderId,
              conversationId: conversationId,
              messageId: messageId,
              status: 'delivered',
            );
          }

          setState(() {
            final idx = _chats.indexWhere(
              (c) => c.conversationId == conversationId,
            );

            if (idx != -1) {
              final old = _chats[idx];
              final updated = RecentChat(
                conversationId: old.conversationId,
                myIsMuted: old.myIsMuted,
                themUserId: old.themUserId,
                themUserName: old.themUserName,
                themUserRole: old.themUserRole,
                themIsOnline: old.themIsOnline,
                groupName: old.groupName,
                conversationType: old.conversationType,
                createdBy: old.createdBy,
                createdByName: old.createdByName,
                createdAt: old.createdAt,
                lastMessageId: (msg['id'] as num?)?.toInt(),
                lastMessageTime: DateTime.tryParse(
                  msg['createdAt'] as String? ?? '',
                ),
                lastMessageText: (msg['messageText'] as String?) ?? '',
                lastMessageSenderId: (msg['senderId'] as num?)?.toInt() ?? 0,
                lastMessageType: (msg['messageType'] as String?) ?? 'text',
                lastMessageMediaId: (msg['mediaId'] as num?)?.toInt(),

                unRead: isMine || isOpenConversation ? 0 : old.unRead + 1,
                fileUrl: msg['fileUrl'] as String?,
                fileType: msg['fileType'] as String?,
                fileMimeType: msg['fileMimeType'] as String?,
                fileName: msg['fileName'] as String?,
                groupMembers: old.groupMembers,
              );

              _chats.removeAt(idx);
              _chats.insert(0, updated); // move to top
            } else {
              // New conversation not in list yet — fetch to get full data
              _fetchRecentChats(silent: true);
            }
          });

          // Show notification only if message is not mine and chat is not open
          if (!isMine && !isOpenConversation) {
            final chat = _chats.firstWhere(
              (c) => c.conversationId == conversationId,
              orElse: () => _chats.first,
            );
            NotificationService().showMessageNotification(
              conversationId: conversationId,
              senderName: chat.themUserName,
              message: (msg['messageText'] as String?) ?? '',
              isGroup: chat.conversationType == 2,
              groupName: chat.groupName,
            );
          }
        } catch (_) {}
      });

      SocketEvents.onUserStatus((data) {
        if (!mounted) return;
        final map = Map<String, dynamic>.from(data as Map);
        final userId = (map['userId'] as num?)?.toInt() ?? 0;
        final isOnline = map['isOnline'] == 1 || map['isOnline'] == true;
        _updateUserOnlineStatus(userId, isOnline);
      });

      // Handles initial list of online users when app connects
      SocketEvents.onOnlineUsers((data) {
        if (!mounted) return;
        final ids = (data as List<dynamic>)
            .map((e) => (e as num?)?.toInt() ?? 0)
            .where((id) => id > 0)
            .toSet();
        setState(() {
          _onlineUserIds
            ..clear()
            ..addAll(ids);
          // Apply to current chats
          _chats = _chats
              .map(
                (c) => _rebuildChat(
                  c,
                  themIsOnline: _onlineUserIds.contains(c.themUserId),
                ),
              )
              .toList();
        });
        debugPrint('👥 Online users: $_onlineUserIds');
      });

      SocketEvents.onUserStatus((data) {
        if (!mounted) return;
        final map = Map<String, dynamic>.from(data as Map);
        final userId = (map['userId'] as num?)?.toInt() ?? 0;
        final isOnline = map['isOnline'] == 1 || map['isOnline'] == true;

        setState(() {
          if (isOnline) {
            _onlineUserIds.add(userId);
          } else {
            _onlineUserIds.remove(userId);
          }
          // Update the specific chat's online status
          _chats = _chats.map((c) {
            if (c.themUserId == userId) {
              return _rebuildChat(c, themIsOnline: isOnline);
            }
            return c;
          }).toList();
        });
        debugPrint('📡 user_status: userId=$userId isOnline=$isOnline');
      });
    } catch (_) {}
  }

  void _updateUserOnlineStatus(int userId, bool isOnline) {
    setState(() {
      _chats = _chats.map((c) {
        if (c.themUserId == userId) {
          return _rebuildChat(c, themIsOnline: isOnline);
        }
        return c;
      }).toList();
    });
  }

  RecentChat _rebuildChat(RecentChat c, {required bool themIsOnline}) {
    return RecentChat(
      conversationId: c.conversationId,
      myIsMuted: c.myIsMuted,
      themUserId: c.themUserId,
      themUserName: c.themUserName,
      themUserRole: c.themUserRole,
      themIsOnline: themIsOnline,
      groupName: c.groupName,
      conversationType: c.conversationType,
      createdBy: c.createdBy,
      createdByName: c.createdByName,
      createdAt: c.createdAt,
      lastMessageId: c.lastMessageId,
      lastMessageTime: c.lastMessageTime,
      lastMessageText: c.lastMessageText,
      lastMessageSenderId: c.lastMessageSenderId,
      lastMessageType: c.lastMessageType,
      lastMessageMediaId: c.lastMessageMediaId,
      unRead: c.unRead,
      fileUrl: c.fileUrl,
      fileType: c.fileType,
      fileMimeType: c.fileMimeType,
      fileName: c.fileName,
      callId: c.callId,
      callType: c.callType,
      callStatus: c.callStatus,
      groupMembers: c.groupMembers,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _searchController.dispose();
    _callOverlayEntry?.remove();
    _callOverlayEntry = null;
    _callAcceptedSub?.cancel();

    try {
      final socket = SocketIndex.getSocket();
      socket.off('recent_chat_update');
      socket.off('incoming_call');
      socket.off('user_status');
      socket.off('online_users');
      SocketEvents.offGroupCallIncoming();
    } catch (_) {}

    super.dispose();
  }

  // ── API ────────────────────────────────────

  Future<void> _fetchRecentChats({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() {
        _isLoading = true;
        _hasError = false;
      });
    }
    try {
      final response = await ApiCall.get('v1/chat/recent');
      if (!mounted) return;
      if (response['success'] == true) {
        final data = response['data'] as List<dynamic>;
        final chats = data
            .map((e) => RecentChat.fromJson(e as Map<String, dynamic>))
            .toList();

        setState(() {
          // ← Preserve socket-tracked online status — API always returns null
          _chats = chats
              .map(
                (c) => _rebuildChat(
                  c,
                  themIsOnline: _onlineUserIds.contains(c.themUserId),
                ),
              )
              .toList();
          _isLoading = false;
          _hasError = false;
        });

        SocketEvents.emitMultiMessageStatusDelivered(receiverId: widget.userId);
      } else {
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
    }
  }

  List<RecentChat> get _filteredChats {
    if (_searchQuery.isEmpty) return _chats;
    return _chats
        .where(
          (c) =>
              c.themUserName.toLowerCase().contains(_searchQuery.toLowerCase()),
        )
        .toList();
  }

  Future<void> _logout() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final userId = prefs.getInt('user_id') ?? 0;
      if (userId > 0) {
        await ApiCall.post(
          'v1/user/user-device',
          data: {
            'userId': userId,
            'deviceType': Platform.isIOS ? 'ios' : 'android',
            'fcmToken': null,
            'voIpToken': null,
          },
        );
      }
    } catch (e) {
      debugPrint('⚠️ Failed to clear device token: $e');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    await prefs.remove('user_id');
    await prefs.remove('user_name');
    await prefs.remove('user_email');
    ApiCall.clearAuthToken();
    SocketIndex.disconnectSocket();
    if (mounted) {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (_) => false,
      );
    }
  }

  void _showNewChatModal() async {
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _NewChatModal(
        currentUserId: widget.userId,
        myUserId: widget.userId,
        onlineUserIds: _onlineUserIds,
        onChatOpened: (conversationId, themUserId, themUserName, themIsOnline) {
          setState(() => _openConversationId = conversationId);
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                conversationId: conversationId,
                themUserId: themUserId,
                themUserName: themUserName,
                themIsOnline: themIsOnline,
                myUserId: widget.userId,
                onlineUserIds: _onlineUserIds,
                isGroup: themUserId == 0,
                groupMembers: const [],
              ),
            ),
          ).then((_) async {
            await Future.delayed(const Duration(milliseconds: 500));
            if (mounted) setState(() => _openConversationId = null);
          });
        },
      ),
    );
    _fetchRecentChats(silent: true);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      ),
    );

    return Scaffold(
      body: Column(
        children: [
          _buildHeader(isDark),
          _buildSearchBar(isDark),
          _buildSectionLabel(isDark),
          Expanded(child: _buildBody(isDark)),
        ],
      ),
    );
  }

  Widget _buildHeader(bool isDark) {
    return Container(
      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 16, 14),
          child: Row(
            children: [
              Stack(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [AppTheme.redAccent, AppTheme.redDark],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.redAccent.withOpacity(0.3),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Text(
                        _initials(widget.userName),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 1,
                    right: 1,
                    child: Container(
                      width: 13,
                      height: 13,
                      decoration: BoxDecoration(
                        color: _onlineUserIds.contains(widget.userId)
                            ? Color(0xFF4CAF50)
                            : Colors.red,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isDark
                              ? AppTheme.darkCard
                              : AppTheme.lightCard,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'My Chats',
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.5,
                      ),
                    ),
                    Text(
                      widget.userName,
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.darkTextPrimary
                            : AppTheme.lightTextPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              _iconBtn(
                Icons.logout_rounded,
                isDark,
                () => _showLogoutDialog(isDark),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(IconData icon, bool isDark, VoidCallback onTap) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            icon,
            size: 22,
            color: isDark
                ? AppTheme.darkTextSecondary
                : AppTheme.lightTextSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBar(bool isDark) {
    return Container(
      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 44,
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(
                    Icons.search_rounded,
                    size: 20,
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      onChanged: (v) => setState(() => _searchQuery = v),
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.darkTextPrimary
                            : AppTheme.lightTextPrimary,
                        fontSize: 14,
                      ),
                      cursorColor: AppTheme.redAccent,
                      decoration: InputDecoration(
                        hintText: 'Search chats...',
                        hintStyle: TextStyle(
                          color: isDark
                              ? AppTheme.darkTextSecondary.withOpacity(0.6)
                              : AppTheme.lightTextSecondary.withOpacity(0.6),
                          fontSize: 14,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                  if (_searchQuery.isNotEmpty)
                    GestureDetector(
                      onTap: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: Icon(
                          Icons.close_rounded,
                          size: 18,
                          color: isDark
                              ? AppTheme.darkTextSecondary
                              : AppTheme.lightTextSecondary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: _showNewChatModal,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.redAccent, AppTheme.redDark],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(14),
                boxShadow: [
                  BoxShadow(
                    color: AppTheme.redAccent.withOpacity(0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: const Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(bool isDark) {
    return Container(
      color: isDark ? AppTheme.darkBg : AppTheme.lightBg,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
      child: Row(
        children: [
          Text(
            'RECENT CHATS',
            style: TextStyle(
              color: isDark
                  ? AppTheme.darkTextSecondary.withOpacity(0.6)
                  : AppTheme.lightTextSecondary.withOpacity(0.6),
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const Spacer(),
          GestureDetector(
            onTap: _fetchRecentChats,
            child: Icon(
              Icons.refresh_rounded,
              size: 18,
              color: isDark
                  ? AppTheme.darkTextSecondary.withOpacity(0.5)
                  : AppTheme.lightTextSecondary.withOpacity(0.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(bool isDark) {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          valueColor: AlwaysStoppedAnimation<Color>(AppTheme.redAccent),
        ),
      );
    }

    if (_hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.wifi_off_rounded,
              size: 48,
              color: isDark
                  ? AppTheme.darkTextSecondary.withOpacity(0.3)
                  : AppTheme.lightTextSecondary.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              'Failed to load chats',
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _fetchRecentChats,
              icon: const Icon(
                Icons.refresh_rounded,
                size: 16,
                color: AppTheme.redAccent,
              ),
              label: const Text(
                'Retry',
                style: TextStyle(color: AppTheme.redAccent),
              ),
            ),
          ],
        ),
      );
    }

    if (_filteredChats.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 56,
              color: isDark
                  ? AppTheme.darkTextSecondary.withOpacity(0.3)
                  : AppTheme.lightTextSecondary.withOpacity(0.3),
            ),
            const SizedBox(height: 16),
            Text(
              _searchQuery.isNotEmpty ? 'No chats found' : 'No chats yet',
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _searchQuery.isNotEmpty
                  ? 'Try a different search'
                  : 'Tap + to start a new chat',
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkTextSecondary.withOpacity(0.5)
                    : AppTheme.lightTextSecondary.withOpacity(0.5),
                fontSize: 13,
              ),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      color: AppTheme.redAccent,
      backgroundColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
      onRefresh: _fetchRecentChats,
      child: ListView.builder(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        itemCount: _filteredChats.length,
        itemBuilder: (_, i) => _buildChatTile(_filteredChats[i], isDark),
      ),
    );
  }

  Widget _buildChatTile(RecentChat chat, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () async {
            setState(() {
              _openConversationId = chat.conversationId;
              // Clear unread badge immediately when chat is opened
              final idx = _chats.indexWhere(
                (c) => c.conversationId == chat.conversationId,
              );
              if (idx != -1 && _chats[idx].unRead > 0) {
                final old = _chats[idx];
                _chats[idx] = RecentChat(
                  conversationId: old.conversationId,
                  myIsMuted: old.myIsMuted,
                  themUserId: old.themUserId,
                  themUserName: old.themUserName,
                  themUserRole: old.themUserRole,
                  themIsOnline: old.themIsOnline,
                  groupName: old.groupName,
                  conversationType: old.conversationType,
                  createdBy: old.createdBy,
                  createdByName: old.createdByName,
                  createdAt: old.createdAt,
                  lastMessageId: old.lastMessageId,
                  lastMessageTime: old.lastMessageTime,
                  lastMessageText: old.lastMessageText,
                  lastMessageSenderId: old.lastMessageSenderId,
                  lastMessageType: old.lastMessageType,
                  lastMessageMediaId: old.lastMessageMediaId,
                  unRead: 0, // ← clear immediately
                  fileUrl: old.fileUrl,
                  fileType: old.fileType,
                  fileMimeType: old.fileMimeType,
                  fileName: old.fileName,
                  groupMembers: old.groupMembers,
                );
              }
            });
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => ChatScreen(
                  conversationId: chat.conversationId,
                  themUserId: chat.themUserId,
                  themUserName: chat.displayName,
                  themIsOnline: chat.themIsOnline,
                  myUserId: widget.userId,
                  onlineUserIds: _onlineUserIds,
                  isGroup: chat.conversationType == 2,
                  groupMembers: chat.groupMembers,
                ),
              ),
            );
            await Future.delayed(const Duration(milliseconds: 500));
            if (mounted) setState(() => _openConversationId = null);
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
            child: Row(
              children: [
                Stack(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        color: _avatarColor(chat.displayName),
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          _initials(chat.displayName),
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ),
                    if (chat.conversationType == 1 && chat.themIsOnline)
                      Positioned(
                        bottom: 1,
                        right: 1,
                        child: Container(
                          width: 13,
                          height: 13,
                          decoration: BoxDecoration(
                            color: const Color(0xFF4CAF50),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isDark
                                  ? AppTheme.darkCard
                                  : AppTheme.lightCard,
                              width: 2,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        chat.displayName,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.darkTextPrimary
                              : AppTheme.lightTextPrimary,
                          fontSize: 14,
                          fontWeight: chat.unRead > 0
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          if (chat.callId != null)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(
                                chat.callType == 2
                                    ? Icons.videocam_outlined
                                    : Icons.call_outlined,
                                size: 14,
                                color: isDark
                                    ? AppTheme.darkTextSecondary.withOpacity(
                                        0.6,
                                      )
                                    : AppTheme.lightTextSecondary.withOpacity(
                                        0.6,
                                      ),
                              ),
                            )
                          else if (chat.isMediaMessage)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: Icon(
                                _mediaIcon(chat.fileType),
                                size: 14,
                                color: isDark
                                    ? AppTheme.darkTextSecondary.withOpacity(
                                        0.6,
                                      )
                                    : AppTheme.lightTextSecondary.withOpacity(
                                        0.6,
                                      ),
                              ),
                            ),
                          Expanded(
                            child: Text(
                              chat.previewText,
                              style: TextStyle(
                                color: chat.unRead > 0
                                    ? (isDark
                                          ? AppTheme.darkTextPrimary
                                                .withOpacity(0.8)
                                          : AppTheme.lightTextPrimary
                                                .withOpacity(0.7))
                                    : (isDark
                                          ? AppTheme.darkTextSecondary
                                          : AppTheme.lightTextSecondary),
                                fontSize: 12,
                                fontWeight: chat.unRead > 0
                                    ? FontWeight.w500
                                    : FontWeight.w400,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      chat.formattedTime,
                      style: TextStyle(
                        color: chat.unRead > 0
                            ? AppTheme.redAccent
                            : (isDark
                                  ? AppTheme.darkTextSecondary
                                  : AppTheme.lightTextSecondary),
                        fontSize: 11,
                        fontWeight: chat.unRead > 0
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    const SizedBox(height: 5),
                    if (chat.unRead > 0)
                      Container(
                        constraints: const BoxConstraints(minWidth: 20),
                        height: 20,
                        padding: const EdgeInsets.symmetric(horizontal: 5),
                        decoration: const BoxDecoration(
                          color: AppTheme.redAccent,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            chat.unRead > 99 ? '99+' : '${chat.unRead}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      )
                    else
                      const SizedBox(height: 20),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  IconData _mediaIcon(String? fileType) {
    switch (fileType) {
      case 'video':
        return Icons.videocam_outlined;
      case 'audio':
        return Icons.mic_outlined;
      default:
        return Icons.image_outlined;
    }
  }

  void _showLogoutDialog(bool isDark) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Logout',
          style: TextStyle(
            color: isDark
                ? AppTheme.darkTextPrimary
                : AppTheme.lightTextPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          'Are you sure you want to logout?',
          style: TextStyle(
            color: isDark
                ? AppTheme.darkTextSecondary
                : AppTheme.lightTextSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'Cancel',
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _logout();
            },
            child: const Text(
              'Logout',
              style: TextStyle(
                color: AppTheme.redAccent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// New Chat Modal
// ─────────────────────────────────────────────

class _NewChatModal extends StatefulWidget {
  final int currentUserId;
  final int myUserId;
  final Set<int> onlineUserIds;
  final void Function(
    int conversationId,
    int themUserId,
    String themUserName,
    bool themIsOnline,
  )
  onChatOpened;

  const _NewChatModal({
    required this.currentUserId,
    required this.myUserId,
    required this.onlineUserIds,
    required this.onChatOpened,
  });

  @override
  State<_NewChatModal> createState() => _NewChatModalState();
}

class _NewChatModalState extends State<_NewChatModal> {
  final TextEditingController _searchCtrl = TextEditingController();
  List<ChatUser> _allUsers = [];
  List<ChatUser> _filtered = [];
  bool _loading = true;
  bool _starting = false;
  bool _isMultiSelect = false;
  final Set<int> _selectedUserIds = {};
  final List<ChatUser> _selectedUsers = [];

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    try {
      final response = await ApiCall.get('v1/user');
      if (!mounted) return;
      if (response['success'] == true) {
        final data = response['data'] as List<dynamic>;
        final users = data
            .map((e) => ChatUser.fromJson(e as Map<String, dynamic>))
            .where((u) => u.value != widget.currentUserId && u.label.isNotEmpty)
            .toList();
        setState(() {
          _allUsers = users;
          _filtered = users;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSearch(String query) {
    setState(() {
      _filtered = query.isEmpty
          ? _allUsers
          : _allUsers
                .where(
                  (u) => u.label.toLowerCase().contains(query.toLowerCase()),
                )
                .toList();
    });
  }

  // Show confirm dialog then call POST v1/chat/private
  void _onUserTap(ChatUser user) {
    if (_isMultiSelect) {
      setState(() {
        if (_selectedUserIds.contains(user.value)) {
          _selectedUserIds.remove(user.value);
          _selectedUsers.removeWhere((u) => u.value == user.value);
        } else {
          _selectedUserIds.add(user.value);
          _selectedUsers.add(user);
        }
        if (_selectedUserIds.isEmpty) _isMultiSelect = false;
      });
    } else {
      final isDark = Theme.of(context).brightness == Brightness.dark;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          icon: Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.chat_bubble_outline_rounded,
              size: 28,
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
            ),
          ),
          title: Text(
            'Start Conversation',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isDark
                  ? AppTheme.darkTextPrimary
                  : AppTheme.lightTextPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
          ),
          content: Text(
            'Start a conversation with ${user.label}?',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
              fontSize: 14,
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          actions: [
            Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    style: TextButton.styleFrom(
                      backgroundColor: AppTheme.redAccent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextButton(
                    onPressed: _starting ? null : () => _startChat(ctx, user),
                    style: TextButton.styleFrom(
                      backgroundColor: const Color(0xFF2196F3),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: _starting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Yes',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }
  }

  Future<void> _startChat(BuildContext dialogCtx, ChatUser user) async {
    setState(() => _starting = true);
    try {
      final response = await ApiCall.post(
        'v1/chat/private',
        data: {'toUserId': user.value},
      );

      if (!mounted) return;

      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>;
        final conversationId = (data['conversationId'] as num?)?.toInt() ?? 0;
        final themUserName = (data['themUserName'] as String?) ?? user.label;

        // Close dialog
        Navigator.pop(dialogCtx);
        // Close modal
        Navigator.pop(context);

        // Navigate to chat screen
        widget.onChatOpened(conversationId, user.value, themUserName, false);
      } else {
        Navigator.pop(dialogCtx);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                response['message'] as String? ?? 'Failed to start chat',
              ),
              backgroundColor: AppTheme.redAccent,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        Navigator.pop(dialogCtx);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to start chat'),
            backgroundColor: AppTheme.redAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Future<void> _createGroup(BuildContext dialogCtx, String groupName) async {
    setState(() => _starting = true);
    try {
      final response = await ApiCall.post(
        'v1/chat/group',
        data: {
          'groupName': groupName,
          'userIds': _selectedUsers.map((u) => u.value).toList(),
        },
      );

      if (!mounted) return;

      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>;
        final conversationId = (data['conversationId'] as num?)?.toInt() ?? 0;

        Navigator.pop(dialogCtx); // close group name dialog
        Navigator.pop(context); // close modal

        widget.onChatOpened(conversationId, 0, groupName, false);
      } else {
        Navigator.pop(dialogCtx);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                response['message'] as String? ?? 'Failed to create group',
              ),
              backgroundColor: AppTheme.redAccent,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        Navigator.pop(dialogCtx);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to create group'),
            backgroundColor: AppTheme.redAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  void _onUserLongPress(ChatUser user) {
    if (!_isMultiSelect) {
      setState(() {
        _isMultiSelect = true;
        _selectedUserIds.add(user.value);
        _selectedUsers.add(user);
      });
    }
  }

  void _showGroupNameDialog() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final TextEditingController groupNameCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'Group Name',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: isDark
                ? AppTheme.darkTextPrimary
                : AppTheme.lightTextPrimary,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '${_selectedUsers.length} members selected',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 16),
            Container(
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                ),
              ),
              child: TextField(
                controller: groupNameCtrl,
                autofocus: true,
                style: TextStyle(
                  color: isDark
                      ? AppTheme.darkTextPrimary
                      : AppTheme.lightTextPrimary,
                  fontSize: 14,
                ),
                cursorColor: AppTheme.redAccent,
                decoration: InputDecoration(
                  hintText: 'Enter group name...',
                  hintStyle: TextStyle(
                    color: isDark
                        ? AppTheme.darkTextSecondary.withOpacity(0.5)
                        : AppTheme.lightTextSecondary.withOpacity(0.6),
                    fontSize: 14,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                ),
              ),
            ),
          ],
        ),
        actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
        actions: [
          Row(
            children: [
              Expanded(
                child: TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: TextButton.styleFrom(
                    backgroundColor: isDark
                        ? AppTheme.darkInput
                        : AppTheme.lightInput,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                  child: Text(
                    'Cancel',
                    style: TextStyle(
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: StatefulBuilder(
                  builder: (ctx2, setBtn) => TextButton(
                    onPressed: _starting
                        ? null
                        : () async {
                            final name = groupNameCtrl.text.trim();
                            if (name.isEmpty) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: const Text(
                                    'Please enter a group name',
                                  ),
                                  backgroundColor: AppTheme.redAccent,
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              );
                              return;
                            }
                            await _createGroup(ctx, name);
                          },
                    style: TextButton.styleFrom(
                      backgroundColor: AppTheme.redAccent,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    child: _starting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Create',
                            style: TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withOpacity(0.15)
                  : Colors.black.withOpacity(0.15),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 0),
            child: Row(
              children: [
                if (_isMultiSelect)
                  GestureDetector(
                    onTap: () {
                      setState(() {
                        _isMultiSelect = false;
                        _selectedUserIds.clear();
                        _selectedUsers.clear();
                      });
                    },
                    child: Icon(
                      Icons.close_rounded,
                      size: 20,
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  )
                else
                  const SizedBox.shrink(),
                if (_isMultiSelect) const SizedBox(width: 8),
                Text(
                  _isMultiSelect
                      ? '${_selectedUserIds.length} Selected'
                      : 'START NEW CHAT',
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.5,
                  ),
                ),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.close_rounded,
                      size: 16,
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              height: 46,
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                ),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Icon(
                    Icons.search_rounded,
                    size: 20,
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: _onSearch,
                      autofocus: true,
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.darkTextPrimary
                            : AppTheme.lightTextPrimary,
                        fontSize: 14,
                      ),
                      cursorColor: AppTheme.redAccent,
                      decoration: InputDecoration(
                        hintText: 'Search users...',
                        hintStyle: TextStyle(
                          color: isDark
                              ? AppTheme.darkTextSecondary.withOpacity(0.5)
                              : AppTheme.lightTextSecondary.withOpacity(0.6),
                          fontSize: 14,
                        ),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          _buildSelectedChips(isDark),
          const SizedBox(height: 8),
          if (_isMultiSelect && _selectedUserIds.length >= 2)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: GestureDetector(
                onTap: _showGroupNameDialog,
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 13),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [AppTheme.redAccent, AppTheme.redDark],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: AppTheme.redAccent.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.group_add_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Create Group (${_selectedUserIds.length})',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: _loading
                ? Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        AppTheme.redAccent,
                      ),
                    ),
                  )
                : _filtered.isEmpty
                ? Center(
                    child: Text(
                      'No users found',
                      style: TextStyle(
                        color: isDark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary,
                      ),
                    ),
                  )
                : ListView.builder(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 4,
                    ),
                    itemCount: _filtered.length,
                    itemBuilder: (_, i) => _buildUserTile(_filtered[i], isDark),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedChips(bool isDark) {
    if (!_isMultiSelect || _selectedUsers.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _selectedUsers.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, i) {
          final user = _selectedUsers[i];
          return AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: AppTheme.redAccent.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: AppTheme.redAccent.withOpacity(0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(width: 6),
                Container(
                  width: 22,
                  height: 22,
                  decoration: BoxDecoration(
                    color: _avatarColor(user.label),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      user.initials,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  user.label.split(' ').first, // first name only
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.darkTextPrimary
                        : AppTheme.lightTextPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () {
                    setState(() {
                      _selectedUserIds.remove(user.value);
                      _selectedUsers.removeWhere((u) => u.value == user.value);
                      if (_selectedUserIds.isEmpty) _isMultiSelect = false;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: AppTheme.redAccent,
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildUserTile(ChatUser user, bool isDark) {
    final isSelected = _selectedUserIds.contains(user.value);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _onUserTap(user),
        onLongPress: () => _onUserLongPress(user),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Row(
            children: [
              Stack(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? AppTheme.redAccent
                          : _avatarColor(user.label),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: isSelected
                          ? const Icon(
                              Icons.check_rounded,
                              color: Colors.white,
                              size: 22,
                            )
                          : Text(
                              user.initials,
                              style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  user.label,
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.darkTextPrimary
                        : AppTheme.lightTextPrimary,
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!_isMultiSelect)
                Icon(
                  Icons.chevron_right_rounded,
                  size: 20,
                  color: isDark
                      ? AppTheme.darkTextSecondary.withOpacity(0.4)
                      : AppTheme.lightTextSecondary.withOpacity(0.4),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
