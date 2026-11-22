import SwiftUI
import AppKit
import Combine

// AppKit lifecycle only. A SwiftUI `Settings { EmptyView() }` scene was the
// app's sole scene, so macOS opened its window ("EdgeShift Settings") on every
// launch. This app lives entirely in the menu bar and owns its windows itself,
// so it runs NSApplication directly instead of hosting a SwiftUI scene.
@main
enum EdgeShiftMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let controller = MenuBarController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private var progressObserver: AnyCancellable?
    private lazy var popover = Self.makePopover(model: model)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.toolTip = "EdgeShift · 显示器设置"
        item.button?.setAccessibilityLabel("EdgeShift，主屏与副屏")
        progressObserver = model.$progress.map { $0 > 0 }.removeDuplicates().sink { [weak self] pushing in
            let image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "EdgeShift")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: pushing ? .semibold : .regular))
            image?.isTemplate = true
            self?.statusItem?.button?.image = image
        }
    }

    static func makePopover(model: AppModel) -> NSPopover {
        // NSPopover owns the entire frame, material, corners and shadow. Do not
        // replace its shape with a mask on the SwiftUI scroll container.
        let popover = NSPopover()
        let content = MenuContentController(rootView: ContentView(model: model))
        content.sizingOptions.insert(.preferredContentSize)
        content.onCancel = { [weak popover] in popover?.performClose(nil) }
        popover.contentViewController = content
        popover.contentSize = NSSize(width: 350, height: 760)
        popover.behavior = .transient
        return popover
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

private final class MenuContentController: NSHostingController<ContentView> {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @StateObject private var menuLayout = MenuLayout()

    var body: some View {
        ScrollView {
            menuContent
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: MenuContentHeightKey.self, value: proxy.size.height)
                })
        }
        .frame(width: 350, height: min(menuLayout.contentHeight, max(300, (NSScreen.main?.visibleFrame.height ?? 800) - 60)))
        .onPreferenceChange(MenuContentHeightKey.self) { height in
            if height > 0, abs(menuLayout.contentHeight - height) > 0.5 { menuLayout.contentHeight = height }
        }
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("EdgeShift").font(.title3.weight(.semibold))
                    Text("显示器设置").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(model.automaticReady ? Color.green : Color.orange).frame(width: 8, height: 8)
                    .accessibilityLabel(model.automaticReady ? "自动排列已就绪" : "自动排列未就绪或已暂停")
            }
            mainDisplayControls
            displayModeControls
            if let snapshot = model.snapshot {
                ArrangementView(snapshot: snapshot, selectedID: model.manualDisplayID, onMove: { id, origin in
                    guard model.snapshot == snapshot else { return }
                    model.manualDisplayID = id
                    model.arrange(displayID: id, origin: origin)
                })
                    .frame(height: 145)
                    .allowsHitTesting(!model.isChangingDisplays)
                Text("拖动扩展副屏贴合其他屏幕；自动排列按系统识别顺序轮流选择扩展副屏。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ContentUnavailableViewCompat(
                    title: model.topology == nil ? "正在读取显示器状态" :
                        (model.selectedDisplay?.mode == .mirrored ? "副屏正在复制显示" : "暂无可排列的扩展副屏"),
                    message: model.selectedDisplay == nil ? "连接至少两块显示器后可选择扩展或复制。" : "在上方选择“扩展”后可调整排列。")
                    .frame(maxWidth: .infinity).frame(height: 135)
            }
            if model.selectedDisplay != nil {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        moveButton("移到上方", icon: "arrow.up", side: .top)
                        moveButton("移到下方", icon: "arrow.down", side: .bottom)
                    }
                    HStack(spacing: 8) {
                        moveButton("移到左侧", icon: "arrow.left", side: .left)
                        moveButton("移到右侧", icon: "arrow.right", side: .right)
                    }
                }.buttonStyle(.bordered)
                    .disabled(!model.canArrangeSelectedDisplay)
            }
            Divider()
            Toggle("边缘推动自动排列", isOn: $model.enabled)
            HStack {
                Text("持续推动")
                Spacer()
                Picker("持续推动", selection: $model.duration) {
                    Text("0.3 秒").tag(0.3)
                    Text("0.5 秒").tag(0.5)
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("3 秒").tag(3.0)
                }.labelsHidden().frame(width: 100)
            }.disabled(!model.enabled)
            ProgressView(value: model.progress)
                .controlSize(.small)
                .opacity(model.progress > 0 ? 1 : 0)
                .accessibilityHidden(model.progress <= 0)
            Toggle("登录时自动启动", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            Toggle("边缘切换水波折射", isOn: $model.rippleEnabled)
            if model.rippleEnabled && !model.screenCapturePermission {
                HStack(spacing: 8) {
                    Text("真实桌面像素折射需“屏幕录制”权限")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("去授权") { model.requestScreenCapturePermission() }
                        .controlSize(.small)
                }
            }
            Button("自动暂停设置…") { model.showPauseSettings() }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayedStatus).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 34, alignment: .topLeading)
                    .help(model.displayedStatus)
                Text(model.notice ?? "").lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 16, alignment: .topLeading)
                    .help(model.notice ?? "")
            }.font(.caption).foregroundStyle(.secondary)
            if !model.permission && model.enabled {
                HStack {
                    Button("请求输入监控权限") { model.requestPermission() }
                    Button("打开系统设置") { model.openPrivacy() }
                }.controlSize(.small)
            }
            HStack {
                Spacer()
                Button("退出 EdgeShift") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }.font(.caption)
        }
        .padding(18).frame(width: 350)
    }

    @ViewBuilder private var mainDisplayControls: some View {
        if let topology = model.topology {
            VStack(alignment: .leading, spacing: 6) {
                Picker("主显示器", selection: Binding(get: { model.topology?.mainID ?? 0 },
                                                   set: { model.setMainDisplay($0) })) {
                    ForEach(topology.independentDisplays) { display in
                        Text("\(topology.number(for: display.id)) · \(display.name)").tag(display.id)
                    }
                }
                .disabled(model.isChangingDisplays || topology.independentDisplays.count < 2)
                if model.pendingMainDisplayChange != nil {
                    Text("正在切换主显示器…").font(.caption).foregroundStyle(.secondary)
                } else if topology.independentDisplays.count < 2, topology.secondaries.contains(where: { $0.mode == .mirrored }) {
                    Text("复制屏需先切回扩展，才能设为主显示器。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var displayModeControls: some View {
        if let topology = model.topology, let selected = model.selectedDisplay {
            VStack(alignment: .leading, spacing: 8) {
                if topology.secondaries.count > 1 {
                    Picker("副屏", selection: $model.manualDisplayID) {
                        ForEach(topology.secondaries) { display in
                            Text("\(topology.number(for: display.id)) · \(display.name)").tag(display.id)
                        }
                    }
                    .disabled(model.isChangingDisplays)
                } else {
                    Text("副屏 \(topology.number(for: selected.id)) · \(selected.name)")
                        .font(.callout).lineLimit(1).help(selected.name)
                }
                Picker("显示模式", selection: Binding(get: { model.selectedDisplay?.mode ?? .extended },
                                                   set: { model.setDisplayMode($0) })) {
                    ForEach(DisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(model.isChangingDisplays)
                if model.isSwitchingMode {
                    Text("正在切换显示模式…")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let sourceID = selected.mirrorSourceID {
                    let sourceName = topology.displays.first(where: { $0.id == sourceID })?.name ?? "显示器"
                    Text("正在复制\(sourceID == topology.mainID ? "主屏" : "屏幕") \(topology.number(for: sourceID)) · \(sourceName)；复制屏幕无法单独排列。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("扩展使用独立桌面；复制显示当前主屏内容。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func moveButton(_ title: String, icon: String, side: Side) -> some View {
        Button { model.move(side) } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity)
        }
        .accessibilityLabel(title)
    }
}

private final class MenuLayout: ObservableObject {
    @Published var contentHeight: CGFloat = 760
}

private struct MenuContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct ContentUnavailableViewCompat: View {
    let title: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "display.2").font(.system(size: 28)).foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.medium))
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

final class DragModel: ObservableObject {
    @Published var translation = CGSize.zero
    @Published var displayID: CGDirectDisplayID?
}

struct ArrangementView: View {
    let snapshot: DisplaySnapshot
    let selectedID: CGDirectDisplayID
    let onMove: (CGDirectDisplayID, CGPoint) -> Void
    @StateObject private var dragModel = DragModel()
    var body: some View {
        GeometryReader { proxy in
            let union = snapshot.displays.dropFirst().reduce(snapshot.displays[0].bounds) { $0.union($1.bounds) }
            let scale = min((proxy.size.width - 16) / max(union.width, 1), (proxy.size.height - 16) / max(union.height, 1), 0.13)
            let offset = CGPoint(x: (proxy.size.width - union.width * scale) / 2 - union.minX * scale,
                                 y: (proxy.size.height - union.height * scale) / 2 - union.minY * scale)
            let panelShape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            ZStack(alignment: .topLeading) {
                panelShape.fill(Color.primary.opacity(0.04))
                ForEach(snapshot.displays) { display in
                    if display.id == snapshot.mainID {
                        screen(display.bounds, label: "主屏 \(snapshot.number(for: display.id))", color: .secondary, scale: scale)
                            .overlay(alignment: .top) {
                                Capsule().fill(Color.primary.opacity(0.4)).frame(height: 3).padding(6)
                            }
                            .position(x: offset.x + display.bounds.midX * scale, y: offset.y + display.bounds.midY * scale)
                            .accessibilityLabel("主显示器 \(snapshot.number(for: display.id))")
                    } else {
                        screen(display.bounds, label: "副屏 \(snapshot.number(for: display.id))", color: display.id == selectedID ? .accentColor : .secondary, scale: scale)
                            .position(x: offset.x + display.bounds.midX * scale + (dragModel.displayID == display.id ? dragModel.translation.width : 0),
                                      y: offset.y + display.bounds.midY * scale + (dragModel.displayID == display.id ? dragModel.translation.height : 0))
                            .gesture(DragGesture(minimumDistance: 2)
                                .onChanged { dragModel.displayID = display.id; dragModel.translation = $0.translation }
                                .onEnded { value in
                                    let point = CGPoint(x: display.bounds.minX + value.translation.width / scale,
                                                        y: display.bounds.minY + value.translation.height / scale)
                                    dragModel.translation = .zero; dragModel.displayID = nil
                                    let otherScreens = snapshot.displays.filter { $0.id != display.id }.map(\.bounds)
                                    let origin = LayoutGeometry.snappedToDisplays(secondary: display.bounds.size, proposed: point, otherScreens: otherScreens) ?? point
                                    onMove(display.id, origin)
                                })
                            .accessibilityLabel("副屏 \(snapshot.number(for: display.id))，可拖动调整位置")
                    }
                }
            }.clipShape(panelShape)
        }
    }
    func screen(_ rect: CGRect, label: String, color: Color, scale: CGFloat) -> some View {
        let outline = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return outline
            .fill(color.opacity(0.18))
            .overlay(outline.stroke(color.opacity(0.7), lineWidth: 1.5))
            .overlay(Text(label).font(.caption.weight(.medium)).foregroundStyle(color))
            .frame(width: rect.width * scale, height: rect.height * scale)
    }
}
