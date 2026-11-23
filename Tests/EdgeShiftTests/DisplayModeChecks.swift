import Foundation
import CoreGraphics
#if !EDGESHIFT_STANDALONE
@testable import EdgeShift
#endif

// Shared by XCTest and the Command Line Tools runner; all display writes are mocked.
enum DisplayModeChecks {
    static func arrangementTransaction(expect: @escaping (Bool, String) -> Void) {
        let suite = "org.edgeshift.arrangementchecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "enabled")
        var observed: DisplayTopology? = topology([display(1), display(2)])
        var reads = 0
        var pending: ((String?) -> Void)?
        var queued = true
        var results: [Bool] = []
        let model = AppModel(defaults: defaults, startsServices: false, readTopology: {
            reads += 1
            return observed
        }, applyArrangement: { _, id, origin, completion in
            expect(id == 2 && origin == CGPoint(x: -1920, y: 0), "异步排列使用选中的目标与合法位置")
            if queued { pending = completion; return true }
            completion("模拟立即拒绝")
            return false
        })
        expect(model.moveAsync(displayID: 2, edge: .left) { results.append($0) }, "有效排列进入异步配置")
        let before = reads
        model.refresh()
        model.refresh()
        expect(reads == before, "配置过程中不在主线程轮询 WindowServer")
        expect(!model.moveAsync(displayID: 2, edge: .left) { results.append($0) }, "配置期间拒绝重复排列")
        observed = topology([display(1), display(2, origin: CGPoint(x: -1920, y: 0))])
        pending?(nil)
        pending = nil
        expect(results == [true] && reads > before && model.snapshot?.secondaries.first?.bounds.minX == -1920,
               "完成后恢复查询并回读真实排列")
        expect(model.moveAsync(displayID: 2, edge: .left) { results.append($0) }, "完成后可以接收下一次请求")
        pending?("模拟提交失败")
        pending = nil
        expect(results == [true, false] && model.notice == "模拟提交失败", "提交失败不会伪报成功")
        queued = false
        expect(!model.moveAsync(displayID: 2, edge: .left) { results.append($0) }, "立即拒绝返回未启动")
        let after = reads
        model.refresh()
        expect(reads > after && results == [true, false, false], "立即失败后仍恢复查询")
    }

    static func display(_ id: CGDirectDisplayID, source: CGDirectDisplayID? = nil, active: Bool = true,
                        origin: CGPoint? = nil) -> ConnectedDisplay {
        ConnectedDisplay(id: id, bounds: CGRect(origin: origin ?? CGPoint(x: Int((source ?? id) - 1) * 1920, y: 0),
                                               size: CGSize(width: 1920, height: 1080)),
                         name: "屏幕 \(id)", isActive: active, mirrorSourceID: source)
    }

    static func topology(_ displays: [ConnectedDisplay], mainID: CGDirectDisplayID = 1) -> DisplayTopology {
        DisplayTopology(mainID: mainID, displays: displays)
    }

    static func classification(expect: (Bool, String) -> Void) {
        let extended = topology([display(1), display(2)])
        expect(extended.arrangement?.secondaries.map(\.id) == [2], "双屏扩展可排列")
        for active in [false, true] {
            let mirrored = topology([display(1), display(2, source: 1, active: active)])
            expect(mirrored.secondaries.map(\.id) == [2], "硬件和软件复制屏幕都保留在选择器中")
            expect(mirrored.arrangement == nil, "全部复制时无独立扩展副屏")
            expect(mirrored.selection(preserving: 2) == 2, "复制后保留选中屏幕")
        }
        let mixed = topology([display(1), display(2, source: 1), display(3)])
        expect(mixed.arrangement?.displays.map(\.id) == [1, 3], "混合模式排除复制屏幕")
        expect(mixed.arrangement?.number(for: 3) == 3, "混合模式编号与选择器一致")
        expect(mixed.selection(preserving: 3) == 3, "保留仍连接的选择")
        expect(mixed.selection(preserving: 99) == 2, "断开的选择回退到首块副屏")
        expect(topology([display(1)]).selection(preserving: 2) == 0, "没有副屏时清空选择")
        expect(topology([display(1), display(2, active: false)]).arrangement == nil, "非活动屏幕不参与排列")
        expect(topology([display(2)]).arrangement == nil, "主屏缺失时不生成排列快照")
        let source = topology([display(1), display(2), display(3, source: 2)])
        expect(source.arrangement?.secondaries.map(\.id) == [2], "其他复制组的源仍代表一个独立桌面")
        expect(source.modeChangeError(displayID: 2, mode: .mirrored) != nil, "不能将复制源改为复制屏幕")
        expect(source.modeChangeError(displayID: 3, mode: .extended) == nil, "可单独解除复制关系")
    }

