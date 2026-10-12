import AppKit
import SwiftUI
import Combine

struct AgentEvent: Codable, Identifiable {
    let id: String
    let session: String
    let agent: String
    let project: String
    let state: String
    let detail: String
    let timestamp: Double
}

final class SessionStore: ObservableObject {
    @Published var sessions: [AgentEvent] = []
    @Published var demo = false
    @Published var error: String?
    @Published var expanded = false
    @Published var expansionProgress: CGFloat = 0
    @Published var notchWidth: CGFloat = 180
    @Published var notchHeight: CGFloat = 32
    @Published var muted = false
    @Published var tab: PanelTab = .quotas
    let directory: URL
    private var timer: Timer?
    private var watcher: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?
    init() {
        let env = ProcessInfo.processInfo.environment["TOUTU_DATA_DIR"]
        directory = env.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Toutu/events")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { self.error = error.localizedDescription }
        poll()
        watch()
        // The directory watcher delivers new events instantly; this slow timer only
        // expires stale entries and covers the rare case where the watcher is unavailable.
        let timer = Timer(timeInterval: watcher == nil ? 5 : 60, repeats: true) { [weak self] _ in self?.poll() }
        timer.tolerance = watcher == nil ? 1 : 15
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func watch() {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            // Hooks write several files in quick succession; coalesce into one read.
            self.pending?.cancel()
            let work = DispatchWorkItem { self.poll() }
            self.pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
    func poll() {
        guard !demo else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            let events = files.compactMap { url -> AgentEvent? in
                guard let data = try? Data(contentsOf: url), data.count <= 262144 else { return nil }
                return try? JSONDecoder().decode(AgentEvent.self, from: data)
            }.filter { Date().timeIntervalSince1970 - $0.timestamp < 86400 }.sorted { $0.timestamp > $1.timestamp }
            var seen = Set<String>()
            let latest = Array(events.filter { seen.insert($0.session).inserted }.prefix(20))
            if !muted && latest.contains(where: { event in event.state == "done" && !sessions.contains(where: { $0.id == event.id }) }) { NSSound(named: "Glass")?.play() }
            // Avoid publishing identical state: every change re-renders the SwiftUI tree.
            if latest.map(\.id) != sessions.map(\.id) { sessions = latest }
            if error != nil { error = nil }
        } catch { self.error = error.localizedDescription }
    }
    func toggleDemo() {
        demo.toggle()
        if demo {
            sessions = [AgentEvent(id: "demo-1", session: "demo-1", agent: "Cursor", project: "toutu / landing", state: "working", detail: "Обновляет компоненты интерфейса", timestamp: Date().timeIntervalSince1970), AgentEvent(id: "demo-2", session: "demo-2", agent: "Cursor", project: "api / server", state: "done", detail: "Задача завершена", timestamp: Date().timeIntervalSince1970)]
        } else { sessions = []; poll() }
    }
    func openApp(_ name: String, fallback: String) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        } else if let url = URL(string: fallback) { NSWorkspace.shared.open(url) }
    }
}

// Every animated frame re-renders the SwiftUI tree, which is the main CPU and
// battery cost of a notch companion. The character is therefore static when idle,
// nods a few frames per second in the compact strip while an agent works, and only
// moves continuously while the panel is open and someone is looking at it.
enum CompanionMotion { case still, gentle, lively }

