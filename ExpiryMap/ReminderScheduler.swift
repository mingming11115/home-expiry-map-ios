import Combine
import Foundation
import UserNotifications

@MainActor
protocol ReminderNotificationClient {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func pendingRequests() async -> [UNNotificationRequest]
    func removePendingRequests(withIdentifiers identifiers: [String])
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor
final class SystemReminderNotificationClient: ReminderNotificationClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func pendingRequests() async -> [UNNotificationRequest] {
        await center.pendingNotificationRequests()
    }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }
}

@MainActor
final class ReminderScheduler: ObservableObject {
    @Published private(set) var statusText = "尚未开启提醒"
    @Published private(set) var isAuthorized = false
    @Published private(set) var scheduledCount = 0
    @Published private(set) var errorMessage: String?

    private let client: any ReminderNotificationClient
    private var latestItems: [ExpiryRecord] = []
    private var revision: UInt64 = 0
    private var shouldRequestAuthorization = false
    private var syncTask: Task<Void, Never>?

    convenience init() {
        self.init(client: SystemReminderNotificationClient())
    }

    init(client: any ReminderNotificationClient) {
        self.client = client
    }

    func refreshStatus() async {
        if let syncTask { await syncTask.value }
        let observedRevision = revision
        let authorization = await client.authorizationStatus()
        let pending = await client.pendingRequests()
        // Reading settings must not overwrite a newer in-flight sync's state.
        guard revision == observedRevision, syncTask == nil else { return }
        let count = pending.filter { $0.identifier.hasPrefix(ReminderPlan.identifierPrefix) }.count
        publish(authorization, count: Self.allowsNotifications(authorization) ? count : 0,
                failure: isAuthorized ? errorMessage : nil)
    }

    /// Call only from the user's explicit enable-reminders action.
    func enable(items: [ExpiryRecord]) async {
        register(items)
        shouldRequestAuthorization = true
        await synchronizeLatest()
    }

    func enable(store: NativeStore) async {
        guard canRead(store) else { return }
        await enable(items: store.items)
    }

    /// Supply the store's committed items after a successful save. This method
    /// also refreshes future reminders on foregrounding, without a permission prompt.
    func sync(items: [ExpiryRecord]) async {
        register(items)
        await synchronizeLatest()
    }

    func sync(store: NativeStore) async {
        guard canRead(store) else { return }
        await sync(items: store.items)
    }

    private func canRead(_ store: NativeStore) -> Bool {
        guard store.loadError == nil else {
            statusText = "记录读取失败，提醒未更改"
            errorMessage = "本机记录读取失败，已有提醒保持原样。请先恢复备份或修复数据。"
            return false
        }
        return true
    }

    private func register(_ items: [ExpiryRecord]) {
        latestItems = items
        revision &+= 1
    }

    private func synchronizeLatest() async {
        if let syncTask {
            await syncTask.value
            return
        }
        let task = Task { await self.applyLatestPlan() }
        syncTask = task
        await task.value
    }

    private func applyLatestPlan() async {
        defer { syncTask = nil }

        // One worker owns all removals and additions. If a save happens during
        // an awaited system call, restart with the newest snapshot before finishing.
        while true {
            let planRevision = revision
            let items = latestItems
            let mayRequest = shouldRequestAuthorization
            shouldRequestAuthorization = false
            var authorization = await client.authorizationStatus()
            var failure: String?

            if mayRequest && authorization == .notDetermined {
                do {
                    _ = try await client.requestAuthorization(options: [.alert, .badge, .sound])
                } catch {
                    failure = "无法开启通知：\(error.localizedDescription)"
                }
                authorization = await client.authorizationStatus()
            }
            guard revision == planRevision else { continue }

            let pending = await client.pendingRequests()
            guard revision == planRevision else { continue }
            let ownedIDs = pending.map(\.identifier).filter { $0.hasPrefix(ReminderPlan.identifierPrefix) }
            client.removePendingRequests(withIdentifiers: ownedIDs)

            guard Self.allowsNotifications(authorization) else {
                publish(authorization, count: 0, failure: failure)
                return
            }

            let plan = ReminderPlan.make(items: items)
            var count = 0
            for reminder in plan {
                guard revision == planRevision else { break }
                // System operations can take time; do not enqueue a date that
                // passed while earlier requests were being added.
                guard reminder.fireDate > Date() else { continue }
                do {
                    try await client.add(Self.request(for: reminder))
                    count += 1
                } catch {
                    if failure == nil {
                        failure = "部分提醒未能保存，请重试：\(error.localizedDescription)"
                    }
                }
            }
            guard revision == planRevision else { continue }
            publish(authorization, count: count, failure: failure)
            return
        }
    }

    private static func request(for reminder: PlannedReminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "\(reminder.title) · 到期提醒"
        content.body = "打开到期地图，查看并处理这件物品。"
        content.sound = .default

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
    }

    private static func allowsNotifications(_ authorization: UNAuthorizationStatus) -> Bool {
        switch authorization {
        case .authorized, .provisional, .ephemeral: return true
        case .denied, .notDetermined: return false
        @unknown default: return false
        }
    }

    private func publish(_ authorization: UNAuthorizationStatus, count: Int, failure: String?) {
        isAuthorized = Self.allowsNotifications(authorization)
        scheduledCount = count
        errorMessage = failure
        switch authorization {
        case .authorized, .ephemeral:
            statusText = failure == nil ? "已开启 · \(count) 条待提醒" : "提醒同步未完成"
        case .provisional:
            statusText = failure == nil ? "已开启静默提醒 · \(count) 条待提醒" : "提醒同步未完成"
        case .denied:
            statusText = "通知权限已关闭"
            errorMessage = "请在 iPhone「设置 → 通知 → 到期地图」中允许通知。"
        case .notDetermined:
            statusText = "尚未开启提醒"
        @unknown default:
            statusText = "暂时无法使用通知"
            errorMessage = "无法读取通知权限，请稍后重试。"
        }
    }
}