    static func configuration(expect: (Bool, String) -> Void) {
        let extended = topology([display(1), display(2), display(3)])
        let mixed = topology([display(1), display(2, source: 1), display(3)])
        var writes: [(CGDirectDisplayID, CGDirectDisplayID)] = []
        let apply: (CGDirectDisplayID, CGDirectDisplayID) -> String? = { writes.append(($0, $1)); return nil }
        let error = DisplayManager.setMode(extended, displayID: 2, mode: .mirrored,
                                          readTopology: { extended }, applyMirror: apply)
        expect(error == nil && writes.count == 1 && writes[0].0 == 2 && writes[0].1 == 1,
               "仅设置选中副屏复制主屏")
        writes.removeAll()
        expect(DisplayManager.setMode(mixed, displayID: 2, mode: .extended,
                                      readTopology: { mixed }, applyMirror: apply) == nil, "支持解除复制")
        expect(writes.count == 1 && writes[0].0 == 2 && writes[0].1 == kCGNullDirectDisplay,
               "仅解除选中副屏的复制关系")
        writes.removeAll()
        expect(DisplayManager.setMode(extended, displayID: 2, mode: .mirrored,
                                      readTopology: { mixed }, applyMirror: apply) != nil, "拒绝过期状态")
        expect(DisplayManager.setMode(extended, displayID: 99, mode: .mirrored,
                                      readTopology: { extended }, applyMirror: apply) != nil, "拒绝断开的目标")
        expect(DisplayManager.setMode(extended, displayID: 1, mode: .mirrored,
                                      readTopology: { extended }, applyMirror: apply) != nil, "不修改主屏")
        let source = topology([display(1), display(2), display(3, source: 2)])
        expect(DisplayManager.setMode(source, displayID: 2, mode: .mirrored,
                                      readTopology: { source }, applyMirror: apply) != nil, "复制源依赖检查先于系统写入")
        expect(DisplayManager.setMode(extended, displayID: 2, mode: .extended,
                                      readTopology: { extended }, applyMirror: apply) == nil, "相同模式无需写入")
        expect(writes.isEmpty, "无效操作均不写入系统")
        expect(DisplayManager.setMode(extended, displayID: 2, mode: .mirrored,
                                      readTopology: { extended }, applyMirror: { _, _ in "模拟配置失败" }) == "模拟配置失败",
               "向调用方返回配置错误")
    }

