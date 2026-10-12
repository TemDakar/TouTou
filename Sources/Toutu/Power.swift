import AppKit
import Combine
import IOKit.ps

// Keeps the Mac running with the lid closed so agents finish their work.
// macOS only honours lid-closed wake through `pmset -a disablesleep 1`, which
// needs administrator rights; the system password prompt is shown each time.
final class PowerStore: ObservableObject {
    @Published var lidAwake = false
    @Published var busy = false
    @Published var onBattery = false
    @Published var batteryPercent: Int?
    @Published var message: String?
    @Published var restoreOnQuit: Bool {
        didSet { UserDefaults.standard.set(restoreOnQuit, forKey: "restoreSleepOnQuit") }
    }
    private var enabledByApp = false
    private var timer: Timer?
    private var powerSource: CFRunLoopSource?
    private var lastSettingsRead: Date?

    init() {
        restoreOnQuit = UserDefaults.standard.object(forKey: "restoreSleepOnQuit") as? Bool ?? true
        readBattery()
        refresh()
        // IOKit tells us when the power source changes; no polling required.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context = context else { return }
            Unmanaged<PowerStore>.fromOpaque(context).takeUnretainedValue().readBattery()
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
        // `pmset -g` spawns a process, so the system setting is re-read rarely;
        // the toggle and opening the Power tab refresh it on demand.
        let timer = Timer(timeInterval: 600, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 120
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    deinit {
        if let source = powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode) }
    }

    func readBattery() {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return }
        let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let battery = type == kIOPMBatteryPowerKey
        var percent: Int?
        for item in list {
            guard let description = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                  let capacity = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
            percent = Int((Double(capacity) / Double(maximum) * 100).rounded())
            break
        }
        if onBattery != battery { onBattery = battery }
        if batteryPercent != percent { batteryPercent = percent }
    }

    static func read(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func sleepDisabled(in settings: String) -> Bool {
        settings.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    func refresh() {
        lastSettingsRead = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let disabled = Self.sleepDisabled(in: Self.read(["-g"]))
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !self.busy && self.lidAwake != disabled { self.lidAwake = disabled }
            }
        }
    }

    func refreshIfStale(_ seconds: TimeInterval = 30) {
        guard Date().timeIntervalSince(lastSettingsRead ?? .distantPast) >= seconds else { return }
        refresh()
    }

    func setLidAwake(_ on: Bool) {
        guard !busy, on != lidAwake else { return }
        busy = true
        message = nil
        let source = "do shell script \"/usr/bin/pmset -a disablesleep \(on ? 1 : 0)\" with administrator privileges"
        var failure: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&failure)
        busy = false
        if let failure = failure {
            let code = failure[NSAppleScript.errorNumber] as? Int
            message = code == -128 ? "Отменено" : "Нужен пароль администратора"
        } else {
            lidAwake = on
            enabledByApp = on
            message = on ? "Крышку можно закрывать" : "Обычный режим сна"
        }
        refresh()
    }

    func restoreBeforeQuit() {
        guard restoreOnQuit, enabledByApp, lidAwake else { return }
        setLidAwake(false)
    }

    var statusText: String {
        var parts: [String] = []
        parts.append(onBattery ? "От батареи" : "От сети")
        if let percent = batteryPercent { parts[0] += " \(percent)%" }
        parts.append(lidAwake ? "сон при закрытии выключен" : "при закрытии крышки уснёт")
        return parts.joined(separator: " · ")
    }
}
