import SwiftUI
import AppKit

// MARK: - 「设置」页 —— 原生 Form（.grouped），对应原设置抽屉全部字段

struct SettingsPanel: View {
    @ObservedObject var app: AppState

    var body: some View {
        // 统一规范：ScrollView Full-Bleed（自身零 padding），所有 padding 在内层 VStack 上，
        // 保证右侧滚动条轨道在模型/设置/关于三页间绝对一致（顶端/底端纹丝不动）。
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                SettingSectionCard(title: "采集") { captureRows }
                    .frame(maxWidth: 640, alignment: .leading)
                SettingSectionCard(title: "省算力") { powerRows }
                    .frame(maxWidth: 640, alignment: .leading)
                SettingSectionCard(title: "存储位置") { storageRows }
                    .frame(maxWidth: 640, alignment: .leading)
                SettingSectionCard(title: "存储与清理") { cleanupRows }
                    .frame(maxWidth: 640, alignment: .leading)
                SettingSectionCard(title: "行为") { behaviorRows }
                    .frame(maxWidth: 640, alignment: .leading)
                SettingSectionCard(title: "备份") { backupRows }
                    .frame(maxWidth: 640, alignment: .leading)
            }
            // 关键：外层容器必须铺满 detail 列（maxWidth .infinity），滚动条才会贴窗口右边；
            // 单张卡片各自限宽 640 靠左，避免内容被无限拉宽。
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 40)
            .padding(.trailing, 40)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollIndicators(.automatic)
        .defaultScrollAnchor(.top)
        .navigationTitle("设置")
        // 锚点 toolbar：保证窗口 NSToolbar 始终存在，切到本页时标题栏/边栏不跳动
        .toolbar {
            // 全局搜索为独立内容状态：搜索时清空整个 toolbar（不继承当前页面原有 items）
            if !app.isSearching {
                ToolbarItem(placement: .primaryAction) { ToolbarAnchor() }
            }
        }
        // 纯 SwiftUI 原生毛玻璃：toolbar 背景材质，滚动内容上滑时被模糊（macOS 26 原生，无 AppKit 兜底）
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
    }

    // MARK: 采集

    @ViewBuilder
    private var captureRows: some View {
        SettingRow("截屏间隔（秒）") { number($app.cfg.intervalSec, range: 5...3600) }
        SettingRow("落盘图片宽度") { number($app.cfg.saveWidth, range: 640...3840) }
        SettingRow("送模型图片宽度") { number($app.cfg.analyzeWidth, range: 480...2560) }
        SettingRow("JPEG 质量") { number($app.cfg.jpegQuality, range: 30...100) }
        SettingToggleRow("抓取所有显示器", isOn: $app.cfg.captureAllDisplays, divider: false) {
            app.scheduleSave()
        }
    }

    // MARK: 省算力

    @ViewBuilder
    private var powerRows: some View {
        SettingToggleRow("画面无变化时跳过分析", isOn: $app.cfg.skipDuplicate) { app.scheduleSave() }
        SettingRow("无变化判定阈值（0-20，越小越严格）") { number($app.cfg.dupThreshold, range: 0...20) }
        SettingToggleRow("无变化时仍然保存截图", isOn: $app.cfg.saveDuplicateShots) { app.scheduleSave() }
        SettingToggleRow("长时间无操作时暂停采集", isOn: $app.cfg.skipWhenIdle) { app.scheduleSave() }
        SettingRow("判定空闲的秒数", divider: false) { number($app.cfg.idleThresholdSec, range: 30...7200) }
    }

    // MARK: 存储位置

    @ViewBuilder
    private var storageRows: some View {
        SettingRow("保存目录", divider: false) {
            HStack(spacing: 8) {
                Text(app.cfg.outputDir)
                    .font(.callout)
                    .foregroundStyle(T.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 240, alignment: .trailing)
                    .help(app.cfg.outputDir)
                Button("更改…") {
                    guard let url = Dialogs.pickFolder(current: app.cfg.outputDir) else { return }
                    Task { await app.changeOutputDir(to: url.path) }
                }
                .controlSize(.regular)
            }
        }
    }

    // MARK: 存储与清理

    @ViewBuilder
    private var cleanupRows: some View {
        Text("采用图文分离存储：自动清理只抹去大文件截图，保留精简的 AI 文本记录。不占存储空间，亦不丢失任何记忆。")
            .font(.footnote)
            .foregroundStyle(T.muted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
        SettingToggleRow("启用自动清理", isOn: $app.cfg.cleanup.enabled) { app.scheduleSave() }
        SettingRow("最多保留截图（张，0=不限制）") { number($app.cfg.cleanup.maxShots, range: 0...100000) }
        SettingRow("清理 N 天前截图（天，0=不限制）") { number($app.cfg.cleanup.olderThanDays, range: 0...3650) }
        SettingRow("截图超此容量时清理（GB，0=不限制）", divider: false) { gbField }
        HStack(spacing: 10) {
            Button(app.cleaning ? "清理中…" : "立即清理一次") {
                Task { await app.cleanupNow() }
            }
            .disabled(app.cleaning)
            .controlSize(.regular)
            if !app.cleanHint.isEmpty {
                Text(app.cleanHint)
                    .font(.footnote)
                    .foregroundStyle(T.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.top, 10)
    }

    // MARK: 行为

    @ViewBuilder
    private var behaviorRows: some View {
        SettingToggleRow("启动应用后自动开始记录", isOn: $app.cfg.autoStartCapture) { app.scheduleSave() }
        SettingToggleRow("开机自动启动", isOn: $app.cfg.launchAtLogin) { app.scheduleSave() }
        SettingToggleRow("常驻状态栏（顶部菜单栏图标）", isOn: $app.cfg.stayInTray, divider: false) { app.scheduleSave() }
    }

    // MARK: 备份

    @ViewBuilder
    private var backupRows: some View {
        HStack(spacing: 10) {
            Button("导出备份") {
                Task { await app.exportBackup() }
            }
            .disabled(app.backupBusy)
            .controlSize(.regular)
            Button("导入备份") {
                Task { await app.importBackup() }
            }
            .disabled(app.backupBusy)
            .controlSize(.regular)
            if !app.backupHint.isEmpty {
                Text(app.backupHint)
                    .font(.footnote)
                    .foregroundStyle(T.muted)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .padding(.top, 2)
    }

    // MARK: 输入控件

    private func textField(_ s: Binding<String>, width: CGFloat) -> some View {
        TextField("", text: s)
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .frame(width: width)
            .onChange(of: s.wrappedValue) { _, _ in app.scheduleSave() }
    }

    private func number(_ v: Binding<Int>, range: ClosedRange<Int>) -> some View {
        // 纯文本框：去掉 stepper 上下箭头、不加千位分隔号
        TextField("", value: v, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .frame(width: 96)
            .multilineTextAlignment(.trailing)
            .onChange(of: v.wrappedValue) { _, _ in app.scheduleSave() }
    }

    /// GB ↔ 字节（0.1 精度）：纯文本框，无 stepper、无千位分隔号、无默认 0 占位
    private var gbField: some View {
        TextField(
            "",
            value: Binding(
                get: {
                    let b = app.cfg.cleanup.maxBytes
                    return b > 0 ? (Double(b) / 1_073_741_824 * 10).rounded() / 10 : 0
                },
                set: { gb in
                    app.cfg.cleanup.maxBytes = gb > 0 ? Int64((gb * 1_073_741_824).rounded()) : 0
                }
            ),
            format: .number.precision(.fractionLength(1)).grouping(.never)
        )
        .textFieldStyle(.roundedBorder)
        .font(.callout)
        .frame(width: 96)
        .multilineTextAlignment(.trailing)
        .onChange(of: app.cfg.cleanup.maxBytes) { _, _ in app.scheduleSave() }
    }
}
