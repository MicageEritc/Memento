import SwiftUI
import AppKit

/// 主界面 —— 原生 SwiftUI NavigationSplitView（Apple 原生边栏外观）。
/// 关键配置（第三十二轮定稿）：
/// - **不用 `.navigationSplitViewStyle(.balanced)`**：balanced 会无视 columnVisibility，
///   导致原生「隐藏侧栏」按钮点击无效（之前多轮"按钮无效"的真凶）。
/// - `columnVisibility: $app.sidebarVisible`：绑定可变状态，原生 toggle 按钮才真正生效。
/// - Sidebar 上 `.navigationSplitViewColumnWidth(min:200, ideal:240, max:400)`：
///   首次启动按 ideal 240 呈现，可拖动调节，可隐藏。
struct RootView: View {
    @ObservedObject var app: AppState

    var body: some View {
        // 单一 NavigationSplitView，绝不条件重建 —— 重建会销毁并重建视图树，
        // 导致切换瞬间界面跳动/闪烁。
        NavigationSplitView(columnVisibility: $app.sidebarVisible) {
            Sidebar(app: app)
        } detail: {
            DetailRoot(app: app)
        }
        .overlay(RootOverlays(app: app))
    }
}

/// 详情区根视图 —— 按 app.tab 切换面板（被 NavigationSplitView 的 detail 列承载）
struct DetailRoot: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            if app.showPermBanner {
                PermBanner(app: app)
            }

            ZStack(alignment: .top) {
                Group {
                    switch app.tab {
                    case .instant:  InstantPanel(app: app)
                    case .yinian:   YinianPanel(app: app)
                    case .muse:     MusePanel(app: app)
                    case .panorama: PanoramaPanel(app: app)
                    case .model:    ModelPanel(app: app)
                    case .settings: SettingsPanel(app: app)
                    case .about:    AboutPanel(app: app)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 搜索结果作为「内容区覆盖层」：下方面板 toolbar（含系统 .searchable 搜索框）
                // 始终不重建，第三方输入法第一响应者永不丢失，中文可连续输入完整词后再搜。
                if app.searchHasRun {
                    SearchResultsLayer(app: app)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.22), value: app.searchHasRun)
        // ESC 双保险：即便焦点不在搜索框也能清空退出
        .background(
            Button("") {
                app.cancelSearch()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .opacity(0)
        )
    }
}

/// 搜索结果覆盖层：贴在内容区顶部，toolbar（含系统搜索框）不重建 → 输入法不中断。
struct SearchResultsLayer: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            SearchScopeBar(app: app)
            Divider()
            SearchResultsView(app: app)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 全局浮层（灯箱 + 请作者喝杯奶茶）。搜索已改为 toolbar 嵌入式，不再使用居中弹窗。
struct RootOverlays: View {
    @ObservedObject var app: AppState

    var body: some View {
        ZStack {
            if let p = app.lightboxPath {
                Lightbox(path: p) { app.lightboxPath = nil }
                    .transition(.opacity)
            }
            if app.showDonate {
                DonateOverlay(show: $app.showDonate)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.82, blendDuration: 0.10), value: app.lightboxPath != nil)
        .background(KeyboardShortcuts(app: app))
    }
}

// MARK: - 「请作者喝杯奶茶」全局居中弹窗

private struct DonateOverlay: View {
    @Binding var show: Bool

    /// 从 app 包内加载微信收款码（build-app.sh 已将 Resources/WeChat.png 拷入 .app/Contents/Resources）
    private var qrImage: NSImage? {
        guard let path = Bundle.main.path(forResource: "WeChat", ofType: "png") else { return nil }
        return NSImage(contentsOfFile: path)
    }

    var body: some View {
        ZStack {
            // 半透明遮罩：点击空白处（卡片以外）即关闭
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .onTapGesture { show = false }

            card
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private var card: some View {
        VStack(spacing: 0) {
            // 标题区
            VStack(spacing: 8) {
                Text("☕ 请作者喝杯奶茶")
                    .font(.title3.bold())
                    .foregroundColor(.primary)

                Text("如果「留刻」对你有一点帮助，\n欢迎请作者喝杯奶茶")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 28)
            .padding(.bottom, 22)

            // 收款码
            qrImageView
                .frame(width: 300, height: 300)
                .shadow(color: .black.opacity(0.10), radius: 18, y: 6)

            Text("微信扫码，即可赞赏")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.top, 18)
                .padding(.bottom, 28)
        }
        .frame(width: 420)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(NSColor.windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.20), radius: 32, y: 14)
    }

    @ViewBuilder
    private var qrImageView: some View {
        if let img = qrImage {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.05))
                .overlay(Text("[ 微信收款码 ]").foregroundColor(.secondary))
        }
    }

}

// MARK: - 键盘快捷键（⌘F / ⌘K 聚焦搜索、⌘, 设置、⌘R 刷新）

private struct KeyboardShortcuts: NSViewRepresentable {
    let app: AppState

    func makeNSView(context: Context) -> NSView {
        let v = KeyCatcherView()
        v.app = app
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        (v as? KeyCatcherView)?.app = app
    }

    final class KeyCatcherView: NSView {
        weak var app: AppState?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, let app = self.app, self.window?.isKeyWindow == true else { return e }
                // ESC：强制清空并退出搜索（致命死锁修复，无论焦点在哪都能退出）
                if e.keyCode == 53 {
                    if !app.searchQuery.isEmpty {
                        app.searchQuery = ""
                        app.runSearch()
                        return nil
                    }
                    return e
                }
                guard e.modifierFlags.contains(.command) else { return e }
                switch e.charactersIgnoringModifiers?.lowercased() {
                case "k", "f":
                    app.openSearch()
                    return nil
                case "n":
                    // ⌘N：仅在随想页新建一篇随想（其余页面留给各自的「新建」语义）
                    if app.tab == .muse { app.newMuseNote() }
                    return nil
                case ",":
                    app.tab = .settings
                    return nil
                case "r":
                    Task { await app.reload() }
                    return nil
                default:
                    return e
                }
            }
        }

        deinit {
            if let m = monitor { NSEvent.removeMonitor(m) }
        }
    }
}
