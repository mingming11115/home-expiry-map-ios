import Foundation
#if REMINDER_SCHEDULER_TESTS
import UserNotifications
#endif

@main
@MainActor
struct ReminderSchedulerTests {
    static func main() async {
        let cases: [(String, () throws -> Void)] = [
            ("lead days and stable notification identity", testLeadDays),
            ("zero lead days uses due morning", testSameDay),
            ("missed advance reminder falls back to due morning", testFallback),
            ("past reminders are never sent immediately", testPast),
            ("completed, undated and invalid records are skipped", testIneligible),
            ("spring DST preserves local nine o'clock", testSpringDST),
            ("autumn DST preserves local nine o'clock", testAutumnDST),
            ("only earliest sixty future reminders are scheduled", testLimit),
            ("equal dates have deterministic ordering", testTies)
        ]
        var failures: [String] = []
        for (name, test) in cases {
            do { try test(); print("PASS: \(name)") }
            catch { failures.append("\(name): \(error)"); print("FAIL: \(name): \(error)") }
        }
        if !failures.isEmpty {
            FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
        }
        guard failures.isEmpty else { exit(1) }
        print("PASS: all \(cases.count) reminder planning groups; time zone \(TimeZone.current.identifier)")
#if REMINDER_SCHEDULER_TESTS
        let schedulerCases: [(String, () async throws -> Void)] = [
            ("sync never asks for notification access", testSyncWithoutPermission),
            ("denied permission is explicit and clears owned requests", testDenied),
            ("authorized sync preserves unrelated notifications", testAuthorizedSync),
            ("enable requests the expected permissions", testEnable),
            ("refresh reports actual pending reminder count", testRefresh),
            ("failed scheduling is visible", testFailure),
            ("newer sync wins while an old add is suspended", testLatestSyncWins),
            ("corrupt store cannot clear existing reminders", testCorruptStoreSync),
            ("corrupt store cannot request permission", testCorruptStoreEnable),
            ("healthy store uses only committed records", testHealthyStore)
        ]
        for (name, test) in schedulerCases {
            do { try await test(); print("PASS: \(name)") }
            catch { failures.append("\(name): \(error)"); print("FAIL: \(name): \(error)") }
        }
        if !failures.isEmpty {
            FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
            exit(1)
        }
        print("PASS: all \(schedulerCases.count) reminder scheduler groups")
#endif
    }

