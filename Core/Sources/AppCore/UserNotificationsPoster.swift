import Foundation
import UserNotifications

public actor UserNotificationsPoster: NotificationPosting {
    public init() {}

    public func postReviewReady(reviewID: String, title: String, body: String) async {
        await post(identifier: "review-ready-\(reviewID)", reviewID: reviewID, title: title, body: body)
    }

    public func postNeedsYou(reviewID: String, title: String, body: String) async {
        await post(identifier: "needs-you-\(reviewID)", reviewID: reviewID, title: title, body: body)
    }

    private func post(identifier: String, reviewID: String, title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied:
            return
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            guard granted else { return }
        case .authorized, .provisional, .ephemeral:
            break
        @unknown default:
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["reviewID": reviewID]
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        try? await center.add(request)
    }
}
