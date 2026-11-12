import AppKit
import Combine
import CoreGraphics
import ServiceManagement

final class AppModel: ObservableObject {
    @Published private(set) var topology: DisplayTopology?
    @Published var snapshot: DisplaySnapshot?
    @Published private(set) var pendingDisplayModeChange: PendingDisplayModeChange?
    @Published private(set) var pendingMainDisplayChange: PendingMainDisplayChange?
    @Published var status = "正在检查显示器…"
    @Published var notice: String?
    @Published var progress = 0.0
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "enabled"); invalidateAutomation(); updateTap(); refresh() } }
    @Published var duration: Double { didSet { defaults.set(duration, forKey: "duration"); invalidateAutomation() } }
    @Published var pauseSettings: PauseSettings {
        didSet {
            pauseSettings.save(to: defaults)
            invalidateAutomation()
            refreshAutomationContext()
        }
    }
    @Published private(set) var pauseReason: PauseReason?
    @Published var pauseSettingsMessage: String?
    @Published var loginEnabled = false
    @Published var permission = false
    @Published var manualDisplayID: CGDirectDisplayID = 0
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pushSession = AutomaticPushSession()
    private let defaults: UserDefaults
    private let startsServices: Bool
    private let readTopology: () -> DisplayTopology?
    private let applyDisplayMode: (DisplayTopology, CGDirectDisplayID, DisplayMode) -> String?
    private let applyMainDisplay: (DisplayTopology, CGDirectDisplayID) -> String?
    private let uptime: () -> TimeInterval
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "com.edgeshift.app"
    private let foregroundMonitor = ForegroundMonitor()
    private var foregroundApplication: ForegroundApplication?
    private lazy var pauseSettingsWindow = PauseSettingsWindowController(model: self)
    private var cooldownUntil: TimeInterval = 0
    private var timer: Timer?
    private var isArranging = false
    private var screenLocked = false
    private var permissionFallbackScheduled = false
    private var displayCycle = DisplayCycle<CGDirectDisplayID>()

    init(defaults: UserDefaults = .standard, startsServices: Bool = true,
         readTopology: @escaping () -> DisplayTopology? = DisplayManager.topology,
         applyDisplayMode: @escaping (DisplayTopology, CGDirectDisplayID, DisplayMode) -> String? = {
             DisplayManager.setMode($0, displayID: $1, mode: $2)
         }, applyMainDisplay: @escaping (DisplayTopology, CGDirectDisplayID) -> String? = {
             DisplayManager.setMainDisplay($0, displayID: $1)
         }, uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.defaults = defaults
        self.startsServices = startsServices
        self.readTopology = readTopology
        self.applyDisplayMode = applyDisplayMode
        self.applyMainDisplay = applyMainDisplay
        self.uptime = uptime
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        duration = defaults.object(forKey: "duration") as? Double ?? 2
        pauseSettings = PauseSettings.load(from: defaults, ownBundleID: ownBundleID)
        refresh()
        guard startsServices else { return }
        if defaults.object(forKey: "loginAttempted") == nil {
            defaults.set(true, forKey: "loginAttempted")
            setLogin(true)
        } else { refreshLogin() }
        updateTap()
        // Ask once per launch after AppKit has initialized. macOS may suppress
        // the prompt after a previous decision, so the settings link remains available.
        if enabled && !permission {
            DispatchQueue.main.async { [weak self] in self?.requestPermission() }
        }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake), name: NSWorkspace.didWakeNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(frontmostChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(lockScreen), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(unlockScreen), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
    }
    @objc private func lockScreen() { screenLocked = true; invalidateAutomation() }
    @objc private func unlockScreen() { screenLocked = false; invalidateAutomation(); refresh() }
    @objc private func wake() { invalidateAutomation(); refresh(); updateTap() }
    @objc private func frontmostChanged() { refreshAutomationContext() }
    @objc private func spaceChanged() { invalidateAutomation(); refreshAutomationContext() }

    var automaticReady: Bool {
        enabled && permission && snapshot != nil && !screenLocked && pauseReason == nil && !isChangingDisplays
    }

    var isSwitchingMode: Bool { pendingDisplayModeChange != nil }
    var isChangingDisplays: Bool { isSwitchingMode || pendingMainDisplayChange != nil }
    var selectedDisplay: ConnectedDisplay? { topology?.secondaries.first { $0.id == manualDisplayID } }
    var canArrangeSelectedDisplay: Bool {
        !isChangingDisplays && snapshot?.secondaries.contains(where: { $0.id == manualDisplayID }) == true
    }

    var displayedStatus: String {
        if pendingMainDisplayChange != nil { return "正在切换主显示器，自动排列已暂停…" }
        if isSwitchingMode { return "正在切换显示模式，自动排列已暂停…" }
        guard snapshot != nil, enabled, permission else { return status }
        if screenLocked { return "锁屏期间自动排列已暂停" }
        return pauseReason?.message ?? status
    }

    func showPauseSettings() {
        refreshAutomationContext()
        pauseSettingsWindow.show()
    }

    func addPausedApplications(from urls: [URL]) {
        var updated = pauseSettings
        var added = 0
        for url in urls {
            guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
                  let id = bundle.bundleIdentifier else { continue }
            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent
            if updated.add(PausedApplication(bundleID: id, name: name), ownBundleID: ownBundleID) { added += 1 }
        }
        if updated != pauseSettings { pauseSettings = updated }
        pauseSettingsMessage = added > 0 ? "已添加 \(added) 个应用" : "未添加应用：重复项目、EdgeShift 自身或无有效标识的应用会被跳过。"
    }

    func removePausedApplication(bundleID: String) {
        guard pauseSettings.applications.contains(where: { $0.bundleID == bundleID }) else { return }
        pauseSettings.remove(bundleID: bundleID)
        pauseSettingsMessage = nil
    }

    func setReserved(_ side: Side, reserved: Bool) {
        guard pauseSettings.reserves(side) != reserved else { return }
        pauseSettings.setReserved(side, reserved: reserved)
    }

    private func refreshAutomationContext() {
        let context = foregroundMonitor.snapshot()
        let reason = PausePolicy.reason(settings: pauseSettings, context: context,
                                        displays: topology?.independentDisplays.map(\.bounds) ?? [])
        if context.application != foregroundApplication || reason != pauseReason {
            invalidateAutomation()
            foregroundApplication = context.application
            if reason != pauseReason { pauseReason = reason }
        }
    }
    func refresh() {
        let newTopology = readTopology()
        if newTopology != topology {
            if newTopology?.mainID != topology?.mainID || newTopology?.displays.map(\.id) != topology?.displays.map(\.id) ||
                newTopology?.displays.map(\.mirrorSourceID) != topology?.displays.map(\.mirrorSourceID) {
                displayCycle.reset()
            }
            topology = newTopology
            invalidateAutomation()
        }
        let new = newTopology?.arrangement
        if new != snapshot {
            if new?.mainID != snapshot?.mainID || Set(new?.displays.map(\.id) ?? []) != Set(snapshot?.displays.map(\.id) ?? []) {
                displayCycle.reset()
            }
            snapshot = new
            invalidateAutomation()
        }
        let selection = newTopology?.selection(preserving: manualDisplayID) ?? 0
        if selection != manualDisplayID { manualDisplayID = selection }
        refreshPendingModeChange()
        refreshPendingMainDisplayChange()
        let granted = CGPreflightListenEventAccess()
        if permission != granted { permission = granted; invalidateAutomation() }
        refreshAutomationContext()
        if permission && notice == "请在系统设置的“隐私与安全性 → 输入监控”中开启 EdgeShift。" { notice = nil }
        let updatedStatus: String
        if newTopology == nil { updatedStatus = "暂时无法读取显示器状态，请稍后重试" }
        else if newTopology!.secondaries.isEmpty { updatedStatus = "连接至少两块显示器后可选择扩展或复制" }
        else if new == nil { updatedStatus = "没有可排列的扩展副屏，自动排列已暂停" }
        else if !enabled { updatedStatus = "自动排列已关闭" }
        else if !permission { updatedStatus = "请授予输入监控权限以启用自动排列" }
        else { updatedStatus = "\(new!.secondaries.count) 块扩展副屏可排列，复制屏幕不参与自动排列" }
        if status != updatedStatus { status = updatedStatus }
    }

    func setDisplayMode(_ mode: DisplayMode) {
        guard !isArranging, !isChangingDisplays else { return }
        let targetID = manualDisplayID
        refresh()
        guard let topology, let target = selectedDisplay, target.id == targetID else {
            notice = "显示器状态已改变，请重新选择目标副屏。"
            return
        }
        if let error = topology.modeChangeError(displayID: target.id, mode: mode) { notice = error; return }
        guard target.mode != mode else { return }
        pendingDisplayModeChange = PendingDisplayModeChange(displayID: target.id,
            mirrorSourceID: mode == .mirrored ? topology.mainID : nil, deadline: uptime() + 5)
        invalidateAutomation()
        displayCycle.reset()
        notice = "正在切换显示模式…"
        if let error = applyDisplayMode(topology, target.id, mode) {
            pendingDisplayModeChange = nil
            refresh()
            notice = error
        } else {
            refresh()
        }
    }

    private func refreshPendingModeChange() {
        guard let pending = pendingDisplayModeChange else { return }
        let message: String
        if let topology, pending.isApplied(to: topology) {
            message = "显示模式已切换为\(pending.mirrorSourceID == nil ? "扩展" : "复制")"
        } else if let topology, !topology.secondaries.contains(where: { $0.id == pending.displayID }) {
            message = "目标副屏已断开或变为主屏，请重新选择。"
        } else if uptime() >= pending.deadline {
            message = "未确认显示模式切换成功，请检查系统显示器设置后重试。"
        } else { return }
        pendingDisplayModeChange = nil
        invalidateAutomation()
        cooldownUntil = uptime() + 3
        notice = message
    }

    func setMainDisplay(_ displayID: CGDirectDisplayID) {
        guard !isArranging, !isChangingDisplays else { return }
        refresh()
        guard let topology else { notice = "暂时无法读取显示器状态，请稍后重试。"; return }
        if let error = topology.mainDisplayChangeError(displayID: displayID) { notice = error; return }
        guard displayID != topology.mainID else { return }
        guard let origins = topology.originsForMainDisplay(displayID) else { notice = "显示器坐标超出可配置范围。"; return }
        pendingMainDisplayChange = PendingMainDisplayChange(displayID: displayID, origins: origins, deadline: uptime() + 5)
        invalidateAutomation()
        displayCycle.reset()
        notice = "正在切换主显示器…"
        if let error = applyMainDisplay(topology, displayID) {
            pendingMainDisplayChange = nil
            refresh()
            notice = error
        } else {
            refresh()
        }
    }

    private func refreshPendingMainDisplayChange() {
        guard let pending = pendingMainDisplayChange else { return }
        let message: String
        if let topology, topology.mainID == pending.displayID {
            message = pending.preservesLayout(in: topology) ? "主显示器已切换，原主屏现为副屏" :
                "主显示器已切换；系统同时调整了排列，请检查。"
        } else if let topology, !topology.displays.contains(where: { $0.id == pending.displayID }) {
            message = "目标显示器已断开，请重新选择主显示器。"
        } else if uptime() >= pending.deadline {
            message = "未确认主显示器切换成功，请检查系统显示器设置后重试。"
        } else { return }
        pendingMainDisplayChange = nil
        invalidateAutomation()
        cooldownUntil = uptime() + 3
        notice = message
    }
    private func tick() {
        if pushSession.hasPush && ProcessInfo.processInfo.systemUptime - pushSession.last > 0.2 { reset() }
        let wasPermission = permission
        refresh()
        if permission != wasPermission { updateTap() }
    }
    func requestPermission() {
        _ = CGRequestListenEventAccess()
        refresh(); updateTap()
        if !permission {
            notice = "请在系统设置的“隐私与安全性 → 输入监控”中开启 EdgeShift。"
            if !permissionFallbackScheduled {
                permissionFallbackScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self else { return }
                    self.permissionFallbackScheduled = false
                    self.refresh()
                    if self.enabled && !self.permission { self.openPrivacy() }
                }
            }
        } else {
            notice = nil
        }
    }
    func openPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") { NSWorkspace.shared.open(url) }
    }
    func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch { notice = "登录启动设置失败：\(error.localizedDescription)" }
        refreshLogin()
    }
    func refreshLogin() { loginEnabled = SMAppService.mainApp.status == .enabled }
    private func reset() { pushSession.reset(); if progress != 0 { progress = 0 } }
    private func invalidateAutomation() { pushSession.invalidate(); if progress != 0 { progress = 0 } }
    @discardableResult
    func arrange(displayID: CGDirectDisplayID, origin: CGPoint) -> Bool {
        guard let s = snapshot, !isArranging, !isChangingDisplays else { return false }
        isArranging = true; invalidateAutomation()
        let error = DisplayManager.arrange(s, displayID: displayID, origin: origin)
        isArranging = false
        refresh()
        if let error { notice = error; return false }
        cooldownUntil = ProcessInfo.processInfo.systemUptime + 3
        notice = "显示器排列已更新"
        return true
    }
    func move(_ edge: Side) {
        move(displayID: manualDisplayID, edge: edge)
    }
    @discardableResult
    private func move(displayID: CGDirectDisplayID, edge: Side) -> Bool {
        guard let s = snapshot, let target = s.secondaries.first(where: { $0.id == displayID }) else { return false }
        let obstacles = s.displays.filter { $0.id != displayID && $0.id != s.mainID }.map(\.bounds)
        let origin = LayoutGeometry.nextAvailableOrigin(edge: edge, main: s.main, target: target.bounds, obstacles: obstacles)
        return arrange(displayID: displayID, origin: origin)
    }
    private func updateTap() {
        guard startsServices else { return }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); self.source = nil }
        if let tap { CFMachPortInvalidate(tap); self.tap = nil }
        guard enabled, CGPreflightListenEventAccess() else { return }
        let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let model = Unmanaged<AppModel>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { if let tap = model.tap { CGEvent.tapEnable(tap: tap, enable: true) }; model.invalidateAutomation() }
            else if type == .mouseMoved { model.handle(event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque()) else { status = "无法监听鼠标事件，请检查输入监控权限。"; return }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
    private func handle(_ event: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        guard automaticReady, !isArranging, now >= cooldownUntil, let s = snapshot,
              !CGEventSource.buttonState(.combinedSessionState, button: .left),
              !CGEventSource.buttonState(.combinedSessionState, button: .right),
              !CGEventSource.buttonState(.combinedSessionState, button: .center) else { reset(); return }
        let p = event.location
        let dx = CGFloat(event.getIntegerValueField(.mouseEventDeltaX))
        let dy = CGFloat(event.getIntegerValueField(.mouseEventDeltaY))
        guard let edge = LayoutGeometry.outwardEdge(point: p, deltaX: dx, deltaY: dy, main: s.main),
              !s.secondaries.contains(where: { LayoutGeometry.traversable(edge: edge, at: p, main: s.main, secondary: $0.bounds) }),
              !pauseSettings.reservedSides.contains(edge) else { reset(); return }
        progress = pushSession.update(edge: edge, time: now, duration: duration, allowed: automaticReady)
        if progress >= 1 {
            cooldownUntil = now + 3
            reset()
            let ticket = pushSession.generation
            let ids = s.secondaries.map(\.id)
            guard let target = displayCycle.next(in: ids) else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // The app can change after the final mouse event but before this
                // block runs. Refresh both protection and display geometry here.
                self.refresh()
                guard self.pushSession.permitsQueuedMove(ticket: ticket, allowed: self.automaticReady),
                      self.snapshot == s else { return }
                if self.move(displayID: target, edge: edge) { self.displayCycle.didMove(target) }
            }
        }
    }
}
