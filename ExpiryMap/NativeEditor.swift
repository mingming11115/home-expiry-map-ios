import SwiftUI
import EventKit
import EventKitUI

struct NativeRecordEditor: View {
    @ObservedObject var store: NativeStore
    let existing: ExpiryRecord?
    let scan: LabelScanResult?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: ItemKind
    @State private var room: HomeRoom
    @State private var location: String
    @State private var hasDate: Bool
    @State private var due: Date
    @State private var leadDays: Int
    @State private var notes: String
    @State private var assignee: String
    @State private var confirmed = false
    @State private var error: String?

    init(store: NativeStore, existing: ExpiryRecord?, suggestedRoom: HomeRoom? = nil, scan: LabelScanResult? = nil) {
        self.store = store; self.existing = existing; self.scan = scan
        _name = State(initialValue: existing?.name ?? scan?.suggestedName ?? "")
        _kind = State(initialValue: existing?.kind ?? .food)
        _room = State(initialValue: existing?.room ?? suggestedRoom ?? .kitchen)
        _location = State(initialValue: existing?.location ?? "")
        let day = existing?.dueDate ?? scan?.suggestedDueDate
        _hasDate = State(initialValue: day != nil)
        _due = State(initialValue: day.flatMap { LocalDay.date(from: $0) } ?? Date())
        _leadDays = State(initialValue: existing?.leadDays ?? 3)
        _notes = State(initialValue: existing?.notes ?? "")
        _assignee = State(initialValue: existing?.assignee ?? "我")
    }

    var body: some View {
        NavigationStack {
            Form {
                if let scan {
                    Section {
                        Label("已在本机识别，请核对后保存", systemImage: "text.viewfinder").font(.subheadline)
                        if scan.suggestedDueDate == nil {
                            Text("未找到明确的到期日期。请看包装上的有效期手动填写；生产日期不会自动作为到期日。")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        DisclosureGroup("查看识别文字") { Text(scan.text).font(.footnote).textSelection(.enabled) }
                    }
                }
                Section("物品信息") {
                    TextField("物品或事项名称", text: $name).accessibilityIdentifier("editor.name")
                    Picker("分类", selection: $kind) { ForEach(ItemKind.allCases) { value in Label(value.title, systemImage: value.symbol).tag(value) } }
                    Picker("放在哪里", selection: $room) { ForEach(HomeRoom.allCases) { value in Text(value.title).tag(value) } }
                        .accessibilityIdentifier("editor.room")
                    TextField("具体位置，如冰箱冷藏层", text: $location).accessibilityIdentifier("editor.location")
                }
                Section {
                    Toggle("填写到期日", isOn: $hasDate).accessibilityIdentifier("editor.hasDate")
                    if hasDate {
                        DatePicker("到期日期", selection: $due, in: (LocalDay.date(from: "1900-01-01") ?? .distantPast)...(LocalDay.date(from: "2200-12-31") ?? .distantFuture), displayedComponents: .date)
                            .datePickerStyle(.compact).accessibilityIdentifier("editor.date")
                        Picker("提前提醒", selection: $leadDays) {
                            ForEach(Array(Set([0, 1, 3, 7, 14, 30, 90, leadDays])).sorted(), id: \.self) { day in Text(day == 0 ? "当天" : "提前 \(day) 天").tag(day) }
                        }
                        if scan != nil { Toggle("我已核对包装上的到期日期", isOn: $confirmed).accessibilityIdentifier("editor.confirmDate") }
                    }
                } header: { Text("日期与提醒") } footer: {
                    Text(hasDate ? "开启通知后，按所选日期上午 9 点提醒。已经过去的提醒时间不会补发。" : "可以先保存，之后补上日期；未填写日期的记录不会发送提醒。")
                }
                Section("补充信息") {
                    Picker("谁来留意", selection: $assignee) {
                        ForEach(Array(Set(store.members + [assignee])).sorted(), id: \.self) { name in Text(name).tag(name) }
                    }
                    TextField("备注（选填）", text: $notes, axis: .vertical).lineLimit(3...6).accessibilityIdentifier("editor.notes")
                }
                Section { Label("保存在这台 iPhone，尚未与家人同步", systemImage: "iphone").font(.footnote).foregroundStyle(.secondary) }
            }
            .navigationTitle(existing == nil ? "记一件" : "编辑记录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.bold()
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (scan != nil && hasDate && !confirmed))
                        .accessibilityIdentifier("editor.save")
                }
            }
            .alert("未能保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
        }.tint(HomeStyle.ink).environment(\.locale, Locale(identifier: "zh_CN"))
    }

    private func save() {
        var record = existing ?? ExpiryRecord(name: name)
        record.name = name; record.kind = kind; record.room = room; record.location = location
        record.dueDate = hasDate ? LocalDay.string(from: due) : nil
        record.leadDays = leadDays; record.notes = notes; record.assignee = assignee
        do { try store.upsert(record); dismiss() } catch { self.error = error.localizedDescription }
    }
}

struct NativeRecordDetail: View {
    @ObservedObject var store: NativeStore
    let recordID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var deleting = false
    @State private var renewing = false
    @State private var calendar = false
    @State private var nextDate = Calendar.current.date(byAdding: .day, value: 30, to: Date()) ?? Date()
    @State private var error: String?
    private var record: ExpiryRecord? { store.items.first { $0.id == recordID } }

