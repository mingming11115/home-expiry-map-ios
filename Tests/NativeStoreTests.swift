import Foundation

@main
@MainActor
struct NativeStoreTests {
    static func main() throws {
        let cases: [(String, () throws -> Void)] = [
            ("strict local calendar dates", testDates),
            ("empty store and persisted edits", testPersistence),
            ("failed writes preserve memory", testFailedWrite),
            ("corrupt files cannot be overwritten", testCorruptProtection),
            ("complete and next period are one operation", testComplete),
            ("failed completion preserves both records", testFailedCompletion),
            ("restore and delete persist", testRestoreDelete),
            ("backup merges only new IDs", testImport),
            ("invalid backups make no partial changes", testInvalidImport),
            ("record and household validation", testValidation)
        ]
        var failures: [String] = []
        for (name, test) in cases {
            do { try test(); print("PASS: \(name)") }
            catch { failures.append("\(name): \(error)"); print("FAIL: \(name): \(error)") }
        }
        if !failures.isEmpty {
            FileHandle.standardError.write(Data((failures.joined(separator: "\n") + "\n").utf8))
        }
        try expect(failures.isEmpty, "\(failures.count) test groups failed")
        print("PASS: all \(cases.count) NativeStore groups; time zone \(Calendar.current.timeZone.identifier)")
    }

    static func testDates() throws {
        for value in ["2028-02-29", "1900-01-01", "2200-12-31"] {
            let date = try unwrap(LocalDay.date(from: value), "valid day \(value)")
            try expect(LocalDay.string(from: date) == value, "local date round trip")
        }
        for value in ["2025-02-29", "1900-02-29", "2026-04-31", "2026-13-01", "2026-01-00", "2026-1-01", "1899-12-31", "2201-01-01", "２０２６-01-01"] {
            try expect(LocalDay.date(from: value) == nil, "reject invalid date \(value)")
        }
        try expect(LocalDay.adding(1, to: "2028-02-28") == "2028-02-29", "leap day increment")
        try expect(LocalDay.adding(1, to: "2026-12-31") == "2027-01-01", "year rollover")
        try expect(LocalDay.adding(1, to: "2200-12-31") == nil, "upper date bound")
        try expect(LocalDay.adding(-1, to: "1900-01-01") == nil, "lower date bound")
        let day = try unwrap(LocalDay.date(from: "2026-03-08"), "DST start day")
        try expect(LocalDay.daysUntil("2026-03-09", now: day.addingTimeInterval(12 * 3600)) == 1, "day count ignores partial days and DST")
        try expect(LocalDay.daysUntil("2026-03-07", now: day) == -1, "past day count")
    }

    static func testPersistence() throws {
        try withDirectory { dir in
            let url = dir.appendingPathComponent("nested/store.json")
            let store = NativeStore(fileURL: url)
            try expect(store.items.isEmpty && store.loadError == nil, "starts with zero records")
            try expect(store.familyName == "我的家" && store.members == ["我"], "initial household")
            var item = ExpiryRecord(name: "牛奶", dueDate: "2026-10-10")
            try store.upsert(item)
            item.notes = "冷藏"
            try store.upsert(item)
            try store.renameFamily("  小家  ")
            try store.setMembers(["我", "家人"])
            let reopened = NativeStore(fileURL: url)
            try expect(reopened.loadError == nil && reopened.items == [item], "save, edit and reopen preserve data")
            try expect(reopened.familyName == "小家" && reopened.members == ["我", "家人"], "household edits persist")
        }
    }

    static func testFailedWrite() throws {
        try withDirectory { dir in
            let parent = dir.appendingPathComponent("parent")
            let store = NativeStore(fileURL: parent.appendingPathComponent("store.json"))
            let item = ExpiryRecord(name: "原记录", completedAt: Date())
            try store.upsert(item)
            let other = NativeStore(fileURL: dir.appendingPathComponent("other.json"))
            try other.upsert(ExpiryRecord(name: "待合并记录"))
            let backup = try other.exportData()
            try obstruct(parent, in: dir)
            try expectThrows { try store.upsert(ExpiryRecord(name: "不能保存")) }
            try expectThrows { try store.renameFamily("不能保存的家") }
            try expectThrows { try store.setMembers(["新成员"]) }
            try expectThrows { try store.restore(id: item.id) }
            try expectThrows { try store.delete(id: item.id) }
            try expectThrows { _ = try store.importData(backup) }
            try expect(store.items == [item] && store.familyName == "我的家" && store.members == ["我"], "all failed saves leave published state unchanged")
        }
    }