    static func testLeadDays() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let item = ExpiryRecord(id: id, name: "牛奶", dueDate: "2026-10-10", leadDays: 3)
        let plan = ReminderPlan.make(items: [item], now: day(2026, 10, 1))
        try expect(plan.count == 1, "eligible record has a reminder")
        let reminder = try unwrap(plan.first)
        try expect(reminder.id == "home-expiry-00000000-0000-0000-0000-000000000001", "identity must be namespaced and stable")
        try expect(reminder.title.contains("牛奶"), "notification identifies the saved item")
        try expect(reminder.fireDate == day(2026, 10, 7, 9), "three calendar days before due date at 09:00")
    }

    static func testSameDay() throws {
        let plan = ReminderPlan.make(items: [ExpiryRecord(name: "滤芯", dueDate: "2026-10-10", leadDays: 0)], now: day(2026, 10, 10, 8, 59))
        try expect(plan.map(\.fireDate) == [day(2026, 10, 10, 9)], "zero lead time permits today's future morning")
    }

    static func testFallback() throws {
        let item = ExpiryRecord(name: "药品", dueDate: "2026-10-10", leadDays: 7)
        for now in [day(2026, 10, 3, 9), day(2026, 10, 8, 18), day(2026, 10, 10, 8)] {
            let plan = ReminderPlan.make(items: [item], now: now)
            try expect(plan.map(\.fireDate) == [day(2026, 10, 10, 9)], "missed reminder uses future due morning instead of firing immediately")
        }
    }

    static func testPast() throws {
        let items = [
            ExpiryRecord(name: "今天", dueDate: "2026-10-10", leadDays: 0),
            ExpiryRecord(name: "昨天", dueDate: "2026-10-09", leadDays: 3),
            ExpiryRecord(name: "很久以前", dueDate: "1900-01-01", leadDays: 0)
        ]
        for now in [day(2026, 10, 10, 9), day(2026, 10, 10, 12)] {
            try expect(ReminderPlan.make(items: items, now: now).isEmpty, "nothing at or before now can be delivered as a historical reminder")
        }
    }

    static func testIneligible() throws {
        let items = [
            ExpiryRecord(name: "完成", dueDate: "2026-10-10", completedAt: day(2026, 10, 1)),
            ExpiryRecord(name: "未填日期"),
            ExpiryRecord(name: "无效日期", dueDate: "2026-02-30"),
            ExpiryRecord(name: "越界日期", dueDate: "2201-01-01")
        ]
        try expect(ReminderPlan.make(items: items, now: day(2026, 1, 1)).isEmpty, "ineligible records do not create notifications")
    }

    static func testSpringDST() throws {
        let plan = ReminderPlan.make(items: [ExpiryRecord(name: "春天", dueDate: "2026-03-09", leadDays: 2)], now: day(2026, 3, 1))
        let fireDate = try unwrap(plan.first).fireDate
        try expect(fireDate == day(2026, 3, 7, 9), "calendar subtraction must not shift to 08:00 before spring DST")
        if TimeZone.current.identifier == "America/Los_Angeles" {
            try expect(day(2026, 3, 9, 9).timeIntervalSince(fireDate) == 47 * 3600, "fixture crosses a 23-hour day")
        }
    }

    static func testAutumnDST() throws {
        let plan = ReminderPlan.make(items: [ExpiryRecord(name: "秋天", dueDate: "2026-11-02", leadDays: 2)], now: day(2026, 10, 1))
        let fireDate = try unwrap(plan.first).fireDate
        try expect(fireDate == day(2026, 10, 31, 9), "calendar subtraction must not shift to 10:00 before autumn DST")
        if TimeZone.current.identifier == "America/Los_Angeles" {
            try expect(day(2026, 11, 2, 9).timeIntervalSince(fireDate) == 49 * 3600, "fixture crosses a 25-hour day")
        }
    }

    static func testLimit() throws {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let items = (0..<70).reversed().map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: day(2027, 1, 2))!
            return ExpiryRecord(name: "物品 \(offset)", dueDate: formatter.string(from: date), leadDays: 0)
        }
        let plan = ReminderPlan.make(items: items, now: day(2027, 1, 1))
        try expect(plan.count == 60, "leave system notification capacity available")
        try expect(plan.first?.fireDate == day(2027, 1, 2, 9), "closest reminder must survive truncation")
        try expect(plan.last?.fireDate == day(2027, 3, 2, 9), "farthest reminders are deferred")
        try expect(zip(plan, plan.dropFirst()).allSatisfy { $0.fireDate <= $1.fireDate }, "delivery order is chronological")
    }

    static func testTies() throws {
        let first = ExpiryRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "一", dueDate: "2026-10-10")
        let second = ExpiryRecord(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "二", dueDate: "2026-10-10")
        let now = day(2026, 10, 1)
        let forwards = ReminderPlan.make(items: [first, second], now: now)
        let backwards = ReminderPlan.make(items: [second, first], now: now)
        try expect(forwards.count == 2 && forwards == backwards, "same-date ordering is independent of source order")
    }

    static var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = .current
        return result
    }

    static func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw Failure(message: "expected a planned reminder") }
        return value
    }

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}

#if REMINDER_SCHEDULER_TESTS
extension ReminderSchedulerTests {
    static func testSyncWithoutPermission() async throws {
        let client = NotificationFixture(status: .notDetermined)
        let scheduler = ReminderScheduler(client: client)
        await scheduler.sync(items: [futureItem("牛奶")])
        try expect(client.requestedOptions.isEmpty, "background sync cannot trigger permission dialog")
        try expect(!scheduler.isAuthorized && scheduler.scheduledCount == 0, "no access means no active reminders")
        try expect(client.requests.isEmpty, "no notification is added without authorization")
    }

    static func testDenied() async throws {
        let client = NotificationFixture(status: .denied)
        client.requests = [fixtureRequest("home-expiry-obsolete"), fixtureRequest("another-feature")]
        let scheduler = ReminderScheduler(client: client)
        await scheduler.enable(items: [futureItem("牛奶")])
        try expect(client.requestedOptions.isEmpty, "denied permission cannot be requested again")
        try expect(!scheduler.isAuthorized && scheduler.scheduledCount == 0, "denied permission is never presented as enabled")
        try expect(scheduler.errorMessage?.contains("设置") == true, "denial gives actionable settings guidance")
        try expect(client.requests.map(\.identifier) == ["another-feature"], "only this feature's stale notifications are removed")
    }

