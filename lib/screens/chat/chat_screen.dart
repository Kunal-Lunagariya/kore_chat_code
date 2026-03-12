import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../../services/api_call_service.dart';
import '../../theme/app_theme.dart';

// ─────────────────────────────────────────────
// Model
// ─────────────────────────────────────────────

class ChatMessage {
  final int id;
  final int conversationId;
  final int senderId;
  final String senderName;
  final String messageType;
  final String messageText;
  final int? mediaId;
  final int? replyToMessageId;
  final String? replyMessageText;
  final int? replyMediaId;
  final String? replyFileUrl;
  final String? replyFileType;
  final String? replyFileMimeType;
  final String? replyFileName;
  final String? replyToUserName;
  final String replyToSender;
  final DateTime createdAt;
  final bool isDeleted;
  final String currentStatus;
  final String sender; // "me" | "them"
  final String? fileUrl;
  final String? fileType;
  final String? fileMimeType;
  final String? fileName;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.senderName,
    required this.messageType,
    required this.messageText,
    this.mediaId,
    this.replyToMessageId,
    this.replyMessageText,
    this.replyMediaId,
    this.replyFileUrl,
    this.replyFileType,
    this.replyFileMimeType,
    this.replyFileName,
    this.replyToUserName,
    required this.replyToSender,
    required this.createdAt,
    required this.isDeleted,
    required this.currentStatus,
    required this.sender,
    this.fileUrl,
    this.fileType,
    this.fileMimeType,
    this.fileName,
  });

  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    return ChatMessage(
      id: (json['id'] as num?)?.toInt() ?? 0,
      conversationId: (json['conversationId'] as num?)?.toInt() ?? 0,
      senderId: (json['senderId'] as num?)?.toInt() ?? 0,
      senderName: (json['senderName'] as String?) ?? '',
      messageType: (json['messageType'] as String?) ?? 'text',
      messageText: (json['messageText'] as String?) ?? '',
      mediaId: (json['mediaId'] as num?)?.toInt(),
      replyToMessageId: (json['replyToMessageId'] as num?)?.toInt(),
      replyMessageText: json['replyMessageText'] as String?,
      replyMediaId: (json['replyMediaId'] as num?)?.toInt(),
      replyFileUrl: json['replyFileUrl'] as String?,
      replyFileType: json['replyFileType'] as String?,
      replyFileMimeType: json['replyFileMimeType'] as String?,
      replyFileName: json['replyFileName'] as String?,
      replyToUserName: json['replyToUserName'] as String?,
      replyToSender: (json['replyToSender'] as String?) ?? 'them',
      createdAt:
      DateTime.tryParse(json['createdAt'] as String? ?? '') ?? DateTime.now(),
      isDeleted: json['isDeleted'] as bool? ?? false,
      currentStatus: (json['currentStatus'] as String?) ?? 'sent',
      sender: (json['sender'] as String?) ?? 'them',
      fileUrl: json['fileUrl'] as String?,
      fileType: json['fileType'] as String?,
      fileMimeType: json['fileMimeType'] as String?,
      fileName: json['fileName'] as String?,
    );
  }

  bool get isMe => sender == 'me';
  bool get hasMedia => fileUrl != null && fileUrl!.isNotEmpty;
  bool get hasReply => replyToMessageId != null;
  bool get isImage => fileType == 'image';

  String get formattedTime {
    // API stores times in UTC — display as-is (no timezone conversion)
    // so it matches web app output (e.g. "01:20 pm" from 13:20 UTC)
    final h = createdAt.hour;
    final m = createdAt.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'pm' : 'am';
    final hour = h > 12 ? h - 12 : (h == 0 ? 12 : h);
    return '$hour:$m $period';
  }

  String get dateLabel {
    final nowUtc = DateTime.now().toUtc();
    final diff = DateTime.utc(nowUtc.year, nowUtc.month, nowUtc.day)
        .difference(DateTime.utc(createdAt.year, createdAt.month, createdAt.day))
        .inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const days = [
      'Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday'
    ];
    if (diff < 7) return days[createdAt.weekday - 1];
    return '${createdAt.day}/${createdAt.month}/${createdAt.year}';
  }
}

// ─────────────────────────────────────────────
// Chat Screen
// ─────────────────────────────────────────────

class ChatScreen extends StatefulWidget {
  final int conversationId;
  final int themUserId;
  final String themUserName;
  final bool themIsOnline;
  final int myUserId;

  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.themUserId,
    required this.themUserName,
    required this.themIsOnline,
    required this.myUserId,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _focusNode = FocusNode();

