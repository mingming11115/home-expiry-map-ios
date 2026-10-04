import Foundation

enum ItemKind: String, Codable, CaseIterable, Identifiable {
    case food, medicine, care, service, warranty, maintenance
    var id: String { rawValue }
    var title: String {
        switch self {
        case .food: return "食品"
        case .medicine: return "药品"
        case .care: return "护理用品"
        case .service: return "会员服务"
        case .warranty: return "保修"
        case .maintenance: return "定期更换"
        }
    }
    var symbol: String {
        switch self {
        case .food: return "carrot.fill"
        case .medicine: return "pills.fill"
        case .care: return "sparkles"
        case .service: return "creditcard.fill"
        case .warranty: return "shield.lefthalf.filled"
        case .maintenance: return "wrench.and.screwdriver.fill"
        }
    }
}

enum HomeRoom: String, Codable, CaseIterable, Identifiable {
    case kitchen, bath, storage, living, bedroom, service, other
    var id: String { rawValue }
    var title: String {
        switch self {
        case .kitchen: return "厨房"
        case .bath: return "浴室"
        case .storage: return "储物柜"
        case .living: return "客厅"
        case .bedroom: return "卧室"
        case .service: return "家庭服务"
        case .other: return "其他位置"
        }
    }
    var symbol: String {
        switch self {
        case .kitchen: return "fork.knife"
        case .bath: return "shower.fill"
        case .storage: return "shippingbox.fill"
        case .living: return "sofa.fill"
        case .bedroom: return "bed.double.fill"
        case .service: return "creditcard.fill"
        case .other: return "square.grid.2x2.fill"
        }
    }
}

struct ExpiryRecord: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var kind: ItemKind
    var room: HomeRoom
    var location: String
    var dueDate: String?
    var leadDays: Int
    var notes: String
    var assignee: String
    var createdAt: Date
    var completedAt: Date?

    init(id: UUID = UUID(), name: String, kind: ItemKind = .food, room: HomeRoom = .kitchen, location: String = "", dueDate: String? = nil, leadDays: Int = 3, notes: String = "", assignee: String = "我", createdAt: Date = Date(), completedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.room = room
        self.location = location
        self.dueDate = dueDate
        self.leadDays = leadDays
        self.notes = notes
        self.assignee = assignee
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    var isCompleted: Bool { completedAt != nil }
}

enum LocalDay {
    private static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = Calendar.current.timeZone
        return value
    }

    static func string(from date: Date) -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return "" }
        let parts = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard parts.era == 1, let year = parts.year, (1900...2200).contains(year),
              let month = parts.month, let day = parts.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func date(from string: String) -> Date? {
        let bytes = Array(string.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ $0.offset == 4 || $0.offset == 7 || (48...57).contains($0.element) }),
              let year = Int(string.prefix(4)), (1900...2200).contains(year),
              let month = Int(string.dropFirst(5).prefix(2)), let day = Int(string.suffix(2)) else { return nil }
        let cal = calendar
        guard let date = cal.date(from: DateComponents(year: year, month: month, day: day)),
              self.string(from: date) == string else { return nil }
        // A few time zones skip midnight. Preserve the day at its first valid instant.
        return cal.startOfDay(for: date)
    }

    static func daysUntil(_ date: String, now: Date = Date()) -> Int? {
        guard now.timeIntervalSinceReferenceDate.isFinite, let end = self.date(from: date) else { return nil }
        let cal = calendar
        return cal.dateComponents([.day], from: cal.startOfDay(for: now), to: end).day
    }

    static func adding(_ days: Int, to date: String) -> String? {
        // The supported range has fewer than 110,000 days; reject arithmetic overflow.
        guard (-110_000...110_000).contains(days), let start = self.date(from: date),
              let end = calendar.date(byAdding: .day, value: days, to: start) else { return nil }
        let result = string(from: end)
        return result.isEmpty ? nil : result
    }
}
