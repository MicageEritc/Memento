import AppKit
import SwiftUI

/// 应用主控 —— 对应 main.js 的 createWindow / showWindow / app 生命周期
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private(set) var appState: AppState!
    private var window: NSWindow?
    private var tray: TrayController?
    private var quitting = false

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ n: Notification) {
        Log.shared.info("app ready · \(AppInfo.name) v\(AppInfo.version)")

        buildMainMenu()

        let state = AppState()
        appState = state

        createWindow(state)

        let t = TrayController(app: state)
        t.onOpenPanel = { [weak self] in self?.showWindow() }
        t.onQuit = { [weak self] in self?.terminate() }
        t.mainWindowProvider = { [weak self] in self?.window }
        t.syncWithConfig()
        tray = t

        state.onDataChanged = { [weak t] in
            guard let t else { return }
            Task { @MainActor in await t.refresh() }
        }

        NotificationCenter.default.addObserver(
            forName: .lensShowWindow, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.showWindow() }
        }

        applyDockPolicy(windowVisible: true)
        showWindow()

        Task { @MainActor in
            await state.bootstrap()
            await t.refresh()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    /// 点 Dock 图标 / 重新打开 → 拉回主窗口（定格一念期间不打扰）
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if tray?.isCapturingYinian == true { return false }
        showWindow()
        return true
    }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        quitting = true
        appState?.stopRecording()
        return .terminateNow
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private func terminate() {
        quitting = true
        NSApp.terminate(nil)
    }

    // MARK: - 主窗口（对应 createWindow）

    private func createWindow(_ state: AppState) {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.title = AppInfo.name
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = false
        // ⚠️ 不能开 isMovableByWindowBackground：它会让「在文字上拖拽选择」变成拖动窗口，
        //    导致文字无法选中/复制。拖拽窗口走原生标题栏/toolbar 区域。
        w.isMovableByWindowBackground = false
        w.isOpaque = true
        w.backgroundColor = NSColor.windowBackgroundColor
        w.minSize = NSSize(width: 1000, height: 660)
        w.tabbingMode = .disallowed
        w.delegate = self

        // ===== 原生 SwiftUI NavigationSplitView（保留原生 Sidebar / toolbar）=====
        // 第 28 轮曾误用 AppKit NSSplitViewController 替换，导致原生控件丢失、toolbar 桥接失效，
        // 现已回退到这一版：单 NSHostingController 承载 RootView（NavigationSplitView）。
        let root = NSHostingController(rootView: RootView(app: state))
        w.contentViewController = root
        w.center()
        window = w
        state.mainWindow = w
    }

    func showWindow() {
        guard let w = window else { return }
        applyDockPolicy(windowVisible: true)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// showInDock=false 且窗口已隐藏时，从 Dock 里消失（对应 app.dock.hide()）
    private func applyDockPolicy(windowVisible: Bool) {
        let wantRegular = windowVisible || (appState?.cfg.showInDock ?? true)
        let target: NSApplication.ActivationPolicy = wantRegular ? .regular : .accessory
        if NSApp.activationPolicy() != target {
            NSApp.setActivationPolicy(target)
        }
    }

    // MARK: - NSWindowDelegate

    /// 关闭窗口 = 隐藏（后台继续记录），只有真正退出才销毁
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if quitting { return true }
        sender.orderOut(nil)
        applyDockPolicy(windowVisible: false)
        return false
    }

    func windowDidResize(_ n: Notification) {}
    func windowDidBecomeKey(_ n: Notification) {}

    // MARK: - 菜单栏

    /// SwiftPM 可执行文件没有 xib，主菜单必须手写。
    /// 「编辑」菜单不能省 —— 少了它设置页/搜索框的 ⌘C/⌘V/⌘A 会全部失效。
    private func buildMainMenu() {
        let main = NSMenu()

        // 应用菜单
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于\(AppInfo.name)", action: #selector(openAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏\(AppInfo.name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "显示全部", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出\(AppInfo.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // 编辑菜单（标准 responder 链选择器）
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        // 视图菜单
        let viewItem = NSMenuItem()
        let view = NSMenu(title: "视图")
        view.addItem(withTitle: "刷新", action: #selector(reloadData), keyEquivalent: "r").target = self
        view.addItem(withTitle: "搜索…", action: #selector(openSearch), keyEquivalent: "f").target = self
        view.addItem(.separator())
        let fs = view.addItem(withTitle: "进入全屏幕", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        viewItem.submenu = view
        main.addItem(viewItem)

        // 窗口菜单
        let winItem = NSMenuItem()
        let win = NSMenu(title: "窗口")
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        win.addItem(.separator())
        win.addItem(withTitle: "留刻主面板", action: #selector(bringWindowToFront), keyEquivalent: "0").target = self
        winItem.submenu = win
        main.addItem(winItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = win
    }

    @objc private func openAbout() {
        showWindow()
        appState?.tab = .about
    }

    @objc private func openSettings() {
        showWindow()
        appState?.tab = .settings
    }

    @objc private func openSearch() {
        showWindow()
        guard let s = appState else { return }
        s.searchQuery = ""
        s.searchResults = []
        s.searchHasRun = false
        s.openSearch()
    }

    @objc private func reloadData() {
        guard let s = appState else { return }
        Task { @MainActor in await s.reload() }
    }

    @objc private func bringWindowToFront() { showWindow() }
}
