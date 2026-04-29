import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../services/notification_service.dart';
import '../../socket/socket_events.dart';
import '../../socket/socket_index.dart';

enum CallState { idle, calling, ringing, incoming, active, ended }

class CallScreen extends StatefulWidget {
  final int myUserId;
  final int remoteUserId;
  final String remoteUserName;
  final String callType;
  final bool isOutgoing;
  final Map<String, dynamic>? incomingOffer;
  final bool autoAnswer;
  final int? roomId;
  final int? conversationId;

  const CallScreen({
    super.key,
    required this.myUserId,
    required this.remoteUserId,
    required this.remoteUserName,
    required this.callType,
    required this.isOutgoing,
    this.incomingOffer,
    this.autoAnswer = false,
    this.roomId,
    this.conversationId,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with TickerProviderStateMixin {
  // ── WebRTC ──────────────────────────────────────────────────────
  RTCPeerConnection? _pc;
  RTCDataChannel? _dataChannel;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final List<RTCIceCandidate> _pendingCandidates = [];
  Map<String, dynamic>? _pendingAnswer; // answer arrived before PC was ready
  bool _remoteDescSet = false;
  int? _roomId;
  int? _conversationId;

  // ── State ───────────────────────────────────────────────────────
  CallState _callState = CallState.calling;
  bool _isMuted = false;
  bool _isSpeakerOn = true;
  bool _isVideoOff = false;
  bool _isFrontCamera = true;
  bool _controlsVisible = true;
  bool _remoteIsMuted = false;
  int _elapsed = 0;
  Timer? _timer;
  Timer? _controlsTimer;

  // ── PiP drag ────────────────────────────────────────────────────
  double _pipX = 0;
  double _pipY = 0;
  bool _pipInitialized = false;

  // ── Animations ──────────────────────────────────────────────────
  late AnimationController _pulseCtrl;
  late AnimationController _controlsFadeCtrl;
  late Animation<double> _pulse1, _pulse2, _pulse3;
  late Animation<double> _controlsFade;

  bool get _isVideo => widget.callType == 'video';

  static const _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
  };

  // ── Lifecycle ───────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    SocketIndex.setCallActive(true);
    _initAnimations();
    _init();
  }

  void _initAnimations() {
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    _pulse1 = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _pulseCtrl,
        curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
      ),
    );
    _pulse2 = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _pulseCtrl,
        curve: const Interval(0.2, 0.9, curve: Curves.easeOut),
      ),
    );
    _pulse3 = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _pulseCtrl,
        curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
      ),
    );

    _controlsFadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 1.0,
    );
    _controlsFade = CurvedAnimation(
      parent: _controlsFadeCtrl,
      curve: Curves.easeInOut,
    );
  }

  Future<void> _init() async {
    _roomId = widget.roomId;
    _conversationId = widget.conversationId;
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    _registerSocketListeners();
    if (widget.isOutgoing) {
      setState(() => _callState = CallState.calling);
      await _startOutgoingCall();
    } else {
      setState(() => _callState = CallState.incoming);
      // ← ADD: notify caller that we're ringing
      try {
        SocketEvents.emitCallRinging(toUserId: widget.remoteUserId);
      } catch (_) {}
      if (widget.autoAnswer && widget.incomingOffer != null) {
        // iOS: wait for CallKit to fully release the audio session to WebRTC
        if (Platform.isIOS) {
          await Future.delayed(const Duration(milliseconds: 400));
        }
        await _answerCall();
      }
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controlsTimer?.cancel();
    _pulseCtrl.dispose();
    _controlsFadeCtrl.dispose();
    SocketIndex.setCallActive(false);
    _cleanupPC();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    SocketEvents.offCallAnswered();
    SocketEvents.offCallEnded();
    SocketEvents.offIceCandidate();
    SocketEvents.offCallRinging();
    SocketEvents.offCallUnavailableWait();
    SocketEvents.offCallRingingNow();
    NotificationService().endAllCalls();
    super.dispose();
  }

  // ── Socket ──────────────────────────────────────────────────────

  void _registerSocketListeners() {
    SocketEvents.onCallRinging((_) {
      if (!mounted) return;
      if (_callState == CallState.calling) {
        setState(() => _callState = CallState.ringing);
      }
    });

    SocketEvents.onCallAnswered((data) async {
      if (!mounted) return;
      final map = Map<String, dynamic>.from(data as Map);
      await _applyAnswer(map['answer'] as Map<String, dynamic>);
    });

    SocketEvents.onCallEnded((_) {
      if (!mounted) return;
      _handleRemoteHangup();
    });

    SocketEvents.onIceCandidate((data) async {
      if (!mounted) return;
      final map = Map<String, dynamic>.from(data as Map);
      final c = map['candidate'] as Map<String, dynamic>;
      final candidate = RTCIceCandidate(
        c['candidate'] as String,
        c['sdpMid'] as String?,
        (c['sdpMLineIndex'] as num?)?.toInt(),
      );
      if (_remoteDescSet && _pc != null) {
        await _pc!.addCandidate(candidate);
      } else {
        _pendingCandidates.add(candidate);
      }
    });

    SocketEvents.onCallUnavailableWait((data) {
      if (!mounted) return;
      final map = Map<String, dynamic>.from(data as Map);
      if (map['roomId'] != null) {
        _roomId = int.tryParse(map['roomId'].toString());
      }
      if (map['conversationId'] != null) {
        _conversationId = int.tryParse(map['conversationId'].toString());
      }
    });

    SocketEvents.onCallRingingNow((data) {
      if (!mounted) return;
      final map = Map<String, dynamic>.from(data as Map);
      if (map['roomId'] != null) {
        _roomId = int.tryParse(map['roomId'].toString());
      }
      if (map['conversationId'] != null) {
        _conversationId = int.tryParse(map['conversationId'].toString());
      }
      if (_callState == CallState.calling) {
        setState(() => _callState = CallState.ringing);
      }
    });
  }

  // ── WebRTC ──────────────────────────────────────────────────────

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

  Future<RTCPeerConnection> _createPC() async {
    final pc = await createPeerConnection(_iceServers);
    pc.onIceCandidate = (candidate) {
      if (candidate.candidate != null) {
        SocketEvents.emitIceCandidate(
          toUserId: widget.remoteUserId,
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
        setState(() {
          _remoteStream = event.streams[0];
          _remoteRenderer.srcObject = _remoteStream;
        });
      }
    };
    pc.onConnectionState = (state) {
      if (!mounted) return;
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateConnected) {
        Helper.setSpeakerphoneOn(_isSpeakerOn).catchError((_) {});
      }
      if ([
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
        RTCPeerConnectionState.RTCPeerConnectionStateFailed,
        RTCPeerConnectionState.RTCPeerConnectionStateClosed,
      ].contains(state)) {
        _handleRemoteHangup();
      }
    };
    // Answerer side: receive the data channel the caller created
    pc.onDataChannel = (dc) => _setupDataChannel(dc);
    _pc = pc;
    return pc;
  }

  void _setupDataChannel(RTCDataChannel dc) {
    _dataChannel = dc;
    dc.onDataChannelState = (s) {
      if (s == RTCDataChannelState.RTCDataChannelOpen) _sendMyState();
    };
    dc.onMessage = (msg) {
      try {
        final map = jsonDecode(msg.text) as Map<String, dynamic>;
        if (mounted) setState(() => _remoteIsMuted = map['muted'] as bool? ?? false);
      } catch (_) {}
    };
  }

  void _sendMyState() {
    try {
      if (_dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
        _dataChannel!.send(RTCDataChannelMessage(
          jsonEncode({'muted': _isMuted, 'videoOff': _isVideoOff}),
        ));
      }
    } catch (_) {}
  }

  Future<void> _startOutgoingCall() async {
    try {
      _localStream = await _getMedia();
      _localStream?.getAudioTracks().forEach((t) => t.enabled = true);
      _localRenderer.srcObject = _localStream;
      if (mounted) setState(() {});
      final pc = await _createPC();
      _localStream!.getTracks().forEach((t) => pc.addTrack(t, _localStream!));
      // Caller creates the data channel
      try {
        final dc = await pc.createDataChannel('state', RTCDataChannelInit()..ordered = true);
        _setupDataChannel(dc);
      } catch (_) {}
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      SocketEvents.emitCallUser(
        toUserId: widget.remoteUserId,
        offer: {'type': offer.type, 'sdp': offer.sdp},
        callType: widget.callType,
      );
      // Apply answer that may have arrived while we were creating the PC
      if (_pendingAnswer != null) {
        await _applyAnswer(_pendingAnswer!);
        _pendingAnswer = null;
      }
    } catch (e) {
      debugPrint('Error starting call: $e');
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _answerCall() async {
    if (widget.incomingOffer == null) return;
    try {
      _localStream = await _getMedia();
      // Explicitly enable audio — iOS/CallKit may deliver disabled tracks
      _localStream?.getAudioTracks().forEach((t) => t.enabled = true);
      _localRenderer.srcObject = _localStream;
      final pc = await _createPC();
      _localStream!.getTracks().forEach((t) => pc.addTrack(t, _localStream!));
      final offer = RTCSessionDescription(
        widget.incomingOffer!['sdp'] as String,
        widget.incomingOffer!['type'] as String,
      );
      await pc.setRemoteDescription(offer);
      _remoteDescSet = true;
      for (final c in _pendingCandidates) {
        await pc.addCandidate(c);
      }
      _pendingCandidates.clear();
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      SocketEvents.emitAnswerCall(
        toUserId: widget.remoteUserId,
        answer: {'type': answer.type, 'sdp': answer.sdp},
        callType: widget.callType,
        roomId: _roomId,
        conversationId: _conversationId,
      );

      _startTimer();
      try {
        await Helper.setSpeakerphoneOn(_isSpeakerOn);
      } catch (_) {}

      if (mounted) setState(() => _callState = CallState.active);
    } catch (e) {
      debugPrint('Error answering: $e');
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _applyAnswer(Map<String, dynamic> answerMap) async {
    // PC may not be ready yet — cache and apply once _startOutgoingCall creates it
    if (_pc == null) {
      _pendingAnswer = answerMap;
      return;
    }
    try {
      if (_pc!.signalingState !=
          RTCSignalingState.RTCSignalingStateHaveLocalOffer) {
        return;
      }
      await _pc!.setRemoteDescription(
        RTCSessionDescription(
          answerMap['sdp'] as String,
          answerMap['type'] as String,
        ),
      );
      _remoteDescSet = true;
      for (final c in _pendingCandidates) {
        await _pc!.addCandidate(c);
      }
      _pendingCandidates.clear();
      _startTimer();
      try {
        await Helper.setSpeakerphoneOn(_isSpeakerOn);
      } catch (_) {}
      if (mounted) setState(() => _callState = CallState.active);
    } catch (e) {
      debugPrint('Error applying answer: $e');
    }
  }

  void _cleanupPC() {
    _timer?.cancel();
    _dataChannel?.close();
    _dataChannel = null;
    _localStream?.getTracks().forEach((t) => t.stop());
    _localStream?.dispose();
    _localStream = null;
    _remoteStream?.dispose();
    _remoteStream = null;
    _pc?.close();
    _pc = null;
    _localRenderer.srcObject = null;
    _remoteRenderer.srcObject = null;
  }

  // ── Actions ─────────────────────────────────────────────────────

  void _startTimer() {
    _elapsed = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
  }

  void _hangup() {
    final currentState = _callState;
    if (currentState == CallState.ended) return;

    final statusId = currentState == CallState.incoming
        ? 2
        : (currentState == CallState.calling ||
              currentState == CallState.ringing)
        ? 1
        : 5;

    // 1. End CallKit ring FIRST — this stops the ring on both sides
    NotificationService().endAllCalls();
    SocketIndex.notifyCallEnded();

    // 2. Tell other side
    try {
      SocketEvents.emitEndCall(
        toUserId: widget.remoteUserId,
        fromUserId: widget.myUserId,
        statusId: statusId,
        roomId: _roomId,
        conversationId: _conversationId,
      );
    } catch (e) {
      debugPrint('⚠️ emitEndCall error: $e');
    }

    // 3. Cleanup WebRTC
    _cleanupPC();

    // 4. UI
    if (mounted) {
      setState(() => _callState = CallState.ended);
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  void _handleRemoteHangup() {
    if (_callState == CallState.ended) return; // guard double fire

    NotificationService().endAllCalls();
    SocketIndex.notifyCallEnded();
    _cleanupPC();

    if (!mounted) return;
    setState(() => _callState = CallState.ended);
    Future.delayed(const Duration(milliseconds: 800), () {
      if (mounted) Navigator.pop(context);
    });
  }

  void _toggleMute() {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !t.enabled);
    setState(() => _isMuted = !_isMuted);
    _sendMyState();
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
    _sendMyState();
  }

  Future<void> _switchCamera() async {
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    await Helper.switchCamera(track);
    setState(() => _isFrontCamera = !_isFrontCamera);
  }

  void _onTapScreen() {
    if (_callState != CallState.active) return;
    setState(() => _controlsVisible = !_controlsVisible);
    _controlsVisible
        ? _controlsFadeCtrl.forward()
        : _controlsFadeCtrl.reverse();
    _controlsTimer?.cancel();
    if (_controlsVisible) {
      _controlsTimer = Timer(const Duration(seconds: 4), () {
        if (mounted && _callState == CallState.active) {
          setState(() => _controlsVisible = false);
          _controlsFadeCtrl.reverse();
        }
      });
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────

  String get _elapsedLabel {
    final m = (_elapsed ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsed % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get _statusText => switch (_callState) {
    CallState.ringing => 'Ringing…', // ← ADD
    CallState.incoming => 'Incoming ${_isVideo ? 'video' : 'audio'} call',
    CallState.calling => 'Calling…',
    CallState.active => _elapsedLabel,
    CallState.ended => 'Call ended',
    CallState.idle => '',
  };

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

  // ── Build ────────────────────────────────────────────────────────

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
      body: GestureDetector(
        onTap: _onTapScreen,
        child: _isVideo ? _buildVideoCall() : _buildAudioCall(),
      ),
    );
  }

  // ════════════════════════════════════════════════════════════════
  //  AUDIO CALL
  // ════════════════════════════════════════════════════════════════

  Widget _buildAudioCall() {
    final size = MediaQuery.of(context).size;
    final isActive = _callState == CallState.active;
    final isIncoming = _callState == CallState.incoming;
    final isCalling = _callState == CallState.calling;
    final isEnded = _callState == CallState.ended;
    final showPulse = isIncoming || isCalling;

    return Stack(
      children: [
        // ── Background ──
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
                stops: [0.0, 0.5, 1.0],
              ),
            ),
          ),
        ),

        // ── Subtle grid overlay ──
        Positioned.fill(child: CustomPaint(painter: _GridPainter())),

        // ── Avatar + name + status ──
        Positioned.fill(
          child: SafeArea(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Spacer(flex: 2),

                // Avatar with pulse
                if (showPulse)
                  _PulseAvatar(
                    initials: _initials(widget.remoteUserName),
                    color: _avatarColor(widget.remoteUserName),
                    pulse1: _pulse1,
                    pulse2: _pulse2,
                    pulse3: _pulse3,
                    size: 100,
                  )
                else
                  _StaticAvatar(
                    initials: _initials(widget.remoteUserName),
                    color: _avatarColor(widget.remoteUserName),
                    size: 100,
                  ),

                const SizedBox(height: 28),

                Text(
                  widget.remoteUserName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 26,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                  ),
                ),

                const SizedBox(height: 8),

                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 400),
                  child: Text(
                    _statusText,
                    key: ValueKey(_statusText),
                    style: TextStyle(
                      color: isActive
                          ? const Color(0xFF4CAF50)
                          : Colors.white.withOpacity(0.6),
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),

                const Spacer(flex: 3),
              ],
            ),
          ),
        ),

        // ── Controls ──
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isActive) ...[
                    // Active: mute + speaker row above end button
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
                  ] else if (isIncoming) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        _ActionBtn(
                          icon: Icons.call_end_rounded,
                          label: 'Decline',
                          color: const Color(0xFFE53935),
                          onTap: _hangup,
                        ),
                        _ActionBtn(
                          icon: Icons.call_rounded,
                          label: 'Answer',
                          color: const Color(0xFF43A047),
                          onTap: _answerCall,
                        ),
                      ],
                    ),
                  ] else if (isCalling || _callState == CallState.ringing) ...[
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
                    _EndBtn(onTap: _hangup, label: 'Cancel'),
                  ] else if (isEnded) ...[
                    const SizedBox(height: 16),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ════════════════════════════════════════════════════════════════
  //  VIDEO CALL
  // ════════════════════════════════════════════════════════════════

  Widget _buildVideoCall() {
    final size = MediaQuery.of(context).size;
    final isActive = _callState == CallState.active;
    final isIncoming = _callState == CallState.incoming;
    final isCalling = _callState == CallState.calling;
    final showPulse = isIncoming || isCalling;

    // Initialize PiP position (bottom right)
    if (!_pipInitialized) {
      _pipX = size.width - 112;
      _pipY = size.height - 220;
      _pipInitialized = true;
    }

    return Stack(
      children: [
        // ── Remote video fullscreen ──
        if (isActive && _remoteStream != null)
          Positioned.fill(
            child: Stack(
              children: [
                Positioned.fill(
                  child: RTCVideoView(
                    _remoteRenderer,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                ),
                if (_remoteIsMuted)
                  Positioned(
                    bottom: 100,
                    left: 16,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.6),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.mic_off_rounded, color: Color(0xFFE53935), size: 16),
                          const SizedBox(width: 4),
                          Text(
                            widget.remoteUserName,
                            style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          )
        else
          // Pre-call background
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
                  stops: [0.0, 0.5, 1.0],
                ),
              ),
              child: CustomPaint(painter: _GridPainter()),
            ),
          ),

        // ── Blur overlay on remote video when controls visible ──
        if (isActive && _controlsVisible)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withOpacity(0.55),
                    Colors.transparent,
                    Colors.transparent,
                    Colors.black.withOpacity(0.7),
                  ],
                  stops: const [0.0, 0.25, 0.6, 1.0],
                ),
              ),
            ),
          ),

        // ── Pre-call center content ──
        if (!isActive)
          Positioned.fill(
            child: SafeArea(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Spacer(flex: 2),
                  if (showPulse)
                    _PulseAvatar(
                      initials: _initials(widget.remoteUserName),
                      color: _avatarColor(widget.remoteUserName),
                      pulse1: _pulse1,
                      pulse2: _pulse2,
                      pulse3: _pulse3,
                      size: 96,
                    )
                  else
                    _StaticAvatar(
                      initials: _initials(widget.remoteUserName),
                      color: _avatarColor(widget.remoteUserName),
                      size: 96,
                    ),
                  const SizedBox(height: 24),
                  Text(
                    widget.remoteUserName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _statusText,
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 15,
                    ),
                  ),
                  const Spacer(flex: 3),
                ],
              ),
            ),
          ),

        // ── Top bar (name + timer) ──
        if (isActive)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: FadeTransition(
              opacity: _controlsFade,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.remoteUserName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                shadows: [
                                  Shadow(blurRadius: 8, color: Colors.black54),
                                ],
                              ),
                            ),
                            Text(
                              _elapsedLabel,
                              style: const TextStyle(
                                color: Color(0xFF4CAF50),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Flip camera
                      _GlassBtn(
                        icon: Icons.flip_camera_ios_rounded,
                        onTap: _switchCamera,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

        // ── Draggable PiP (local video) ──
        if (isActive || isCalling)
          Positioned(
            left: _pipX,
            top: _pipY,
            child: GestureDetector(
              onPanUpdate: (d) {
                setState(() {
                  _pipX = (_pipX + d.delta.dx).clamp(0.0, size.width - 96);
                  _pipY = (_pipY + d.delta.dy).clamp(0.0, size.height - 128);
                });
              },
              child: Container(
                width: 96,
                height: 128,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withOpacity(0.3),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
                      blurRadius: 12,
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: _isVideoOff
                      ? Container(
                          color: const Color(0xFF1E1E2E),
                          child: const Center(
                            child: Icon(
                              Icons.videocam_off_rounded,
                              color: Colors.white38,
                              size: 24,
                            ),
                          ),
                        )
                      : RTCVideoView(
                          _localRenderer,
                          mirror: _isFrontCamera,
                          objectFit:
                              RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                        ),
                ),
              ),
            ),
          ),

        // ── Bottom controls ──
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: FadeTransition(
            opacity: isActive
                ? _controlsFade
                : const AlwaysStoppedAnimation(1.0),
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                child: isActive
                    ? _buildVideoActiveControls()
                    : isIncoming
                    ? _buildIncomingControls()
                    : _buildCallingControls(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildVideoActiveControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Top row: mute + video toggle + speaker
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.45),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _PillBtn(
                icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
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
              Center(child: _EndBtn(onTap: _hangup)),
            ],
          ),
        ),
        // End call button
      ],
    );
  }

  Widget _buildIncomingControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _ActionBtn(
          icon: Icons.call_end_rounded,
          label: 'Decline',
          color: const Color(0xFFE53935),
          onTap: _hangup,
        ),
        _ActionBtn(
          icon: _isVideo ? Icons.videocam_rounded : Icons.call_rounded,
          label: 'Answer',
          color: const Color(0xFF43A047),
          onTap: _answerCall,
        ),
      ],
    );
  }

  Widget _buildCallingControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.45),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _PillBtn(
                icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
                label: _isMuted ? 'Unmute' : 'Mute',
                active: !_isMuted,
                onTap: _toggleMute,
              ),
              _PillBtn(
                icon: _isSpeakerOn
                    ? Icons.volume_up_rounded
                    : Icons.volume_off_rounded,
                label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
                active: _isSpeakerOn,
                onTap: _toggleSpeaker,
              ),
              _EndBtn(onTap: _hangup, label: 'Cancel'),
            ],
          ),
        ),
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════
//  SHARED WIDGETS
// ════════════════════════════════════════════════════════════════

