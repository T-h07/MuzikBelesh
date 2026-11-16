import Foundation
import UIKit
import UserNotifications

/// Local notification delivery. Downloads never depend on notification permission.
@MainActor protocol PlaylistAcquisitionNotifying: AnyObject {
    /// Asks once while permission is undetermined; never re-prompts after a decision.
    func requestAuthorizationIfUndetermined() async
    /// `.delivered` only after iOS accepted the request; `.notPermitted` when the user
    /// denied notifications; `.failed` for transient failures (including a permission
    /// decision not yet made), which the caller may retry a bounded number of times.
    func deliver(identifier: String, title: String, body: String, playlistID: String) async -> AcquisitionNotificationDelivery
    var onOpenPlaylist: ((String) -> Void)? { get set }
}

@MainActor final class UserNotificationAcquisitionNotifier: NSObject, PlaylistAcquisitionNotifying, MigrationIssueNotifying, UNUserNotificationCenterDelegate {
    nonisolated static let playlistKey = "playlistID"
    /// Phase 10.7: where a tap should land ("issues" opens Migration Issues).
    nonisolated static let destinationKey = "destination"
    nonisolated static let issuesDestination = "issues"
    private let center: UNUserNotificationCenter
    var onOpenPlaylist: ((String) -> Void)?
    var onOpenIssues: ((String) -> Void)?

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        super.init()
        // Installed during app initialization so a tap that launches the app is delivered.
        center.delegate = self
    }

    func requestAuthorizationIfUndetermined() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    func deliver(identifier: String, title: String, body: String, playlistID: String) async -> AcquisitionNotificationDelivery {
        await schedule(identifier: identifier, title: title, body: body, userInfo: [Self.playlistKey: playlistID])
    }

    /// Same delegate, permission handling and delivery contract as acquisition
    /// notifications; only the tap destination differs.
    func deliverMigrationReport(identifier: String, title: String, body: String, playlistID: String,
                                opensIssues: Bool) async -> AcquisitionNotificationDelivery {
        var info = [Self.playlistKey: playlistID]
        if opensIssues { info[Self.destinationKey] = Self.issuesDestination }
        return await schedule(identifier: identifier, title: title, body: body, userInfo: info)
    }

    private func schedule(identifier: String, title: String, body: String, userInfo: [String: String]) async -> AcquisitionNotificationDelivery {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: break
        case .notDetermined: return .failed
        default: return .notPermitted
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = userInfo
        do {
            try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            return .delivered
        } catch { return .failed }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let playlistID = info[Self.playlistKey] as? String
        let issues = (info[Self.destinationKey] as? String) == Self.issuesDestination
        Task { @MainActor in
            // The coordinators install these handlers during app initialization, before a
            // launch-causing tap is delivered.
            if let playlistID {
                if issues, let open = self.onOpenIssues { open(playlistID) } else { self.onOpenPlaylist?(playlistID) }
            }
            completionHandler()
        }
    }
}

/// Used where no notification delivery is wanted (unit and UI tests by default).
@MainActor final class SilentAcquisitionNotifier: PlaylistAcquisitionNotifying, MigrationIssueNotifying {
    var onOpenPlaylist: ((String) -> Void)?
    var onOpenIssues: ((String) -> Void)?
    func requestAuthorizationIfUndetermined() async {}
    func deliver(identifier: String, title: String, body: String, playlistID: String) async -> AcquisitionNotificationDelivery { .notPermitted }
    func deliverMigrationReport(identifier: String, title: String, body: String, playlistID: String,
                                opensIssues: Bool) async -> AcquisitionNotificationDelivery { .notPermitted }
}

/// Short, bounded app execution while iOS has woken the app (for example after a
/// background URLSession event). Never used to keep the app alive indefinitely.
@MainActor protocol BackgroundExecutionGranting: AnyObject {
    func begin(_ name: String, expired: @escaping @MainActor () -> Void) -> Int?
    func end(_ token: Int)
}

@MainActor final class UIKitBackgroundExecution: BackgroundExecutionGranting {
    private var handlers: [Int: @MainActor () -> Void] = [:]
    func begin(_ name: String, expired: @escaping @MainActor () -> Void) -> Int? {
        let box = BackgroundTaskBox()
        let identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            Task { @MainActor in self?.expire(box.value) }
        }
        guard identifier != .invalid else { return nil }
        box.value = identifier.rawValue
        handlers[identifier.rawValue] = expired
        return identifier.rawValue
    }
    private func expire(_ token: Int) {
        guard let handler = handlers.removeValue(forKey: token) else { return }
        handler()
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
    }
    func end(_ token: Int) {
        guard handlers.removeValue(forKey: token) != nil else { return }
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
    }
}

private final class BackgroundTaskBox: @unchecked Sendable { var value = 0 }
