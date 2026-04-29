import Flutter
import UIKit
import PushKit
import AVFoundation
import FirebaseMessaging
import flutter_callkit_incoming
import CallKit

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate, CXCallObserverDelegate {

    private let callObserver = CXCallObserver()
    // MUST be a strong property — if local, ARC deallocates it and VoIP push stops working
    private var voipRegistry: PKPushRegistry!

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        application.registerForRemoteNotifications()

        // Observe CallKit for audio session handoff
        callObserver.setDelegate(self, queue: .main)

        // Register VoIP push — stored as strong property so it survives this function
        voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
        voipRegistry.delegate = self
        voipRegistry.desiredPushTypes = [PKPushType.voIP]

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // ── CXCallObserver — activates audio when call connects ───────

    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        print("📞 CXCall: connected=\(call.hasConnected) ended=\(call.hasEnded)")
        if call.hasConnected && !call.hasEnded {
            activateAudio()
        }
        if call.hasEnded {
            deactivateAudio()
        }
    }

    private func activateAudio() {
        do {
            let s = AVAudioSession.sharedInstance()
            try s.setCategory(.playAndRecord, mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            try s.setActive(true, options: .notifyOthersOnDeactivation)
            print("✅ Audio activated")
        } catch { print("⚠️ Audio activate error: \(error)") }
    }

    private func deactivateAudio() {
        do {
            try AVAudioSession.sharedInstance().setActive(false,
                options: .notifyOthersOnDeactivation)
            print("✅ Audio deactivated")
        } catch { print("⚠️ Audio deactivate error: \(error)") }
    }

    // ── APNs token ────────────────────────────────────────────────

    override func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Foundation.Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
        print("✅ APNs token set")
        super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    }

    override func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("⚠️ APNs failed: \(error)")
    }

    // ── PushKit: VoIP token ───────────────────────────────────────

    func pushRegistry(_ registry: PKPushRegistry,
                      didUpdate pushCredentials: PKPushCredentials,
                      for type: PKPushType) {
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
        print("📱 VoIP token registered: \(token)")
        SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
    }

    func pushRegistry(_ registry: PKPushRegistry,
                      didInvalidatePushTokenFor type: PKPushType) {
        print("⚠️ VoIP token invalidated — will re-register on next launch")
    }

    // ── PushKit: incoming VoIP call ───────────────────────────────

    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {

        let p = payload.dictionaryPayload
        print("📦 VoIP payload: \(p)")

        // callerName is always required
        guard let callerName = p["callerName"] as? String, !callerName.isEmpty else {
            print("⚠️ VoIP: missing callerName — cannot show CallKit")
            completion()
            return
        }

        // callType: backend may send "callType" string OR "hasVideo" bool
        let callType: String
        if let ct = p["callType"] as? String, !ct.isEmpty {
            callType = ct
        } else if let hv = p["hasVideo"] as? Bool {
            callType = hv ? "video" : "audio"
        } else {
            callType = "audio"
        }

        // callerId: backend may send "callerId" (user id) or "callId" (room id)
        let callerIdStr = (p["callerId"] as? String)
            ?? (p["callId"]   as? String)
            ?? "0"

        // offer: backend must include "offerJson" or "offer"
        let offerJson = (p["offerJson"] as? String)
            ?? (p["offer"]    as? String)
            ?? ""

        print("📞 VoIP: caller=\(callerName) type=\(callType) id=\(callerIdStr) offerEmpty=\(offerJson.isEmpty)")

        let uuid = UUID().uuidString
        let isVideo = callType == "video"

        activateAudio()

        let callData = flutter_callkit_incoming.Data(
            id: uuid,
            nameCaller: callerName,
            handle: callerName,
            type: isVideo ? 1 : 0
        )
        callData.appName  = "Kore Circle"
        callData.duration = 45000
        callData.extra    = [
            "callerId":   callerIdStr,
            "callerName": callerName,
            "callType":   callType,
            "offerJson":  offerJson,
            "callTimestamp": String(Int(Date().timeIntervalSince1970 * 1000)),
        ]
        callData.iconName                              = "AppIcon"
        callData.handleType                            = "generic"
        callData.supportsVideo                         = isVideo
        callData.maximumCallGroups                     = 1
        callData.maximumCallsPerCallGroup              = 1
        callData.audioSessionMode                      = "voiceChat"
        callData.audioSessionActive                    = true
        callData.audioSessionPreferredSampleRate       = 44100.0
        callData.audioSessionPreferredIOBufferDuration = 0.005
        callData.supportsDTMF                          = false
        callData.supportsHolding                       = false
        callData.supportsGrouping                      = false
        callData.supportsUngrouping                    = false
        callData.ringtonePath                          = "system_ringtone_default"

        SwiftFlutterCallkitIncomingPlugin.sharedInstance?
            .showCallkitIncoming(callData, fromPushKit: true)

        completion()
    }
}