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

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)
        application.registerForRemoteNotifications()

        // Observe CallKit for audio session handoff
        callObserver.setDelegate(self, queue: .main)

        // Register VoIP push
        let voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
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
        print("📱 VoIP token: \(token)")
        SwiftFlutterCallkitIncomingPlugin.sharedInstance?.setDevicePushTokenVoIP(token)
    }

    // ── PushKit: incoming VoIP call ───────────────────────────────

    func pushRegistry(_ registry: PKPushRegistry,
                      didReceiveIncomingPushWith payload: PKPushPayload,
                      for type: PKPushType,
                      completion: @escaping () -> Void) {

        let p = payload.dictionaryPayload
        print("📦 VoIP payload keys: \(p.keys)")

        guard
            let callerName  = p["callerName"]  as? String,
            let callType    = p["callType"]    as? String,
            let callerIdStr = p["callerId"]    as? String
        else {
            print("⚠️ Missing required VoIP payload fields")
            completion()
            return
        }

        // ← Backend sends 'offer' key — read both to be safe
        let offerJson = (p["offerJson"] as? String)
            ?? (p["offer"] as? String)
            ?? ""

        print("📞 VoIP call from \(callerName), offerJson empty: \(offerJson.isEmpty)")

        let uuid = UUID().uuidString
        let isVideo = callType == "video"

        // Activate audio before showing CallKit (required by Apple)
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
            "offerJson":  offerJson,  // ← store as offerJson for Flutter to read
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

    func pushRegistry(_ registry: PKPushRegistry,
                      didInvalidatePushTokenFor type: PKPushType) {
        print("⚠️ VoIP token invalidated")
    }
}