    static func model(expect: @escaping (Bool, String) -> Void) {
        let suite = "org.edgeshift.displaychecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "enabled")
        var observed: DisplayTopology? = topology([display(1), display(2), display(3)])
        var now = 100.0
        var failure: String?
        var calls = 0
        let model = AppModel(defaults: defaults, startsServices: false, readTopology: { observed },
                             applyDisplayMode: { _, id, _ in
                                 calls += 1
                                 expect(id == 2, "切换仅作用于选中目标")
                                 return failure
                             }, uptime: { now })
        expect(model.manualDisplayID == 2 && model.canArrangeSelectedDisplay, "默认选中第一块副屏")
        model.progress = 0.75
        model.setDisplayMode(.mirrored)
        expect(model.progress == 0 && model.isSwitchingMode && !model.automaticReady, "切换清空推动并暂停自动排列")
        expect(model.selectedDisplay?.mode == .extended, "等待回读时不提前显示成功")
        expect(!model.canArrangeSelectedDisplay, "切换期间禁用快捷排列")
        expect(!model.arrange(displayID: 2, origin: .zero), "切换期间拒绝拖动排列")
        model.setDisplayMode(.extended)
        expect(calls == 1, "切换期间拒绝重复请求")
        observed = topology([display(1), display(2, source: 1, active: false), display(3)])
        model.refresh()
        expect(!model.isSwitchingMode && model.selectedDisplay?.mode == .mirrored, "系统回读确认复制成功")
        expect(model.manualDisplayID == 2 && !model.canArrangeSelectedDisplay, "复制后保留选中目标并禁用快捷排列")
        expect(model.snapshot?.secondaries.map(\.id) == [3], "其他扩展副屏继续参与排列")
        model.manualDisplayID = 3
        expect(model.canArrangeSelectedDisplay, "仍可手动调整其他扩展副屏")
        model.manualDisplayID = 2
        failure = "模拟应用配置失败"
        model.setDisplayMode(.extended)
        expect(!model.isSwitchingMode && model.selectedDisplay?.mode == .mirrored, "失败后保留系统实际模式")
        expect(model.notice == failure, "显示具体配置失败原因")
        failure = nil
        model.setDisplayMode(.extended)
        observed = topology([display(1), display(2), display(3)])
        model.refresh()
        expect(!model.isSwitchingMode && model.canArrangeSelectedDisplay, "切回扩展后恢复排列")
        model.setDisplayMode(.mirrored)
        now += 5
        model.refresh()
        expect(!model.isSwitchingMode && model.selectedDisplay?.mode == .extended, "超时不改变实际显示模式")
        expect(model.notice?.contains("未确认") == true, "超时给出未确认提示")
        model.setDisplayMode(.mirrored)
        observed = topology([display(1), display(3)])
        model.refresh()
        expect(!model.isSwitchingMode && model.manualDisplayID == 3, "切换中拔出目标则结束等待并回退选择")
        expect(model.notice?.contains("断开") == true, "拔出目标给出明确提示")
        observed = topology([display(1), display(2), display(3)])
        model.refresh()
        model.manualDisplayID = 2
        observed = topology([display(1), display(3)])
        let oldCalls = calls
        model.setDisplayMode(.mirrored)
        expect(calls == oldCalls && model.manualDisplayID == 3, "点击时目标断开不能误操作回退屏幕")
        observed = topology([display(1), display(3, source: 1)])
        model.refresh()
        expect(model.selectedDisplay?.mode == .mirrored && model.snapshot == nil, "同步外部切换为全复制模式")
        expect(model.status.contains("没有可排列"), "全复制模式显示自动暂停原因")
        observed = nil
        model.refresh()
        expect(model.selectedDisplay == nil && model.manualDisplayID == 0, "查询失败不保留可操作的过期目标")
        expect(defaults.object(forKey: "loginAttempted") == nil, "测试初始化不注册登录项或启动监听")
    }

    static func mainDisplayConfiguration(expect: (Bool, String) -> Void) {
        let current = topology([
            display(1), display(2, origin: CGPoint(x: -1920, y: 150)),
            display(3, origin: CGPoint(x: 0, y: -1080)),
            display(4, source: 2, active: false, origin: CGPoint(x: -1920, y: 150))
        ])
        let expected = [DisplayOrigin(displayID: 1, x: 1920, y: -150),
                        DisplayOrigin(displayID: 3, x: 1920, y: -1230),
                        DisplayOrigin(displayID: 2, x: 0, y: 0)]
        expect(current.originsForMainDisplay(2) == expected, "主屏切换平移全部独立桌面并最后设置新主屏")
        var writes: [[DisplayOrigin]] = []
        let apply: ([DisplayOrigin]) -> String? = { writes.append($0); return nil }
        expect(DisplayManager.setMainDisplay(current, displayID: 2, readTopology: { current }, applyOrigins: apply) == nil,
               "可将带复制屏的独立副屏设为主屏")
        expect(writes == [expected], "单次配置包含所有独立屏，且不配置复制屏的位置")
        writes.removeAll()
        expect(DisplayManager.setMainDisplay(current, displayID: 1, readTopology: { current }, applyOrigins: apply) == nil,
               "选择当前主屏无需系统写入")
        expect(DisplayManager.setMainDisplay(current, displayID: 4, readTopology: { current }, applyOrigins: apply) != nil,
               "复制屏必须先切回扩展")
        expect(DisplayManager.setMainDisplay(current, displayID: 99, readTopology: { current }, applyOrigins: apply) != nil,
               "拒绝将断开的目标设为主屏")
        expect(DisplayManager.setMainDisplay(current, displayID: 2, readTopology: { nil }, applyOrigins: apply) != nil,
               "主屏切换拒绝过期连接状态")
        let sleeping = topology([display(1), display(2, active: false)])
        expect(DisplayManager.setMainDisplay(sleeping, displayID: 2, readTopology: { sleeping }, applyOrigins: apply) != nil,
               "非活动屏幕不能设为主屏")
        let overflow = topology([display(1), display(2, origin: CGPoint(x: CGFloat(Int32.max) + 2, y: 0))])
        expect(DisplayManager.setMainDisplay(overflow, displayID: 2, readTopology: { overflow }, applyOrigins: apply) != nil,
               "坐标溢出不崩溃且不写入系统")
        expect(writes.isEmpty, "所有无效主屏请求都不修改系统")
        expect(DisplayManager.setMainDisplay(current, displayID: 2, readTopology: { current },
                                             applyOrigins: { _ in "模拟主屏配置失败" }) == "模拟主屏配置失败",
               "主屏配置失败返回具体原因")
    }

