import SwiftUI
import AppKit
import Combine

/// 菜单栏速览面板的数据源（让 SwiftUI 能跟着刷新）
@MainActor
final class PopoverModel: ObservableObject {
    @Published var overview = TodayOverview()
}

/// NSHostingView 的根视图外壳
private struct PopoverHost: View {
    @ObservedObject var app: AppState
    @ObservedObject var model: PopoverModel
    var onCaptureYinian: () -> Void
    var onOpenPanel: () -> Void
    var onQuit: () -> Void

    var body: some View {
        PopoverView(app: app,
                    data: model.overview,
                    onCaptureYinian: onCaptureYinian,
                    onOpenPanel: onOpenPanel,
                    onQuit: onQuit)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// borderless NSPanel 默认不能成为 key window，重写后才能收到 didResignKey（失焦自动隐藏）
final class TrayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 菜单栏常驻图标 + 今日速览面板
///
/// 1:1 对应 main.js 的 `buildTray / destroyTray / toggleTrayPopover /
/// positionPopover / data:todayOverview / yinian:captureFromPopover`。
///
/// 关键差异（比 Electron 版更稳）：
/// - 面板高度用 SwiftUI 的 `fittingSize` 一次算准，不需要轮询 body.offsetHeight
/// - 只有 click / rightMouseUp 一个入口，不存在原生 menu 与 popover「双弹」的问题
@MainActor
final class TrayController {

    private let app: AppState
    private let model = PopoverModel()

    private var statusItem: NSStatusItem?
    private var panel: TrayPanel?
    private var hosting: NSHostingView<PopoverHost>?

    private var heightCache: CGFloat = 0
    private var yinianCapturing = false
    private var resignObserver: NSObjectProtocol?
    private var bag = Set<AnyCancellable>()

    /// 「打开主面板」回调（由 AppDelegate 注入）
    var onOpenPanel: (() -> Void)?
    /// 「退出留刻」回调
    var onQuit: (() -> Void)?
    /// 取主窗口（定格一念时要把它挪出屏幕，避免被拍进去）
    var mainWindowProvider: (() -> NSWindow?)?

    /// 定格一念期间为 true —— AppDelegate 的 reopen 逻辑要读它，避免误拉出主窗口
    private(set) var isCapturingYinian = false

    init(app: AppState) {
        self.app = app
        observeNotifications()
    }

    // MARK: - 安装 / 卸载（对应 buildTray / destroyTray）

    func syncWithConfig() {
        if app.cfg.stayInTray { install() } else { remove() }
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = item.button {
            btn.image = TrayController.trayImage()
            btn.imagePosition = .imageOnly
            btn.toolTip = AppInfo.name
            btn.target = self
            btn.action = #selector(statusItemClicked(_:))
            btn.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        Task { await refresh() }
    }

    func remove() {
        hidePanel(animated: false)
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    /// 菜单栏只显示图标，不显示文字（对应 refreshTray 的空实现 —— 老公明确要求）
    private func refreshTrayIcon() {
        statusItem?.button?.image = TrayController.trayImage()
    }

    // MARK: - 图标

    /// 读 trayTemplate.png（含 @2x），损坏或缺失时用代码画一个兜底图，
    /// 保证「只要 app 在跑，菜单栏一定有东西可点」。
    static func trayImage() -> NSImage {
        if let img = loadTemplateImage() { return img }
        return fallbackImage()
    }

    private static func loadTemplateImage() -> NSImage? {
        let url1x = AppPaths.resource("trayTemplate.png")
        guard let data1 = try? Data(contentsOf: url1x),
              let rep1 = NSBitmapImageRep(data: data1),
              rep1.pixelsWide > 0, rep1.pixelsHigh > 0 else { return nil }
        // 校验能真正解码（历史坑：PNG 头正常但 IDAT 损坏）
        guard rep1.cgImage != nil else { return nil }

        let img = NSImage(size: NSSize(width: 18, height: 18))
        rep1.size = NSSize(width: 18, height: 18)
        img.addRepresentation(rep1)

        let url2x = AppPaths.resource("trayTemplate@2x.png")
        if let data2 = try? Data(contentsOf: url2x),
           let rep2 = NSBitmapImageRep(data: data2),
           rep2.cgImage != nil {
            rep2.size = NSSize(width: 18, height: 18)
            img.addRepresentation(rep2)
        }
        img.isTemplate = true
        return img
    }

    private static func fallbackImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let s = "留" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.black
            ]
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: (rect.width - sz.width) / 2,
                               y: (rect.height - sz.height) / 2),
                   withAttributes: attrs)
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: - 点击

    @objc private func statusItemClicked(_ sender: Any?) {
        togglePanel()
    }

    func togglePanel() {
        if let p = panel, p.isVisible {
            hidePanel(animated: false)
            return
        }
        showPanel()
    }

    // MARK: - 面板

    private func ensurePanel() -> TrayPanel {
        if let p = panel { return p }

        let host = NSHostingView(rootView: PopoverHost(
            app: app,
            model: model,
            onCaptureYinian: { [weak self] in self?.captureYinianFromPopover() },
            onOpenPanel: { [weak self] in
                self?.hidePanel(animated: false)
                self?.onOpenPanel?()
            },
            onQuit: { [weak self] in
                self?.hidePanel(animated: false)
                self?.onQuit?()
            }
        ))

        let p = TrayPanel(contentRect: NSRect(x: 0, y: 0, width: 270, height: 380),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered,
                          defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovableByWindowBackground = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.contentView = host

        // 失焦自动隐藏（菜单栏小面板的标准行为，对应原版 trayPopover.on('blur')）
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: p, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.yinianCapturing else { return }
                self.hidePanel(animated: false)
            }
        }

        hosting = host
        panel = p
        return p
    }

