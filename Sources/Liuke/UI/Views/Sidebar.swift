import SwiftUI
import AppKit

/// 侧栏 —— NavigationSplitView 的原生 Sidebar（List 分组，一级导航）
/// Server：瞬息 / 一念 / 全景　General：模型 / 设置 / 关于
/// ⚠️ 不用 `.navigationSplitViewStyle(.balanced)`：它会无视 columnVisibility，
///    使原生「隐藏侧栏」按钮失效。宽度靠 navigationSplitViewColumnWidth 控制。
struct Sidebar: View {
    @ObservedObject var app: AppState
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $app.tab) {
                Section("Server") {
                    navItem(.instant)
                    navItem(.yinian)
                    navItem(.muse)
                    navItem(.panorama)
                }
                Section("General") {
                    navItem(.model)
                    navItem(.settings)
                    navItem(.about)
                }
            }
            .listStyle(.sidebar)
            // 全局搜索挂到 sidebar：macOS 在侧栏顶部渲染原生搜索框（绑定全局 searchQuery）
            .searchable(text: $app.searchQuery, placement: .sidebar, prompt: "搜索")
            .searchFocused($searchFocused)
            .padding(.top, 16)
            .frame(maxWidth: .infinity)
            // 输入即搜索（防抖在 runSearch 内）；⌘F/⌘K（app.openSearch 自增 signal）→ 聚焦搜索框
            .onChange(of: app.searchQuery) { _, _ in app.runSearch() }
            .onChange(of: app.searchFocusSignal) { _, _ in
                searchFocused = true
            }

            footer
        }
        // 硬性尺寸约束：State Restoration / NavigationSplitView 可能覆盖列宽配置，
        // 直接在根视图上把 View 硬撑到舒适宽度。
        .frame(minWidth: 230, idealWidth: 250, maxWidth: 300, maxHeight: .infinity, alignment: .leading)
        // 与 SplitView 列宽约束同步，避免系统状态恢复覆盖。
        .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
    }

    private func navItem(_ t: MainTab) -> some View {
        Label(t.title, systemImage: t.icon)
            .font(T.f(13))
            .padding(.vertical, 1)
            .tag(t)
    }

    /// 底部品牌 + 按页面计数 + 录制状态后缀
    /// 瞬息/一念/全景 = 计数·状态；模型/设置/关于 = 仅状态（无计数）
    private var footer: some View {
        HStack(spacing: 6) {
            Text("留刻")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(T.text)
            Spacer(minLength: 0)
            Text(footerText)
                .font(.caption)
                .foregroundStyle(T.muted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(T.divider).frame(height: 1)
        }
    }

    /// 计数 + 状态后缀（用 · 拼接；无后缀时保持原样）
    private var footerText: String {
        let base: String
        switch app.tab {
        case .instant: base = "今天已捕捉 \(app.records.count) 条瞬息"
        case .yinian: base = "总共已捕捉 \(app.totalYinian) 条一念"
        case .muse: base = "总共已捕捉 \(app.museNotes.count) 条随想"
        case .panorama: base = "总共已捕捉 \(app.totalInstant) 条瞬息"
        default: base = ""
        }
        let suffix = recordStatusSuffix
        if suffix.isEmpty { return base }
        return base.isEmpty ? suffix : "\(base)·\(suffix)"
    }

    /// 录制状态：已暂停 = 「已暂停记录」；记录中 = 「N秒后开始截图」（无倒计时则空）
    private var recordStatusSuffix: String {
        guard app.running else { return "已暂停记录" }
        let t = app.countdownText
        if t != "—", let secs = Int(t.replacingOccurrences(of: "s", with: "")) {
            return "\(secs)秒后开始截图"
        }
        return ""
    }
}