struct Companion: View {
    var active: Bool
    var motion: CompanionMotion
    @State private var float = false
    @State private var blink = false
    @State private var timer: Timer?
    @State private var ticks = 0
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22).fill(LinearGradient(colors: [Color(red: 0.82, green: 0.94, blue: 0.64), Color(red: 0.43, green: 0.72, blue: 0.42)], startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack(spacing: 13) {
                Capsule().fill(Color.black.opacity(0.85)).frame(width: 7, height: blink ? 2 : 12)
                Capsule().fill(Color.black.opacity(0.85)).frame(width: 7, height: blink ? 2 : 12)
            }.offset(y: -2)
            Capsule().fill(Color.black.opacity(0.55)).frame(width: active ? 9 : 12, height: 3).offset(y: 12)
        }.frame(width: 58, height: 54).rotationEffect(.degrees(float && active ? 5 : -3)).offset(y: float ? -3 : 2)
        .onAppear { update(motion) }
        .onChange(of: motion) { value in update(value) }
        .onDisappear { timer?.invalidate(); timer = nil }
    }
    private func update(_ motion: CompanionMotion) {
        timer?.invalidate()
        timer = nil
        switch motion {
        case .still:
            withAnimation(.easeOut(duration: 0.3)) { float = false }
            blink = false
        case .lively:
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { float = true }
            schedule(every: 4.2) { doBlink() }
        case .gentle:
            // One short eased nod per 1.2 s averages roughly a dozen frames per second.
            schedule(every: 1.2) {
                withAnimation(.easeInOut(duration: 0.25)) { float.toggle() }
                ticks += 1
                if ticks % 4 == 0 { doBlink() }
            }
        }
    }
    private func schedule(every interval: TimeInterval, _ action: @escaping () -> Void) {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in action() }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    private func doBlink() {
        blink = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { blink = false }
    }
}

enum IslandLayout {
    static let expandedWidth: CGFloat = 440
    static let expandedHeight: CGFloat = 200
    static let cardHeight: CGFloat = 100
}

enum PanelTab: String, CaseIterable {
    case quotas, power
    var title: String { self == .quotas ? "Лимиты" : "Питание" }
}

