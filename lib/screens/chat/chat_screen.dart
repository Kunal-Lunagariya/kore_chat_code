import 'dart:async';
import 'dart:io' as dart_io;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:video_player/video_player.dart';
import 'package:video_thumbnail/video_thumbnail.dart';
import '../../models/chat_model.dart';
import '../../services/api_call_service.dart';
import '../../socket/socket_events.dart';
import '../../theme/app_theme.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import 'call_screen.dart';
import 'group_call_screen.dart';

class ChatScreen extends StatefulWidget {
  final int conversationId;
  final int themUserId;
  final String themUserName;
  final bool themIsOnline;
  final int myUserId;
  final Set<int> onlineUserIds;
  final bool isGroup;
  final List<Map<String, dynamic>> groupMembers;

  const ChatScreen({
    super.key,
    required this.conversationId,
    required this.themUserId,
    required this.themUserName,
    required this.themIsOnline,
    required this.myUserId,
    required this.onlineUserIds,
    this.isGroup = false,
    this.groupMembers = const [],
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _messageCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  final FocusNode _focusNode = FocusNode();
  final Map<int, GlobalKey> _messageKeys = {};
  List<ChatMessage> _messages = [];
  bool _isLoading = true;
  bool _isSending = false;
  bool _hasError = false;
  bool _hasText = false;
  bool _isTyping = false;
  Timer? _typingTimer;
  int? _highlightedMessageId;
  String? _pendingImagePath;

  final AudioRecorder _audioRecorder = AudioRecorder();
  bool _isRecording = false;
  Duration _recordDuration = Duration.zero;
  Timer? _recordTimer;
  String? _recordedPath;
  String? _pendingVideoPath;
  String? _pendingAudioPath;
  String? _pendingDocPath;
  String? _pendingDocName;
  List<Map<String, dynamic>> _groupMembers = [];
  bool _loadingMembers = false;

  // Pagination
  int _page = 1;
  static const int _limit = 20;
  bool _hasNextPage = false;
  bool _loadingMore = false;

  // Reply
  ChatMessage? _replyingTo;

  // Scroll-to-bottom button
  bool _showScrollToBottom = false;

  bool _isScrollingToMessage = false;

  bool get _isOnline => widget.onlineUserIds.contains(widget.themUserId);

  @override
  void initState() {
    super.initState();
    _fetchMessages();
    _scrollCtrl.addListener(_onScroll);
    _messageCtrl.addListener(() {
      final has = _messageCtrl.text.trim().isNotEmpty;
      if (has != _hasText) setState(() => _hasText = has);

      // Emit typing
      SocketEvents.emitStartTyping(conversationId: widget.conversationId);
      _typingTimer?.cancel();
      _typingTimer = Timer(const Duration(milliseconds: 1500), () {
        SocketEvents.emitStopTyping(conversationId: widget.conversationId);
      });
    });
    SocketEvents.joinConversation(widget.conversationId.toString());

    SocketEvents.onStartTyping((data) {
      if (!mounted) return;
      final cid = (Map<String, dynamic>.from(
        data as Map,
      )['conversationId'])?.toString();
      if (cid == widget.conversationId.toString()) {
        setState(() => _isTyping = true);
      }
    });

    SocketEvents.onStopTyping((data) {
      if (!mounted) return;
      final cid = (Map<String, dynamic>.from(
        data as Map,
      )['conversationId'])?.toString();
      if (cid == widget.conversationId.toString()) {
        setState(() => _isTyping = false);
      }
    });

    SocketEvents.onNewMessage((data) {
      if (!mounted) return;
      try {
        final map = Map<String, dynamic>.from(data as Map);
        final senderId = (map['senderId'] as num?)?.toInt() ?? 0;
        map['sender'] = senderId == widget.myUserId ? 'me' : 'them';

        final msg = ChatMessage.fromJson(map);
        final alreadyExists = _messages.any((m) => m.id == msg.id);
        if (alreadyExists) return;

        setState(() => _messages.insert(0, msg));
        _scrollToBottom();

        // ← Emit read receipt for incoming messages
        if (senderId != widget.myUserId) {
          SocketEvents.emitMessageStatus(
            receiverId: widget.myUserId,
            senderId: senderId,
            conversationId: widget.conversationId,
            messageId: msg.id,
            status: 'read',
          );
        }
      } catch (_) {}
    });

    SocketEvents.emitMultiMessageStatus(
      receiverId: widget.myUserId,
      conversationId: widget.conversationId,
    );

    SocketEvents.onUpdatedMessageStatus((data) {
      if (!mounted) return;
      try {
        final msg = Map<String, dynamic>.from(data as Map);
        final messageId = (msg['id'] as num?)?.toInt() ?? 0;
        final newStatus = (msg['currentStatus'] as String?) ?? '';
        final senderId = (msg['senderId'] as num?)?.toInt() ?? 0;

        // Only update if this message was sent by me
        if (senderId != widget.myUserId) return;

        setState(() {
          final idx = _messages.indexWhere((m) => m.id == messageId);
          if (idx != -1) {
            _messages[idx] = _messages[idx].copyWith(currentStatus: newStatus);
          }
        });
      } catch (_) {}
    });

    SocketEvents.onUpdatedMultiMessageStatus((data) {
      if (!mounted) return;
      try {
        final list = data as List<dynamic>;
        setState(() {
          for (final item in list) {
            final msg = Map<String, dynamic>.from(item as Map);
            final messageId = (msg['id'] as num?)?.toInt() ?? 0;
            final newStatus = (msg['currentStatus'] as String?) ?? '';
            final senderId = (msg['senderId'] as num?)?.toInt() ?? 0;
            if (senderId != widget.myUserId) return;
            final idx = _messages.indexWhere((m) => m.id == messageId);
            if (idx != -1) {
              _messages[idx] = _messages[idx].copyWith(
                currentStatus: newStatus,
              );
            }
          }
        });
      } catch (_) {}
    });
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    SocketEvents.emitStopTyping(conversationId: widget.conversationId);
    _messageCtrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    _audioRecorder.dispose();
    _recordTimer?.cancel();
    SocketEvents.offNewMessage();
    SocketEvents.offUpdatedMessageStatus();
    SocketEvents.offUpdatedMultiMessageStatus();
    SocketEvents.offStartTyping();
    SocketEvents.offStopTyping();
    SocketEvents.leaveConversation(widget.conversationId.toString());
    super.dispose();
  }

  void _onScroll() {
    // Don't interfere with programmatic scroll-to-message
    if (_isScrollingToMessage) return;

    final show = _scrollCtrl.offset > 200;
    if (show != _showScrollToBottom) {
      setState(() => _showScrollToBottom = show);
    }

    if (_scrollCtrl.position.pixels >=
        _scrollCtrl.position.maxScrollExtent - 300) {
      if (_hasNextPage && !_loadingMore) _loadMoreMessages();
    }
  }

  // ── API ────────────────────────────────────

  Future<void> _fetchMessages() async {
    if (mounted)
      setState(() {
        _isLoading = true;
        _hasError = false;
      });
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
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    } catch (_) {
      if (mounted)
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
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
    if (_pendingImagePath != null) {
      final path = _pendingImagePath!;
      setState(() => _pendingImagePath = null);
      await _uploadAndSendFile(filePath: path, type: 'image');
      return;
    }
    if (_pendingVideoPath != null) {
      final path = _pendingVideoPath!;
      setState(() => _pendingVideoPath = null);
      await _uploadAndSendFile(filePath: path, type: 'video');
      return;
    }
    if (_pendingAudioPath != null) {
      final path = _pendingAudioPath!;
      setState(() {
        _pendingAudioPath = null;
        _pendingDocName = null;
      });
      await _uploadAndSendFile(filePath: path, type: 'audio');
      return;
    }
    if (_pendingDocPath != null) {
      final path = _pendingDocPath!;
      setState(() {
        _pendingDocPath = null;
        _pendingDocName = null;
      });
      await _uploadAndSendFile(filePath: path, type: 'document');
      return;
    }

    final text = _messageCtrl.text.trim();
    if (text.isEmpty || _isSending) return;
    _messageCtrl.clear();

    final replyId = _replyingTo?.id;
    setState(() {
      _isSending = true;
      _replyingTo = null;
    });

    try {
      SocketEvents.sendMessage({
        'conversationId': widget.conversationId,
        'themUserId': widget.themUserId,
        'senderId': widget.myUserId,
        'messageText': text,
        'messageType': 'text',
        if (replyId != null) 'replyToMessageId': replyId,
      }, callback: (response) {});
    } catch (_) {
      if (mounted) {
        _messageCtrl.text = text;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to send'),
            backgroundColor: AppTheme.redAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _scrollToBottom() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  void _scrollToMessage(int messageId) {
    final msgIdx = _messages.indexWhere((m) => m.id == messageId);
    if (msgIdx == -1) return;

    setState(() => _highlightedMessageId = messageId);
    Future.delayed(const Duration(milliseconds: 2000), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });

    _isScrollingToMessage = true;
    _doScrollToMessage(messageId, attempts: 0);
  }

  void _doScrollToMessage(int messageId, {required int attempts}) {
    if (attempts > 10) {
      _isScrollingToMessage = false;
      return;
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final key = _messageKeys[messageId];
      final ctx = key?.currentContext;

      if (ctx != null) {
        // Message is rendered — scroll to it
        final renderBox = ctx.findRenderObject() as RenderBox?;
        if (renderBox == null) {
          _isScrollingToMessage = false;
          return;
        }
        final viewport = RenderAbstractViewport.of(renderBox);
        final revealOffset = viewport.getOffsetToReveal(renderBox, 0.5);
        _scrollCtrl
            .animateTo(
              revealOffset.offset.clamp(
                _scrollCtrl.position.minScrollExtent,
                _scrollCtrl.position.maxScrollExtent,
              ),
              duration: const Duration(milliseconds: 400),
              curve: Curves.easeInOut,
            )
            .then((_) {
              _isScrollingToMessage = false;
            });
      } else {
        // Not rendered yet — scroll up a bit to trigger lazy rendering
        final currentOffset = _scrollCtrl.position.pixels;
        final targetOffset = (currentOffset + 500).clamp(
          _scrollCtrl.position.minScrollExtent,
          _scrollCtrl.position.maxScrollExtent,
        );

        if (targetOffset <= currentOffset) {
          // Already at max, message might just not exist on screen
          _isScrollingToMessage = false;
          return;
        }

        _scrollCtrl.jumpTo(targetOffset);
        // Retry after frame renders new items
        _doScrollToMessage(messageId, attempts: attempts + 1);
      }
    });
  }

  void _showMessageOptions(ChatMessage msg, bool isDark) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
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
            if (msg.isMe) // ← only show for my messages
              _optionTile(
                Icons.info_outline_rounded,
                'Message info',
                isDark,
                () {
                  Navigator.pop(context);
                  _showMessageInfo(msg, isDark);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showMessageInfo(ChatMessage msg, bool isDark) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) =>
          _MessageInfoSheet(messageId: msg.id, message: msg, isDark: isDark),
    );
  }

  void _showAttachOptions(bool isDark) {
    HapticFeedback.lightImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withOpacity(0.15)
                    : Colors.black.withOpacity(0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _attachOption(
                  icon: Icons.image_rounded,
                  label: 'Image',
                  color: const Color(0xFF7C3AED),
                  isDark: isDark,
                  onTap: () {
                    Navigator.pop(context);
                    _pickAndSendFile(type: 'image');
                  },
                ),
                _attachOption(
                  icon: Icons.videocam_rounded,
                  label: 'Video',
                  color: const Color(0xFF0EA5E9),
                  isDark: isDark,
                  onTap: () {
                    Navigator.pop(context);
                    _pickAndSendFile(type: 'video');
                  },
                ),
                _attachOption(
                  icon: Icons.headphones_rounded,
                  label: 'Audio',
                  color: const Color(0xFF10B981),
                  isDark: isDark,
                  onTap: () {
                    Navigator.pop(context);
                    _pickAndSendFile(type: 'audio');
                  },
                ),
                _attachOption(
                  icon: Icons.insert_drive_file_rounded,
                  label: 'Document',
                  color: const Color(0xFFF59E0B),
                  isDark: isDark,
                  onTap: () {
                    Navigator.pop(context);
                    _pickAndSendFile(type: 'document');
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndSendFile({required String type}) async {
    String? filePath;

    try {
      if (type == 'image') {
        final picked = await ImagePicker().pickImage(
          source: ImageSource.gallery,
          imageQuality: 85,
        );
        if (picked != null && mounted) {
          setState(() => _pendingImagePath = picked.path);
        }
        return;
      } else if (type == 'video') {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.video,
          allowMultiple: false,
        );
        if (result?.files.single.path != null && mounted) {
          setState(() => _pendingVideoPath = result!.files.single.path);
        }
        return;
      } else if (type == 'audio') {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.audio,
          allowMultiple: false,
        );
        if (result?.files.single.path != null && mounted) {
          setState(() {
            _pendingAudioPath = result!.files.single.path;
            _pendingDocName = result.files.single.name;
          });
        }
        return;
      } else if (type == 'document') {
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: [
            'pdf',
            'doc',
            'docx',
            'xls',
            'xlsx',
            'txt',
            'ppt',
            'pptx',
          ],
          allowMultiple: false,
        );
        if (result?.files.single.path != null && mounted) {
          setState(() {
            _pendingDocPath = result!.files.single.path;
            _pendingDocName = result.files.single.name;
          });
        }
        return;
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Could not access files. Please allow permission in Settings.',
            ),
            backgroundColor: AppTheme.redAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
      return;
    }

    if (filePath == null) return;
    await _uploadAndSendFile(filePath: filePath, type: type);
  }

  Future<void> _uploadAndSendFile({
    required String filePath,
    required String type,
  }) async {
    setState(() => _isSending = true);
    final replyId = _replyingTo?.id;
    setState(() => _replyingTo = null);

    try {
      final uploadResponse = await ApiCall.uploadFile(
        'v1/media/upload',
        filePath: filePath,
        fileFieldName: 'files',
      );

      if (!mounted) return;

      final uploadedData =
          uploadResponse['data']?['uploadedData'] as List<dynamic>?;
      if (uploadedData == null || uploadedData.isEmpty) {
        throw Exception('Upload failed — no media ID returned');
      }

      SocketEvents.sendMessage({
        'conversationId': widget.conversationId,
        'themUserId': widget.themUserId,
        'senderId': widget.myUserId,
        'messageType': 'media', // ← always 'media' regardless of type
        'mediaIds': uploadedData,
        if (replyId != null) 'replyToMessageId': replyId,
      }, callback: (response) {});

      _scrollToBottom();
    } catch (e) {
      debugPrint('File send error: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceAll('Exception:', '').trim()),
            backgroundColor: AppTheme.redAccent,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Widget _attachOption({
    required IconData icon,
    required String label,
    required Color color,
    required bool isDark,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              shape: BoxShape.circle,
              border: Border.all(color: color.withOpacity(0.3)),
            ),
            child: Icon(icon, color: color, size: 26),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImagePreviewOverlay(bool isDark) {
    return Positioned.fill(
      child: Container(
        color: Colors.black,
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => setState(() => _pendingImagePath = null),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  const Expanded(
                    child: Text(
                      'Send Photo',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            // Image preview — fills remaining space
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.file(
                    dart_io.File(_pendingImagePath!),
                    fit: BoxFit.contain,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVideoPreviewOverlay(bool isDark) {
    return Positioned.fill(
      child: Container(
        color: Colors.black,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => setState(() => _pendingVideoPath = null),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  const Expanded(
                    child: Text(
                      'Send Video',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Container(
                  margin: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 32),
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: const Color(0xFF0EA5E9).withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.videocam_rounded,
                          color: Color(0xFF0EA5E9),
                          size: 36,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _pendingVideoPath!.split('/').last,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Video ready to send',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioPreviewOverlay(bool isDark) {
    return Positioned.fill(
      child: Container(
        color: Colors.black,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => setState(() {
                      _pendingAudioPath = null;
                      _pendingDocName = null;
                    }),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  const Expanded(
                    child: Text(
                      'Send Audio',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Container(
                  margin: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 32),
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.headphones_rounded,
                          color: Color(0xFF10B981),
                          size: 36,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _pendingDocName ?? _pendingAudioPath!.split('/').last,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Audio ready to send',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocPreviewOverlay(bool isDark) {
    final name = _pendingDocName ?? _pendingDocPath!.split('/').last;
    final ext = name.split('.').last.toLowerCase();

    final Color docColor;
    final IconData docIcon;
    switch (ext) {
      case 'pdf':
        docColor = const Color(0xFFEF4444);
        docIcon = Icons.picture_as_pdf_rounded;
        break;
      case 'doc':
      case 'docx':
        docColor = const Color(0xFF3B82F6);
        docIcon = Icons.description_rounded;
        break;
      case 'xls':
      case 'xlsx':
        docColor = const Color(0xFF10B981);
        docIcon = Icons.table_chart_rounded;
        break;
      case 'ppt':
      case 'pptx':
        docColor = const Color(0xFFF59E0B);
        docIcon = Icons.slideshow_rounded;
        break;
      default:
        docColor = const Color(0xFF6B7280);
        docIcon = Icons.insert_drive_file_rounded;
    }

    return Positioned.fill(
      child: Container(
        color: Colors.black,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
              child: Row(
                children: [
                  IconButton(
                    onPressed: () => setState(() {
                      _pendingDocPath = null;
                      _pendingDocName = null;
                    }),
                    icon: const Icon(
                      Icons.close_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                  const Expanded(
                    child: Text(
                      'Send Document',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Container(
                  margin: const EdgeInsets.all(24),
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1A1A1A),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 72,
                        height: 72,
                        decoration: BoxDecoration(
                          color: docColor.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Icon(docIcon, color: docColor, size: 36),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        ext.toUpperCase(),
                        style: TextStyle(
                          color: docColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startRecording() async {
    final hasPermission = await _audioRecorder.hasPermission();
    if (!hasPermission) return;

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

    await _audioRecorder.start(
      const RecordConfig(encoder: AudioEncoder.aacLc),
      path: path,
    );

    setState(() {
      _isRecording = true;
      _recordDuration = Duration.zero;
    });

    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted)
        setState(() => _recordDuration += const Duration(seconds: 1));
    });
  }

  Future<void> _stopAndSendRecording() async {
    _recordTimer?.cancel();
    final path = await _audioRecorder.stop();
    setState(() => _isRecording = false);

    if (path == null) return;
    await _uploadAndSendFile(filePath: path, type: 'audio');
  }

  void _cancelRecording() async {
    _recordTimer?.cancel();
    await _audioRecorder.stop();
    setState(() {
      _isRecording = false;
      _recordDuration = Duration.zero;
    });
  }

  String _fmtRecordDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _buildRecordingIndicator(bool isDark) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _cancelRecording,
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
              shape: BoxShape.circle,
              border: Border.all(
                color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
              ),
            ),
            child: const Icon(
              Icons.delete_outline_rounded,
              size: 18,
              color: Colors.red,
            ),
          ),
        ),
        const SizedBox(width: 8),
        Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Colors.red,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _fmtRecordDuration(_recordDuration),
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkTextPrimary
                    : AppTheme.lightTextPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _stopAndSendRecording,
          child: Container(
            width: 44,
            height: 44,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [AppTheme.redAccent, AppTheme.redDark],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.send_rounded,
              color: Colors.white,
              size: 20,
            ),
          ),
        ),
      ],
    );
  }

  // ── Build ──────────────────────────────────

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
                if (_pendingImagePath != null)
                  _buildImagePreviewOverlay(isDark),
                if (_pendingVideoPath != null)
                  _buildVideoPreviewOverlay(isDark),
                if (_pendingAudioPath != null)
                  _buildAudioPreviewOverlay(isDark),
                if (_pendingDocPath != null) _buildDocPreviewOverlay(isDark),
              ],
            ),
          ),
          if (_replyingTo != null) _buildReplyBar(isDark),
          _buildInputBar(isDark),
        ],
      ),
    );
  }

  void _startCall(String callType) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => CallScreen(
          myUserId: widget.myUserId,
          remoteUserId: widget.themUserId,
          remoteUserName: widget.themUserName,
          callType: callType,
          isOutgoing: true,
        ),
      ),
    );
  }

  // ── AppBar ─────────────────────────────────

  Color _senderColor(int senderId) {
    const colors = [
      Color(0xFF7C3AED),
      Color(0xFF0EA5E9),
      Color(0xFF10B981),
      Color(0xFFF59E0B),
      Color(0xFFEF4444),
      Color(0xFFEC4899),
      Color(0xFF8B5CF6),
      Color(0xFF14B8A6),
    ];
    return colors[senderId % colors.length];
  }

  Widget _buildAppBar(bool isDark) {
    return GestureDetector(
      onTap: widget.isGroup ? () => _showGroupInfoSheet(isDark) : null,
      child: Container(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 8, 10),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    size: 20,
                    color: isDark
                        ? AppTheme.darkTextPrimary
                        : AppTheme.lightTextPrimary,
                  ),
                ),
                // Avatar
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: _avatarColor(widget.themUserName),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: widget.isGroup
                        ? const Icon(
                            Icons.group_rounded,
                            color: Colors.white,
                            size: 20,
                          )
                        : Text(
                            _initials(widget.themUserName),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                // Name + status/member count
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.themUserName,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.darkTextPrimary
                              : AppTheme.lightTextPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        widget.isGroup
                            ? '${widget.groupMembers.length} members · tap for info'
                            : (_isTyping
                                  ? 'typing...'
                                  : (_isOnline ? 'online' : 'offline')),
                        style: TextStyle(
                          color: !widget.isGroup && _isTyping
                              ? const Color(0xFF7C3AED)
                              : (!widget.isGroup && _isOnline
                                    ? const Color(0xFF4CAF50)
                                    : (isDark
                                          ? AppTheme.darkTextSecondary
                                          : AppTheme.lightTextSecondary)),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                // Call buttons — 1-to-1 only
                if (!widget.isGroup) ...[
                  IconButton(
                    onPressed: () => widget.isGroup
                        ? _startGroupCall('audio')
                        : _startCall('audio'),
                    icon: Icon(
                      Icons.call_rounded,
                      size: 22,
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                  IconButton(
                    onPressed: () => widget.isGroup
                        ? _startGroupCall('video')
                        : _startCall('video'),
                    icon: Icon(
                      Icons.videocam_rounded,
                      size: 24,
                      color: isDark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _startGroupCall(String callType) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => GroupCallScreen(
          myUserId: widget.myUserId,
          conversationId: widget.conversationId,
          groupName: widget.themUserName,
          callType: callType,
          isInitiator: true,
          groupMembers: widget.groupMembers,
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
              'Failed to load messages',
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: _fetchMessages,
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

    if (_messages.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 48,
              color: isDark
                  ? AppTheme.darkTextSecondary.withOpacity(0.3)
                  : AppTheme.lightTextSecondary.withOpacity(0.3),
            ),
            const SizedBox(height: 12),
            Text(
              'No messages yet',
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 15,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Say hello 👋',
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

    final itemCount =
        _messages.length + 1 + (_loadingMore ? 1 : 0) + (_isTyping ? 1 : 0);

    return ListView.builder(
      controller: _scrollCtrl,
      reverse: true,
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      itemCount: itemCount,
      itemBuilder: (_, index) {
        // Typing bubble at index 0 (bottom)
        if (_isTyping && index == 0) {
          return _buildTypingBubble(isDark);
        }

        // Shift index when typing bubble is showing
        final msgIndex = _isTyping ? index - 1 : index;

        // Load-more spinner — must check msgIndex not index
        if (msgIndex == _messages.length + 1) {
          return const Padding(
            padding: EdgeInsets.all(12),
            child: Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(AppTheme.redAccent),
                ),
              ),
            ),
          );
        }

        // Beginning of conversation
        if (msgIndex == _messages.length) {
          return _buildConversationStart(isDark);
        }

        // Guard — msgIndex must be valid
        if (msgIndex < 0 || msgIndex >= _messages.length) {
          return const SizedBox.shrink();
        }

        final msg = _messages[msgIndex];
        final key = _messageKeys.putIfAbsent(msg.id, () => GlobalKey());

        // olderMsg = next in array = older message (list is reversed)
        final olderMsg = msgIndex + 1 < _messages.length
            ? _messages[msgIndex + 1]
            : null;
        // newerMsg = prev in array = newer message (list is reversed)
        final newerMsg = msgIndex > 0 ? _messages[msgIndex - 1] : null;

        final showDate =
            olderMsg == null || msg.createdAt.day != olderMsg.createdAt.day;

        // isFirstInGroup = this message starts a new sender streak from above
        // In reversed list: sender changed compared to the OLDER message
        final isFirstInGroup =
            olderMsg == null || olderMsg.senderId != msg.senderId;

        // isLastInGroup = bottom of a sender streak, used for bubble tail
        final isLastInGroup =
            newerMsg == null || newerMsg.senderId != msg.senderId;

        return Column(
          key: key,
          children: [
            if (showDate) _buildDateSeparator(msg.dateLabel, isDark),
            _buildMessageBubble(
              msg,
              isFirstInGroup: isFirstInGroup,
              isLastInGroup: isLastInGroup,
              isDark: isDark,
            ),
          ],
        );
      },
    );
  }

  Widget _buildMessageBubble(
    ChatMessage msg, {
    required bool isFirstInGroup,
    required bool isLastInGroup,
    required bool isDark,
  }) {
    final isMe = msg.isMe;
    final isHighlighted = _highlightedMessageId == msg.id;

    // Show sender name above the FIRST message of a group streak (not mine)
    final showSenderName = widget.isGroup && !isMe && isFirstInGroup;

    return GestureDetector(
      onLongPress: () => _showMessageOptions(msg, isDark),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        color: isHighlighted
            ? const Color(0xFF7C3AED).withOpacity(0.15)
            : Colors.transparent,
        child: Padding(
          padding: EdgeInsets.only(
            // More space after last message in a group streak
            bottom: isLastInGroup ? 6 : 2,
            left: isMe ? 60 : 0,
            right: isMe ? 0 : 60,
          ),
          child: Align(
            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
            child: Column(
              crossAxisAlignment: isMe
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Sender name above first bubble in a group streak
                if (showSenderName)
                  Padding(
                    padding: const EdgeInsets.only(left: 12, bottom: 3),
                    child: Text(
                      msg.senderName.trim().split(' ').first,
                      style: TextStyle(
                        color: _senderColor(msg.senderId),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                _buildBubbleContent(msg, isMe, isDark),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTypingBubble(bool isDark) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, right: 60),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(4),
              bottomRight: Radius.circular(16),
            ),
            border: Border.all(
              color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _TypingDot(delay: 0),
              const SizedBox(width: 4),
              _TypingDot(delay: 200),
              const SizedBox(width: 4),
              _TypingDot(delay: 400),
            ],
          ),
        ),
      ),
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
      child: Row(
        children: [
          Expanded(
            child: Divider(
              color: isDark
                  ? Colors.white.withOpacity(0.07)
                  : Colors.black.withOpacity(0.07),
            ),
          ),
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
            child: Text(
              label,
              style: TextStyle(
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Divider(
              color: isDark
                  ? Colors.white.withOpacity(0.07)
                  : Colors.black.withOpacity(0.07),
            ),
          ),
        ],
      ),
    );
  }

  void _showGroupInfoSheet(bool isDark) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.55,
        minChildSize: 0.35,
        maxChildSize: 0.9,
        builder: (_, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 20),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withOpacity(0.15)
                      : Colors.black.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: _avatarColor(widget.themUserName),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.group_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                widget.themUserName,
                style: TextStyle(
                  color: isDark
                      ? AppTheme.darkTextPrimary
                      : AppTheme.lightTextPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${widget.groupMembers.length} members',
                style: TextStyle(
                  color: isDark
                      ? AppTheme.darkTextSecondary
                      : AppTheme.lightTextSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),
              Divider(
                color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                height: 1,
              ),
              Expanded(
                child: ListView.builder(
                  controller: scrollCtrl,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  itemCount: widget.groupMembers.length,
                  itemBuilder: (_, i) {
                    final m = widget.groupMembers[i];
                    // API returns 'UserName' (capital U N)
                    final name =
                        (m['UserName'] as String?) ??
                        (m['userName'] as String?) ??
                        'Unknown';
                    final userId = (m['userId'] as num?)?.toInt() ?? 0;
                    final role = (m['role'] as String?) ?? 'Member';
                    final isMe = userId == widget.myUserId;

                    return ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 2,
                      ),
                      leading: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _avatarColor(name),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Text(
                            _initials(name),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ),
                      ),
                      title: Text(
                        isMe ? '$name (You)' : name,
                        style: TextStyle(
                          color: isDark
                              ? AppTheme.darkTextPrimary
                              : AppTheme.lightTextPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        role,
                        style: TextStyle(
                          color: role == 'Admin'
                              ? const Color(0xFF7C3AED)
                              : (isDark
                                    ? AppTheme.darkTextSecondary
                                    : AppTheme.lightTextSecondary),
                          fontSize: 12,
                          fontWeight: role == 'Admin'
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Individual bubble ──────────────────────

  Widget _buildCallBubble(ChatMessage msg, bool isMe, bool isDark) {
    final isVideo = msg.isVideoCall;
    final status = msg.callStatus ?? 'Ended';
    final duration = msg.duration;

    // Parse status color + icon
    final isMissed =
        status.toLowerCase() == 'missed' || status.toLowerCase() == 'declined';

    final Color statusColor = isMissed
        ? AppTheme.redAccent
        : (isDark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary);

    final IconData callIcon = isVideo
        ? Icons.videocam_rounded
        : Icons.call_rounded;

    // Format duration — "00:00:58" → "0:58", "00:01:30" → "1:30"
    String? durationLabel;
    if (duration != null && !isMissed) {
      final parts = duration.split(':');
      if (parts.length == 3) {
        final h = int.tryParse(parts[0]) ?? 0;
        final m = int.tryParse(parts[1]) ?? 0;
        final s = int.tryParse(parts[2]) ?? 0;
        if (h > 0) {
          durationLabel = '${h}h ${m}m ${s}s';
        } else if (m > 0) {
          durationLabel = '${m}m ${s}s';
        } else {
          durationLabel = '${s}s';
        }
      }
    }

    final bgColor = isMe
        ? const Color(0xFF6D28D9)
        : (isDark ? AppTheme.darkCard : AppTheme.lightCard);

    return Container(
      constraints: const BoxConstraints(maxWidth: 240, minWidth: 180),
      decoration: BoxDecoration(
        color: bgColor,
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
              ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Call icon circle
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: isMissed
                  ? AppTheme.redAccent.withOpacity(isMe ? 0.25 : 0.12)
                  : (isMe
                        ? Colors.white.withOpacity(0.15)
                        : AppTheme.redAccent.withOpacity(0.1)),
              shape: BoxShape.circle,
            ),
            child: Icon(
              callIcon,
              size: 20,
              color: isMissed
                  ? (isMe ? Colors.white : AppTheme.redAccent)
                  : (isMe ? Colors.white : AppTheme.redAccent),
            ),
          ),
          const SizedBox(width: 10),
          // Text column
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isVideo ? 'Video Call' : 'Audio Call',
                  style: TextStyle(
                    color: isMe
                        ? Colors.white
                        : (isDark
                              ? AppTheme.darkTextPrimary
                              : AppTheme.lightTextPrimary),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    if (isMissed)
                      Icon(
                        Icons.call_missed_rounded,
                        size: 11,
                        color: isMe
                            ? Colors.white.withOpacity(0.7)
                            : AppTheme.redAccent,
                      )
                    else
                      Icon(
                        isMe
                            ? Icons.call_made_rounded
                            : Icons.call_received_rounded,
                        size: 11,
                        color: isMe
                            ? Colors.white.withOpacity(0.7)
                            : statusColor,
                      ),
                    const SizedBox(width: 3),
                    Text(
                      isMissed ? 'Missed' : (durationLabel ?? status),
                      style: TextStyle(
                        color: isMissed
                            ? (isMe
                                  ? Colors.white.withOpacity(0.7)
                                  : AppTheme.redAccent)
                            : (isMe
                                  ? Colors.white.withOpacity(0.6)
                                  : statusColor),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          // Time + status
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.end,
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
                const SizedBox(height: 2),
                _statusIcon(msg.currentStatus),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBubbleContent(ChatMessage msg, bool isMe, bool isDark) {
    if (msg.hasMedia) {
      final ft = msg.fileType ?? '';
      if (ft == 'image') return _buildImageBubble(msg, isMe, isDark);
      if (ft == 'video') return _buildVideoBubble(msg, isMe, isDark);
      if (ft == 'audio') return _buildAudioBubble(msg, isMe, isDark);
      if (ft == 'document') return _buildDocumentBubble(msg, isMe, isDark);
      // fallback — if fileType not set, check isImage
      if (msg.isImage && msg.messageText.isEmpty) {
        return _buildImageBubble(msg, isMe, isDark);
      }
    }

    if (msg.isCallMessage) {
      return _buildCallBubble(msg, isMe, isDark);
    }

    // text bubble
    return IntrinsicWidth(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        decoration: BoxDecoration(
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
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
                    fontStyle: msg.isDeleted
                        ? FontStyle.italic
                        : FontStyle.normal,
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 10, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
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
      ),
    );
  }

  Widget _buildVideoBubble(ChatMessage msg, bool isMe, bool isDark) {
    return GestureDetector(
      onTap: () {
        if (msg.fileUrl != null) {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => _FullScreenVideoPlayer(videoUrl: msg.fileUrl!),
            ),
          );
        }
      },
      child: Container(
        width: 220,
        decoration: BoxDecoration(
          color: isMe
              ? const Color(0xFF7C3AED)
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
                ),
        ),
        child: Column(
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // ← Thumbnail widget
                  _VideoThumbnail(videoUrl: msg.fileUrl!, isDark: isDark),
                  // Play button overlay
                  Container(
                    width: 48,
                    height: 48,
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
              child: Row(
                children: [
                  Icon(
                    Icons.videocam_rounded,
                    size: 13,
                    color: isMe
                        ? Colors.white.withOpacity(0.7)
                        : (isDark
                              ? AppTheme.darkTextSecondary
                              : AppTheme.lightTextSecondary),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      msg.fileName ?? 'Video',
                      style: TextStyle(
                        color: isMe
                            ? Colors.white.withOpacity(0.85)
                            : (isDark
                                  ? AppTheme.darkTextPrimary
                                  : AppTheme.lightTextPrimary),
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 6),
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
      ),
    );
  }

  Widget _buildAudioBubble(ChatMessage msg, bool isMe, bool isDark) {
    return _AudioBubble(msg: msg, isMe: isMe, isDark: isDark);
  }

  Widget _buildDocumentBubble(ChatMessage msg, bool isMe, bool isDark) {
    final ext = (msg.fileName ?? '').split('.').last.toLowerCase();
    final Color docColor;
    final IconData docIcon;

    switch (ext) {
      case 'pdf':
        docColor = const Color(0xFFEF4444);
        docIcon = Icons.picture_as_pdf_rounded;
        break;
      case 'doc':
      case 'docx':
        docColor = const Color(0xFF3B82F6);
        docIcon = Icons.description_rounded;
        break;
      case 'xls':
      case 'xlsx':
        docColor = const Color(0xFF10B981);
        docIcon = Icons.table_chart_rounded;
        break;
      case 'ppt':
      case 'pptx':
        docColor = const Color(0xFFF59E0B);
        docIcon = Icons.slideshow_rounded;
        break;
      default:
        docColor = const Color(0xFF6B7280);
        docIcon = Icons.insert_drive_file_rounded;
    }

    return GestureDetector(
      onTap: () async {
        if (msg.fileUrl != null) {
          final uri = Uri.parse(msg.fileUrl!);
          // Try external app first, fallback to browser
          try {
            final launched = await launchUrl(
              uri,
              mode: LaunchMode.externalNonBrowserApplication,
            );
            if (!launched) {
              await launchUrl(uri, mode: LaunchMode.platformDefault);
            }
          } catch (_) {
            await launchUrl(uri, mode: LaunchMode.platformDefault);
          }
        }
      },
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isMe
              ? const Color(0xFF7C3AED)
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
                ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: docColor.withOpacity(isMe ? 0.25 : 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    docIcon,
                    color: isMe ? Colors.white : docColor,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        msg.fileName ?? 'Document',
                        style: TextStyle(
                          color: isMe
                              ? Colors.white
                              : (isDark
                                    ? AppTheme.darkTextPrimary
                                    : AppTheme.lightTextPrimary),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        ext.toUpperCase(),
                        style: TextStyle(
                          color: isMe
                              ? Colors.white.withOpacity(0.6)
                              : (isDark
                                    ? AppTheme.darkTextSecondary
                                    : AppTheme.lightTextSecondary),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.download_rounded,
                  size: 20,
                  color: isMe ? Colors.white.withOpacity(0.8) : docColor,
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
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
          ],
        ),
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
                color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
              ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Image
          GestureDetector(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => _FullScreenImageViewer(imageUrl: msg.fileUrl!),
              ),
            ),
            child: ClipRRect(
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
                    width: 220,
                    height: 220,
                    color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                    child: Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        value: progress.expectedTotalBytes != null
                            ? progress.cumulativeBytesLoaded /
                                  progress.expectedTotalBytes!
                            : null,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppTheme.redAccent,
                        ),
                      ),
                    ),
                  );
                },
                errorBuilder: (_, __, ___) => Container(
                  width: 220,
                  height: 160,
                  color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                  child: const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.grey,
                    size: 32,
                  ),
                ),
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
        : (msg.replyToUserName
                  ?.trim()
                  .split(' ')
                  .where((p) => p.isNotEmpty)
                  .first ??
              '');

    return GestureDetector(
      onTap: () {
        if (msg.replyToMessageId != null) {
          _scrollToMessage(msg.replyToMessageId!);
        }
      },
      child: Container(
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
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // Reply is to a photo?
                  if (msg.replyFileUrl != null)
                    Row(
                      children: [
                        Icon(
                          Icons.image_outlined,
                          size: 12,
                          color: isMe
                              ? Colors.white.withOpacity(0.6)
                              : (isDark
                                    ? AppTheme.darkTextSecondary
                                    : AppTheme.lightTextSecondary),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'Photo',
                          style: TextStyle(
                            color: isMe
                                ? Colors.white.withOpacity(0.6)
                                : (isDark
                                      ? AppTheme.darkTextSecondary
                                      : AppTheme.lightTextSecondary),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    )
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
                    width: 40,
                    height: 40,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      width: 40,
                      height: 40,
                      color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                      child: const Icon(
                        Icons.image_outlined,
                        size: 16,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _statusIcon(String status) {
    switch (status) {
      case 'read':
        return Icon(
          Icons.done_all_rounded,
          size: 14,
          color: Colors.white.withOpacity(0.9),
        );
      case 'delivered':
        return Icon(
          Icons.done_all_rounded,
          size: 14,
          color: Colors.white.withOpacity(0.5),
        );
      default:
        return Icon(
          Icons.done_rounded,
          size: 14,
          color: Colors.white.withOpacity(0.5),
        );
    }
  }

  // ── Scroll-to-bottom button ────────────────

  Widget _scrollToBottomBtn(bool isDark) {
    return GestureDetector(
      onTap: _scrollToBottom,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
          shape: BoxShape.circle,
          border: Border.all(
            color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.15),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Icon(
          Icons.keyboard_arrow_down_rounded,
          size: 22,
          color: isDark
              ? AppTheme.darkTextSecondary
              : AppTheme.lightTextSecondary,
        ),
      ),
    );
  }

  // ── Reply bar ──────────────────────────────

  Widget _buildReplyBar(bool isDark) {
    final msg = _replyingTo!;
    return Container(
      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
      padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 38,
            decoration: BoxDecoration(
              color: AppTheme.redAccent,
              borderRadius: BorderRadius.circular(2),
            ),
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
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
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
            child: Icon(
              Icons.close_rounded,
              size: 20,
              color: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  // ── Input bar ──────────────────────────────

  Widget _buildInputBar(bool isDark) {
    final hasPending =
        _hasText ||
        _pendingImagePath != null ||
        _pendingVideoPath != null ||
        _pendingAudioPath != null ||
        _pendingDocPath != null;

    return Container(
      color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        8 + MediaQuery.of(context).padding.bottom,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // Attachment
          GestureDetector(
            onTap: () => _showAttachOptions(isDark), // ← was _pickAndSendImage
            child: Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                ),
              ),
              child: Icon(
                Icons.attach_file_rounded,
                size: 20,
                color: isDark
                    ? AppTheme.darkTextSecondary
                    : AppTheme.lightTextSecondary,
              ),
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
                  color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
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
          // Send / mic
          _isRecording
              ? _buildRecordingIndicator(isDark)
              : GestureDetector(
                  onTap: hasPending ? _sendMessage : null,
                  onLongPressStart: hasPending
                      ? null
                      : (_) => _startRecording(),
                  onLongPressEnd: hasPending
                      ? null
                      : (_) => _stopAndSendRecording(),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: hasPending
                          ? const LinearGradient(
                              colors: [AppTheme.redAccent, AppTheme.redDark],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            )
                          : null,
                      color: hasPending
                          ? null
                          : (isDark ? AppTheme.darkInput : AppTheme.lightInput),
                      shape: BoxShape.circle,
                      border: hasPending
                          ? null
                          : Border.all(
                              color: isDark
                                  ? AppTheme.darkBorder
                                  : AppTheme.lightBorder,
                            ),
                      boxShadow: hasPending
                          ? [
                              BoxShadow(
                                color: AppTheme.redAccent.withOpacity(0.4),
                                blurRadius: 10,
                                offset: const Offset(0, 3),
                              ),
                            ]
                          : null,
                    ),
                    child: _isSending
                        ? Padding(
                            padding: const EdgeInsets.all(12),
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                hasPending ? Colors.white : AppTheme.redAccent,
                              ),
                            ),
                          )
                        : Icon(
                            hasPending ? Icons.send_rounded : Icons.mic_rounded,
                            size: 20,
                            color: hasPending
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

  Widget _optionTile(
    IconData icon,
    String label,
    bool isDark,
    VoidCallback onTap,
  ) {
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 20, color: AppTheme.redAccent),
      ),
      title: Text(
        label,
        style: TextStyle(
          color: isDark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w500,
        ),
      ),
      onTap: onTap,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );
  }

  // ── Helpers ────────────────────────────────

  String _initials(String name) {
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return '${parts[0][0]}${parts[1][0]}'.toUpperCase();
    }
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
}

class _TypingDot extends StatefulWidget {
  final int delay;
  const _TypingDot({required this.delay});
  @override
  State<_TypingDot> createState() => _TypingDotState();
}

class _TypingDotState extends State<_TypingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
    _anim = Tween(
      begin: 0.4,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _anim,
      child: Container(
        width: 7,
        height: 7,
        decoration: BoxDecoration(
          color: AppTheme.redAccent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

class _MessageInfoSheet extends StatefulWidget {
  final int messageId;
  final ChatMessage message;
  final bool isDark;

  const _MessageInfoSheet({
    required this.messageId,
    required this.message,
    required this.isDark,
  });

  @override
  State<_MessageInfoSheet> createState() => _MessageInfoSheetState();
}

class _MessageInfoSheetState extends State<_MessageInfoSheet> {
  List<dynamic>? _info;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _fetchInfo();
  }

  Future<void> _fetchInfo() async {
    try {
      final response = await ApiCall.get(
        'v1/chat/message/${widget.messageId}/info',
      );
      if (!mounted) return;
      if (response['success'] == true) {
        setState(() {
          _info = response['data'] as List<dynamic>?;
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _formatTime(String? timestamp) {
    if (timestamp == null) return 'Not yet';
    final dt = DateTime.tryParse(timestamp);
    if (dt == null) return timestamp;
    final h = dt.hour;
    final m = dt.minute.toString().padLeft(2, '0');
    final period = h >= 12 ? 'pm' : 'am';
    final hour = h > 12 ? h - 12 : (h == 0 ? 12 : h);
    return '${dt.day}/${dt.month}/${dt.year}  $hour:$m $period';
  }

  @override
  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).padding.bottom + 16,
      ),
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkCard : AppTheme.lightCard,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 20),
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
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Text(
                  'Message Info',
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.darkTextPrimary
                        : AppTheme.lightTextPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          // ── Message preview at bottom ──
          Divider(
            color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder,
            height: 1,
          ),
          _buildMessagePreview(isDark),
          // const SizedBox(height: 20),
          if (_loading)
            const Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(AppTheme.redAccent),
              ),
            )
          else
            _buildStatusRows(isDark),
        ],
      ),
    );
  }

  Widget _buildMessagePreview(bool isDark) {
    final msg = widget.message;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
      child: Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.72,
          ),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF7C3AED), Color(0xFF6D28D9)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16),
              topRight: Radius.circular(16),
              bottomLeft: Radius.circular(16),
              bottomRight: Radius.circular(4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (msg.hasMedia && msg.isImage)
                ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                  child: Image.network(
                    msg.fileUrl!,
                    width: double.infinity,
                    height: 160,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      height: 160,
                      color: isDark ? AppTheme.darkInput : AppTheme.lightInput,
                      child: const Icon(
                        Icons.broken_image_outlined,
                        color: Colors.grey,
                        size: 32,
                      ),
                    ),
                  ),
                ),
              if (msg.messageText.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Text(
                    msg.messageText,
                    style: const TextStyle(color: Colors.white, fontSize: 14),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 10, 8),
                child: Text(
                  msg.formattedTime,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.6),
                    fontSize: 10,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusRows(bool isDark) {
    final info = _info ?? [];

    // Find timestamps by status field
    String? findTime(String status) {
      try {
        final item = info.firstWhere(
          (e) => (e as Map<String, dynamic>)['status'] == status,
          orElse: () => null,
        );
        if (item == null) return null;
        return (item as Map<String, dynamic>)['statusTime'] as String?;
      } catch (_) {
        return null;
      }
    }

    final readAt = findTime('readAt') ?? findTime('read');
    final deliveredAt = findTime('delivered');
    final sentAt = findTime('sent');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          if (readAt != null) ...[
            _statusRow(
              icon: Icons.done_all_rounded,
              iconColor: Colors.blue,
              label: 'Read',
              time: _formatTime(readAt),
              isDark: isDark,
            ),
            Divider(color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
          ],
          if (deliveredAt != null) ...[
            _statusRow(
              icon: Icons.done_all_rounded,
              iconColor: isDark
                  ? AppTheme.darkTextSecondary
                  : AppTheme.lightTextSecondary,
              label: 'Delivered',
              time: _formatTime(deliveredAt),
              isDark: isDark,
            ),
            Divider(color: isDark ? AppTheme.darkBorder : AppTheme.lightBorder),
          ],
          _statusRow(
            icon: Icons.done_rounded,
            iconColor: isDark
                ? AppTheme.darkTextSecondary
                : AppTheme.lightTextSecondary,
            label: 'Sent',
            time: _formatTime(sentAt),
            isDark: isDark,
          ),
        ],
      ),
    );
  }

  Widget _statusRow({
    required IconData icon,
    required Color iconColor,
    required String label,
    required String time,
    required bool isDark,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.darkTextPrimary
                        : AppTheme.lightTextPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  time,
                  style: TextStyle(
                    color: isDark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FullScreenImageViewer extends StatelessWidget {
  final String imageUrl;
  const _FullScreenImageViewer({required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Pinch-to-zoom image
          Center(
            child: InteractiveViewer(
              minScale: 0.5,
              maxScale: 4.0,
              child: Image.network(
                imageUrl,
                fit: BoxFit.contain,
                loadingBuilder: (_, child, progress) {
                  if (progress == null) return child;
                  return Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      value: progress.expectedTotalBytes != null
                          ? progress.cumulativeBytesLoaded /
                                progress.expectedTotalBytes!
                          : null,
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        AppTheme.redAccent,
                      ),
                    ),
                  );
                },
                errorBuilder: (_, __, ___) => const Icon(
                  Icons.broken_image_outlined,
                  color: Colors.grey,
                  size: 48,
                ),
              ),
            ),
          ),
          // Close button
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AudioBubble extends StatefulWidget {
  final ChatMessage msg;
  final bool isMe;
  final bool isDark;

  const _AudioBubble({
    required this.msg,
    required this.isMe,
    required this.isDark,
  });

  @override
  State<_AudioBubble> createState() => _AudioBubbleState();
}

class _AudioBubbleState extends State<_AudioBubble> {
  final AudioPlayer _player = AudioPlayer();
  bool _isPlaying = false;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted)
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay() async {
    if (_isPlaying) {
      await _player.pause();
      setState(() => _isPlaying = false);
    } else {
      if (widget.msg.fileUrl != null) {
        await _player.play(UrlSource(widget.msg.fileUrl!));
        setState(() => _isPlaying = true);
      }
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final isMe = widget.isMe;
    final isDark = widget.isDark;
    final progress = _duration.inMilliseconds > 0
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      width: 240,
      padding: const EdgeInsets.fromLTRB(10, 10, 12, 8),
      decoration: BoxDecoration(
        color: isMe
            ? const Color(0xFF7C3AED)
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
              ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: _togglePlay,
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isMe
                        ? Colors.white.withOpacity(0.2)
                        : AppTheme.redAccent.withOpacity(0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    color: isMe ? Colors.white : AppTheme.redAccent,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Waveform bars
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildWaveform(progress, isMe),
                    const SizedBox(height: 4),
                    Text(
                      _isPlaying || _position.inSeconds > 0
                          ? _fmt(_position)
                          : _fmt(_duration),
                      style: TextStyle(
                        color: isMe
                            ? Colors.white.withOpacity(0.7)
                            : (isDark
                                  ? AppTheme.darkTextSecondary
                                  : AppTheme.lightTextSecondary),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Text(
                widget.msg.formattedTime,
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
                _statusIconStatic(widget.msg.currentStatus),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildWaveform(double progress, bool isMe) {
    // Static waveform heights — looks natural
    const bars = [
      4.0,
      8.0,
      14.0,
      10.0,
      18.0,
      12.0,
      20.0,
      8.0,
      16.0,
      10.0,
      22.0,
      14.0,
      8.0,
      18.0,
      12.0,
      6.0,
      16.0,
      10.0,
      14.0,
      8.0,
    ];
    final totalBars = bars.length;

    return SizedBox(
      height: 24,
      child: Row(
        children: List.generate(totalBars, (i) {
          final filled = (i / totalBars) <= progress;
          return Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 1),
              height: bars[i],
              decoration: BoxDecoration(
                color: filled
                    ? (isMe ? Colors.white : AppTheme.redAccent)
                    : (isMe
                          ? Colors.white.withOpacity(0.3)
                          : AppTheme.redAccent.withOpacity(0.25)),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }

  Widget _statusIconStatic(String status) {
    switch (status) {
      case 'read':
        return Icon(
          Icons.done_all_rounded,
          size: 14,
          color: Colors.white.withOpacity(0.9),
        );
      case 'delivered':
        return Icon(
          Icons.done_all_rounded,
          size: 14,
          color: Colors.white.withOpacity(0.5),
        );
      default:
        return Icon(
          Icons.done_rounded,
          size: 14,
          color: Colors.white.withOpacity(0.5),
        );
    }
  }
}

class _FullScreenVideoPlayer extends StatefulWidget {
  final String videoUrl;
  const _FullScreenVideoPlayer({required this.videoUrl});

  @override
  State<_FullScreenVideoPlayer> createState() => _FullScreenVideoPlayerState();
}

class _FullScreenVideoPlayerState extends State<_FullScreenVideoPlayer> {
  late VideoPlayerController _ctrl;
  bool _initialized = false;
  bool _showControls = true;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl))
      ..initialize().then((_) {
        if (mounted) setState(() => _initialized = true);
      });
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        child: Stack(
          children: [
            // Video
            Center(
              child: _initialized
                  ? AspectRatio(
                      aspectRatio: _ctrl.value.aspectRatio,
                      child: VideoPlayer(_ctrl),
                    )
                  : const CircularProgressIndicator(
                      color: AppTheme.redAccent,
                      strokeWidth: 2,
                    ),
            ),
            // Controls overlay
            if (_showControls) ...[
              // Top — close button
              SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Container(
                      padding: const EdgeInsets.all(6),
                      decoration: const BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              ),
              // Bottom — progress + play/pause
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    12,
                    16,
                    16 + MediaQuery.of(context).padding.bottom,
                  ),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Seek bar
                      if (_initialized)
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: AppTheme.redAccent,
                            inactiveTrackColor: Colors.white24,
                            thumbColor: AppTheme.redAccent,
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 6,
                            ),
                            trackHeight: 3,
                            overlayShape: SliderComponentShape.noOverlay,
                          ),
                          child: Slider(
                            value: _ctrl.value.position.inMilliseconds
                                .toDouble(),
                            min: 0,
                            max: _ctrl.value.duration.inMilliseconds
                                .toDouble()
                                .clamp(1, double.infinity),
                            onChanged: (v) =>
                                _ctrl.seekTo(Duration(milliseconds: v.toInt())),
                          ),
                        ),
                      Row(
                        children: [
                          if (_initialized)
                            Text(
                              '${_fmt(_ctrl.value.position)} / ${_fmt(_ctrl.value.duration)}',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                              ),
                            ),
                          const Spacer(),
                          GestureDetector(
                            onTap: () {
                              _ctrl.value.isPlaying
                                  ? _ctrl.pause()
                                  : _ctrl.play();
                            },
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: const BoxDecoration(
                                color: Colors.white24,
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                _ctrl.value.isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                color: Colors.white,
                                size: 28,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VideoThumbnail extends StatefulWidget {
  final String videoUrl;
  final bool isDark;

  const _VideoThumbnail({required this.videoUrl, required this.isDark});

  @override
  State<_VideoThumbnail> createState() => _VideoThumbnailState();
}

class _VideoThumbnailState extends State<_VideoThumbnail> {
  Uint8List? _thumbnail;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _generateThumbnail();
  }

  Future<void> _generateThumbnail() async {
    try {
      final bytes = await VideoThumbnail.thumbnailData(
        video: widget.videoUrl,
        imageFormat: ImageFormat.JPEG,
        maxWidth: 220,
        quality: 75,
      );
      if (mounted)
        setState(() {
          _thumbnail = bytes;
          _loading = false;
        });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        width: 220,
        height: 160,
        color: Colors.black,
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppTheme.redAccent,
            ),
          ),
        ),
      );
    }

    if (_thumbnail != null) {
      return Image.memory(
        _thumbnail!,
        width: 220,
        height: 160,
        fit: BoxFit.cover,
      );
    }

    // Fallback if thumbnail generation fails
    return Container(
      width: 220,
      height: 160,
      color: Colors.black,
      child: const Icon(
        Icons.videocam_rounded,
        color: Colors.white24,
        size: 48,
      ),
    );
  }
}
