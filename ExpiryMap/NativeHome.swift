import SwiftUI

enum HomeStyle {
    static let ink = Color(red: 0.065, green: 0.071, blue: 0.08)
    static let background = Color(red: 0.967, green: 0.967, blue: 0.956)
    static let blue = Color(red: 0.65, green: 0.72, blue: 0.97)
    static let purple = Color(red: 0.84, green: 0.68, blue: 0.96)
    static let orange = Color(red: 0.98, green: 0.71, blue: 0.42)
    static let red = Color(red: 0.67, green: 0.19, blue: 0.10)
    static func color(_ kind: ItemKind) -> Color {
        switch kind {
        case .food, .maintenance: return blue.opacity(0.42)
        case .medicine, .warranty: return orange.opacity(0.44)
        case .care, .service: return purple.opacity(0.43)
        }
    }
    static func roomColor(_ room: HomeRoom) -> Color {
        switch room {
        case .kitchen: return blue
        case .bath, .bedroom: return purple.opacity(0.65)
        case .storage, .service: return orange.opacity(0.75)
        default: return Color.white
        }
    }
}

enum HomeSection: String, CaseIterable {
    case recent = "最近", map = "地图", household = "我的家"
    var symbol: String { self == .recent ? "clock" : self == .map ? "square.grid.2x2" : "house" }
}

private struct NewRecordRequest: Identifiable {
    let id = UUID()
    let room: HomeRoom?
    let scan: LabelScanResult?
}

struct NativeRootView: View {
    @StateObject private var store = NativeStore()
    @StateObject private var reminders = ReminderScheduler()
    @Environment(\.scenePhase) private var scenePhase
    @State private var section = HomeSection.recent
    @State private var selectedRoom: HomeRoom?
    @State private var filter = "全部"
    @State private var history = false
    @State private var search = ""
    @State private var newRecord: NewRecordRequest?
    @State private var selectedRecord: ExpiryRecord?
    @State private var showScanner = false
    @State private var pendingScan: LabelScanResult?
    @State private var now = Date()