struct IslandView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var usage: UsageStore
    @ObservedObject var power: PowerStore
    @State private var closeTask: DispatchWorkItem?
    var active: Bool { store.sessions.contains { $0.state == "working" } }
    var body: some View {
        VStack(spacing: 0) {
            Button { store.expanded = true } label: {
                HStack(spacing: 0) {
                    Companion(active: active, motion: store.expansionProgress > 0 ? .lively : active ? .gentle : .still)
                        .scaleEffect(0.32).frame(width: 32, height: store.notchHeight)
                    Color.clear.frame(width: store.notchWidth, height: store.notchHeight)
                    HStack(spacing: 4) {
                        Circle().fill(quotaColor("chatgpt")).frame(width: 4, height: 4)
                        Circle().fill(quotaColor("cursor")).frame(width: 4, height: 4)
                        if power.lidAwake { Image(systemName: "moon.zzz.fill").font(.system(size: 7)).foregroundStyle(.yellow) }
                    }.frame(width: 32, height: store.notchHeight)
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.plain).help("Остаток лимитов ChatGPT и Cursor")
                VStack(spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(PanelTab.allCases, id: \.self) { tab in
                            Button(tab.title) { store.tab = tab }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(store.tab == tab ? .primary : .secondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(store.tab == tab ? Color.white.opacity(0.14) : .clear, in: Capsule())
                        }
                        Spacer()
                        if store.tab == .quotas {
                            Button { usage.refresh() } label: {
                                Image(systemName: usage.refreshing ? "ellipsis" : "arrow.clockwise")
                            }.disabled(usage.refreshing).help("Обновить лимиты")
                        }
                        Button { store.expanded = false } label: { Image(systemName: "chevron.up") }.help("Свернуть")
                    }.font(.system(size: 10)).buttonStyle(.plain)
                    Group {
                        if store.tab == .quotas {
                            HStack(alignment: .top, spacing: 8) {
                                quotaRow("ChatGPT", id: "chatgpt", icon: "sparkles", color: .green)
                                quotaRow("Cursor", id: "cursor", icon: "cursorarrow", color: .cyan)
                            }
                        } else { powerTab }
                    }.frame(height: IslandLayout.cardHeight)
                    HStack(spacing: 12) {
                        if let event = store.sessions.first {
                            Circle().fill(event.state == "working" ? Color.green : .gray).frame(width: 4, height: 4)
                        }
                        Text(footerText).lineLimit(1).font(.system(size: 9)).foregroundStyle(.secondary)
                        Spacer(minLength: 2)
                        Button { store.muted.toggle() } label: { Image(systemName: store.muted ? "speaker.slash" : "speaker.wave.2") }.help("Звук завершения")
                        Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }.help("Выйти")
                    }.font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(.secondary)
                }.padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 12)
                .frame(width: IslandLayout.expandedWidth)
                .opacity(Double(store.expansionProgress))
                .offset(y: -6 * (1 - store.expansionProgress))
                .allowsHitTesting(store.expansionProgress > 0.95)
                .accessibilityHidden(store.expansionProgress < 0.95)
        }.frame(width: store.notchWidth + 64 + (IslandLayout.expandedWidth - store.notchWidth - 64) * store.expansionProgress,
                 height: store.notchHeight + (IslandLayout.expandedHeight - store.notchHeight) * store.expansionProgress,
                 alignment: .top)
        .foregroundStyle(.white).background(Color.black, in: NotchShape())
        .clipShape(NotchShape()).preferredColorScheme(.dark)
        .contentShape(NotchShape())
        .onHover { inside in
            closeTask?.cancel()
            if inside { store.expanded = true }
            else {
                let task = DispatchWorkItem { store.expanded = false }
                closeTask = task
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
            }
        }
    }
    func quotaColor(_ provider: String) -> Color {
        guard let windows = usage.snapshot?.providers.first(where: { $0.provider == provider })?.windows,
              let remaining = windows.map({ $0.remainingPercent }).min() else { return .gray }
        return remaining <= 10 ? .red : remaining <= 25 ? .orange : .green
    }
    var footerText: String {
        if store.tab == .power, let message = power.message { return message }
        return usage.error ?? (usage.refreshing ? "Обновляю…" : store.sessions.first?.detail ?? (usage.snapshot == nil ? "Подключение…" : "Автообновление · \(Int(usage.interval / 60)) мин"))
    }
    func quotaRow(_ title: String, id: String, icon: String, color: Color) -> some View {
        let provider = usage.snapshot?.providers.first(where: { $0.provider == id })
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon).foregroundStyle(color)
                Button(title) {
                    store.openApp(id == "chatgpt" ? "com.openai.codex" : "com.todesktop.230313mzl4w4u92", fallback: id == "chatgpt" ? "https://chatgpt.com" : "https://cursor.com")
                }.buttonStyle(.plain)
                if let plan = provider?.plan {
                    Text(plan).font(.system(size: 8, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(color.opacity(0.22), in: Capsule())
                }
                Spacer()
                if id == "chatgpt" { Text("Codex").font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).fixedSize().help("Лимиты ChatGPT Work / Codex") }
            }.font(.system(size: 12, weight: .semibold))
            if let provider = provider, !provider.windows.isEmpty {
                ForEach(Array(provider.windows.enumerated()), id: \.offset) { _, window in
                    HStack(spacing: 7) {
                        Text(window.label).frame(width: 46, alignment: .leading).foregroundStyle(.secondary).lineLimit(1)
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.12))
                                Capsule().fill(window.remainingPercent <= 10 ? Color.red : window.remainingPercent <= 25 ? Color.orange : color)
                                    .frame(width: geometry.size.width * max(0, min(1, window.remainingPercent / 100)))
                            }
                        }.frame(height: 4)
                        Text(window.detail ?? String(format: "%.0f%%", window.remainingPercent)).monospacedDigit()
                            .frame(width: window.detail == nil ? 30 : 60, alignment: .trailing).lineLimit(1)
                    }.font(.system(size: 10)).help(windowHelp(window))
                }
                let note = noteText(provider)
                if !note.isEmpty {
                    Text(note).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(note)
                }
            } else {
                Text(provider?.error ?? "Получаю данные…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }.padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
    var powerTab: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "laptopcomputer").foregroundStyle(.yellow)
                Text("Не спать при закрытой крышке").font(.system(size: 12, weight: .semibold))
                Spacer()
                if power.busy { ProgressView().controlSize(.mini) }
                Toggle("", isOn: Binding(get: { power.lidAwake }, set: { power.setLidAwake($0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden().disabled(power.busy)
                    .help("Включает системную настройку pmset disablesleep; нужен пароль администратора")
            }
            Text("Mac продолжит работу с закрытой крышкой: агенты Cursor и Codex доработают задачи, экран погаснет. Для переключения macOS спросит пароль администратора.")
                .font(.system(size: 9)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Circle().fill(power.lidAwake ? Color.yellow : (power.onBattery ? Color.orange : Color.green)).frame(width: 5, height: 5)
                Text(power.statusText).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                if power.lidAwake && power.onBattery {
                    Text("· батарея будет разряжаться").font(.system(size: 9)).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Toggle(isOn: $power.restoreOnQuit) {
                Text("Вернуть обычный сон при выходе из Toutu").font(.system(size: 9))
            }.toggleStyle(.checkbox).controlSize(.mini)
        }.padding(9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
    func noteText(_ provider: ProviderQuota) -> String {
        var parts = provider.notes ?? []
        let resets = provider.windows.compactMap { $0.resetsAt }
        var seen = Set<Int>()
        let unique = resets.filter { seen.insert(Int($0)).inserted }
        if !unique.isEmpty { parts.append("сброс " + unique.map(shortReset).joined(separator: " / ")) }
        return parts.joined(separator: " · ")
    }
    func windowHelp(_ window: QuotaWindow) -> String {
        let used = String(format: "Использовано %.1f%%, осталось %.1f%%", 100 - window.remainingPercent, window.remainingPercent)
        return used + ". " + resetText(window.resetsAt)
    }
    func shortReset(_ timestamp: Double) -> String {
        let delta = timestamp - Date().timeIntervalSince1970
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        if delta <= 60 { return "сейчас" }
        if delta < 3600 { return "через \(Int(delta / 60)) мин" }
        formatter.dateFormat = delta < 86400 ? "HH:mm" : "d MMM"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
    func resetText(_ timestamp: Double?) -> String {
        guard let timestamp = timestamp else { return "Остаток включённого лимита" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.dateFormat = "d MMM, HH:mm"
        return "Сброс: " + formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

struct NotchShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(roundedRect: rect, cornerRadius: min(22, rect.height / 2))
    }
}

// AppKit normally constrains windows to the area below the menu bar.
// A notch companion deliberately occupies that reserved top strip.
final class NotchPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    var statusItem: NSStatusItem!
    let store = SessionStore()
    let usage = UsageStore()
    let power = PowerStore()
    private var subscriptions = Set<AnyCancellable>()
    private var screenObserver: NSObjectProtocol?
    private var animationTimer: Timer?
    func positionPanel(animated: Bool = true) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        let top = screen.safeAreaInsets.top
        var centerX = screen.frame.midX
        store.notchHeight = top > 0 ? top : 30
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, top > 0 {
            store.notchWidth = max(120, right.minX - left.maxX)
            centerX = (right.minX + left.maxX) / 2
        } else { store.notchWidth = 180 }
        animationTimer?.invalidate()
        let start = store.expansionProgress
        let target: CGFloat = store.expanded ? 1 : 0
        let compactWidth = store.notchWidth + 64
        let compactHeight = store.notchHeight
        let expandedHeight = IslandLayout.expandedHeight
        func apply(_ progress: CGFloat) {
            let width = compactWidth + (IslandLayout.expandedWidth - compactWidth) * progress
            let height = compactHeight + (expandedHeight - compactHeight) * progress
            self.store.expansionProgress = progress
            self.panel.setFrame(NSRect(x: centerX - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: true)
        }
        guard animated, panel.isVisible, abs(start - target) > 0.001,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            apply(target)
            return
        }
        let started = ProcessInfo.processInfo.systemUptime
        let duration = target > start ? 0.32 : 0.26
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard self != nil else { timer.invalidate(); return }
            let time = min(1, (ProcessInfo.processInfo.systemUptime - started) / duration)
            // Smooth acceleration and deceleration; a reversal starts at the current size.
            let eased = CGFloat(time * time * (3 - 2 * time))
            apply(start + (target - start) * eased)
            if time >= 1 { timer.invalidate() }
        }
        animationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = NotchPanel(contentRect: NSRect(x: 0, y: 0, width: 394, height: 500), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: IslandView(store: store, usage: usage, power: power).frame(maxHeight: .infinity, alignment: .top).ignoresSafeArea())
        host.sizingOptions = []
        panel.contentView = host
        positionPanel(animated: false)
        store.$expanded.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] expanded in
            guard let self = self else { return }
            self.positionPanel()
            // Fresh numbers when the user actually looks, instead of polling in the background.
            if expanded {
                self.usage.refreshIfStale(90)
                if self.store.tab == .power { self.power.refreshIfStale() }
            }
        }.store(in: &subscriptions)
        store.$tab.removeDuplicates().sink { [weak self] tab in if tab == .power { self?.power.refreshIfStale() } }.store(in: &subscriptions)
        store.$sessions.map { $0.isEmpty }.removeDuplicates().receive(on: RunLoop.main).sink { [weak self] _ in self?.positionPanel() }.store(in: &subscriptions)
        // On battery the expensive quota refresh runs half as often.
        power.$onBattery.removeDuplicates().sink { [weak self] battery in self?.usage.interval = battery ? 600 : 300 }.store(in: &subscriptions)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.updatePause(asleep: true) }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in self?.updatePause(asleep: false) }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.positionPanel() }
        panel.orderFrontRegardless()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "leaf.fill", accessibilityDescription: "Toutu")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggle)
    }
    private var screensAsleep = false
    private func updatePause(asleep: Bool? = nil) {
        if let asleep = asleep { screensAsleep = asleep }
        usage.paused = screensAsleep || !panel.isVisible
    }
    @objc func toggle() {
        if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() }
        updatePause()
    }
    func applicationWillTerminate(_ notification: Notification) { power.restoreBeforeQuit() }
}