    static func testAuthorizedSync() async throws {
        let client = NotificationFixture(status: .authorized)
        client.requests = [fixtureRequest("home-expiry-obsolete"), fixtureRequest("another-feature")]
        let scheduler = ReminderScheduler(client: client)
        let item = futureItem("牛奶")
        await scheduler.sync(items: [item])
        try expect(client.requestedOptions.isEmpty, "sync does not request permission when authorized either")
        try expect(scheduler.isAuthorized && scheduler.scheduledCount == 1 && scheduler.errorMessage == nil, "successful sync reports one reminder")
        let expectedID = "home-expiry-" + item.id.uuidString.lowercased()
        try expect(Set(client.requests.map(\.identifier)) == Set(["another-feature", expectedID]), "owned stale requests replaced, other requests preserved")
        let request = try unwrap(client.requests.first { $0.identifier == expectedID })
        let trigger = try unwrap(request.trigger as? UNCalendarNotificationTrigger)
        try expect(!trigger.repeats, "saved expiry generates one notification")
        try expect(trigger.dateComponents.year == 2100 && trigger.dateComponents.month == 10 && trigger.dateComponents.day == 7 && trigger.dateComponents.hour == 9, "system request uses the planned calendar date")
        try expect(request.content.title.contains("牛奶") && request.content.sound != nil, "notification is identifiable and audible")
    }

    static func testEnable() async throws {
        let client = NotificationFixture(status: .notDetermined)
        let scheduler = ReminderScheduler(client: client)
        await scheduler.enable(items: [futureItem("牛奶")])
        try expect(client.requestedOptions == [[.alert, .badge, .sound]], "explicit enable requests alert, badge and sound only")
        try expect(scheduler.isAuthorized && scheduler.scheduledCount == 1, "permission approval is followed by actual scheduling")
        await scheduler.sync(items: [])
        try expect(client.requestedOptions.count == 1 && scheduler.scheduledCount == 0, "later sync does not ask again and clears deleted records")
    }

    static func testRefresh() async throws {
        let client = NotificationFixture(status: .authorized)
        client.requests = [fixtureRequest("home-expiry-existing"), fixtureRequest("another-feature")]
        let scheduler = ReminderScheduler(client: client)
        await scheduler.refreshStatus()
        try expect(scheduler.isAuthorized && scheduler.scheduledCount == 1, "status counts only actual pending owned requests")
        try expect(client.requestedOptions.isEmpty, "viewing settings does not ask for permission")
    }

    static func testFailure() async throws {
        let client = NotificationFixture(status: .authorized)
        client.failAdds = true
        let scheduler = ReminderScheduler(client: client)
        await scheduler.sync(items: [futureItem("牛奶")])
        try expect(scheduler.scheduledCount == 0 && scheduler.errorMessage != nil, "failed add cannot be reported as successfully scheduled")
    }

    static func testLatestSyncWins() async throws {
        let client = NotificationFixture(status: .authorized)
        client.suspendNextAdd = true
        let scheduler = ReminderScheduler(client: client)
        await scheduler.refreshStatus()
        try expect(scheduler.isAuthorized, "authorized scheduler can begin the competing syncs")
        let old = futureItem("旧记录")
        let new = futureItem("新记录")
        let oldSync = Task { await scheduler.sync(items: [old]) }
        await client.waitForSuspendedAdd()
        // This release runs only when the main actor yields inside the newer
        // sync, after the newer desired items have been registered.
        let release = Task { client.releaseSuspendedAdd() }
        await scheduler.sync(items: [new])
        await oldSync.value
        await release.value
        try expect(client.requests.map(\.identifier) == ["home-expiry-" + new.id.uuidString.lowercased()], "older pending system calls cannot leave the old plan installed")
        try expect(scheduler.scheduledCount == 1 && scheduler.errorMessage == nil, "published state corresponds to the newest plan")
    }