    static func testCorruptProtection() throws {
        try withDirectory { dir in
            let url = dir.appendingPathComponent("store.json")
            let original = Data("{broken json".utf8)
            try original.write(to: url)
            let store = NativeStore(fileURL: url)
            try expect(store.loadError != nil && store.items.isEmpty, "reports corruption")
            try expectThrows { try store.upsert(ExpiryRecord(name: "不能覆盖")) }
            try expectThrows { try store.renameFamily("不能覆盖") }
            try expectThrows { _ = try store.exportData() }
            let healthy = NativeStore(fileURL: dir.appendingPathComponent("healthy.json"))
            try expectThrows { _ = try store.importData(healthy.exportData()) }
            try expect(try Data(contentsOf: url) == original, "preserves the damaged file")
        }
    }

    static func testComplete() throws {
        try withDirectory { dir in
            let url = dir.appendingPathComponent("store.json")
            let store = NativeStore(fileURL: url)
            let original = ExpiryRecord(name: "滤芯", kind: .maintenance, room: .kitchen, location: "水槽下", dueDate: "2026-10-10", notes: "型号 A", assignee: "我")
            try store.upsert(original)
            try store.complete(id: original.id, nextDue: "2027-01-10")
            let done = try unwrap(store.items.first { $0.id == original.id }, "completed record")
            let next = try unwrap(store.items.first { $0.id != original.id }, "next period")
            try expect(done.isCompleted && done.dueDate == original.dueDate, "completion keeps original date")
            try expect(!next.isCompleted && next.dueDate == "2027-01-10" && next.name == original.name && next.kind == original.kind && next.room == original.room && next.location == original.location && next.notes == original.notes, "next period has a fresh identity and copied fields")
            try expectThrows { try store.complete(id: original.id, nextDue: "2027-04-10") }
            try expect(store.items.count == 2, "repeat completion cannot duplicate next period")
            try expect(NativeStore(fileURL: url).items == store.items, "both changes persist together")
        }
    }

    static func testFailedCompletion() throws {
        try withDirectory { dir in
            let parent = dir.appendingPathComponent("parent")
            let store = NativeStore(fileURL: parent.appendingPathComponent("store.json"))
            let item = ExpiryRecord(name: "滤芯", dueDate: "2026-10-10")
            try store.upsert(item)
            try expectThrows { try store.complete(id: item.id, nextDue: "2026-02-30") }
            try expect(store.items == [item], "invalid next date cannot complete original")
            try obstruct(parent, in: dir)
            try expectThrows { try store.complete(id: item.id, nextDue: "2027-01-10") }
            try expect(store.items == [item], "write failure cannot partially complete or insert")
        }
    }

    static func testRestoreDelete() throws {
        try withDirectory { dir in
            let url = dir.appendingPathComponent("store.json")
            let store = NativeStore(fileURL: url)
            let item = ExpiryRecord(name: "药品")
            try store.upsert(item)
            try store.complete(id: item.id, nextDue: nil)
            try store.restore(id: item.id)
            try expect(store.items == [item], "restore clears completion")
            try store.delete(id: item.id)
            try expect(NativeStore(fileURL: url).items.isEmpty, "deletion persists")
            try expectThrows { try store.complete(id: UUID(), nextDue: nil) }
        }
    }

