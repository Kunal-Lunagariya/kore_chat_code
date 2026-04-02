import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../services/notification_service.dart';
import '../../socket/socket_events.dart';
import '../../theme/app_theme.dart';

enum CallState { idle, calling, incoming, active, ended }

class CallScreen extends StatefulWidget {
  final int myUserId;
  final int remoteUserId;
  final String remoteUserName;
  final String callType;
  final bool isOutgoing;
  final Map<String, dynamic>? incomingOffer;

  const CallScreen({
    super.key,
    required this.myUserId,
    required this.remoteUserId,
    required this.remoteUserName,
    required this.callType,
    required this.isOutgoing,
    this.incomingOffer,
  });

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> with TickerProviderStateMixin {
  // ── WebRTC ─────────────────────────────────────────────────────
  RTCPeerConnection? _pc;
  MediaStream? _localStream;
  MediaStream? _remoteStream;
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer _remoteRenderer = RTCVideoRenderer();
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescSet = false;

  // ── UI state ───────────────────────────────────────────────────
  CallState _callState = CallState.calling;
  bool _isMuted = false;
  bool _isSpeakerOn = true;
  bool _isVideoOff = false;
  bool _isFrontCamera = true;
  bool _controlsVisible = true;
  int _elapsed = 0;
  Timer? _timer;
  Timer? _controlsTimer;

  // ── Ripple animation ───────────────────────────────────────────
  late AnimationController _rippleCtrl;
  late Animation<double> _ripple1, _ripple2, _ripple3;

  bool get _isVideo => widget.callType == 'video';

  static const _iceServers = {
    'iceServers': [
      {'urls': 'stun:stun.l.google.com:19302'},
      {'urls': 'stun:stun1.l.google.com:19302'},
    ],
  };

  // ── Lifecycle ──────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _initRipple();
    _init();
  }

