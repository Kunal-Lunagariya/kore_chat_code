import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../services/notification_service.dart';
import '../../socket/socket_events.dart';
import '../../socket/socket_index.dart';

enum GroupCallState { calling, active, ended }

class GroupCallScreen extends StatefulWidget {
  final int myUserId;
  final int conversationId;
  final String groupName;
  final String callType;
  final bool isInitiator;
  final List<Map<String, dynamic>> groupMembers;
  // For incoming call
  final int? callerId;
  final String? callerName;

  const GroupCallScreen({
    super.key,
    required this.myUserId,
    required this.conversationId,
    required this.groupName,
    required this.callType,
    required this.isInitiator,
    required this.groupMembers,
    this.callerId,
    this.callerName,
  });

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen>
    with TickerProviderStateMixin {
  // ── WebRTC — one PC per remote peer ───────────────────────────
  final Map<int, RTCPeerConnection> _pcs = {};
  final Map<int, MediaStream> _remoteStreams = {};
  final Map<int, List<RTCIceCandidate>> _pendingCandidates = {};
  final Map<int, RTCVideoRenderer> _remoteRenderers = {};
  final Map<int, RTCDataChannel> _dataChannels = {};
  MediaStream? _localStream;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();

  // ── State ──────────────────────────────────────────────────────
  GroupCallState _state = GroupCallState.calling;
  bool _isMuted = false;
  bool _isVideoOff = false;
  bool _isSpeakerOn = true;
  bool _isFrontCamera = true;
  int _elapsed = 0;
  Timer? _timer;

  // ── Active participant names + their media states ──────────────
  // userId → name (for display)
  final Map<int, String> _participantNames = {};
  final Map<int, bool> _peerIsMuted = {};
  final Map<int, bool> _peerIsVideoOff = {};
  bool _cleanedUp = false;

  bool get _isVideo => widget.callType == 'video';

  static const _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
  };

  // ── Animations ─────────────────────────────────────────────────
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    SocketIndex.setCallActive(true);
    SocketIndex.addReconnectCallback(_onSocketReconnect);