    private var active: [ExpiryRecord] { store.items.filter { !$0.isCompleted } }
    private var visible: [ExpiryRecord] {
        store.items.filter { item in
            guard item.isCompleted == history else { return false }
            if section == .map, let room = selectedRoom, item.room != room { return false }
            if filter == "食品", item.kind != .food { return false }
            if filter == "健康护理", ![ItemKind.medicine, .care].contains(item.kind) { return false }
            if filter == "家庭服务", ![ItemKind.service, .warranty, .maintenance].contains(item.kind) { return false }
            return search.isEmpty || [item.name, item.location, item.notes, item.assignee, item.room.title].contains { $0.localizedCaseInsensitiveContains(search) }
        }.sorted { a, b in
            if history { return (a.completedAt ?? .distantPast) > (b.completedAt ?? .distantPast) }
            if a.dueDate != b.dueDate { return (a.dueDate ?? "9999") < (b.dueDate ?? "9999") }
            return a.createdAt > b.createdAt
        }
    }
    private var weekCount: Int { active.filter { if let d = $0.dueDate, let n = LocalDay.daysUntil(d, now: now) { return (0..<7).contains(n) }; return false }.count }
    private var overdueCount: Int { active.filter { if let d = $0.dueDate, let n = LocalDay.daysUntil(d, now: now) { return n < 0 }; return false }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let error = store.loadError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.subheadline).padding().background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
                    }
                    if section == .household {
                        NativeSettingsView(store: store, reminders: reminders)
                    } else {
                        titleAndActions
                        if section == .recent && !history && search.isEmpty { summary; weekStrip }
                        if section == .map { roomMap }
                        recordsSection
                    }
                }.padding(.horizontal, 22).padding(.top, 16).padding(.bottom, 26)
            }
            .background(HomeStyle.background)
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
            .tint(HomeStyle.ink)
            .sheet(item: $newRecord) { request in
                NativeRecordEditor(store: store, existing: nil, suggestedRoom: request.room, scan: request.scan)
            }
            .sheet(item: $selectedRecord) { record in
                NativeRecordDetail(store: store, recordID: record.id)
            }
            .sheet(isPresented: $showScanner, onDismiss: {
                if let result = pendingScan {
                    pendingScan = nil
                    newRecord = NewRecordRequest(room: selectedRoom, scan: result)
                }
            }) {
                LabelScannerSheet { result in pendingScan = result; showScanner = false }
            }
            .task { await reminders.refreshStatus(); await reminders.sync(store: store) }
            .onChange(of: store.items) { _, _ in Task { await reminders.sync(store: store) } }
            .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { now = $0 }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { now = Date(); Task { await reminders.refreshStatus(); await reminders.sync(store: store) } }
            }
        }
        .environment(\.locale, Locale(identifier: "zh_CN"))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "house.fill").font(.title3).frame(width: 44, height: 44)
                .background(HomeStyle.blue, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(store.familyName).font(.headline).lineLimit(1)
                Text("到期地图 · 本机保存").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { section = .household } label: {
                Image(systemName: reminders.isAuthorized ? "bell.badge" : "bell").font(.title3)
                    .frame(width: 44, height: 44).background(.white, in: Circle())
            }.accessibilityLabel("提醒设置")
        }.foregroundStyle(HomeStyle.ink)
    }

    private var titleAndActions: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(now.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(section == .map ? "家里的地图" : history ? "完成记录" : "最近到期")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text(".").font(.system(size: 34, weight: .black)).foregroundStyle(HomeStyle.blue)
                }
            }
            HStack(spacing: 10) {
                Button { newRecord = NewRecordRequest(room: selectedRoom, scan: nil) } label: {
                    Label("手动记一件", systemImage: "plus").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 15)
                }.background(.white, in: Capsule()).accessibilityIdentifier("record.add")
                Button { showScanner = true } label: {
                    Label("拍照记录", systemImage: "camera").font(.subheadline.bold()).frame(maxWidth: .infinity).padding(.vertical, 15)
                }.foregroundStyle(.white).background(HomeStyle.ink, in: Capsule()).accessibilityIdentifier("record.scan")
            }.buttonStyle(.plain)
        }
    }

    private var summary: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                Image(systemName: "clock").font(.title3).frame(width: 40, height: 40).background(.white, in: Circle())
                Text("未来 7 天，需要留意").font(.subheadline.weight(.medium))
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(weekCount)").font(.system(size: 54, weight: .bold, design: .rounded))
                    Text("件事项").font(.subheadline)
                }
                Text(overdueCount > 0 ? "另有 \(overdueCount) 件已到期" : "最近没有已到期事项")
                    .font(.caption.weight(.medium)).padding(.horizontal, 11).padding(.vertical, 8)
                    .background(.white.opacity(0.6), in: Capsule())
            }
            Spacer(minLength: 0)
            Image("HomeInk").resizable().scaledToFit().frame(width: 130).accessibilityHidden(true)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(HomeStyle.blue, in: RoundedRectangle(cornerRadius: 30))
            .accessibilityElement(children: .combine)
    }

    private var weekStrip: some View {
        HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { offset in
                let key = LocalDay.adding(offset, to: LocalDay.string(from: now)) ?? ""
                let date = LocalDay.date(from: key) ?? now
                let count = active.filter { $0.dueDate == key }.count
                VStack(spacing: 9) {
                    Text(offset == 0 ? "今天" : date.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(String(key.suffix(2))).font(.subheadline.bold())
                    Text(count == 0 ? "·" : "\(count)").font(.caption.bold())
                        .frame(width: 23, height: 23)
                        .foregroundStyle(count > 0 ? .white : HomeStyle.ink)
                        .background(count > 0 ? HomeStyle.ink : Color.clear, in: Circle())
                }.frame(maxWidth: .infinity)
                    .accessibilityLabel("\(date.formatted(date: .abbreviated, time: .omitted))，\(count) 件到期")
            }
        }.padding(.vertical, 16).background(.white, in: RoundedRectangle(cornerRadius: 26))
    }

    private var roomMap: some View {
        VStack(alignment: .leading, spacing: 12) {
            if selectedRoom != nil {
                Button("查看所有位置") { selectedRoom = nil }.font(.subheadline).underline()
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                ForEach(HomeRoom.allCases) { room in
                    let records = active.filter { $0.room == room }
                    let urgent = records.filter { if let d = $0.dueDate, let n = LocalDay.daysUntil(d, now: now) { return n <= 7 }; return false }.count
                    Button { selectedRoom = selectedRoom == room ? nil : room; history = false; filter = "全部" } label: {
                        VStack(alignment: .leading, spacing: 15) {
                            HStack { Image(systemName: room.symbol).font(.title2); Spacer(); if selectedRoom == room { Image(systemName: "checkmark.circle.fill") } }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(room.title).font(.headline)
                                Text("\(records.count) 件" + (urgent > 0 ? " · \(urgent) 件需留意" : ""))
                                    .font(.caption).lineLimit(2).frame(minHeight: 18, alignment: .top)
                            }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(selectedRoom == room ? .white : HomeStyle.ink)
                            .background(selectedRoom == room ? HomeStyle.ink : HomeStyle.roomColor(room), in: RoundedRectangle(cornerRadius: 26))
                    }.buttonStyle(.plain).accessibilityIdentifier("room.\(room.rawValue)")
                }
            }
        }
    }

    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(section == .map ? selectedRoom?.title ?? "全部位置" : history ? "已完成" : "待处理").font(.title3.bold())
                Text("\(visible.count)").font(.caption.bold()).padding(.horizontal, 9).padding(.vertical, 5).background(.white, in: Capsule())
                Spacer()
                Button(history ? "返回待处理" : "已完成") { history.toggle() }
                    .font(.subheadline).accessibilityIdentifier("records.history")
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索物品或位置", text: $search).font(.subheadline).accessibilityIdentifier("records.search")
                if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("清空搜索") }
            }.padding(14).background(.white, in: Capsule())
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["全部", "食品", "健康护理", "家庭服务"], id: \.self) { value in
                        Button { filter = value } label: { Text(value).font(.subheadline).padding(.horizontal, 16).padding(.vertical, 10) }
                            .foregroundStyle(filter == value ? .white : HomeStyle.ink)
                            .background(filter == value ? HomeStyle.ink : .white, in: Capsule())
                    }
                }
            }
            if visible.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: history ? "checkmark.circle" : "shippingbox").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text(history ? "还没有完成记录" : active.isEmpty ? "先记一件怕忘的小事" : "这里暂时没有事项").font(.headline)
                    Text(history ? "处理过的事项会保存在这里。" : "牛奶、药品、滤芯、会员，都能记。")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if !history {
                        Button("记一件") { newRecord = NewRecordRequest(room: selectedRoom, scan: nil) }
                            .font(.subheadline.bold()).padding(.horizontal, 22).padding(.vertical, 12)
                            .foregroundStyle(.white).background(HomeStyle.ink, in: Capsule())
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 32).padding(.horizontal, 15)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(visible) { item in
                        Button { selectedRecord = item } label: { NativeRecordRow(item: item, now: now) }
                            .buttonStyle(.plain).accessibilityIdentifier("record.\(item.id.uuidString)")
                    }
                }
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(HomeSection.allCases, id: \.self) { tab in
                Button {
                    section = tab; history = false; filter = "全部"; search = ""; selectedRoom = nil
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: section == tab ? tab.symbol + ".fill" : tab.symbol).font(.system(size: 20, weight: .medium))
                        Text(tab.rawValue).font(.caption.weight(section == tab ? .bold : .regular))
                    }.frame(maxWidth: .infinity).frame(height: 58)
                        .foregroundStyle(section == tab ? HomeStyle.ink : Color.secondary)
                }.buttonStyle(.plain).accessibilityIdentifier("tab.\(tab.rawValue)")
            }
        }.padding(.top, 7).background(.white)
    }
}