    var body: some View {
        NavigationStack {
            Group {
                if let item = record {
                    List {
                        Section {
                            VStack(alignment: .leading, spacing: 13) {
                                Image(systemName: item.kind.symbol).font(.largeTitle)
                                    .frame(width: 66, height: 66).background(HomeStyle.color(item.kind), in: RoundedRectangle(cornerRadius: 22))
                                Text(item.name).font(.title2.bold())
                                Text(item.isCompleted ? "已完成" : deadlineText(item)).font(.headline)
                                    .foregroundStyle(item.isCompleted ? Color.secondary : HomeStyle.ink)
                            }.padding(.vertical, 12)
                        }.listRowBackground(HomeStyle.color(item.kind).opacity(0.6))
                        Section("详情") {
                            LabeledContent("分类", value: item.kind.title)
                            LabeledContent("位置", value: item.room.title + (item.location.isEmpty ? "" : " · " + item.location))
                            LabeledContent("到期日", value: item.dueDate ?? "待确认")
                            LabeledContent("谁来留意", value: item.assignee)
                            LabeledContent("提前提醒", value: item.leadDays == 0 ? "当天" : "提前 \(item.leadDays) 天")
                            if !item.notes.isEmpty { Text(item.notes).textSelection(.enabled) }
                        }
                        if item.isCompleted {
                            Section {
                                if let date = item.completedAt { LabeledContent("完成于", value: date.formatted(date: .abbreviated, time: .shortened)) }
                                Button { perform { try store.restore(id: item.id) } } label: { Label("恢复为待处理", systemImage: "arrow.uturn.backward") }
                                    .accessibilityIdentifier("detail.restore")
                            }
                        } else {
                            Section {
                                Button { perform { try store.complete(id: item.id) } } label: {
                                    Label(completionTitle(item.kind), systemImage: "checkmark.circle.fill").font(.headline)
                                }.accessibilityIdentifier("detail.complete")
                                Button { renewing = true } label: { Label("完成并记录下一期", systemImage: "arrow.clockwise") }
                                if item.dueDate != nil {
                                    Button { calendar = true } label: { Label("添加到系统日历", systemImage: "calendar.badge.plus") }
                                }
                            }
                        }
                        Section { Button("删除记录", role: .destructive) { deleting = true }.accessibilityIdentifier("detail.delete") }
                    }
                    .sheet(isPresented: $editing) { NativeRecordEditor(store: store, existing: item) }
                    .sheet(isPresented: $calendar) { NativeCalendarSheet(record: item) }
                } else { ContentUnavailableView("这条记录已移除", systemImage: "tray") }
            }
            .navigationTitle("记录详情").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { if record != nil { Button("编辑") { editing = true }.accessibilityIdentifier("detail.edit") } }
            }
            .alert("删除这条记录？", isPresented: $deleting) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { perform { try store.delete(id: recordID); dismiss() } }
            } message: { Text("删除后无法恢复。你也可以标记完成，保留处理记录。") }
            .alert("操作未完成", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("知道了", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
            .sheet(isPresented: $renewing) {
                NavigationStack {
                    Form {
                        Section { DatePicker("下一次到期", selection: $nextDate, in: Date()...(LocalDay.date(from: "2200-12-31") ?? .distantFuture), displayedComponents: .date).datePickerStyle(.graphical) }
                        Section { Text("当前记录会保存在已完成中，并新增一条下一期记录。").font(.subheadline).foregroundStyle(.secondary) }
                    }
                    .navigationTitle("记录下一期").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { renewing = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("完成并新增") { renewing = false; perform { try store.complete(id: recordID, nextDue: LocalDay.string(from: nextDate)) } }.bold() }
                    }
                }.presentationDetents([.large])
            }
        }.tint(HomeStyle.ink).environment(\.locale, Locale(identifier: "zh_CN"))
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    private func completionTitle(_ kind: ItemKind) -> String {
        switch kind { case .food, .care: return "已用完"; case .service: return "已续费"; case .maintenance: return "已更换"; default: return "已处理" }
    }
}

private struct NativeCalendarSheet: UIViewControllerRepresentable {
    let record: ExpiryRecord
    @Environment(\.dismiss) private var dismiss
    func makeCoordinator() -> Coordinator { Coordinator { dismiss() } }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let controller = EKEventEditViewController()
        let store = EKEventStore()
        controller.eventStore = store; controller.editViewDelegate = context.coordinator
        let event = EKEvent(eventStore: store)
        event.title = record.name; event.location = record.room.title + " " + record.location; event.notes = record.notes
        event.isAllDay = true
        let date = record.dueDate.flatMap { LocalDay.date(from: $0) } ?? Date()
        event.startDate = date; event.endDate = Calendar.current.date(byAdding: .day, value: 1, to: date)
        if let reminder = Calendar.current.date(byAdding: .day, value: -record.leadDays, to: date) { event.addAlarm(EKAlarm(relativeOffset: reminder.timeIntervalSince(date))) }
        controller.event = event
        return controller
    }
    func updateUIViewController(_ uiViewController: EKEventEditViewController, context: Context) {}
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let finish: () -> Void
        init(finish: @escaping () -> Void) { self.finish = finish }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { finish() }
    }
}