    static func testCorruptStoreSync() async throws {
        try await withStore(corrupt: true) { store in
            let client = NotificationFixture(status: .authorized)
            client.requests = [fixtureRequest("home-expiry-existing"), fixtureRequest("another-feature")]
            let scheduler = ReminderScheduler(client: client)
            await scheduler.refreshStatus()
            await scheduler.sync(store: store)
            try expect(client.requests.map(\.identifier) == ["home-expiry-existing", "another-feature"], "placeholder empty items after load failure cannot erase existing reminders")
            try expect(scheduler.scheduledCount == 1 && scheduler.isAuthorized, "failed store read does not imply changed system notification state")
            try expect(scheduler.errorMessage?.contains("读取") == true, "damaged data is reported as a read error")
            try expect(client.requestedOptions.isEmpty, "damaged store sync never asks for permission")
        }
    }

    static func testCorruptStoreEnable() async throws {
        try await withStore(corrupt: true) { store in
            let client = NotificationFixture(status: .notDetermined)
            client.requests = [fixtureRequest("home-expiry-existing")]
            let scheduler = ReminderScheduler(client: client)
            await scheduler.enable(store: store)
            try expect(client.requestedOptions.isEmpty, "damaged store cannot initiate a permission dialog")
            try expect(client.requests.map(\.identifier) == ["home-expiry-existing"], "enable cannot remove reminders when records failed to load")
            try expect(scheduler.errorMessage?.contains("读取") == true, "failed enable explains the local data read problem")
        }
    }

    static func testHealthyStore() async throws {
        try await withStore(corrupt: false) { store in
            let item = futureItem("已保存的牛奶")
            try store.upsert(item)
            let client = NotificationFixture(status: .notDetermined)
            let scheduler = ReminderScheduler(client: client)
            await scheduler.enable(store: store)
            try expect(client.requestedOptions.count == 1 && scheduler.scheduledCount == 1, "healthy committed store can enable reminders")
            try expect(client.requests.map(\.identifier) == ["home-expiry-" + item.id.uuidString.lowercased()], "saved identity reaches the notification plan")
            try store.delete(id: item.id)
            await scheduler.sync(store: store)
            try expect(client.requests.isEmpty && scheduler.scheduledCount == 0, "successful deletion updates the notification plan")
        }
    }

    static func withStore(corrupt: Bool, _ body: (NativeStore) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ReminderStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("store.json")
        if corrupt { try Data("{broken json".utf8).write(to: url) }
        let store = NativeStore(fileURL: url)
        try expect((store.loadError != nil) == corrupt, "fixture must expose the requested store load state")
        try await body(store)
    }

    static func futureItem(_ name: String) -> ExpiryRecord {
        ExpiryRecord(name: name, dueDate: "2100-10-10", leadDays: 3)
    }

    static func fixtureRequest(_ id: String) -> UNNotificationRequest {
        UNNotificationRequest(identifier: id, content: UNMutableNotificationContent(), trigger: nil)
    }
}

@MainActor
private final class NotificationFixture: ReminderNotificationClient {
    var status: UNAuthorizationStatus
    var requests: [UNNotificationRequest] = []
    var requestedOptions: [UNAuthorizationOptions] = []
    var failAdds = false
    var suspendNextAdd = false
    private var suspendedAdd: CheckedContinuation<Void, Never>?
    private var addObserver: CheckedContinuation<Void, Never>?

    init(status: UNAuthorizationStatus) { self.status = status }

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        requestedOptions.append(options)
        status = .authorized
        return true
    }

    func pendingRequests() async -> [UNNotificationRequest] { requests }

    func removePendingRequests(withIdentifiers identifiers: [String]) {
        requests.removeAll { identifiers.contains($0.identifier) }
    }

    func add(_ request: UNNotificationRequest) async throws {
        if failAdds { throw ReminderSchedulerTests.Failure(message: "Fixture notification failure") }
        if suspendNextAdd {
            suspendNextAdd = false
            await withCheckedContinuation { continuation in
                suspendedAdd = continuation
                addObserver?.resume()
                addObserver = nil
            }
        }
        requests.removeAll { $0.identifier == request.identifier }
        requests.append(request)
    }

    func waitForSuspendedAdd() async {
        if suspendedAdd != nil { return }
        await withCheckedContinuation { addObserver = $0 }
    }

    func releaseSuspendedAdd() {
        suspendedAdd?.resume()
        suspendedAdd = nil
    }
}
#endif
