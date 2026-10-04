import Foundation

struct CalendarDraft {
    let title: String
    let location: String
    let notes: String
    let startDate: Date
    let endDate: Date
    let reminderOffset: TimeInterval?

    /// Parses the single all-day event exported by the web app, not arbitrary calendars.
    static func parse(_ text: String) throws -> CalendarDraft {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains("\r") else { throw ParseError.invalidCalendar }
        var lines: [String] = []
        for line in normalized.components(separatedBy: "\n") {
            if line.unicodeScalars.first?.value == 32 || line.unicodeScalars.first?.value == 9 {
                guard !lines.isEmpty else { throw ParseError.invalidCalendar }
                lines[lines.count - 1] += String(line.unicodeScalars.dropFirst())
            } else if !line.isEmpty {
                lines.append(line)
            }
        }

        var components: [String] = []
        var sawCalendar = false
        var sawEvent = false
        var sawAlarm = false
        var fields: [String: String] = [:]
        var trigger: String?
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw ParseError.invalidCalendar }
            let header = String(line[..<colon]).uppercased()
            let value = String(line[line.index(after: colon)...])
            let name = String(header.split(separator: ";", omittingEmptySubsequences: false).first ?? "")
            if header == "BEGIN" {
                let component = value.uppercased()
                switch component {
                case "VCALENDAR" where components.isEmpty && !sawCalendar:
                    sawCalendar = true
                case "VEVENT" where components == ["VCALENDAR"] && !sawEvent:
                    sawEvent = true
                case "VALARM" where components == ["VCALENDAR", "VEVENT"] && !sawAlarm:
                    sawAlarm = true
                default:
                    throw ParseError.invalidCalendar
                }
                components.append(component)
            } else if header == "END" {
                guard components.last == value.uppercased() else { throw ParseError.invalidCalendar }
                components.removeLast()
            } else {
                guard !components.isEmpty else { throw ParseError.invalidCalendar }
                if components.last == "VEVENT" {
                    switch name {
                    case "DTSTART", "DTEND":
                        guard header == "\(name);VALUE=DATE" else { throw ParseError.unsupportedDate }
                    case "SUMMARY", "LOCATION", "DESCRIPTION":
                        guard header == name else { throw ParseError.invalidCalendar }
                    default:
                        continue
                    }
                    guard fields[name] == nil else { throw ParseError.invalidCalendar }
                    fields[name] = value
                } else if components.last == "VALARM", name == "TRIGGER" {
                    guard header == "TRIGGER", trigger == nil else { throw ParseError.invalidReminder }
                    trigger = value
                }
            }
        }
        guard sawCalendar, sawEvent, components.isEmpty,
              let start = fields["DTSTART"], let end = fields["DTEND"] else {
            throw ParseError.invalidCalendar
        }

        // ICS DATE values are Gregorian even if the device uses another calendar.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Calendar.current.timeZone
        let startDate = try parseDate(start, calendar: calendar)
        let endDate = try parseDate(end, calendar: calendar)
        guard endDate > startDate else { throw ParseError.invalidDate }

        var reminderOffset: TimeInterval?
        if sawAlarm {
            guard let trigger, trigger.hasPrefix("-P"), trigger.hasSuffix("D") else {
                throw ParseError.invalidReminder
            }
            let digits = trigger.dropFirst(2).dropLast()
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  let days = Int(digits),
                  let reminderDate = calendar.date(byAdding: .day, value: -days, to: startDate) else {
                throw ParseError.invalidReminder
            }
            let offset = reminderDate.timeIntervalSince(startDate)
            guard offset.isFinite, offset <= 0 else { throw ParseError.invalidReminder }
            reminderOffset = offset
        }

        return CalendarDraft(
            title: try unescape(fields["SUMMARY"] ?? ""),
            location: try unescape(fields["LOCATION"] ?? ""),
            notes: try unescape(fields["DESCRIPTION"] ?? ""),
            startDate: startDate, endDate: endDate, reminderOffset: reminderOffset
        )
    }

    private static func parseDate(_ value: String, calendar: Calendar) throws -> Date {
        let bytes = Array(value.utf8)
        guard bytes.count == 8, bytes.allSatisfy({ (48...57).contains($0) }),
              let year = Int(value.prefix(4)), year > 0,
              let month = Int(value.dropFirst(4).prefix(2)),
              let day = Int(value.suffix(2)) else { throw ParseError.unsupportedDate }
        let wanted = DateComponents(year: year, month: month, day: day, hour: 0, minute: 0, second: 0)
        guard let date = calendar.date(from: wanted) else { throw ParseError.invalidDate }
        let actual = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        guard actual.year == year, actual.month == month, actual.day == day,
              actual.hour == 0, actual.minute == 0, actual.second == 0 else {
            throw ParseError.invalidDate
        }
        return date
    }

    private static func unescape(_ value: String) throws -> String {
        var result = ""
        var iterator = value.unicodeScalars.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.unicodeScalars.append(character)
                continue
            }
            guard let escaped = iterator.next() else { throw ParseError.invalidCalendar }
            switch escaped {
            case "n", "N": result.append("\n")
            case "\\", ",", ";": result.unicodeScalars.append(escaped)
            default: throw ParseError.invalidCalendar
            }
        }
        return result
    }

    enum ParseError: LocalizedError {
        case invalidCalendar
        case unsupportedDate
        case invalidDate
        case invalidReminder

        var errorDescription: String? {
            switch self {
            case .invalidCalendar: return "日历文件不完整，或包含多个事件。"
            case .unsupportedDate: return "仅支持包含开始和结束日期的全天日历事件。"
            case .invalidDate: return "日历日期无效，请返回记录检查日期。"
            case .invalidReminder: return "无法读取这个日历提醒时间。"
            }
        }
    }
}
