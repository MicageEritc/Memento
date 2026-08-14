import SwiftUI
import AppKit

/// 菜单栏速览面板的数据快照 —— 对应 main.js `data:todayOverview`
struct TodayOverview: Equatable {
    var date: String = ""
    var running = false
    var recordCount = 0
    var yinianCount = 0
    var activeHours: Double = 0
    /// 托盘口径：专注 /（专注 + 分散），不含空闲
    var focusPct = 0
    var categories: [(String, Int)] = []
    var topApps: [(String, Int)] = []

    static func == (a: TodayOverview, b: TodayOverview) -> Bool {
        a.date == b.date && a.running == b.running && a.recordCount == b.recordCount
            && a.yinianCount == b.yinianCount && a.activeHours == b.activeHours
            && a.focusPct == b.focusPct
            && a.categories.map(\.0) == b.categories.map(\.0)
            && a.categories.map(\.1) == b.categories.map(\.1)
            && a.topApps.map(\.0) == b.topApps.map(\.0)
            && a.topApps.map(\.1) == b.topApps.map(\.1)
    }
}

/// 菜单栏速览面板 —— macOS 控制中心风格
/// 结构：Header → 概览+状态卡片 → 双操作按钮 → 极简 Footer
struct PopoverView: View {

    @ObservedObject var app: AppState
    var data: TodayOverview
    var onCaptureYinian: () -> Void
    var onOpenPanel: () -> Void
    var onQuit: () -> Void

    @State private var yinianBusy = false

    /// 统一引用 Theme 的分类配色（深浅色自适应），避免与 CatStyle.palette 双份定义不一致
    private static let catColor: [String: Color] = CatStyle.palette

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)

            // 概览 + 状态：整体微光圆角卡片
            VStack(alignment: .leading, spacing: 12) {
                overviewContent
                statusContent
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .padding(.horizontal, 14)

            // 快速操作：双并排原生控制中心风格按钮
            HStack(spacing: 8) {
                Button {
                    app.toggleRecording()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: data.running ? "pause.fill" : "play.fill")
                            .font(.caption.weight(.semibold))
                        Text(data.running ? "暂停瞬息" : "开启瞬息")
                            .font(.callout.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button {
                    guard !yinianBusy else { return }
                    yinianBusy = true
                    onCaptureYinian()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { yinianBusy = false }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.caption.weight(.semibold))
                        Text(yinianBusy ? "定格中…" : "定格一念")
                            .font(.callout.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 32)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(yinianBusy)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)

            // 极简 Footer 提示：当前模型状态 + 模型名称 + 延迟
            HStack(spacing: 6) {
                Circle()
                    .fill(modelDotColor)
                    .frame(width: 7, height: 7)
                Text(modelHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .frame(width: 280)
        .background(
            VisualEffectBackground(material: .popover, blending: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.black.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: Header —— 留刻 + 状态点 + 设置/主面板按钮

    private var header: some View {
        HStack(spacing: 8) {
            Text("留刻")
                .font(.title3.bold())
                .foregroundStyle(.primary)

            Circle()
                .fill(data.running ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)

            Spacer(minLength: 0)

            Button {
                app.tab = .settings
                onOpenPanel()
            } label: {
                Image(systemName: "gearshape")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开设置")
        }
    }

    // MARK: 今日概览 —— 指标环 + 记录数 + 活跃时长

    private var overviewContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            blockTitle("今日概览")

            HStack(spacing: 14) {
                FocusRing(progress: Double(data.focusPct) / 100,
                          valueText: "\(data.focusPct)%",
                          label: "专注度",
                          size: 58, lineWidth: 6)

                VStack(alignment: .leading, spacing: 8) {
                    metricRow(value: "\(data.recordCount)", label: "今日记录")
                    metricRow(value: String(format: "%.1f h", data.activeHours), label: "活跃时长")
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func metricRow(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(value)
                .font(.title2.bold())
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: 今日状态 —— 专注状态 + 主要活动

    private var statusContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            blockTitle("今日状态")

            HStack(spacing: 8) {
                Text("专注状态")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("\(data.focusPct)%")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(T.accent)
                Text(FocusStatus.text(data.focusPct))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 8) {
                Text("主要活动")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                let tops = Array(data.categories.prefix(3))
                if tops.isEmpty {
                    Text("暂无")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    WrapHStack(spacing: 4, lineSpacing: 4) {
                        ForEach(Array(tops.enumerated()), id: \.offset) { _, c in
                            Text(c.0)
                                .font(.caption2)
                                .foregroundStyle(Self.catColor[c.0] ?? .secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill((Self.catColor[c.0] ?? Color.secondary).opacity(0.10)))
                        }
                    }
                    .frame(maxWidth: 150, alignment: .trailing)
                }
            }
        }
    }

    private func blockTitle(_ t: String) -> some View {
        Text(t)
            .font(.caption.weight(.semibold))
            .tracking(0.3)
            .foregroundStyle(.secondary)
    }

    // MARK: Footer 模型状态提示

    private var modelDotColor: Color {
        switch app.svc.stateText {
        case "在线":       return Color.green
        case "离线":       return Color.red
        case "模型未加载": return Color.orange
        default:           return Color.secondary.opacity(0.5)
        }
    }

    private var modelHint: String {
        "\(app.svc.stateText) · \(app.svc.modelText) · \(app.svc.latencyText)"
    }
}