    _localRenderer.initialize();
    _registerSocketListeners();
    _initCall();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseCtrl.dispose();
    SocketIndex.setCallActive(false);
    SocketIndex.removeReconnectCallback(_onSocketReconnect);
    _cleanupAll();
    SocketEvents.offGroupCallUserJoined();
    SocketEvents.offGroupCallUserLeft();
    SocketEvents.offGroupCallOffer();
    SocketEvents.offGroupCallAnswer();
    SocketEvents.offGroupCallIceCandidate();
    SocketEvents.offGroupCallEnded();
    NotificationService().endAllCalls();
    super.dispose();
  }

  /// Re-joins the group call room when the socket reconnects mid-call.
  void _onSocketReconnect() {
    if (_state != GroupCallState.active || !mounted) return;
    SocketEvents.emitGroupCallJoin(
      conversationId: widget.conversationId,
      userId: widget.myUserId,
    );
  }

  void _registerSocketListeners() {
    // New participant joined — send them an offer
    SocketEvents.onGroupCallUserJoined((data) async {
      if (!mounted) return;
      final map = Map<String, dynamic>.from(data as Map);
      final userId = (map['userId'] as num?)?.toInt() ?? 0;
      if (userId == widget.myUserId) return;
      debugPrint('👥 Group call: user $userId joined');
      // Add name from group members if available
      _addParticipantName(userId);
      await _makeOffer(userId);
    });

    // Participant left
    SocketEvents.onGroupCallUserLeft((data) {
      if (!mounted) return;
      final map = Map<String, dynamic>.from(data as Map);
      final userId = (map['userId'] as num?)?.toInt() ?? 0;
      _closePeerConnection(userId);
      setState(() {
        _participantNames.remove(userId);
      });
    });

    // Received offer from a peer
    SocketEvents.onGroupCallOffer((data) async {
      if (!mounted) return;
      final map = Map<String, dynamic>.from(data as Map);
      final fromUserId = (map['fromUserId'] as num?)?.toInt() ?? 0;
      final offerMap = Map<String, dynamic>.from(map['offer'] as Map);
      final callType = (map['callType'] as String?) ?? widget.callType;
      _addParticipantName(fromUserId);
      await _handleOffer(fromUserId, offerMap, callType);
    });

    // Received answer from a peer
    SocketEvents.onGroupCallAnswer((data) async {
      if (!mounted) return;
      final map = Map<String, dynamic>.from(data as Map);
      final fromUserId = (map['fromUserId'] as num?)?.toInt() ?? 0;
      final answerMap = Map<String, dynamic>.from(map['answer'] as Map);
      await _handleAnswer(fromUserId, answerMap);
    });

    // ICE candidate from a peer
    SocketEvents.onGroupCallIceCandidate((data) async {
      if (!mounted) return;
      final map = Map<String, dynamic>.from(data as Map);
      final fromUserId = (map['fromUserId'] as num?)?.toInt() ?? 0;
      final cMap = Map<String, dynamic>.from(map['candidate'] as Map);
      final candidate = RTCIceCandidate(
        cMap['candidate'] as String,
        cMap['sdpMid'] as String?,
        (cMap['sdpMLineIndex'] as num?)?.toInt(),
      );
      final pc = _pcs[fromUserId];
      if (pc != null &&
          pc.signalingState != RTCSignalingState.RTCSignalingStateClosed) {
        await pc.addCandidate(candidate);
      } else {
        _pendingCandidates.putIfAbsent(fromUserId, () => []).add(candidate);
      }
    });

    // Call ended by initiator or all left
    SocketEvents.onGroupCallEnded((data) {
      if (!mounted) return;
      final map = Map<String, dynamic>.from(data as Map);
      final convId = (map['conversationId'] as num?)?.toInt() ?? 0;
      if (convId == widget.conversationId) {
        _handleCallEnded();
      }
    });
  }

  void _addParticipantName(int userId) {
    if (_participantNames.containsKey(userId)) return;
    final member = widget.groupMembers.firstWhere(
      (m) => (m['userId'] as num?)?.toInt() == userId,
      orElse: () => {},
    );
    final name =
        (member['UserName'] as String?) ??
        (member['userName'] as String?) ??
        'User $userId';
    setState(() => _participantNames[userId] = name.trim().split(' ').first);
  }

  Future<void> _initCall() async {
    try {
      _localStream = await _getMedia();
      // Explicitly enable audio in case the OS delivered a disabled track
      _localStream?.getAudioTracks().forEach((t) => t.enabled = true);
      _localRenderer.srcObject = _localStream;
      if (mounted) setState(() {});

      if (widget.isInitiator) {
        // Start the call — backend notifies all group members
        SocketEvents.emitGroupCallInitiate(
          conversationId: widget.conversationId,
          callerId: widget.myUserId,
          callType: widget.callType,
        );
        // Go active immediately as initiator
        _startTimer();
        if (mounted) setState(() => _state = GroupCallState.active);
      } else {
        // Join the call
        SocketEvents.emitGroupCallJoin(
          conversationId: widget.conversationId,
          userId: widget.myUserId,
        );
        _startTimer();
        if (mounted) setState(() => _state = GroupCallState.active);
      }
    } catch (e) {
      debugPrint('GroupCall init error: $e');
      if (mounted) Navigator.pop(context);
    }
  }

  Future<MediaStream> _getMedia() async {
    final constraints = _isVideo
        ? {
            'audio': {
              'echoCancellation': true,
              'noiseSuppression': true,
              'autoGainControl': true,
            },
            'video': {
              'facingMode': 'user',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
            },
          }
        : {
            'audio': {
              'echoCancellation': true,
              'noiseSuppression': true,
              'autoGainControl': true,
            },
            'video': false,
          };
    return navigator.mediaDevices.getUserMedia(constraints);
  }

  Future<RTCPeerConnection> _createPC(int peerId) async {
    if (_pcs.containsKey(peerId)) return _pcs[peerId]!;

    final pc = await createPeerConnection(_iceServers);
    _pcs[peerId] = pc;

    // Init renderer for this peer
    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    _remoteRenderers[peerId] = renderer;

    pc.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        SocketEvents.emitGroupCallIceCandidate(
          toUserId: peerId,
          conversationId: widget.conversationId,
          candidate: {
            'candidate': candidate.candidate,
            'sdpMid': candidate.sdpMid,
            'sdpMLineIndex': candidate.sdpMLineIndex,
          },
        );
      }
    };

    pc.onTrack = (event) {
      if (event.streams.isNotEmpty && mounted) {
        final stream = event.streams[0];
        _remoteStreams[peerId] = stream;
        _remoteRenderers[peerId]?.srcObject = stream;
        setState(() {});
      }
    };

    pc.onConnectionState = (state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        Helper.setSpeakerphoneOn(_isSpeakerOn).catchError((_) {});
      }
      if ([
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
        RTCPeerConnectionState.RTCPeerConnectionStateFailed,
        RTCPeerConnectionState.RTCPeerConnectionStateClosed,
      ].contains(state)) {
        _closePeerConnection(peerId);
      }
    };

    // ── Data channel: offerer creates it ─────────────────────────
    try {
      final dcInit = RTCDataChannelInit()..ordered = true;
      final dc = await pc.createDataChannel('state', dcInit);
      _dataChannels[peerId] = dc;
      dc.onDataChannelState = (s) {
        if (s == RTCDataChannelState.RTCDataChannelOpen) {
          _sendStateTo(dc);
        }
      };
      dc.onMessage = (msg) => _handlePeerStateMessage(peerId, msg);
    } catch (_) {}

    return pc;
  }

  Future<void> _makeOffer(int peerId) async {
    final pc = await _createPC(peerId);
    _localStream?.getTracks().forEach((t) => pc.addTrack(t, _localStream!));
    final offer = await pc.createOffer();
    await pc.setLocalDescription(offer);
    SocketEvents.emitGroupCallOffer(
      toUserId: peerId,
      conversationId: widget.conversationId,
      offer: {'type': offer.type, 'sdp': offer.sdp},
      callType: widget.callType,
    );
  }

  Future<void> _handleOffer(
    int fromUserId,
    Map<String, dynamic> offerMap,
    String callType,
  ) async {
    final pc = await _createPC(fromUserId);

    // Answerer side: receive the data channel the offerer created
    pc.onDataChannel = (dc) {
      _dataChannels[fromUserId] = dc;
      dc.onDataChannelState = (s) {
        if (s == RTCDataChannelState.RTCDataChannelOpen) {
          _sendStateTo(dc);
        }
      };
      dc.onMessage = (msg) => _handlePeerStateMessage(fromUserId, msg);
    };

    _localStream?.getTracks().forEach((t) => pc.addTrack(t, _localStream!));
    await pc.setRemoteDescription(
      RTCSessionDescription(
        offerMap['sdp'] as String,
        offerMap['type'] as String,
      ),
    );
    // Flush pending candidates
    final pending = _pendingCandidates.remove(fromUserId) ?? [];
    for (final c in pending) {
      await pc.addCandidate(c);
    }

    final answer = await pc.createAnswer();
    await pc.setLocalDescription(answer);
    SocketEvents.emitGroupCallAnswer(
      toUserId: fromUserId,
      conversationId: widget.conversationId,
      answer: {'type': answer.type, 'sdp': answer.sdp},
    );
  }

  Future<void> _handleAnswer(
    int fromUserId,
    Map<String, dynamic> answerMap,
  ) async {
    final pc = _pcs[fromUserId];
    if (pc == null) return;
    if (pc.signalingState !=
        RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
      return;
    }
    await pc.setRemoteDescription(
      RTCSessionDescription(
        answerMap['sdp'] as String,
        answerMap['type'] as String,
      ),
    );
    final pending = _pendingCandidates.remove(fromUserId) ?? [];
    for (final c in pending) {
      await pc.addCandidate(c);
    }
  }

  void _closePeerConnection(int peerId) {
    _dataChannels[peerId]?.close();
    _dataChannels.remove(peerId);
    _pcs[peerId]?.close();
    _pcs.remove(peerId);
    _remoteStreams.remove(peerId);
    _remoteRenderers[peerId]?.srcObject = null;
    _remoteRenderers[peerId]?.dispose();
    _remoteRenderers.remove(peerId);
    _pendingCandidates.remove(peerId);
    _peerIsMuted.remove(peerId);
    _peerIsVideoOff.remove(peerId);
    _participantNames.remove(peerId);
    if (mounted) setState(() {});
  }

  void _cleanupAll() {
    if (_cleanedUp) return;
    _cleanedUp = true;
    _timer?.cancel();
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    for (final dc in _dataChannels.values) {
      dc.close();
    }
    _dataChannels.clear();
    for (final peerId in List.from(_pcs.keys)) {
      _pcs[peerId]?.close();
      _remoteRenderers[peerId]?.srcObject = null;
      _remoteRenderers[peerId]?.dispose();
    }
    _pcs.clear();
    _remoteStreams.clear();
    _remoteRenderers.clear();
    _localRenderer.srcObject = null;
    _localRenderer.dispose();
  }

  void _startTimer() {
    _elapsed = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
  }

  String get _elapsedLabel {
    final m = (_elapsed ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsed % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  void _hangup() {
    if (_state == GroupCallState.ended) return;
    if (widget.isInitiator) {
      _showEndCallDialog();
    } else {
      _doHangup(endForAll: false);
    }
  }

  Future<void> _showEndCallDialog() async {
    final choice = await showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => Dialog(
        backgroundColor: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E2E),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: const BoxDecoration(
                  color: Color(0x33E53935),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.call_end_rounded, color: Color(0xFFE53935), size: 28),
              ),
              const SizedBox(height: 16),
              const Text(
                'End Call',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Do you want to leave or end the call for everyone?',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white60, fontSize: 13),
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, 'leave'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        side: const BorderSide(color: Colors.white24),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('Leave'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => Navigator.pop(context, 'end_all'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFE53935),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      child: const Text('End for All'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (choice == null || !mounted) return;
    _doHangup(endForAll: choice == 'end_all');
  }

  void _doHangup({required bool endForAll}) {
    if (_state == GroupCallState.ended) return;
    NotificationService().endAllCalls();
    SocketIndex.notifyCallEnded();

    if (endForAll) {
      SocketEvents.emitGroupCallEnd(
        conversationId: widget.conversationId,
        userId: widget.myUserId,
      );
    } else {
      SocketEvents.emitGroupCallLeave(
        conversationId: widget.conversationId,
        userId: widget.myUserId,
      );
    }
    _cleanupAll();
    if (mounted) {
      setState(() => _state = GroupCallState.ended);
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  void _handleCallEnded() {
    if (_state == GroupCallState.ended) return;
    NotificationService().endAllCalls();
    SocketIndex.notifyCallEnded();
    _cleanupAll();
    if (!mounted) return;
    setState(() => _state = GroupCallState.ended);
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) Navigator.pop(context);
    });
  }

  void _sendStateTo(RTCDataChannel dc) {
    try {
      final payload = jsonEncode({'muted': _isMuted, 'videoOff': _isVideoOff});
      dc.send(RTCDataChannelMessage(payload));
    } catch (_) {}
  }

  void _broadcastState() {
    for (final dc in _dataChannels.values) {
      if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
        _sendStateTo(dc);
      }
    }
  }

  void _handlePeerStateMessage(int peerId, RTCDataChannelMessage msg) {
    try {
      final map = jsonDecode(msg.text) as Map<String, dynamic>;
      final muted = map['muted'] as bool? ?? false;
      final videoOff = map['videoOff'] as bool? ?? false;
      if (mounted) {
        setState(() {
          _peerIsMuted[peerId] = muted;
          _peerIsVideoOff[peerId] = videoOff;
        });
      }
    } catch (_) {}
  }

  void _toggleMute() {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !t.enabled);
    setState(() => _isMuted = !_isMuted);
    _broadcastState();
  }

  Future<void> _toggleSpeaker() async {
    setState(() => _isSpeakerOn = !_isSpeakerOn);
    try {
      await Helper.setSpeakerphoneOn(_isSpeakerOn);
    } catch (_) {}
  }

  void _toggleVideo() {
    _localStream?.getVideoTracks().forEach((t) => t.enabled = !t.enabled);
    setState(() => _isVideoOff = !_isVideoOff);
    _broadcastState();
  }

  Future<void> _switchCamera() async {
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    await Helper.switchCamera(track);
    setState(() => _isFrontCamera = !_isFrontCamera);
  }

  // ── Helpers ────────────────────────────────────────────────────

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

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );
    return Scaffold(
      backgroundColor: Colors.black,
      body: _isVideo ? _buildVideoCall() : _buildAudioCall(),
    );
  }

  // ── Audio UI ───────────────────────────────────────────────────

  Widget _buildAudioCall() {
    final activeParticipants = _participantNames.entries.toList();
    final totalInCall = activeParticipants.length + 1; // +1 for me

    return Stack(
      children: [
        // Background gradient
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF0D0D1A),
                  Color(0xFF1A0D2E),
                  Color(0xFF0D1A1A),
                ],
              ),
            ),
          ),
        ),

        // Content
        SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 20),
              // Group name + timer
              Text(
                widget.groupName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _state == GroupCallState.active
                    ? '$_elapsedLabel · $totalInCall in call'
                    : 'Starting call…',
                style: TextStyle(
                  color: _state == GroupCallState.active
                      ? const Color(0xFF4CAF50)
                      : Colors.white60,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 32),

              // Participant grid
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: GridView.builder(
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 16,
                          crossAxisSpacing: 16,
                          childAspectRatio: 0.85,
                        ),
                    itemCount: totalInCall,
                    itemBuilder: (_, i) {
                      // First tile = me
                      if (i == 0) {
                        return _buildParticipantTile(
                          name: 'You',
                          isMe: true,
                          isMuted: _isMuted,
                        );
                      }
                      final entry = activeParticipants[i - 1];
                      return _buildParticipantTile(
                        name: entry.value,
                        isMe: false,
                        isMuted: _peerIsMuted[entry.key] ?? false,
                      );
                    },
                  ),
                ),
              ),

              // Controls
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _RoundBtn(
                          icon: _isMuted
                              ? Icons.mic_off_rounded
                              : Icons.mic_rounded,
                          label: _isMuted ? 'Unmute' : 'Mute',
                          active: !_isMuted,
                          onTap: _toggleMute,
                        ),
                        const SizedBox(width: 24),
                        _RoundBtn(
                          icon: _isSpeakerOn
                              ? Icons.volume_up_rounded
                              : Icons.volume_off_rounded,
                          label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
                          active: _isSpeakerOn,
                          onTap: _toggleSpeaker,
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    _EndBtn(onTap: _hangup),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildParticipantTile({
    required String name,
    required bool isMe,
    required bool isMuted,
  }) {
    final color = _avatarColor(name);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          alignment: Alignment.bottomRight,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: isMe ? const Color(0xFF7C3AED) : color,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: (isMe ? const Color(0xFF7C3AED) : color).withOpacity(
                      0.4,
                    ),
                    blurRadius: 12,
                  ),
                ],
              ),
              child: Center(
                child: Text(
                  _initials(name),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            if (isMuted)
              Container(
                width: 20,
                height: 20,
                decoration: const BoxDecoration(
                  color: Color(0xFFE53935),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.mic_off_rounded,
                  size: 12,
                  color: Colors.white,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          name,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  // ── Video UI ───────────────────────────────────────────────────

  Widget _buildVideoCall() {
    final peerIds = _remoteRenderers.keys.toList();
    final totalVideos = peerIds.length + 1; // +1 for local

    return Stack(
      children: [
        // Video grid
        _buildVideoGrid(peerIds),

        // Top bar
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.groupName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            shadows: [
                              Shadow(blurRadius: 8, color: Colors.black54),
                            ],
                          ),
                        ),
                        Text(
                          _state == GroupCallState.active
                              ? '$_elapsedLabel · $totalVideos in call'
                              : 'Starting…',
                          style: TextStyle(
                            color: _state == GroupCallState.active
                                ? const Color(0xFF4CAF50)
                                : Colors.white60,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_isVideo)
                    _GlassBtn(
                      icon: Icons.flip_camera_ios_rounded,
                      onTap: _switchCamera,
                    ),
                ],
              ),
            ),
          ),
        ),

        // Bottom controls
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: Colors.white.withOpacity(0.08)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _PillBtn(
                      icon: _isMuted
                          ? Icons.mic_off_rounded
                          : Icons.mic_rounded,
                      label: _isMuted ? 'Unmute' : 'Mute',
                      active: !_isMuted,
                      onTap: _toggleMute,
                    ),
                    _PillBtn(
                      icon: _isVideoOff
                          ? Icons.videocam_off_rounded
                          : Icons.videocam_rounded,
                      label: _isVideoOff ? 'Cam off' : 'Cam on',
                      active: !_isVideoOff,
                      onTap: _toggleVideo,
                    ),
                    _PillBtn(
                      icon: _isSpeakerOn
                          ? Icons.volume_up_rounded
                          : Icons.volume_off_rounded,
                      label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
                      active: _isSpeakerOn,
                      onTap: _toggleSpeaker,
                    ),
                    _EndBtn(onTap: _hangup),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVideoGrid(List<int> peerIds) {
    final total = peerIds.length + 1;

    if (total == 1) {
      // Only me — local fullscreen
      return Positioned.fill(
        child: _buildVideoTile(
          video: _isVideoOff
              ? _buildBlackAvatar('You')
              : RTCVideoView(
                  _localRenderer,
                  mirror: _isFrontCamera,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
          name: 'You',
          isMuted: _isMuted,
        ),
      );
    }

    if (total == 2) {
      // Me + 1 peer — peer fullscreen, local PiP
      final peer = peerIds[0];
      final renderer = _remoteRenderers[peer];
      final name = _participantNames[peer] ?? 'User';
      final peerMuted = _peerIsMuted[peer] ?? false;
      return Stack(
        children: [
          // Peer fullscreen with name + mute badge
          Positioned.fill(
            child: _buildVideoTile(
              video: renderer != null &&
                      _remoteStreams[peer] != null &&
                      _peerIsVideoOff[peer] != true
                  ? RTCVideoView(
                      renderer,
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    )
                  : _buildBlackAvatar(name),
              name: name,
              isMuted: peerMuted,
            ),
          ),
          // Local PiP with mute badge
          Positioned(
            right: 16,
            bottom: 120,
            child: Stack(
              children: [
                Container(
                  width: 96,
                  height: 128,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.white.withOpacity(0.3)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: _isVideoOff
                        ? _buildBlackAvatar('You')
                        : RTCVideoView(
                            _localRenderer,
                            mirror: _isFrontCamera,
                            objectFit:
                                RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                          ),
                  ),
                ),
                if (_isMuted)
                  Positioned(
                    bottom: 6,
                    right: 6,
                    child: Container(
                      width: 22,
                      height: 22,
                      decoration: const BoxDecoration(
                        color: Color(0xFFE53935),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.mic_off_rounded, size: 13, color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }

    // 3+ people — grid layout
    return GridView.builder(
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: total <= 4 ? 2 : 3,
        mainAxisSpacing: 2,
        crossAxisSpacing: 2,
      ),
      itemCount: total,
      itemBuilder: (_, i) {
        if (i == 0) {
          return _buildVideoTile(
            video: _isVideoOff
                ? _buildBlackAvatar('You')
                : RTCVideoView(
                    _localRenderer,
                    mirror: _isFrontCamera,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
            name: 'You',
            isMuted: _isMuted,
          );
        }
        final peer = peerIds[i - 1];
        final renderer = _remoteRenderers[peer];
        final name = _participantNames[peer] ?? 'User';
        final peerMuted = _peerIsMuted[peer] ?? false;
        return _buildVideoTile(
          video: renderer != null &&
                  _remoteStreams[peer] != null &&
                  _peerIsVideoOff[peer] != true
              ? RTCVideoView(
                  renderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                )
              : _buildBlackAvatar(name),
          name: name,
          isMuted: peerMuted,
        );
      },
    );
  }

  /// Wraps any video widget with a bottom-left name + mute badge overlay.
  Widget _buildVideoTile({
    required Widget video,
    required String name,
    required bool isMuted,
  }) {
    return Stack(
      children: [
        Positioned.fill(child: video),
        Positioned(
          bottom: 8,
          left: 8,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.55),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isMuted) ...[
                  const Icon(Icons.mic_off_rounded, size: 13, color: Color(0xFFE53935)),
                  const SizedBox(width: 4),
                ],
                Text(
                  name,
                  style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBlackAvatar(String name) {
    return Container(
      color: const Color(0xFF1A1A2E),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: _avatarColor(name),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  _initials(name),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              name,
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Reused widgets (same as call_screen.dart) ──────────────────

class _RoundBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _RoundBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = true,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: active
                  ? Colors.white.withOpacity(0.15)
                  : Colors.white.withOpacity(0.06),
              shape: BoxShape.circle,
              border: Border.all(
                color: active
                    ? Colors.white.withOpacity(0.3)
                    : Colors.white.withOpacity(0.1),
              ),
            ),
            child: Icon(
              icon,
              color: active ? Colors.white : Colors.white38,
              size: 24,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _PillBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _PillBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = true,
  });
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: active
                  ? Colors.white.withOpacity(0.15)
                  : Colors.white.withOpacity(0.06),
              shape: BoxShape.circle,
              border: Border.all(
                color: active
                    ? Colors.white.withOpacity(0.25)
                    : Colors.white.withOpacity(0.1),
              ),
            ),
            child: Icon(
              icon,
              color: active ? Colors.white : Colors.white38,
              size: 22,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(
              color: active ? Colors.white.withOpacity(0.85) : Colors.white38,
              fontSize: 10,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _EndBtn extends StatelessWidget {
  final VoidCallback onTap;
  const _EndBtn({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: const BoxDecoration(
              color: Color(0xFFE53935),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Color(0x66E53935),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(
              Icons.call_end_rounded,
              color: Colors.white,
              size: 28,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'End',
            style: TextStyle(
              color: Colors.white.withOpacity(0.7),
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _GlassBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _GlassBtn({required this.icon, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withOpacity(0.2)),
        ),
        child: Icon(icon, color: Colors.white, size: 20),
      ),
    );
  }
}
