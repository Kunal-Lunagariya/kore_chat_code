import Flutter
import UIKit
import PushKit
import flutter_callkit_incoming

@main
@objc class AppDelegate: FlutterAppDelegate, PKPushRegistryDelegate {

    override func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        GeneratedPluginRegistrant.register(with: self)

        // Register for VoIP push notifications via PushKit
        let voipRegistry = PKPushRegistry(queue: DispatchQueue.main)
        voipRegistry.delegate = self
        voipRegistry.desiredPushTypes = [PKPushType.voIP]

        return super.application(application, didFinishLaunchingWithOptions: launchOptions)
    }

    // ── PushKit delegate ─────────────────────────────────────────

    func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        // Convert VoIP token to hex string and send to your backend
        let deviceToken = pushCredentials.token
            .map { String(format: "%02x", $0) }
            .joined()
        print("📱 VoIP Push Token: \(deviceToken)")

        // Pass to flutter_callkit_incoming
        SwiftFlutterCallkitIncomingPlugin.sharedInstance?
            .setDevicePushTokenVoIP(deviceToken)
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        // Called when a VoIP push arrives — even when app is killed
        let data = payload.dictionaryPayload

        guard let callerName = data["callerName"] as? String,
              let callType   = data["callType"]   as? String,
              let callerIdStr = data["callerId"] as? String else {
            completion()
            return
        }

        // Show native iOS CallKit UI immediately
        SwiftFlutterCallkitIncomingPlugin.sharedInstance?.showCallkitIncoming(
            flutter_callkit_incoming.CallKitParams(
                id:          UUID().uuidString,
                nameCaller:  callerName,
                appName:     "Kore Circle",
                type:        callType == "video" ? 1 : 0,
                duration:    45000,
                textAccept:  "Accept",
                textDecline: "Decline",
                extra: [
                    "callerId": callerIdStr,
                    "callType": callType,
                ],
                ios: flutter_callkit_incoming.IOSParams(
                    iconName:           "AppIcon",
                    handleType:         "generic",
                    supportsVideo:      callType == "video",
                    maximumCallGroups:  1,
                    maximumCallsPerCallGroup: 1,
                    audioSessionMode:   "default",
                    audioSessionActive: true,
                    audioSessionPreferredSampleRate: 44100.0,
                    audioSessionPreferredIOBufferDuration: 0.005,
                    supportsDTMF:       false,
                    supportsHolding:    false,
                    supportsGrouping:   false,
                    supportsUngrouping: false,
                    ringtonePath:       "system_ringtone_default"
                )
            ),
            fromPushKit: true
        )
        completion()
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        print("⚠️ VoIP Push Token invalidated")
    }
}