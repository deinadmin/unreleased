import FirebaseAuth
import FirebaseFirestore
import Foundation
import UIKit
import UserNotifications

#if canImport(FirebaseMessaging)
import FirebaseMessaging
#endif

/// Posted (with `ownerID`/`projectID` in `userInfo`) when the user taps a
/// project-invite push notification, so `ContentView` can route to the invite.
extension Notification.Name {
    static let projectInviteTapped = Notification.Name("projectInviteTapped")
}

enum PushUserInfoKey {
    static let ownerID = "ownerID"
    static let projectID = "projectID"
}

/// Owns push-notification registration, permission prompts, and FCM token storage.
///
/// FCM integration is compiled in only when the `FirebaseMessaging` package is
/// added to the target. Without it the app still requests authorization and
/// registers for APNs, but tokens won't be uploaded (so the Cloud Function has
/// nothing to send to until the dependency is added).
final class PushNotificationManager: NSObject {
    static let shared = PushNotificationManager()

    /// Requests notification permission and registers for remote notifications.
    /// Safe to call multiple times (e.g. after sign-in).
    func registerForPushNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if let error { print("PushNotificationManager: auth error — \(error)") }
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    /// Persists the current push token to the signed-in user's private doc so the
    /// Cloud Function can look it up. No-op until a token and a signed-in user exist.
    func uploadToken(_ token: String) {
        guard let uid = Auth.auth().currentUser?.uid else { return }
        let ref = CloudPaths.userPrivateDocument(userID: uid, docID: "push")
        ref.setData([
            "fcmToken": token,
            "platform": "ios",
            "updatedAt": Timestamp(date: Date()),
        ], merge: true)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension PushNotificationManager: UNUserNotificationCenterDelegate {
    /// Show the banner even when the app is in the foreground.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .badge, .sound])
    }

    /// Route a tapped invite to the deep-link handler.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let ownerID = userInfo[PushUserInfoKey.ownerID] as? String,
           let projectID = userInfo[PushUserInfoKey.projectID] as? String {
            NotificationCenter.default.post(
                name: .projectInviteTapped,
                object: nil,
                userInfo: [
                    PushUserInfoKey.ownerID: ownerID,
                    PushUserInfoKey.projectID: projectID,
                ]
            )
        }
        completionHandler()
    }
}

#if canImport(FirebaseMessaging)
// MARK: - MessagingDelegate (active when FirebaseMessaging is linked)

extension PushNotificationManager: MessagingDelegate {
    func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        uploadToken(fcmToken)
    }
}
#endif

/// App delegate used via `UIApplicationDelegateAdaptor` to receive APNs callbacks.
final class PushAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = PushNotificationManager.shared
        #if canImport(FirebaseMessaging)
        Messaging.messaging().delegate = PushNotificationManager.shared
        #endif
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        #if canImport(FirebaseMessaging)
        // Hand the APNs token to FCM, which derives and reports an FCM token.
        Messaging.messaging().apnsToken = deviceToken
        #endif
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("PushAppDelegate: remote registration failed — \(error)")
    }
}