struct NativeRecordRow: View {
    let item: ExpiryRecord
    var now = Date()
    private var days: Int? { item.dueDate.flatMap { LocalDay.daysUntil($0, now: now) } }
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: item.kind.symbol).font(.title2).frame(width: 50, height: 54)
                .background(HomeStyle.color(item.kind), in: RoundedRectangle(cornerRadius: 18))
            VStack(alignment: .leading, spacing: 7) {
                Text(item.name).font(.headline).lineLimit(2)
                Text(item.room.title + (item.location.isEmpty ? "" : " · " + item.location))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(item.isCompleted ? "已完成" : deadlineText(item, now: now))
                    .font(.caption.weight(.semibold)).foregroundStyle((days ?? 1) < 0 && !item.isCompleted ? HomeStyle.red : HomeStyle.ink)
            }
            Spacer(minLength: 0)
            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "chevron.right").font(.subheadline).foregroundStyle(.secondary)
        }.padding(17).frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(HomeStyle.ink).background(.white, in: RoundedRectangle(cornerRadius: 25))
            .accessibilityElement(children: .combine)
    }
}

func deadlineText(_ item: ExpiryRecord, now: Date = Date()) -> String {
    guard let due = item.dueDate, let days = LocalDay.daysUntil(due, now: now) else { return "日期待确认" }
    if days < 0 { return "已到期 \(-days) 天 · \(due)" }
    if days == 0 { return "今天到期" }
    if days == 1 { return "明天到期" }
    return "\(days) 天后到期 · \(due)"
}
