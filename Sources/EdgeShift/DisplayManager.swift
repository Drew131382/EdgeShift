import AppKit
import CoreGraphics

enum DisplayManager {
    static func topology() -> DisplayTopology? {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success, count > 0 else { return nil }
        ids = Array(ids.prefix(Int(count)))
        let systemMain = CGMainDisplayID()
        let mainSource = CGDisplayMirrorsDisplay(systemMain)
        let main = mainSource == kCGNullDirectDisplay ? systemMain : mainSource
        guard ids.contains(main) else { return nil }
        let screens = NSScreen.screens
        let displays = ids.map { id in
            let name = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName ?? "显示器"
            let source = CGDisplayMirrorsDisplay(id)
            return ConnectedDisplay(id: id, bounds: CGDisplayBounds(id), name: name,
                                    isActive: CGDisplayIsActive(id) != 0,
                                    mirrorSourceID: source == kCGNullDirectDisplay ? nil : source)
        }
        return DisplayTopology(mainID: main, displays: displays)
    }

    static func snapshot() -> DisplaySnapshot? { topology()?.arrangement }

    static func setMode(_ topology: DisplayTopology, displayID: CGDirectDisplayID, mode: DisplayMode,
                        readTopology: () -> DisplayTopology? = DisplayManager.topology,
                        applyMirror: (CGDirectDisplayID, CGDirectDisplayID) -> String? = DisplayManager.configureMirror) -> String? {
        guard readTopology() == topology else { return "显示器状态已改变，请重试。" }
        if let error = topology.modeChangeError(displayID: displayID, mode: mode) { return error }
        guard topology.secondaries.first(where: { $0.id == displayID })?.mode != mode else { return nil }
        return applyMirror(displayID, mode == .mirrored ? topology.mainID : kCGNullDirectDisplay)
    }

    private static func configureMirror(displayID: CGDirectDisplayID, sourceID: CGDirectDisplayID) -> String? {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return "无法开始显示器配置。" }
        let result = CGConfigureDisplayMirrorOfDisplay(config, displayID, sourceID)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            return "无法设置显示模式（\(result.rawValue)）。"
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else { return "无法应用显示模式（\(complete.rawValue)）。" }
        return nil
    }

    static func setMainDisplay(_ topology: DisplayTopology, displayID: CGDirectDisplayID,
                               readTopology: () -> DisplayTopology? = DisplayManager.topology,
                               applyOrigins: ([DisplayOrigin]) -> String? = DisplayManager.configureMainDisplayOrigins) -> String? {
        guard readTopology() == topology else { return "显示器状态已改变，请重试。" }
        if let error = topology.mainDisplayChangeError(displayID: displayID) { return error }
        guard displayID != topology.mainID else { return nil }
        guard let origins = topology.originsForMainDisplay(displayID) else { return "显示器坐标超出可配置范围。" }
        return applyOrigins(origins)
    }

    private static func configureMainDisplayOrigins(_ origins: [DisplayOrigin]) -> String? {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return "无法开始显示器配置。" }
        // Apply the chosen main display at (0, 0) last, in the same transaction.
        for origin in origins {
            let result = CGConfigureDisplayOrigin(config, origin.displayID, origin.x, origin.y)
            guard result == .success else {
                CGCancelDisplayConfiguration(config)
                return "无法设置主显示器位置（\(result.rawValue)）。"
            }
        }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else { return "无法应用主显示器设置（\(complete.rawValue)）。" }
        return nil
    }

    private static let configQueue = DispatchQueue(label: "com.edgeshift.display-config", qos: .userInteractive)

    static func arrange(_ snapshot: DisplaySnapshot, displayID: CGDirectDisplayID, origin: CGPoint) -> String? {
        switch prepareArrange(snapshot, displayID: displayID, origin: origin) {
        case .alreadyAtDestination:
            return nil
        case .failure(let error):
            return error
        case .ready(let destination):
            if let error = applyDisplayOrigin(displayID: displayID, origin: destination.origin) {
                return error
            }
            return postArrangeCheck(snapshot, displayID: displayID)
        }
    }

    @discardableResult
    static func arrangeAsync(_ snapshot: DisplaySnapshot, displayID: CGDirectDisplayID, origin: CGPoint,
                             completion: @escaping (String?) -> Void) -> Bool {
        switch prepareArrange(snapshot, displayID: displayID, origin: origin) {
        case .alreadyAtDestination:
            completion(nil)
            return false
        case .failure(let error):
            completion(error)
            return false
        case .ready(let destination):
            configQueue.async {
                let error = applyDisplayOrigin(displayID: displayID, origin: destination.origin)
                DispatchQueue.main.async {
                    if let error {
                        completion(error)
                    } else {
                        completion(postArrangeCheck(snapshot, displayID: displayID))
                    }
                }
            }
            return true
        }
    }

    private enum ArrangePlan {
        case alreadyAtDestination
        case failure(String)
        case ready(CGRect)
    }

    private static func prepareArrange(_ snapshot: DisplaySnapshot, displayID: CGDirectDisplayID, origin: CGPoint) -> ArrangePlan {
        guard self.snapshot() == snapshot else { return .failure("显示器状态已改变，请重试。") }
        guard let target = snapshot.secondaries.first(where: { $0.id == displayID }) else { return .failure("找不到目标副屏，请重试。") }
        let destination = CGRect(origin: CGPoint(x: origin.x.rounded(), y: origin.y.rounded()), size: target.bounds.size)
        let others = snapshot.displays.filter { $0.id != displayID }.map(\.bounds)
        guard !others.contains(where: { $0.intersects(destination) }) else { return .failure("目标位置与其他屏幕重叠，请调整位置。") }
        guard LayoutGeometry.allConnected(others + [destination]) else { return .failure("调整会使屏幕布局断开，请先手动调整其他屏幕。") }
        if destination.origin == target.bounds.origin { return .alreadyAtDestination }
        return .ready(destination)
    }

    private static func applyDisplayOrigin(displayID: CGDirectDisplayID, origin: CGPoint) -> String? {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return "无法开始显示器配置。" }
        let result = CGConfigureDisplayOrigin(config, displayID, Int32(origin.x), Int32(origin.y))
        guard result == .success else { CGCancelDisplayConfiguration(config); return "无法设置显示器位置（\(result.rawValue)）。" }
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        guard complete == .success else { return "无法应用显示器位置（\(complete.rawValue)）。" }
        return nil
    }

    private static func postArrangeCheck(_ snapshot: DisplaySnapshot, displayID: CGDirectDisplayID) -> String? {
        // macOS can adjust other screens as part of its own configuration rules.
        if let updated = self.snapshot() {
            let changedOther = snapshot.displays.filter { $0.id != displayID }.contains { old in
                updated.displays.first(where: { $0.id == old.id })?.bounds != old.bounds
            }
            if updated.mainID != snapshot.mainID || changedOther { return "系统同时调整了其他显示器，请检查显示器排列。" }
        }
        return nil
    }
}