let app = NSApplication.shared
if CommandLine.arguments.contains("--screen-info") {
    for screen in NSScreen.screens {
        print("Screen:", screen.localizedName, "frame:", screen.frame, "visible:", screen.visibleFrame, "safeTop:", screen.safeAreaInsets.top, "left:", String(describing: screen.auxiliaryTopLeftArea), "right:", String(describing: screen.auxiliaryTopRightArea))
    }
    exit(0)
}
if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
    // Renders the expanded panel for each tab into PNG files: <path>-quotas.png, <path>-power.png.
    let base = CommandLine.arguments[index + 1]
    let store = SessionStore(), usage = UsageStore(), power = PowerStore()
    store.expanded = true
    store.expansionProgress = 1
    if ProcessInfo.processInfo.environment["TOUTU_DEMO"] != nil { store.toggleDemo() }
    RunLoop.main.run(until: Date().addingTimeInterval(ProcessInfo.processInfo.environment["TOUTU_DEMO"] != nil ? 1 : 8))
    for tab in PanelTab.allCases {
        store.tab = tab
        let host = NSHostingView(rootView: IslandView(store: store, usage: usage, power: power))
        host.frame = NSRect(x: 0, y: 0, width: IslandLayout.expandedWidth, height: IslandLayout.expandedHeight)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: base + "-" + tab.rawValue + ".png"))
    }
    exit(0)
}
let delegate = AppDelegate()
app.delegate = delegate
app.run()