    private func showPanel() {
        let p = ensurePanel()
        Task { @MainActor in
            await refresh()                 // 先刷数据，再测高 —— 出现即最终大小，不抖不跳
            let size = measure()
            p.setContentSize(size)
            position(p, size: size)
            p.alphaValue = 1
            p.makeKeyAndOrderFront(nil)
        }
    }

    func hidePanel(animated: Bool) {
        guard let p = panel, p.isVisible else { return }
        if animated {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                p.animator().alphaValue = 0
            }, completionHandler: {
                p.orderOut(nil)
                p.alphaValue = 1
            })
        } else {
            p.orderOut(nil)
            p.alphaValue = 1
        }
    }

    /// 用 SwiftUI 的 fittingSize 一次量准，再按屏幕 84% 高度封顶（对应原版 maxH）
    private func measure() -> CGSize {
        guard let host = hosting else { return CGSize(width: 270, height: 380) }
        host.layoutSubtreeIfNeeded()
        var s = host.fittingSize
        s.width = 270
        let wa = (screenForStatusItem() ?? NSScreen.main)?.visibleFrame ?? .zero
        let maxH = wa.height > 0 ? floor(wa.height * 0.84) : 900
        if s.height > maxH { s.height = maxH }
        if s.height < 120 { s.height = heightCache > 0 ? heightCache : 380 }
        heightCache = s.height
        return s
    }

    private func screenForStatusItem() -> NSScreen? {
        guard let btn = statusItem?.button, let bw = btn.window else { return NSScreen.main }
        let rect = bw.convertToScreen(btn.convert(btn.bounds, to: nil))
        let pt = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(pt) } ?? NSScreen.main
    }

    /// 贴在图标正下方居中，越界则贴边（对应 positionPopover）
    private func position(_ p: TrayPanel, size: CGSize) {
        guard let btn = statusItem?.button, let bw = btn.window else { return }
        let rect = bw.convertToScreen(btn.convert(btn.bounds, to: nil))
        let wa = (screenForStatusItem() ?? NSScreen.main)?.visibleFrame ?? rect

        var x = rect.midX - size.width / 2
        var y = rect.minY - 4 - size.height          // AppKit 原点在左下
        if x + size.width > wa.maxX - 8 { x = wa.maxX - size.width - 8 }
        if x < wa.minX + 8 { x = wa.minX + 8 }
        if y < wa.minY + 8 { y = wa.minY + 8 }
        p.setFrameOrigin(NSPoint(x: x.rounded(), y: y.rounded()))
    }

    // MARK: - 数据（对应 data:todayOverview）

    func refresh() async {
        // 面板实例存在就先刷数据（即使未显示，打开时立刻有数据）；
        // 只有「重测高」需要面板可见。
        guard panel != nil else { return }
        let o = await buildOverview()
        model.overview = o
        guard let p = panel, p.isVisible else { return }
        // 面板开着时，内容变化可能改变高度 —— 差异大才 resize（对应 gentle 逻辑）
        let s = measure()
        if abs(s.height - p.frame.height) > 6 {
            p.setContentSize(s)
            position(p, size: s)
        }
    }

    private func buildOverview() async -> TodayOverview {
        let ds = DateUtil.ymd(Date())
        let cfg = app.cfg
        let intervalH = Double(max(1, cfg.intervalSec)) / 3600.0

        let ts = await app.store.todayStats()
        let fb = await app.store.focusBreakdown([ds])

        var o = TodayOverview()
        o.date = ds
        o.running = app.running
        o.recordCount = ts.memento.analyzed != 0 ? ts.memento.analyzed : ts.memento.total
        o.yinianCount = ts.yinianCount
        o.activeHours = Double(ts.memento.analyzed) * intervalH
        o.focusPct = fb.score                       // 托盘口径：专注 /（专注 + 分散），不含空闲
        o.categories = ts.memento.categories
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ($0.key, $0.value) }
        o.topApps = ts.memento.apps
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ($0.key, $0.value) }
        return o
    }

    // MARK: - 定格一念（对应 yinian:captureFromPopover）

    /// 1. 面板淡出隐藏
    /// 2. 主窗口若可见 → 无动画挪出屏幕（系统置顶也拍不到它）
    /// 3. 等 240ms 让画面稳定，再抓屏（秒回，模型分析后台跑）
    /// 4. 挪回主窗口原位，不 focus、不自动打开主面板
    private func captureYinianFromPopover() {
        guard !yinianCapturing else { return }
        yinianCapturing = true
        isCapturingYinian = true

        hidePanel(animated: true)

        Task { @MainActor in
            defer {
                self.yinianCapturing = false
                self.isCapturingYinian = false
            }
            // 等面板淡出动画结束
            try? await Task.sleep(nanoseconds: 200_000_000)

            var savedOrigin: NSPoint?
            let win = mainWindowProvider?()
            if let w = win, w.isVisible {
                savedOrigin = w.frame.origin
                w.setFrameOrigin(NSPoint(x: -24_000, y: -24_000))
            }

            try? await Task.sleep(nanoseconds: 240_000_000)
            let outcome = await app.recorder.captureYinianShot()

            if let w = win, let o = savedOrigin {
                w.setFrameOrigin(o)
            }
            if !outcome.ok, let err = outcome.error {
                Log.shared.warn("状态栏定格一念失败：\(err)")
            }
            await self.refresh()
        }
    }

    // MARK: - 通知

    private func observeNotifications() {
        NotificationCenter.default.publisher(for: .lensTrayToggled)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.syncWithConfig()
                }
            }
            .store(in: &bag)

        NotificationCenter.default.publisher(for: .lensTrayRefresh)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshTrayIcon()
                    Task { await self.refresh() }
                }
            }
            .store(in: &bag)
    }
}
