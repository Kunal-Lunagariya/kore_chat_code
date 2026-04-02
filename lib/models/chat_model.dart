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
  final int? callId;
  final int? callType;
  final String? callStatus;
  final String? duration;
  final String? callStartAt;

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
    this.callId,
    this.callType,
    this.callStatus,
    this.duration,
    this.callStartAt,
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
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      isDeleted: json['isDeleted'] as bool? ?? false,
      currentStatus: (json['currentStatus'] as String?) ?? 'sent',
      sender: (json['sender'] as String?) ?? 'them',
      fileUrl: json['fileUrl'] as String?,
      fileType: json['fileType'] as String?,
      fileMimeType: json['fileMimeType'] as String?,
      fileName: json['fileName'] as String?,
      callId: (json['callId'] as num?)?.toInt(),
      callType: (json['callType'] as num?)?.toInt(),
      callStatus: json['callStatus'] as String?,
      duration: json['duration'] as String?,
      callStartAt: json['callStartAt'] as String?,
    );
  }

  bool get isMe => sender == 'me';
  bool get hasMedia => fileUrl != null && fileUrl!.isNotEmpty;
  bool get hasReply => replyToMessageId != null;
  bool get isImage => fileType == 'image';
  bool get isCallMessage => callId != null;
  bool get isVideoCall => callType == 2;

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
        .difference(
          DateTime.utc(createdAt.year, createdAt.month, createdAt.day),
        )
        .inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    const days = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    if (diff < 7) return days[createdAt.weekday - 1];
    return '${createdAt.day}/${createdAt.month}/${createdAt.year}';
  }

  ChatMessage copyWith({String? currentStatus}) {
    return ChatMessage(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      senderName: senderName,
      messageType: messageType,
      messageText: messageText,
      mediaId: mediaId,
      replyToMessageId: replyToMessageId,
      replyMessageText: replyMessageText,
      replyMediaId: replyMediaId,
      replyFileUrl: replyFileUrl,
      replyFileType: replyFileType,
      replyFileMimeType: replyFileMimeType,
      replyFileName: replyFileName,
      replyToUserName: replyToUserName,
      replyToSender: replyToSender,
      createdAt: createdAt,
      isDeleted: isDeleted,
      currentStatus: currentStatus ?? this.currentStatus,
      sender: sender,
      fileUrl: fileUrl,
      fileType: fileType,
      fileMimeType: fileMimeType,
      fileName: fileName,
      callId: callId,
      callType: callType,
      callStatus: callStatus,
      duration: duration,
      callStartAt: callStartAt,
    );
  }
}
