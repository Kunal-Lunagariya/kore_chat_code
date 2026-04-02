import Flutter
import UIKit
import PushKit
import AVFoundation
import FirebaseMessaging
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        // Register for APNs
        application.registerForRemoteNotifications()

        // Register for VoIP push via PushKit
        let voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
        voipRegistry.delegate = self
        voipRegistry.desiredPushTypes = [PKPushType.voIP]

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // ── APNs token — pass to Firebase manually ────────────────────

    override func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Foundation.Data
    ) {
        Messaging.messaging().apnsToken = deviceToken
        print("✅ APNs token set")
        super.application(
            application,
            didRegisterForRemoteNotificationsWithDeviceToken: deviceToken
        )
    }

    override func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("⚠️ APNs registration failed: \(error)")
    }

    // ── PushKit: VoIP token ───────────────────────────────────────

    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        let token = pushCredentials.token
            .map { String(format: "%02x", $0) }
            .joined()
        print("📱 VoIP token: \(token)")
        SwiftFlutterCallkitIncomingPlugin.sharedInstance?
            .setDevicePushTokenVoIP(token)
    }

    // ── PushKit: incoming VoIP call ───────────────────────────────

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        let p = payload.dictionaryPayload

        guard
            let callerName  = p["callerName"]  as? String,
            let callType    = p["callType"]    as? String,
            let callerIdStr = p["callerId"]    as? String
        else {
            completion()
            return
        }

        let offerJson = p["offerJson"] as? String ?? ""
        let uuid      = UUID().uuidString
        let isVideo   = callType == "video"

        // Activate audio before showing CallKit
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true)
        } catch {
            print("⚠️ Audio error: \(error)")
        }

        let callData = flutter_callkit_incoming.Data(
            id:         uuid,
            nameCaller: callerName,
            handle:     callerName,
            type:       isVideo ? 1 : 0
        )
        callData.appName  = "Kore Circle"
        callData.duration = 45000
        callData.extra    = [
            "callerId":   callerIdStr,
            "callerName": callerName,
            "callType":   callType,
            "offerJson":  offerJson,
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

    // ── PushKit: token invalidated ────────────────────────────────

    func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        print("⚠️ VoIP token invalidated")
    }
}