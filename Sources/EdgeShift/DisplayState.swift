import Foundation
import CoreGraphics

enum DisplayMode: String, CaseIterable {
    case extended = "扩展"
    case mirrored = "复制"
}

struct DisplayItem: Equatable, Identifiable {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let name: String
}

struct ConnectedDisplay: Equatable, Identifiable {
    let id: CGDirectDisplayID
    let bounds: CGRect
    let name: String
    let isActive: Bool
    let mirrorSourceID: CGDirectDisplayID?

    var mode: DisplayMode { mirrorSourceID == nil ? .extended : .mirrored }
    var item: DisplayItem { DisplayItem(id: id, bounds: bounds, name: name) }
}

struct DisplaySnapshot: Equatable {
    let mainID: CGDirectDisplayID
    let displays: [DisplayItem]
    // Keep numbering consistent with the full connected list in mixed mode.
    let displayNumbers: [CGDirectDisplayID: Int]
    var main: CGRect { displays.first(where: { $0.id == mainID })!.bounds }
    var secondaries: [DisplayItem] { displays.filter { $0.id != mainID } }
    func number(for id: CGDirectDisplayID) -> Int { displayNumbers[id] ?? 0 }
}

struct DisplayTopology: Equatable {
    let mainID: CGDirectDisplayID
    // Preserve the order returned by CGGetOnlineDisplayList, including mirrors.
    let displays: [ConnectedDisplay]
    var secondaries: [ConnectedDisplay] { displays.filter { $0.id != mainID } }
    var independentDisplays: [ConnectedDisplay] { displays.filter { $0.isActive && $0.mirrorSourceID == nil } }
    func number(for id: CGDirectDisplayID) -> Int { (displays.firstIndex { $0.id == id } ?? -1) + 1 }

    var arrangement: DisplaySnapshot? {
        let independent = independentDisplays
        guard independent.count >= 2, independent.contains(where: { $0.id == mainID }) else { return nil }
        return DisplaySnapshot(mainID: mainID, displays: independent.map(\.item),
                               displayNumbers: Dictionary(uniqueKeysWithValues: displays.enumerated().map { ($0.element.id, $0.offset + 1) }))
    }

    func selection(preserving id: CGDirectDisplayID) -> CGDirectDisplayID {
        secondaries.contains(where: { $0.id == id }) ? id : secondaries.first?.id ?? 0
    }

    func modeChangeError(displayID: CGDirectDisplayID, mode: DisplayMode) -> String? {
        guard let target = secondaries.first(where: { $0.id == displayID }) else { return "找不到目标副屏，请重新选择。" }
        guard independentDisplays.contains(where: { $0.id == mainID }) else { return "主屏状态暂不可用，请稍后重试。" }
        if mode == .mirrored && displays.contains(where: { $0.mirrorSourceID == target.id }) {
            return "此显示器正在作为其他屏幕的复制源，请先解除这些屏幕的复制关系。"
        }
        return nil
    }

    func mainDisplayChangeError(displayID: CGDirectDisplayID) -> String? {
        guard let target = displays.first(where: { $0.id == displayID }) else { return "找不到目标显示器，请重新选择。" }
        guard target.mirrorSourceID == nil else { return "请先将该屏幕切回扩展，再设为主显示器。" }
        guard target.isActive, independentDisplays.contains(where: { $0.id == mainID }) else {
            return "显示器暂未就绪，请稍后重试。"
        }
        return nil
    }

    func originsForMainDisplay(_ displayID: CGDirectDisplayID) -> [DisplayOrigin]? {
        guard mainDisplayChangeError(displayID: displayID) == nil,
              let target = displays.first(where: { $0.id == displayID }) else { return nil }
        // Translate the entire independent desktop; never configure a mirror's
        // origin, because doing so would remove it from its mirroring set.
        let ordered = independentDisplays.filter { $0.id != displayID } + [target]
        var origins: [DisplayOrigin] = []
        for display in ordered {
            guard let x = Int32(exactly: (display.bounds.minX - target.bounds.minX).rounded()),
                  let y = Int32(exactly: (display.bounds.minY - target.bounds.minY).rounded()) else { return nil }
            origins.append(DisplayOrigin(displayID: display.id, x: x, y: y))
        }
        return origins
    }
}

struct DisplayOrigin: Equatable {
    let displayID: CGDirectDisplayID
    let x: Int32
    let y: Int32
}

struct PendingMainDisplayChange {
    let displayID: CGDirectDisplayID
    let origins: [DisplayOrigin]
    let deadline: TimeInterval

    func preservesLayout(in topology: DisplayTopology) -> Bool {
        origins.allSatisfy { origin in
            topology.independentDisplays.first(where: { $0.id == origin.displayID })?.bounds.origin ==
                CGPoint(x: Int(origin.x), y: Int(origin.y))
        }
    }
}

struct PendingDisplayModeChange {
    let displayID: CGDirectDisplayID
    let mirrorSourceID: CGDirectDisplayID?
    let deadline: TimeInterval

    func isApplied(to topology: DisplayTopology) -> Bool {
        guard let display = topology.secondaries.first(where: { $0.id == displayID }) else { return false }
        return display.mirrorSourceID == mirrorSourceID && (mirrorSourceID != nil || display.isActive)
    }
}