    static func mainDisplayModel(expect: (Bool, String) -> Void) {
        let suite = "org.edgeshift.mainchecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "enabled")
        var observed: DisplayTopology? = topology([display(1), display(2), display(3)])
        var now = 100.0
        var failure: String?
        var mainRequests: [CGDirectDisplayID] = []
        var copyRequests: [(CGDirectDisplayID, CGDirectDisplayID)] = []
        let model = AppModel(defaults: defaults, startsServices: false, readTopology: { observed },
                             applyDisplayMode: { state, id, _ in copyRequests.append((id, state.mainID)); return nil },
                             applyMainDisplay: { _, id in mainRequests.append(id); return failure }, uptime: { now })
        model.progress = 0.7
        model.setMainDisplay(2)
        expect(model.isChangingDisplays && model.pendingMainDisplayChange?.displayID == 2 && model.progress == 0,
               "切换主屏时清空推动并进入忙碌状态")
        expect(model.topology?.mainID == 1 && !model.canArrangeSelectedDisplay && !model.automaticReady,
               "等待系统回读时保留原主屏并禁止排列")
        model.setMainDisplay(3)
        model.setDisplayMode(.mirrored)
        expect(mainRequests == [2] && copyRequests.isEmpty, "主屏切换期间拒绝其他配置请求")
        expect(!model.arrange(displayID: 3, origin: .zero), "主屏切换期间拒绝手动排列")
        observed = topology([display(1, origin: CGPoint(x: -1920, y: 0)), display(2, origin: .zero),
                             display(3, origin: CGPoint(x: 1920, y: 0))], mainID: 2)
        model.refresh()
        expect(!model.isChangingDisplays && model.topology?.mainID == 2, "系统回读确认新主屏")
        expect(model.snapshot?.mainID == 2 && model.manualDisplayID == 1 && model.canArrangeSelectedDisplay,
               "原主屏成为可选择和排列的副屏")
        expect(model.notice?.contains("原主屏现为副屏") == true, "保留相对布局的切换显示成功")
        model.setDisplayMode(.mirrored)
        expect(copyRequests.count == 1 && copyRequests[0].0 == 1 && copyRequests[0].1 == 2,
               "后续复制请求使用新主屏作为来源")
        model.setMainDisplay(3)
        expect(mainRequests == [2], "模式切换期间拒绝主屏切换")
        observed = topology([display(1, source: 2, active: false, origin: .zero), display(2, origin: .zero),
                             display(3, origin: CGPoint(x: 1920, y: 0))], mainID: 2)
        model.refresh()
        model.setMainDisplay(1)
        expect(mainRequests == [2] && model.notice?.contains("先将该屏幕切回扩展") == true,
               "应用层拒绝将复制屏直接设为主屏")
        failure = "模拟主屏应用失败"
        model.setMainDisplay(3)
        expect(!model.isChangingDisplays && model.topology?.mainID == 2 && model.notice == failure,
               "失败后保留系统真实主屏并显示原因")
        failure = nil
        model.setMainDisplay(3)
        now += 5
        model.refresh()
        expect(!model.isChangingDisplays && model.topology?.mainID == 2 && model.notice?.contains("未确认") == true,
               "主屏切换超时不伪报成功")
        model.setMainDisplay(3)
        observed = topology([display(1, source: 2, active: false, origin: .zero), display(2, origin: .zero)], mainID: 2)
        model.refresh()
        expect(!model.isChangingDisplays && model.notice?.contains("断开") == true, "切换中拔出目标主屏会结束等待")
        let oldRequests = mainRequests
        model.setMainDisplay(3)
        expect(mainRequests == oldRequests, "已断开的主屏请求不误操作其他显示器")
        observed = topology([display(1), display(2), display(3)])
        model.refresh()
        expect(model.snapshot?.mainID == 1 && model.manualDisplayID == 2, "同步系统设置里的外部主屏变更")
        model.setMainDisplay(3)
        observed = topology([display(1, origin: CGPoint(x: -3840, y: 0)),
                             display(2, origin: CGPoint(x: -1920, y: 200)), display(3, origin: .zero)], mainID: 3)
        model.refresh()
        expect(!model.isChangingDisplays && model.topology?.mainID == 3 && model.notice?.contains("系统同时调整") == true,
               "系统调整相对布局时显示提醒")
    }