  void _initRipple() {
    _rippleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();

    _ripple1 = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _rippleCtrl,
        curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
      ),
    );
    _ripple2 = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _rippleCtrl,
        curve: const Interval(0.2, 0.9, curve: Curves.easeOut),
      ),
    );
    _ripple3 = Tween(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _rippleCtrl,
        curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
      ),
    );
  }

  Future<void> _init() async {
    await _localRenderer.initialize();
    await _remoteRenderer.initialize();
    _registerSocketListeners();
    if (widget.isOutgoing) {
      setState(() => _callState = CallState.calling);
      await _startOutgoingCall();
    } else {
      setState(() => _callState = CallState.incoming);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controlsTimer?.cancel();
    _rippleCtrl.dispose();
    _cleanupPC();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    SocketEvents.offCallAnswered();
    SocketEvents.offCallEnded();
    SocketEvents.offIceCandidate();
    super.dispose();
  }

  // ── Socket listeners ───────────────────────────────────────────

  void _registerSocketListeners() {
    SocketEvents.onCallAnswered((data) async {
      if (!mounted) return;
      final map = Map<String, dynamic>.from(data as Map);
      final answer = map['answer'] as Map<String, dynamic>;
      await _applyAnswer(answer);
    });

    SocketEvents.onCallEnded((_) {
      if (!mounted) return;
      _handleRemoteHangup();
    });

    SocketEvents.onIceCandidate((data) async {
      if (!mounted) return;
      final map = Map<String, dynamic>.from(data as Map);
      final candidateMap = map['candidate'] as Map<String, dynamic>;
      final candidate = RTCIceCandidate(
        candidateMap['candidate'] as String,
        candidateMap['sdpMid'] as String?,
        (candidateMap['sdpMLineIndex'] as num?)?.toInt(),
      );
      if (_remoteDescSet && _pc != null) {
        await _pc!.addCandidate(candidate);
      } else {
        _pendingCandidates.add(candidate);
      }
    });
  }

  // ── WebRTC ─────────────────────────────────────────────────────

  Future<MediaStream> _getMedia() async {
    final constraints = _isVideo
        ? {
            'audio': true,
            'video': {
              'facingMode': 'user',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
            },
          }
        : {'audio': true, 'video': false};
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
      if ([
        RTCPeerConnectionState.RTCPeerConnectionStateDisconnected,
        RTCPeerConnectionState.RTCPeerConnectionStateFailed,
        RTCPeerConnectionState.RTCPeerConnectionStateClosed,
      ].contains(state)) {
        _handleRemoteHangup();
      }
    };
    _pc = pc;
    return pc;
  }

  Future<void> _startOutgoingCall() async {
    try {
      _localStream = await _getMedia();
      _localRenderer.srcObject = _localStream;
      if (mounted) setState(() {});
      final pc = await _createPC();
      _localStream!.getTracks().forEach((t) => pc.addTrack(t, _localStream!));
      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      SocketEvents.emitCallUser(
        toUserId: widget.remoteUserId,
        offer: {'type': offer.type, 'sdp': offer.sdp},
        callType: widget.callType,
      );
    } catch (e) {
      debugPrint('Error starting call: $e');
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _answerIncomingCall() async {
    NotificationService().stopRinging();
    NotificationService().cancelCallNotification();
    if (widget.incomingOffer == null) return;
    try {
      _localStream = await _getMedia();
      _localRenderer.srcObject = _localStream;
      final pc = await _createPC();
      _localStream!.getTracks().forEach((t) => pc.addTrack(t, _localStream!));
      final offer = RTCSessionDescription(
        widget.incomingOffer!['sdp'] as String,
        widget.incomingOffer!['type'] as String,
      );
      await pc.setRemoteDescription(offer);
      _remoteDescSet = true;
      for (final c in _pendingCandidates) await pc.addCandidate(c);
      _pendingCandidates.clear();
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      SocketEvents.emitAnswerCall(
        toUserId: widget.remoteUserId,
        answer: {'type': answer.type, 'sdp': answer.sdp},
        callType: widget.callType,
      );
      _startTimer();
      if (mounted) setState(() => _callState = CallState.active);
    } catch (e) {
      debugPrint('Error answering: $e');
      if (mounted) Navigator.pop(context);
    }
  }

  Future<void> _applyAnswer(Map<String, dynamic> answerMap) async {
    if (_pc == null) return;
    try {
      final answer = RTCSessionDescription(
        answerMap['sdp'] as String,
        answerMap['type'] as String,
      );
      await _pc!.setRemoteDescription(answer);
      _remoteDescSet = true;
      for (final c in _pendingCandidates) await _pc!.addCandidate(c);
      _pendingCandidates.clear();
      _startTimer();
      if (mounted) setState(() => _callState = CallState.active);
    } catch (e) {
      debugPrint('Error applying answer: $e');
    }
  }

  void _cleanupPC() {
    _timer?.cancel();
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

  void _handleRemoteHangup() {
    NotificationService().stopRinging();
    NotificationService().cancelCallNotification();

    _cleanupPC();
    if (!mounted) return;
    setState(() => _callState = CallState.ended);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) Navigator.pop(context);
    });
  }

  // ── Actions ────────────────────────────────────────────────────

  void _startTimer() {
    _elapsed = 0;
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
  }

  void _hangup() {
    NotificationService().stopRinging();
    NotificationService().cancelCallNotification();

    SocketEvents.emitEndCall(
      toUserId: widget.remoteUserId,
      fromUserId: widget.myUserId,
      statusId: _callState == CallState.incoming ? 2 : 5,
    );
    _cleanupPC();
    if (mounted) {
      setState(() => _callState = CallState.ended);
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) Navigator.pop(context);
      });
    }
  }

  void _toggleMute() {
    _localStream?.getAudioTracks().forEach((t) => t.enabled = !t.enabled);
    setState(() => _isMuted = !_isMuted);
  }

  void _toggleSpeaker() {
    setState(() => _isSpeakerOn = !_isSpeakerOn);
    Helper.setSpeakerphoneOn(_isSpeakerOn);
  }

  void _toggleVideo() {
    _localStream?.getVideoTracks().forEach((t) => t.enabled = !t.enabled);
    setState(() => _isVideoOff = !_isVideoOff);
  }

  Future<void> _switchCamera() async {
    final track = _localStream?.getVideoTracks().firstOrNull;
    if (track == null) return;
    await Helper.switchCamera(track);
    setState(() => _isFrontCamera = !_isFrontCamera);
  }

  void _resetControlsTimer() {
    setState(() => _controlsVisible = true);
    _controlsTimer?.cancel();
    if (_callState == CallState.active) {
      _controlsTimer = Timer(const Duration(seconds: 4), () {
        if (mounted) setState(() => _controlsVisible = false);
      });
    }
  }

  // ── Formatters ─────────────────────────────────────────────────

  String get _elapsedLabel {
    final m = (_elapsed ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsed % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get _statusText {
    return switch (_callState) {
      CallState.incoming => 'Incoming ${_isVideo ? 'video' : 'audio'} call',
      CallState.calling => 'Calling…',
      CallState.active => _elapsedLabel,
      CallState.ended => 'Call ended',
      CallState.idle => '',
    };
  }

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

  // ── Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );

    if (_isVideo) return _buildVideoCallScreen();
    return _buildAudioCallPopup();
  }

  // ══════════════════════════════════════════════════════════════
  //  AUDIO CALL — floating popup (matches React AudioCallPopup)
  // ══════════════════════════════════════════════════════════════

  Widget _buildAudioCallPopup() {
    final showRipple =
        _callState == CallState.calling || _callState == CallState.incoming;

    return Scaffold(
      backgroundColor: Colors.black54,
      body: GestureDetector(
        onTap: () {}, // prevent dismiss on tap
        child: Stack(
          children: [
            // Blurred background dismisses on tap
            Positioned.fill(
              child: GestureDetector(
                onTap: () {
                  if (_callState == CallState.ended) Navigator.pop(context);
                },
                child: Container(color: Colors.transparent),
              ),
            ),
            // Popup anchored to bottom center
            Positioned(
              bottom: 96,
              left: 24,
              right: 24,
              child: _AudioPopupCard(
                remoteUserName: widget.remoteUserName,
                callState: _callState,
                statusText: _statusText,
                isMuted: _isMuted,
                isSpeakerOn: _isSpeakerOn,
                showRipple: showRipple,
                ripple1: _ripple1,
                ripple2: _ripple2,
                ripple3: _ripple3,
                rippleCtrl: _rippleCtrl,
                initials: _initials(widget.remoteUserName),
                avatarColor: _avatarColor(widget.remoteUserName),
                elapsedLabel: _elapsedLabel,
                onAnswer: _answerIncomingCall,
                onDecline: _hangup,
                onEnd: _hangup,
                onDismiss: () => Navigator.pop(context),
                onToggleMute: _toggleMute,
                onToggleSpeaker: _toggleSpeaker,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════
  //  VIDEO CALL — fullscreen (matches React VideoCallScreen)
  // ══════════════════════════════════════════════════════════════

  Widget _buildVideoCallScreen() {
    final showRipple =
        _callState == CallState.calling || _callState == CallState.incoming;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _callState == CallState.active ? _resetControlsTimer : null,
        child: Stack(
          children: [
            // ── Remote video (full screen) ──
            if (_callState == CallState.active)
              Positioned.fill(
                child: RTCVideoView(
                  _remoteRenderer,
                  objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                ),
              ),

            // ── Pre-call / ended background ──
            if (_callState != CallState.active)
              Positioned.fill(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF0F172A), Color(0xFF1E1B4B)],
                    ),
                  ),
                  child: SafeArea(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Avatar with ripple when calling/incoming
                        if (showRipple)
                          _RippleAvatar(
                            initials: _initials(widget.remoteUserName),
                            color: _avatarColor(widget.remoteUserName),
                            ripple1: _ripple1,
                            ripple2: _ripple2,
                            ripple3: _ripple3,
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
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _statusText,
                          style: TextStyle(
                            color: _callState == CallState.active
                                ? const Color(0xFF4CAF50)
                                : Colors.white54,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),

            // ── Top gradient scrim ──
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                height: 120,
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black54, Colors.transparent],
                  ),
                ),
              ),
            ),

            // ── Top bar (name + timer + flip camera) ──
            AnimatedOpacity(
              opacity: _controlsVisible ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 400),
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
                              ),
                            ),
                            Text(
                              _statusText,
                              style: TextStyle(
                                color: _callState == CallState.active
                                    ? const Color(0xFF4CAF50)
                                    : Colors.white60,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_callState == CallState.active)
                        GestureDetector(
                          onTap: _switchCamera,
                          child: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.black38,
                              shape: BoxShape.circle,
                              border: Border.all(color: Colors.white24),
                            ),
                            child: const Icon(
                              Icons.flip_camera_ios_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),

            // ── Local video PiP ──
            if (_callState == CallState.active ||
                _callState == CallState.calling)
              Positioned(
                bottom: 120 + MediaQuery.of(context).padding.bottom,
                right: 16,
                child: Container(
                  width: 96,
                  height: 128,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Colors.white30, width: 2),
                    color: Colors.black,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: _isVideoOff
                        ? const Center(
                            child: Icon(
                              Icons.videocam_off_rounded,
                              color: Colors.white38,
                              size: 24,
                            ),
                          )
                        : RTCVideoView(
                            _localRenderer,
                            mirror: _isFrontCamera,
                            objectFit: RTCVideoViewObjectFit
                                .RTCVideoViewObjectFitCover,
                          ),
                  ),
                ),
              ),

            // ── Bottom controls ──
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 400),
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Colors.black87, Colors.transparent],
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
                      child: _callState == CallState.incoming
                          ? _buildIncomingVideoControls()
                          : _callState == CallState.ended
                          ? _buildEndedControls()
                          : _buildActiveVideoControls(),
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

  Widget _buildIncomingVideoControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _CtrlBtn(
          icon: Icons.call_end_rounded,
          label: 'Decline',
          danger: true,
          onTap: _hangup,
        ),
        _CtrlBtn(
          icon: Icons.videocam_rounded,
          label: 'Answer',
          answer: true,
          onTap: _answerIncomingCall,
        ),
      ],
    );
  }

  Widget _buildActiveVideoControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _CtrlBtn(
          icon: _isMuted ? Icons.mic_off_rounded : Icons.mic_rounded,
          label: _isMuted ? 'Unmute' : 'Mute',
          active: !_isMuted,
          onTap: _toggleMute,
        ),
        _CtrlBtn(
          icon: _isVideoOff
              ? Icons.videocam_off_rounded
              : Icons.videocam_rounded,
          label: _isVideoOff ? 'Cam off' : 'Cam on',
          active: !_isVideoOff,
          onTap: _toggleVideo,
        ),
        _CtrlBtn(
          icon: Icons.call_end_rounded,
          label: 'End',
          danger: true,
          onTap: _hangup,
        ),
        _CtrlBtn(
          icon: _isSpeakerOn
              ? Icons.volume_up_rounded
              : Icons.volume_off_rounded,
          label: _isSpeakerOn ? 'Speaker' : 'Earpiece',
          active: _isSpeakerOn,
          onTap: _toggleSpeaker,
        ),
      ],
    );
  }

  Widget _buildEndedControls() {
    return Center(
      child: GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white24),
          ),
          child: const Text(
            'Close',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
//  AUDIO POPUP CARD (matches React AudioCallPopup exactly)
// ══════════════════════════════════════════════════════════════════

class _AudioPopupCard extends StatelessWidget {
  final String remoteUserName;
  final CallState callState;
  final String statusText;
  final bool isMuted;
  final bool isSpeakerOn;
  final bool showRipple;
  final Animation<double> ripple1, ripple2, ripple3;
  final AnimationController rippleCtrl;
  final String initials;
  final Color avatarColor;
  final String elapsedLabel;
  final VoidCallback onAnswer;
  final VoidCallback onDecline;
  final VoidCallback onEnd;
  final VoidCallback onDismiss;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleSpeaker;

  const _AudioPopupCard({
    required this.remoteUserName,
    required this.callState,
    required this.statusText,
    required this.isMuted,
    required this.isSpeakerOn,
    required this.showRipple,
    required this.ripple1,
    required this.ripple2,
    required this.ripple3,
    required this.rippleCtrl,
    required this.initials,
    required this.avatarColor,
    required this.elapsedLabel,
    required this.onAnswer,
    required this.onDecline,
    required this.onEnd,
    required this.onDismiss,
    required this.onToggleMute,
    required this.onToggleSpeaker,
  });

  @override
  Widget build(BuildContext context) {
    final isActive = callState == CallState.active;
    final isIncoming = callState == CallState.incoming;
    final isEnded = callState == CallState.ended;
    final isCalling = callState == CallState.calling;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xF51E1E2E), // ~95% opacity slate-900
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withOpacity(0.12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.5),
            blurRadius: 30,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Top gradient bar (violet → purple → indigo)
          Container(
            height: 4,
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFF7C3AED),
                  Color(0xFF9333EA),
                  Color(0xFF6366F1),
                ],
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Avatar section ──
                if (showRipple)
                  _RippleAvatar(
                    initials: initials,
                    color: avatarColor,
                    ripple1: ripple1,
                    ripple2: ripple2,
                    ripple3: ripple3,
                    size: 72,
                  )
                else
                  _StaticAvatar(
                    initials: initials,
                    color: avatarColor,
                    size: 64,
                  ),

                const SizedBox(height: 16),

                Text(
                  remoteUserName,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  statusText,
                  style: TextStyle(
                    color: isActive ? const Color(0xFF4CAF50) : Colors.white54,
                    fontSize: 13,
                  ),
                ),

                const SizedBox(height: 24),

                // ── Controls ──
                if (isIncoming)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _CtrlBtn(
                        icon: Icons.call_end_rounded,
                        label: 'Decline',
                        danger: true,
                        onTap: onDecline,
                      ),
                      const SizedBox(width: 40),
                      _CtrlBtn(
                        icon: Icons.call_rounded,
                        label: 'Answer',
                        answer: true,
                        onTap: onAnswer,
                      ),
                    ],
                  )
                else if (isCalling || isActive)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _CtrlBtn(
                        icon: isMuted
                            ? Icons.mic_off_rounded
                            : Icons.mic_rounded,
                        label: isMuted ? 'Unmute' : 'Mute',
                        active: !isMuted,
                        onTap: onToggleMute,
                      ),
                      const SizedBox(width: 20),
                      _CtrlBtn(
                        icon: Icons.call_end_rounded,
                        label: 'End',
                        danger: true,
                        onTap: isCalling ? onDecline : onEnd,
                      ),
                      const SizedBox(width: 20),
                      _CtrlBtn(
                        icon: isSpeakerOn
                            ? Icons.volume_up_rounded
                            : Icons.volume_off_rounded,
                        label: isSpeakerOn ? 'Speaker' : 'Earpiece',
                        active: isSpeakerOn,
                        onTap: onToggleSpeaker,
                      ),
                    ],
                  )
                else if (isEnded)
                  GestureDetector(
                    onTap: onDismiss,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.2),
                        ),
                      ),
                      child: const Text(
                        'Dismiss',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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

// ══════════════════════════════════════════════════════════════════
//  SHARED WIDGETS
// ══════════════════════════════════════════════════════════════════

class _RippleAvatar extends StatelessWidget {
  final String initials;
  final Color color;
  final Animation<double> ripple1, ripple2, ripple3;
  final double size;

  const _RippleAvatar({
    required this.initials,
    required this.color,
    required this.ripple1,
    required this.ripple2,
    required this.ripple3,
    this.size = 80,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * 2.8,
      height: size * 2.8,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Ripple rings
          AnimatedBuilder(
            animation: Listenable.merge([ripple1, ripple2, ripple3]),
            builder: (_, __) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  _buildRing(ripple1, size, 0),
                  _buildRing(ripple2, size, 1),
                  _buildRing(ripple3, size, 2),
                ],
              );
            },
          ),
          // Avatar
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [color, color.withBlue((color.blue * 0.7).toInt())],
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(0.5),
                  blurRadius: 20,
                  spreadRadius: 2,
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
          ),
        ],
      ),
    );
  }

  Widget _buildRing(Animation<double> anim, double baseSize, int index) {
    final ringSize = baseSize + index * (baseSize * 0.45);
    return Opacity(
      opacity: (1.0 - anim.value) * 0.5,
      child: Transform.scale(
        scale: 0.8 + anim.value * 0.7,
        child: Container(
          width: ringSize,
          height: ringSize,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(
              color: const Color(0xFF7C3AED).withOpacity(0.4),
              width: 1,
            ),
          ),
        ),
      ),
    );
  }
}

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
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [color, color.withBlue((color.blue * 0.7).toInt())],
        ),
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.4),
            blurRadius: 16,
            spreadRadius: 2,
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

// Control button — matches React CtrlBtn exactly
class _CtrlBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool active;
  final bool danger;
  final bool answer;

  const _CtrlBtn({
    required this.icon,
    required this.label,
    required this.onTap,
    this.active = true,
    this.danger = false,
    this.answer = false,
  });

  @override
  Widget build(BuildContext context) {
    final Color btnColor;
    final Color iconColor;

    if (danger) {
      btnColor = AppTheme.redAccent;
      iconColor = Colors.white;
    } else if (answer) {
      btnColor = const Color(0xFF4CAF50);
      iconColor = Colors.white;
    } else if (!active) {
      btnColor = Colors.white.withOpacity(0.15);
      iconColor = Colors.white60;
    } else {
      btnColor = Colors.white.withOpacity(0.12);
      iconColor = Colors.white;
    }

    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: btnColor,
              borderRadius: BorderRadius.circular(16),
              border: (!danger && !answer)
                  ? Border.all(color: Colors.white.withOpacity(0.1))
                  : null,
              boxShadow: (danger || answer)
                  ? [
                      BoxShadow(
                        color: btnColor.withOpacity(0.4),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Icon(icon, color: iconColor, size: 22),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white60,
              fontSize: 10,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }
}