  List<ChatMessage> _messages = [];
  bool _isLoading = true;
  bool _isSending = false;
  bool _hasError = false;
  bool _hasText = false;

  // Pagination
  int _page = 1;
  static const int _limit = 20;
  bool _hasNextPage = false;
  bool _loadingMore = false;

  // Reply
  ChatMessage? _replyingTo;

  // Scroll-to-bottom button
  bool _showScrollToBottom = false;

  @override
  void initState() {
    super.initState();
    _fetchMessages();
    _scrollCtrl.addListener(_onScroll);
    _messageCtrl.addListener(() {
      final has = _messageCtrl.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);
    });
  }

  @override
  void dispose() {
    _messageCtrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onScroll() {
    // Show scroll-to-bottom when user scrolled up
    final show = _scrollCtrl.offset > 200;
    if (show != _showScrollToBottom) {
      setState(() => _showScrollToBottom = show);
    }
    // Load more (older) when at top of reversed list = maxScrollExtent
    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 300) {
      if (_hasNextPage && !_loadingMore) _loadMoreMessages();
    }
  }

  // ── API ────────────────────────────────────

  Future<void> _fetchMessages() async {
    if (mounted) setState(() { _isLoading = true; _hasError = false; });
    try {
      final response = await ApiCall.get(
        'v1/chat/messages',
        queryParameters: {
          'conversationId': '${widget.conversationId}',
          'page': '1',
          'limit': '$_limit',
        },
      );
      if (!mounted) return;
      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>;
        final msgs = (data['messages'] as List<dynamic>)
            .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList();
        final pagination = data['pagination'] as Map<String, dynamic>;
        setState(() {
          _messages = msgs;
          _page = 1;
          _hasNextPage = (pagination['hasNextPage'] as num?)?.toInt() == 1;
          _isLoading = false;
        });
      } else {
        setState(() { _isLoading = false; _hasError = true; });
      }
    } catch (_) {
      if (mounted) setState(() { _isLoading = false; _hasError = true; });
    }
  }

  Future<void> _loadMoreMessages() async {
    if (_loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final nextPage = _page + 1;
      final response = await ApiCall.get(
        'v1/chat/messages',
        queryParameters: {
          'conversationId': '${widget.conversationId}',
          'page': '$nextPage',
          'limit': '$_limit',
        },
      );
      if (!mounted) return;
      if (response['success'] == true) {
        final data = response['data'] as Map<String, dynamic>;
        final msgs = (data['messages'] as List<dynamic>)
            .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
            .toList();
        final pagination = data['pagination'] as Map<String, dynamic>;
        setState(() {
          _messages.addAll(msgs);
          _page = nextPage;
          _hasNextPage = (pagination['hasNextPage'] as num?)?.toInt() == 1;
          _loadingMore = false;
        });
      } else {
        setState(() => _loadingMore = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageCtrl.text.trim();
    if (text.isEmpty || _isSending) return;
    setState(() => _isSending = true);
    _messageCtrl.clear();
    try {
      final body = <String, dynamic>{
        'conversationId': widget.conversationId,
        'messageText': text,
        'messageType': 'text',
        if (_replyingTo != null) 'replyToMessageId': _replyingTo!.id,
      };
      final response = await ApiCall.post('v1/chat/send', data: body);
      if (!mounted) return;
      if (response['success'] == true) {
        setState(() => _replyingTo = null);
        await _fetchMessages();
        _scrollToBottom();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Failed to send'),
          backgroundColor: AppTheme.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ));
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _pickAndSendImage() async {
    XFile? picked;
    try {
      picked = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
    } catch (_) {
      // PlatformException: permission denied or channel error
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Gallery access denied. Please allow in Settings.'),
          backgroundColor: AppTheme.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ));
      }
      return;
    }

    if (picked == null) return; // user cancelled

    setState(() => _isSending = true);
    try {
      final fields = <String, String>{
        'conversationId': '${widget.conversationId}',
        'messageType': 'text',
        if (_replyingTo != null)
          'replyToMessageId': '${_replyingTo!.id}',
      };
      final response = await ApiCall.uploadFile(
        'v1/chat/send',
        filePath: picked.path,
        fileFieldName: 'file',
        fields: fields,
      );
      if (!mounted) return;
      if (response['success'] == true) {
        setState(() => _replyingTo = null);
        await _fetchMessages();
        _scrollToBottom();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Failed to send image'),
          backgroundColor: AppTheme.redAccent,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ));
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(0,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  // ── Build ──────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
    ));

    return Scaffold(
      backgroundColor: isDark ? AppTheme.darkBg : AppTheme.lightBg,
      body: Column(
        children: [
          _buildAppBar(isDark),
          Expanded(
            child: Stack(
              children: [
                _buildBody(isDark),
                if (_showScrollToBottom)
                  Positioned(
                    bottom: 12,
                    right: 16,
                    child: _scrollToBottomBtn(isDark),
                  ),
              ],
            ),
          ),
          if (_replyingTo != null) _buildReplyBar(isDark),
          _buildInputBar(isDark),
        ],
      ),
    );
  }

  // ── AppBar ─────────────────────────────────

  Widget _buildAppBar(bool isDark) {
    return Container(
      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 16, 10),
          child: Row(
            children: [
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: Icon(Icons.arrow_back_ios_new_rounded,
                    size: 20,
                    color: isDark
                        ? AppTheme.darkTextPrimary
                        : AppTheme.lightTextPrimary),
              ),
              // Avatar
              Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: _avatarColor(widget.themUserName),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(_initials(widget.themUserName),
                      style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: 14)),
                ),
              ),
              const SizedBox(width: 10),
              // Name + status
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.themUserName,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.darkTextPrimary
                              : AppTheme.lightTextPrimary,
                          fontSize: 15, fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis),
                    Row(children: [
                      Container(
                        width: 7, height: 7,
                        decoration: BoxDecoration(
                          color: widget.themIsOnline
                              ? const Color(0xFF4CAF50)
                              : (isDark
                              ? AppTheme.darkTextSecondary
                              : AppTheme.lightTextSecondary),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        widget.themIsOnline ? 'online' : 'offline',
                        style: TextStyle(
                          color: widget.themIsOnline
                              ? const Color(0xFF4CAF50)
                              : (isDark
                              ? AppTheme.darkTextSecondary
                              : AppTheme.lightTextSecondary),
                          fontSize: 12,
                        ),
                      ),
                    ]),
                  ],
                ),
              ),
              IconButton(
                onPressed: () {},
                icon: Icon(Icons.more_vert_rounded,
                    size: 22,
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Body / Message list ────────────────────

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
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.wifi_off_rounded,
              size: 48,
              color: isDark
                  ? AppTheme.darkTextSecondary.withOpacity(0.3)
                  : AppTheme.lightTextSecondary.withOpacity(0.3)),
          const SizedBox(height: 16),
          Text('Failed to load messages',
              style: TextStyle(
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary)),
          const SizedBox(height: 12),
          TextButton.icon(
            onPressed: _fetchMessages,
            icon: const Icon(Icons.refresh_rounded,
                size: 16, color: AppTheme.redAccent),
            label: const Text('Retry',
                style: TextStyle(color: AppTheme.redAccent)),
          ),
        ]),
      );
    }

    if (_messages.isEmpty) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.chat_bubble_outline_rounded,
              size: 48,
              color: isDark
                  ? AppTheme.darkTextSecondary.withOpacity(0.3)
                  : AppTheme.lightTextSecondary.withOpacity(0.3)),
          const SizedBox(height: 12),
          Text('No messages yet',
              style: TextStyle(
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary,
                  fontSize: 15)),
          const SizedBox(height: 4),
          Text('Say hello 👋',
              style: TextStyle(
                  color: isDark
                      ? AppTheme.darkTextSecondary.withOpacity(0.5)
                      : AppTheme.lightTextSecondary.withOpacity(0.5),
                  fontSize: 13)),
        ]),
      );
    }

    // Items: [newest ... oldest] (reversed list, index 0 = bottom)
    // We append a "Beginning" item + optional load-more indicator at end
    final itemCount = _messages.length + 1 + (_loadingMore ? 1 : 0);

    return ListView.builder(
      controller: _scrollCtrl,
      reverse: true,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: itemCount,
      itemBuilder: (_, index) {
        // Last slot: load-more spinner
        if (index == _messages.length + 1) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(
              child: SizedBox(
                width: 20, height: 20,
                child: CircularProgressIndicator(strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(AppTheme.redAccent)),
              ),
            ),
          );
        }

        // Second-to-last slot: "Beginning of conversation"
        if (index == _messages.length) {
          return _buildConversationStart(isDark);
        }

        final msg = _messages[index];
        // Next item (older) in display = index+1 in reversed list
        final olderMsg =
        index + 1 < _messages.length ? _messages[index + 1] : null;

        // Show date when the day changes going upward
        final showDate = olderMsg == null ||
            msg.createdAt.day != olderMsg.createdAt.day;

        // Group consecutive same-sender messages — last in group shows no tail gap
        final newerMsg = index > 0 ? _messages[index - 1] : null;
        final isLastInGroup =
            newerMsg == null || newerMsg.sender != msg.sender;

        return Column(
          children: [
            if (showDate) _buildDateSeparator(msg.dateLabel, isDark),
            _buildMessageBubble(msg, isLastInGroup, isDark),
          ],
        );
      },
    );
  }

  Widget _buildConversationStart(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Text(
        'Beginning of conversation',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: isDark
              ? AppTheme.darkTextSecondary.withOpacity(0.45)
              : AppTheme.lightTextSecondary.withOpacity(0.45),
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildDateSeparator(String label, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Row(children: [
        Expanded(
            child: Divider(
                color: isDark
                    ? Colors.white.withOpacity(0.07)
                    : Colors.black.withOpacity(0.07))),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            ),
          ),
          child: Text(label,
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 11, fontWeight: FontWeight.w500,
              )),
        ),
        Expanded(
            child: Divider(
                color: isDark
                    ? Colors.white.withOpacity(0.07)
                    : Colors.black.withOpacity(0.07))),
      ]),
    );
  }

  // ── Individual bubble ──────────────────────

  Widget _buildMessageBubble(
      ChatMessage msg, bool isLastInGroup, bool isDark) {
    final isMe = msg.isMe;

    return GestureDetector(
      onLongPress: () => _showMessageOptions(msg, isDark),
      child: Padding(
        padding: EdgeInsets.only(
          bottom: isLastInGroup ? 6 : 2,
          left: isMe ? 60 : 0,
          right: isMe ? 0 : 60,
        ),
        child: Align(
          alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
          child: _buildBubbleContent(msg, isMe, isDark),
        ),
      ),
    );
  }

  Widget _buildBubbleContent(ChatMessage msg, bool isMe, bool isDark) {
    // Pure image message (no text)
    if (msg.hasMedia && msg.isImage && msg.messageText.isEmpty) {
      return _buildImageBubble(msg, isMe, isDark);
    }

    // Text-only or text+other
    return Container(
      decoration: BoxDecoration(
        // "me" = purple gradient matching web; "them" = dark card
        gradient: isMe
            ? const LinearGradient(
          colors: [Color(0xFF7C3AED), Color(0xFF6D28D9)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        )
            : null,
        color: isMe
            ? null
            : (isDark ? AppTheme.darkCard : AppTheme.lightCard),
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMe ? 16 : 4),
          bottomRight: Radius.circular(isMe ? 4 : 16),
        ),
        border: isMe
            ? null
            : Border.all(
          color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (msg.hasReply) _buildReplyQuote(msg, isMe, isDark),
          if (msg.messageText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
              child: Text(
                msg.isDeleted ? 'This message was deleted' : msg.messageText,
                style: TextStyle(
                  color: msg.isDeleted
                      ? Colors.white.withOpacity(0.45)
                      : (isMe
                      ? Colors.white
                      : (isDark
                      ? AppTheme.darkTextPrimary
                      : AppTheme.lightTextPrimary)),
                  fontSize: 14,
                  fontStyle: msg.isDeleted ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 10, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  msg.formattedTime,
                  style: TextStyle(
                    color: isMe
                        ? Colors.white.withOpacity(0.6)
                        : (isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary),
                    fontSize: 10,
                  ),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  _statusIcon(msg.currentStatus),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImageBubble(ChatMessage msg, bool isMe, bool isDark) {
    return Container(
      width: 220,
      decoration: BoxDecoration(
        // Image from "me" gets a purple border/bg — matching web
        color: isMe ? const Color(0xFF7C3AED) : Colors.transparent,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(16),
          topRight: const Radius.circular(16),
          bottomLeft: Radius.circular(isMe ? 16 : 4),
          bottomRight: Radius.circular(isMe ? 4 : 16),
        ),
        border: isMe
            ? null
            : Border.all(
            color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Image
          ClipRRect(
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
            ),
            child: Image.network(
              msg.fileUrl!,
              width: 220,
              height: 220,
              fit: BoxFit.cover,
              loadingBuilder: (_, child, progress) {
                if (progress == null) return child;
                return Container(
                  width: 220, height: 220,
                  color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                  child: Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: progress.expectedTotalBytes != null
                          ? progress.cumulativeBytesLoaded /
                          progress.expectedTotalBytes!
                          : null,
                      valueColor: AlwaysStoppedAnimation<Color>(AppTheme.redAccent),
                    ),
                  ),
                );
              },
              errorBuilder: (_, __, ___) => Container(
                width: 220, height: 160,
                color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                child: const Icon(Icons.broken_image_outlined, color: Colors.grey, size: 32),
              ),
            ),
          ),
          // Time row below image
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 5, 10, 7),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  msg.formattedTime,
                  style: TextStyle(
                    color: isMe
                        ? Colors.white.withOpacity(0.7)
                        : (isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary),
                    fontSize: 10,
                  ),
                ),
                if (isMe) ...[
                  const SizedBox(width: 4),
                  _statusIcon(msg.currentStatus),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Reply quote inside a bubble (e.g. "su che" replying to "hi")
  Widget _buildReplyQuote(ChatMessage msg, bool isMe, bool isDark) {
    final isReplyToMe = msg.replyToSender == 'me';
    final replyName = isReplyToMe
        ? 'You'
        : (msg.replyToUserName?.trim().split(' ').where((p) => p.isNotEmpty).first ?? '');

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
      decoration: BoxDecoration(
        color: isMe
            ? Colors.black.withOpacity(0.18)
            : (isDark
            ? Colors.white.withOpacity(0.06)
            : Colors.black.withOpacity(0.05)),
        borderRadius: BorderRadius.circular(10),
        border: Border(
          left: BorderSide(
            color: isMe
                ? Colors.white.withOpacity(0.55)
                : const Color(0xFF7C3AED),
            width: 3,
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  replyName,
                  style: TextStyle(
                    color: isMe
                        ? Colors.white.withOpacity(0.9)
                        : const Color(0xFF7C3AED),
                    fontSize: 11, fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                // Reply is to a photo?
                if (msg.replyFileUrl != null)
                  Row(children: [
                    Icon(Icons.image_outlined,
                        size: 12,
                        color: isMe
                            ? Colors.white.withOpacity(0.6)
                            : (isDark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary)),
                    const SizedBox(width: 4),
                    Text('Photo',
                        style: TextStyle(
                          color: isMe
                              ? Colors.white.withOpacity(0.6)
                              : (isDark
                              ? AppTheme.darkTextSecondary
                              : AppTheme.lightTextSecondary),
                          fontSize: 12,
                        )),
                  ])
                else
                  Text(
                    msg.replyMessageText ?? '',
                    style: TextStyle(
                      color: isMe
                          ? Colors.white.withOpacity(0.65)
                          : (isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary),
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          // Thumbnail if reply is to an image
          if (msg.replyFileUrl != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  msg.replyFileUrl!,
                  width: 40, height: 40,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(
                    width: 40, height: 40,
                    color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                    child: const Icon(Icons.image_outlined, size: 16, color: Colors.grey),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusIcon(String status) {
    switch (status) {
      case 'read':
        return Icon(Icons.done_all_rounded,
            size: 14, color: Colors.white.withOpacity(0.9));
      case 'delivered':
        return Icon(Icons.done_all_rounded,
            size: 14, color: Colors.white.withOpacity(0.5));
      default:
        return Icon(Icons.done_rounded,
            size: 14, color: Colors.white.withOpacity(0.5));
    }
  }

  // ── Scroll-to-bottom button ────────────────

  Widget _scrollToBottomBtn(bool isDark) {
    return GestureDetector(
      onTap: _scrollToBottom,
      child: Container(
        width: 38, height: 38,
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
          shape: BoxShape.circle,
          border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(Icons.keyboard_arrow_down_rounded,
            size: 22,
            color: isDark
                ? AppTheme.darkTextSecondary
                : AppTheme.lightTextSecondary),
      ),
    );
  }

  // ── Reply bar ──────────────────────────────

  Widget _buildReplyBar(bool isDark) {
    final msg = _replyingTo!;
    return Container(
      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Row(children: [
        Container(
          width: 3, height: 38,
          decoration: BoxDecoration(
              color: AppTheme.redAccent,
              borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                msg.isMe ? 'You' : msg.senderName,
                style: const TextStyle(
                    color: AppTheme.redAccent,
                    fontSize: 12, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                msg.hasMedia ? '📷 Photo' : msg.messageText,
                style: TextStyle(
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary,
                  fontSize: 12,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
        GestureDetector(
          onTap: () => setState(() => _replyingTo = null),
          child: Icon(Icons.close_rounded,
              size: 20,
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary),
        ),
      ]),
    );
  }

  // ── Input bar ──────────────────────────────

  Widget _buildInputBar(bool isDark) {
    return Container(
      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
      padding: EdgeInsets.fromLTRB(
        12, 8, 12, 8 + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Attachment
          GestureDetector(
            onTap: _pickAndSendImage,
            child: Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                shape: BoxShape.circle,
                border: Border.all(
                    color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
              ),
              child: Icon(Icons.attach_file_rounded,
                  size: 20,
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary),
            ),
          ),
          const SizedBox(width: 8),

          // Text field
          Expanded(
            child: Container(
              constraints: const BoxConstraints(maxHeight: 120),
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                    color:
                    isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
              ),
              child: Padding(
                padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: TextField(
                  controller: _messageCtrl,
                  focusNode: _focusNode,
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textCapitalization: TextCapitalization.sentences,
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.darkTextPrimary
                        : AppTheme.lightTextPrimary,
                    fontSize: 14,
                  ),
                  cursorColor: AppTheme.redAccent,
                  decoration: InputDecoration(
                    hintText: 'Type a message...',
                    hintStyle: TextStyle(
                      color: isDark
                          ? AppTheme.darkTextSecondary.withOpacity(0.5)
                          : AppTheme.lightTextSecondary.withOpacity(0.6),
                      fontSize: 14,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),

          // Send / mic
          GestureDetector(
            onTap: _hasText ? _sendMessage : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 44, height: 44,
              decoration: BoxDecoration(
                gradient: _hasText
                    ? const LinearGradient(
                  colors: [AppTheme.redAccent, AppTheme.redDark],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
                    : null,
                color: _hasText
                    ? null
                    : (isDark ? AppTheme.darkInput : AppTheme.lightInput),
                shape: BoxShape.circle,
                border: _hasText
                    ? null
                    : Border.all(
                    color: isDark
                        ? AppTheme.darkBorder
                        : AppTheme.lightBorder),
                boxShadow: _hasText
                    ? [
                  BoxShadow(
                    color: AppTheme.redAccent.withOpacity(0.4),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  )
                ]
                    : null,
              ),
              child: _isSending
                  ? Padding(
                padding: const EdgeInsets.all(12),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(
                      _hasText ? Colors.white : AppTheme.redAccent),
                ),
              )
                  : Icon(
                _hasText
                    ? Icons.send_rounded
                    : Icons.mic_rounded,
                size: 20,
                color: _hasText
                    ? Colors.white
                    : (isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Long-press context menu ────────────────

  void _showMessageOptions(ChatMessage msg, bool isDark) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
          borderRadius:
          const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withOpacity(0.15)
                  : Colors.black.withOpacity(0.15),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 16),
          _optionTile(Icons.reply_rounded, 'Reply', isDark, () {
            Navigator.pop(context);
            setState(() => _replyingTo = msg);
            _focusNode.requestFocus();
          }),
          if (msg.messageText.isNotEmpty)
            _optionTile(Icons.copy_rounded, 'Copy text', isDark, () {
              Navigator.pop(context);
              Clipboard.setData(ClipboardData(text: msg.messageText));
            }),
        ]),
      ),
    );
  }

  Widget _optionTile(
      IconData icon, String label, bool isDark, VoidCallback onTap) {
    return ListTile(
      leading: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 20, color: AppTheme.redAccent),
      ),
      title: Text(label,
          style: TextStyle(
            color: isDark
                ? AppTheme.darkTextPrimary
                : AppTheme.lightTextPrimary,
            fontSize: 14, fontWeight: FontWeight.w500,
          )),
      onTap: onTap,
      shape:
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }

  // ── Helpers ────────────────────────────────

  String _initials(String name) {
    final parts =
    name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
    if (parts.length == 1) return parts[0][0].toUpperCase();
    return '?';
  }

  Color _avatarColor(String name) {
    const colors = [
      Color(0xFF5C6BC0), Color(0xFF26A69A),
      Color(0xFFEF5350), Color(0xFFAB47BC),
      Color(0xFF42A5F5), Color(0xFFFF7043),
      Color(0xFF66BB6A), Color(0xFFEC407A),
    ];
    return colors[name.length % colors.length];
  }
}