    static func switchRipples(expect: @escaping (Bool, String) -> Void) {
        let suite = "org.edgeshift.switchripplechecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "enabled")
        defaults.set(true, forKey: "rippleEnabled")

        var observed: DisplayTopology? = topology([display(1), display(2, origin: CGPoint(x: 1920, y: 0))])
        var events: [SwitchRippleEvent] = []
        var pendingArrange: ((String?) -> Void)?
        let model = AppModel(
            defaults: defaults,
            startsServices: false,
            readTopology: { observed },
            applyArrangement: { _, _, _, completion in
                pendingArrange = completion
                return true
            },
            onSwitchRipple: { events.append($0) }
        )

        let before = model.snapshot!
        let pushPoint = CGPoint(x: 0, y: 540)
        expect(model.moveAsync(displayID: 2, edge: .left) { ok in
            model.finishAutomaticSwitch(target: 2, previousSnapshot: before, edge: .left, point: pushPoint, succeeded: ok)
        }, "发起向左侧切换副屏")
        observed = topology([display(1), display(2, origin: CGPoint(x: -1920, y: 0))])
        pendingArrange?(nil)
        pendingArrange = nil

        expect(events == [SwitchRippleEvent(
            mainDisplayID: 1, mainEdge: .left, mainPoint: pushPoint,
            secondaryDisplayID: 2, secondaryEdge: .right, secondaryPoint: CGPoint(x: 0, y: 540)
        )], "屏幕切换成功瞬间在主屏和刚切换过来的副屏接缝两侧同步触发波纹")

        // Failed arrangement or unchanged snapshot does not trigger switch ripples.
        let secondBefore = model.snapshot!
        expect(model.moveAsync(displayID: 2, edge: .right) { ok in
            model.finishAutomaticSwitch(target: 2, previousSnapshot: secondBefore, edge: .right, point: CGPoint(x: 1919, y: 400), succeeded: ok)
        }, "发起向右侧切换副屏（模拟失败）")
        pendingArrange?("模拟失败")
        pendingArrange = nil
        expect(events.count == 1, "切换失败时不触发副屏波纹")

        // Disabling rippleEnabled suppresses switch ripples even on a successful switch.
        model.rippleEnabled = false
        let thirdBefore = model.snapshot!
        expect(model.moveAsync(displayID: 2, edge: .right) { ok in
            model.finishAutomaticSwitch(target: 2, previousSnapshot: thirdBefore, edge: .right, point: CGPoint(x: 1919, y: 400), succeeded: ok)
        }, "关闭水波后再次切换副屏")
        observed = topology([display(1), display(2, origin: CGPoint(x: 1920, y: 0))])
        pendingArrange?(nil)
        pendingArrange = nil
        expect(events.count == 1, "关闭水波折射后不触发任何切换动画")
    }
}