// Pulsing avatar for incoming/calling state
class _PulseAvatar extends StatelessWidget {
  final String initials;
  final Color color;
  final Animation<double> pulse1, pulse2, pulse3;
  final double size;

  const _PulseAvatar({
    required this.initials,
    required this.color,
    required this.pulse1,
    required this.pulse2,
    required this.pulse3,
    this.size = 96,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * 3,
      height: size * 3,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AnimatedBuilder(
            animation: Listenable.merge([pulse1, pulse2, pulse3]),
            builder: (_, __) => Stack(
              alignment: Alignment.center,
              children: [
                _ring(pulse1, size, 0),
                _ring(pulse2, size, 1),
                _ring(pulse3, size, 2),
              ],
            ),
          ),
          _StaticAvatar(initials: initials, color: color, size: size),
        ],
      ),
    );
  }

  Widget _ring(Animation<double> anim, double base, int i) {
    final s = base + i * base * 0.5;
    return Opacity(
      opacity: (1.0 - anim.value) * 0.4,
      child: Transform.scale(
        scale: 0.85 + anim.value * 0.65,
        child: Container(
          width: s,
          height: s,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xFF7C3AED).withOpacity(0.5),
              width: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

// Static avatar circle
class _StaticAvatar extends StatelessWidget {
  final String initials;
  final Color color;
  final double size;

  const _StaticAvatar({
    required this.initials,
    required this.color,
    required this.size,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color,
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.5),
            blurRadius: 24,
            spreadRadius: 4,
          ),
        ],
      ),
      child: Center(
        child: Text(
          initials,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.33,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

// Meet-style pill button (video call controls bar)
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

// Round button for audio call controls
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

// Red end call button
class _EndBtn extends StatelessWidget {
  final VoidCallback onTap;
  final String label;

  const _EndBtn({required this.onTap, this.label = 'End call'});

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

// Accept / Decline big action buttons
class _ActionBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _ActionBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(0.45),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Icon(icon, color: Colors.white, size: 30),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// Glass icon button (top bar)
class _GlassBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _GlassBtn({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
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
        ),
      ),
    );
  }
}

// Subtle background grid painter
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withOpacity(0.03)
      ..strokeWidth = 0.5;
    const step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) => false;
}