    static func testImport() throws {
        try withDirectory { dir in
            let local = NativeStore(fileURL: dir.appendingPathComponent("local.json"))
            let remote = NativeStore(fileURL: dir.appendingPathComponent("remote.json"))
            let item = ExpiryRecord(name: "本机版本")
            try local.upsert(item)
            var conflict = item
            conflict.name = "备份版本"
            try remote.upsert(conflict)
            let newItem = ExpiryRecord(name: "新记录")
            try remote.upsert(newItem)
            try remote.renameFamily("备份的家")
            try remote.setMembers(["别人"])
            let backup = try remote.exportData()
            let count = try local.importData(backup)
            try expect(count == 1 && local.items == [item, newItem], "only unseen IDs are appended")
            try expect(local.familyName == "我的家" && local.members == ["我"], "import preserves household settings")
            try expect(try local.importData(backup) == 0, "repeated import is idempotent")
        }
    }

    static func testInvalidImport() throws {
        try withDirectory { dir in
            let url = dir.appendingPathComponent("store.json")
            let store = NativeStore(fileURL: url)
            let item = ExpiryRecord(name: "保留")
            try store.upsert(item)
            let before = try Data(contentsOf: url)
            var object = try JSONSerialization.jsonObject(with: store.exportData()) as! [String: Any]
            object["schemaVersion"] = 999
            let future = try JSONSerialization.data(withJSONObject: object)
            try expectThrows { _ = try store.importData(future) }
            try expectThrows { _ = try store.importData(Data(repeating: 32, count: 5 * 1024 * 1024 + 1)) }
            object["schemaVersion"] = 1
            let record = (object["items"] as! [[String: Any]])[0]
            object["items"] = [record, record]
            try expectThrows { _ = try store.importData(JSONSerialization.data(withJSONObject: object)) }
            object["items"] = [record, ["id": UUID().uuidString, "name": "字段不完整"]]
            try expectThrows { _ = try store.importData(JSONSerialization.data(withJSONObject: object)) }
            object["items"] = (0..<10_001).map { _ in
                var copy = record
                copy["id"] = UUID().uuidString
                return copy
            }
            let tooMany = try JSONSerialization.data(withJSONObject: object)
            try expect(tooMany.count < 5 * 1024 * 1024, "count-limit fixture stays under byte limit")
            try expectThrows { _ = try store.importData(tooMany) }
            try expect(store.items == [item] && (try Data(contentsOf: url)) == before, "invalid imports do not change memory or disk")
            try future.write(to: url)
            let incompatible = NativeStore(fileURL: url)
            try expect(incompatible.loadError != nil, "unknown on-disk schema is protected")
            try expectThrows { try incompatible.upsert(ExpiryRecord(name: "不能覆盖")) }
            let oversized = Data(repeating: 32, count: 5 * 1024 * 1024 + 1)
            try oversized.write(to: url)
            let oversizedStore = NativeStore(fileURL: url)
            try expect(oversizedStore.loadError != nil, "oversized files are protected")
            try expectThrows { try oversizedStore.upsert(ExpiryRecord(name: "不能覆盖")) }
            try expect(try Data(contentsOf: url) == oversized, "oversized original remains untouched")
        }
    }

    static func testValidation() throws {
        try withDirectory { dir in
            let store = NativeStore(fileURL: dir.appendingPathComponent("store.json"))
            for item in [ExpiryRecord(name: "  "), ExpiryRecord(name: "名称", dueDate: "2026-02-30"), ExpiryRecord(name: "名称", leadDays: -1), ExpiryRecord(name: "名称", leadDays: 366), ExpiryRecord(name: String(repeating: "长", count: 121))] {
                try expectThrows { try store.upsert(item) }
            }
            try expectThrows { try store.renameFamily(" ") }
            try expectThrows { try store.setMembers([]) }
            try expectThrows { try store.setMembers(["我", " 我 "]) }
            try expect(store.items.isEmpty, "validation does not mutate store")
        }
    }

    static func withDirectory(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("NativeStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    static func obstruct(_ parent: URL, in dir: URL) throws {
        try FileManager.default.moveItem(at: parent, to: dir.appendingPathComponent("saved"))
        try Data("regular file blocks directory creation".utf8).write(to: parent)
    }

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }

    static func expectThrows(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw Failure(message: "expected operation to fail")
    }

    static func unwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw Failure(message: message) }
        return value
    }

    struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}
