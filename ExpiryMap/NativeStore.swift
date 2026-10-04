import Foundation
import Combine

@MainActor
final class NativeStore: ObservableObject {
    @Published private(set) var items: [ExpiryRecord] = []
    @Published private(set) var familyName = "我的家"
    @Published private(set) var members = ["我"]
    @Published private(set) var loadError: String?

    private let fileURL: URL?
    private static let maximumBytes = 5 * 1024 * 1024
    private static let maximumItems = 10_000

    private struct Document: Codable {
        var schemaVersion = 1
        var familyName: String
        var members: [String]
        var items: [ExpiryRecord]
    }

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ExpiryMap", isDirectory: true)
            .appendingPathComponent("native-store.json")
        guard let url = self.fileURL, url.isFileURL else {
            loadError = "无法访问本机存储位置，未修改任何数据。"
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumBytes else { throw StoreError.tooLarge }
            let document = try Self.decode(Data(contentsOf: url))
            items = document.items
            familyName = document.familyName
            members = document.members
        } catch {
            loadError = "本机数据无法读取，已保护原文件并暂停保存。\(error.localizedDescription)"
        }
    }

    func upsert(_ item: ExpiryRecord) throws {
        var document = try snapshot()
        let value = try Self.validated(item)
        if let index = document.items.firstIndex(where: { $0.id == value.id }) {
            document.items[index] = value
        } else {
            document.items.append(value)
        }
        try commit(document)
    }

    func complete(id: UUID, nextDue: String? = nil) throws {
        var document = try snapshot()
        guard let index = document.items.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
        guard !document.items[index].isCompleted else { throw StoreError.alreadyCompleted }
        let now = Date()
        if let nextDue {
            guard LocalDay.date(from: nextDue) != nil else { throw StoreError.invalid("下一期日期无效。") }
            var next = document.items[index]
            next.id = UUID()
            next.dueDate = nextDue
            next.createdAt = now
            next.completedAt = nil
            document.items.append(next)
        }
        document.items[index].completedAt = now
        try commit(document)
    }

    func restore(id: UUID) throws {
        var document = try snapshot()
        guard let index = document.items.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
        document.items[index].completedAt = nil
        try commit(document)
    }

    func delete(id: UUID) throws {
        var document = try snapshot()
        guard let index = document.items.firstIndex(where: { $0.id == id }) else { throw StoreError.notFound }
        document.items.remove(at: index)
        try commit(document)
    }

    func renameFamily(_ name: String) throws {
        var document = try snapshot()
        document.familyName = name
        try commit(document)
    }

    func setMembers(_ names: [String]) throws {
        var document = try snapshot()
        document.members = names
        try commit(document)
    }

    func exportData() throws -> Data {
        try Self.encode(snapshot())
    }

    /// Imports records only. Local records and household settings always take precedence.
    @discardableResult
    func importData(_ data: Data) throws -> Int {
        var document = try snapshot()
        let incoming = try Self.decode(data)
        let existingIDs = Set(document.items.map(\.id))
        let additions = incoming.items.filter { !existingIDs.contains($0.id) }
        guard !additions.isEmpty else { return 0 }
        document.items.append(contentsOf: additions)
        try commit(document)
        return additions.count
    }

    private func snapshot() throws -> Document {
        guard loadError == nil, fileURL != nil else { throw StoreError.protectedFile }
        return Document(familyName: familyName, members: members, items: items)
    }

    private func commit(_ candidate: Document) throws {
        guard loadError == nil, let url = fileURL else { throw StoreError.protectedFile }
        let document = try Self.validated(candidate)
        let data = try Self.encode(document)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        // Publish only after the entire replacement has reached the filesystem.
        items = document.items
        familyName = document.familyName
        members = document.members
    }

    private static func decode(_ data: Data) throws -> Document {
        guard data.count <= maximumBytes else { throw StoreError.tooLarge }
        return try validated(JSONDecoder().decode(Document.self, from: data))
    }

    private static func encode(_ document: Document) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else { throw StoreError.tooLarge }
        return data
    }

    private static func validated(_ candidate: Document) throws -> Document {
        guard candidate.schemaVersion == 1 else { throw StoreError.unsupportedSchema }
        guard candidate.items.count <= maximumItems else { throw StoreError.tooManyItems }
        var document = candidate
        document.familyName = try text(candidate.familyName, label: "家庭名称", maximum: 80, required: true)
        guard (1...20).contains(candidate.members.count) else { throw StoreError.invalid("家庭成员需要 1 至 20 位。") }
        document.members = try candidate.members.map { try text($0, label: "成员姓名", maximum: 40, required: true) }
        guard Set(document.members).count == document.members.count else { throw StoreError.invalid("成员姓名不能重复。") }
        guard Set(candidate.items.map(\.id)).count == candidate.items.count else { throw StoreError.invalid("备份中存在重复的记录编号。") }
        document.items = try candidate.items.map(validated)
        return document
    }

    private static func validated(_ candidate: ExpiryRecord) throws -> ExpiryRecord {
        var item = candidate
        item.name = try text(item.name, label: "物品名称", maximum: 120, required: true)
        item.location = try text(item.location, label: "存放位置", maximum: 200)
        item.notes = try text(item.notes, label: "备注", maximum: 4_000)
        item.assignee = try text(item.assignee, label: "负责人", maximum: 40, required: true)
        guard (0...365).contains(item.leadDays) else { throw StoreError.invalid("提前提醒天数必须在 0 至 365 之间。") }
        if let dueDate = item.dueDate, LocalDay.date(from: dueDate) == nil {
            throw StoreError.invalid("到期日期须为 1900 至 2200 年的有效日期。")
        }
        guard item.createdAt.timeIntervalSinceReferenceDate.isFinite,
              item.completedAt?.timeIntervalSinceReferenceDate.isFinite != false else { throw StoreError.invalid("记录时间无效。") }
        return item
    }

    private static func text(_ value: String, label: String, maximum: Int, required: Bool = false) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.count <= maximum, !required || !result.isEmpty else {
            throw StoreError.invalid("\(label)\(required ? "不能为空，且" : "")最多 \(maximum) 字。")
        }
        return result
    }

    enum StoreError: LocalizedError {
        case protectedFile
        case unsupportedSchema
        case tooLarge
        case tooManyItems
        case notFound
        case alreadyCompleted
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case .protectedFile: return "现有数据文件无法读取，已暂停保存，避免覆盖原数据。"
            case .unsupportedSchema: return "此备份版本暂不受支持，请使用兼容版本的 App。"
            case .tooLarge: return "数据文件不能超过 5 MB。"
            case .tooManyItems: return "最多可保存 10,000 条记录。"
            case .notFound: return "这条记录已不存在。"
            case .alreadyCompleted: return "这条记录已经完成，未重复创建下一期。"
            case .invalid(let message): return message
            }
        }
    }
}
