import Foundation

struct PlannedReminder: Equatable {
    let id: String
    let title: String
    let fireDate: Date
}

enum ReminderPlan {
    static let identifierPrefix = "home-expiry-"

    static func make(items: [ExpiryRecord], now: Date = Date()) -> [PlannedReminder] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let reminders = items.compactMap { item -> PlannedReminder? in
            guard !item.isCompleted,
                  let dueDate = item.dueDate,
                  let dueDay = LocalDay.date(from: dueDate),
                  let dueMorning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dueDay),
                  dueMorning > now,
                  let advanceDay = calendar.date(byAdding: .day, value: -max(0, item.leadDays), to: dueDay),
                  let advanceMorning = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: advanceDay)
            else { return nil }

            // A missed advance reminder falls back to the due morning. Never
            // deliver an immediate burst of historical reminders on launch.
            let fireDate = advanceMorning > now ? advanceMorning : dueMorning
            return PlannedReminder(
                id: identifierPrefix + item.id.uuidString.lowercased(),
                title: item.name,
                fireDate: fireDate
            )
        }
        return Array(reminders.sorted {
            if $0.fireDate == $1.fireDate { return $0.id < $1.id }
            return $0.fireDate < $1.fireDate
        }.prefix(60))
    }
}
