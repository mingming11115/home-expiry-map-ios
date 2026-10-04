import SwiftUI
import UniformTypeIdentifiers

private struct ExpiryBackup: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct NativeSettingsView: View {
    @ObservedObject var store: NativeStore
    @ObservedObject var reminders: ReminderScheduler
    @State private var renaming = false
    @State private var familyName = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var backup = ExpiryBackup(data: Data())
    @State private var message: String?
    @State private var busy = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("我的家").font(.system(size: 30, weight: .bold, design: .rounded))
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Image(systemName: "house.fill").font(.title).frame(width: 62, height: 62).background(.white, in: Circle())
                    Spacer()
                    Button { familyName = store.familyName; renaming = true } label: { Image(systemName: "pencil").frame(width: 44, height: 44).background(.white.opacity(0.6), in: Circle()) }.accessibilityLabel("修改家庭名称")
                }
                Text(store.familyName).font(.title2.bold())
                HStack(spacing: 28) {
                    VStack(alignment: .leading, spacing: 4) { Text("\(store.items.filter { !$0.isCompleted }.count)").font(.title.bold()); Text("待处理").font(.caption) }
                    VStack(alignment: .leading, spacing: 4) { Text("\(store.items.filter { $0.isCompleted }.count)").font(.title.bold()); Text("已完成").font(.caption) }
                }
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading).background(HomeStyle.blue, in: RoundedRectangle(cornerRadius: 30))

            card {
                Label("到期提醒", systemImage: "bell").font(.headline)
                Text(reminders.statusText).font(.subheadline).foregroundStyle(.secondary)
                if let error = reminders.errorMessage { Text(error).font(.footnote).foregroundStyle(HomeStyle.red) }
                if reminders.isAuthorized {
                    Text("已安排 \(reminders.scheduledCount) 条提醒").font(.subheadline)
                    Text("按日期上午 9 点提醒，优先安排最近 60 条；打开 App 时更新计划。系统的专注模式可能静音通知。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button("打开系统通知设置") { openSettings() }.font(.subheadline).underline()
                } else {
                    Button {
                        busy = true
                        Task { await reminders.enable(store: store); busy = false }
                    } label: {
                        HStack { if busy { ProgressView().tint(.white) }; Text("开启到期提醒").bold() }.frame(maxWidth: .infinity).padding(.vertical, 13)
                    }.disabled(busy).foregroundStyle(.white).background(HomeStyle.ink, in: Capsule())
                    Button("在系统设置中检查权限") { openSettings() }.font(.footnote).underline()
                }
            }

            card {
                Label("本机记录与家庭共享", systemImage: "iphone").font(.headline)
                Text("当前记录仅保存在这台 iPhone，尚未与家人同步。").font(.subheadline)
                Text("网页里的历史记录暂未迁入。卸载 App 会删除本机记录，请先导出备份。")
                    .font(.footnote).foregroundStyle(.secondary)
                NavigationLink { LocalMembersView(store: store) } label: {
                    HStack { Label("管理家人标签", systemImage: "person.2"); Spacer(); Image(systemName: "chevron.right") }.font(.subheadline)
                }
                Text("家人标签用于分配谁来留意，不会发送邀请或共享记录。").font(.footnote).foregroundStyle(.secondary)
            }

            card {
                Label("备份与恢复", systemImage: "externaldrive").font(.headline)
                Button {
                    do { backup = ExpiryBackup(data: try store.exportData()); exporting = true }
                    catch { message = error.localizedDescription }
                } label: { settingsRow("导出备份", icon: "square.and.arrow.up") }.accessibilityIdentifier("backup.export")
                Divider()
                Button { importing = true } label: { settingsRow("导入备份", icon: "square.and.arrow.down") }.accessibilityIdentifier("backup.import")
                Text("导入会添加备份中尚未存在的记录，同一条记录以本机内容为准。").font(.footnote).foregroundStyle(.secondary)
            }

            Text("到期地图 1.1 · 本机版").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.top, 4)
        }
        .alert("修改家庭名称", isPresented: $renaming) {
            TextField("家庭名称", text: $familyName)
            Button("取消", role: .cancel) {}
            Button("保存") { do { try store.renameFamily(familyName) } catch { message = error.localizedDescription } }
        }
        .alert("到期地图", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) { message = nil }
        } message: { Text(message ?? "") }
        .fileExporter(isPresented: $exporting, document: backup, contentType: .json, defaultFilename: "到期地图备份-\(LocalDay.string(from: Date()))") { result in
            if case .failure(let error) = result { message = error.localizedDescription }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard size <= 5 * 1_024 * 1_024 else { message = "备份文件超过 5 MB，请选择到期地图导出的备份。"; return }
                let added = try store.importData(Data(contentsOf: url))
                message = added == 0 ? "备份里的记录已在本机，没有重复添加。" : "已导入 \(added) 条记录。"
            } catch { message = error.localizedDescription }
        }
    }
    private func openSettings() { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } }
    private func settingsRow(_ title: String, icon: String) -> some View {
        HStack { Label(title, systemImage: icon); Spacer(); Image(systemName: "chevron.right").font(.caption) }.font(.subheadline).padding(.vertical, 6)
    }
    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 15, content: content).padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white, in: RoundedRectangle(cornerRadius: 27))
    }
}

private struct LocalMembersView: View {
    @ObservedObject var store: NativeStore
    @State private var name = ""
    @State private var error: String?
    var body: some View {
        Form {
            Section {
                ForEach(store.members, id: \.self) { member in
                    HStack {
                        Label(member, systemImage: "person.crop.circle")
                        Spacer()
                        if member != "我" {
                            Button(role: .destructive) {
                                do { try store.setMembers(store.members.filter { $0 != member }) } catch { self.error = error.localizedDescription }
                            } label: { Image(systemName: "minus.circle") }.accessibilityLabel("移除 \(member) 标签")
                        }
                    }
                }
            } header: { Text("家人标签") } footer: { Text("标签仅保存在本机，移除标签不会删除已分配的记录，也不会通知对方。") }
            Section {
                TextField("名字或称呼", text: $name)
                Button("添加标签") {
                    do { try store.setMembers(store.members + [name]); name = "" } catch { self.error = error.localizedDescription }
                }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle("家人标签").navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .alert("未能保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("知道了", role: .cancel) { error = nil } } message: { Text(error ?? "") }
    }
}
