import SwiftUI
import EventKit
import EventKitUI

struct AppView: View {
    @StateObject private var browser = WebBrowser()
    var body: some View {
        VStack(spacing: 0) {
            if browser.isSigningIn {
                HStack {
                    Button { browser.goHome() } label: {
                        Label("返回到期地图", systemImage: "chevron.left")
                    }
                    Spacer()
                    Label(browser.displayHost, systemImage: "lock.fill")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.subheadline).padding(.horizontal, 16).frame(minHeight: 48)
                Divider()
            }
            ZStack {
                BrowserView(browser: browser)
                if let message = browser.failure {
                    VStack(spacing: 20) {
                        Image(systemName: "wifi.exclamationmark").font(.system(size: 42))
                        Text("暂时没有连接上").font(.title2.bold())
                        Text(message).font(.body).multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("重新加载") { browser.retry() }
                            .buttonStyle(.borderedProminent).tint(.black)
                        Button("在 Safari 中打开") { browser.openInSafari() }
                            .font(.subheadline)
                    }
                    .padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.white)
                } else if browser.loading {
                    VStack {
                        ProgressView().controlSize(.small).padding(12)
                            .background(.regularMaterial, in: Capsule())
                        Spacer()
                    }.padding(.top, 12).allowsHitTesting(false)
                }
            }
        }
        .background(.white)
        .sheet(item: $browser.calendarDraft) { item in
            CalendarEditor(draft: item.draft) { browser.calendarDraft = nil }
        }
        .alert("到期地图", isPresented: Binding(get: { browser.notice != nil }, set: { if !$0 { browser.notice = nil } })) {
            Button("知道了", role: .cancel) { browser.notice = nil }
        } message: { Text(browser.notice ?? "") }
    }
}

struct CalendarItem: Identifiable {
    let id = UUID()
    let draft: CalendarDraft
}

struct CalendarEditor: UIViewControllerRepresentable {
    let draft: CalendarDraft
    let onFinish: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let editor = EKEventEditViewController()
        let store = EKEventStore()
        editor.eventStore = store
        editor.editViewDelegate = context.coordinator
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.location = draft.location
        event.notes = draft.notes
        event.isAllDay = true
        event.startDate = draft.startDate
        event.endDate = draft.endDate
        if let offset = draft.reminderOffset { event.addAlarm(EKAlarm(relativeOffset: offset)) }
        editor.event = event
        return editor
    }
    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}
    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) { onFinish() }
    }
}
