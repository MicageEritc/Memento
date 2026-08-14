import SwiftUI
import AppKit

// MARK: - 标题栏毛玻璃（内容滚到透明标题栏下方时被模糊，无硬边线）

extension View {
    /// 让 ScrollView 内容延伸到透明标题栏下方，并在标题栏区域叠加毛玻璃条：
    /// 滚动时内容从控件下方穿过并被半透明模糊（参考系统原生 App 的做法）。
    /// - Parameter height: 毛玻璃条高度（标题栏可视高度，略大于工具栏以不留未模糊缝隙）
    func toolbarGlass(height: CGFloat = 56) -> some View {
        self
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(.regularMaterial)
                    .frame(height: height)
                    .allowsHitTesting(false)
            }
    }
}

// MARK: - 按钮（对应 .btn 系列）

enum BtnKind { case normal, primary, danger, warn }

struct LKButton: View {
    let title: String
    var kind: BtnKind = .normal
    var small: Bool = false
    var fullWidth: Bool = false
    var disabled: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(T.f(small ? 12 : 12.5, kind == .primary || kind == .warn ? .medium : .regular))
                .lineLimit(1)
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .buttonStyle(LKButtonStyle(kind: kind, small: small))
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }
}

/// 自定义 ButtonStyle：保留品牌配色，同时补齐系统级按压反馈与焦点环（键盘导航可见）
struct LKButtonStyle: ButtonStyle {
    var kind: BtnKind
    var small: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, kind: kind, small: small)
    }

    struct StyleBody: View {
        let configuration: Configuration
        let kind: BtnKind
        let small: Bool
        @Environment(\.isFocused) private var isFocused
        @State private var hovering = false

        private var fg: Color {
            switch kind {
            case .normal: return T.text
            case .primary: return .white
            case .danger: return T.err
            case .warn: return T.warnText
            }
        }
        private var bg: Color {
            switch kind {
            case .normal: return hovering ? T.surfaceHover : T.surface
            case .primary: return hovering ? T.accent2 : T.accent
            case .danger: return hovering ? T.errSoft : T.surface
            case .warn: return T.warnSoft
            }
        }
        private var bd: Color {
            switch kind {
            case .normal: return hovering ? T.textDim : T.borderStrong
            case .primary: return hovering ? T.accent2 : T.accent
            case .danger: return T.err.opacity(0.35)
            case .warn: return T.warn.opacity(0.35)
            }
        }

        var body: some View {
            configuration.label
                .foregroundStyle(fg)
                .padding(.horizontal, small ? 10 : 12)
                .padding(.vertical, small ? 5 : 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(bg))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(bd, lineWidth: 1)
                )
                // 系统级按压反馈
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .brightness(configuration.isPressed ? -0.04 : 0)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                // 键盘焦点环（系统 focus ring 同款的强调色描边）
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(T.accent.opacity(isFocused ? 0.8 : 0), lineWidth: 2)
                )
                .onHover { hovering = $0 }
        }
    }
}

/// 图标按钮（对应 .icon-btn）
struct IconButton: View {
    let system: String
    var danger = false
    var help: String = ""
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(danger ? T.err : (hovering ? T.text : T.textDim))
                .frame(width: 21, height: 21)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering ? (danger ? T.errSoft : T.surface2) : .clear)
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering = $0 }
    }
}

// MARK: - 状态标签（对应 .tag / .tag.ok / .tag.warn / .tag.err）

enum TagKind { case plain, ok, warn, err }

struct StatusTag: View {
    let text: String
    var kind: TagKind = .plain

    var body: some View {
        let (bg, fg, bd): (Color, Color, Color) = {
            switch kind {
            case .plain: return (T.surface2, T.textDim, T.border)
            case .ok: return (T.okSoft, T.okText, T.ok.opacity(0.35))
            case .warn: return (T.warnSoft, T.warnText, T.warn.opacity(0.35))
            case .err: return (T.errSoft, T.errText, T.err.opacity(0.45))
            }
        }()
        Text(text)
            .font(T.f(11, kind == .err ? .semibold : .regular))
            .foregroundStyle(fg)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
            .overlay(Capsule().strokeBorder(bd, lineWidth: 1))
    }
}

// MARK: - 细进度条（对应 .cat-track / .usage-bar / .countdown-bar）

struct ThinBar: View {
    var value: Double            // 0...1
    var color: Color = T.accent
    var height: CGFloat = 5
    var track: Color = T.divider

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color)
                    .frame(width: max(0, min(1, value)) * g.size.width)
            }
        }
        .frame(height: height)
    }
}

// MARK: - 指标环（Apple Fitness 风格，非 BI 仪表盘）
// 专注度 / 活跃时长共用：progress 0...1，valueText 中心大字，label 底部标签。

struct FocusRing: View {
    var progress: Double       // 0...1 填充比例
    var valueText: String      // 中心大字（如 "82%" / "6.5h"）
    var label: String = "专注度"
    var size: CGFloat = 64
    var lineWidth: CGFloat = 7
    var color: Color = T.accent
    var track: Color = T.divider

    var body: some View {
        ZStack {
            Circle().stroke(track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(valueText)
                    .font(.system(size: size * 0.21, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(T.text)
                Text(label)
                    .font(.system(size: size * 0.11))
                    .foregroundStyle(T.muted)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 专注状态文字（保持沉浸表达，不做效率评分）
enum FocusStatus {
    static func text(_ pct: Int) -> String {
        if pct >= 70 { return "专注状态良好" }
        if pct >= 40 { return "状态平稳，偶有分心" }
        return "较为分散，可尝试专注模式"
    }
}

// MARK: - 状态灯（对应 .orb / .orb.on / .orb.busy / .orb.err）

struct StatusOrb: View {
    var color: Color?
    var pulsing: Bool
    @State private var phase = false

    var body: some View {
        Circle()
            .fill(color ?? T.muted.opacity(0.55))
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke((color ?? T.muted).opacity(0.35), lineWidth: 3)
                    .scaleEffect(phase ? 1.9 : 1)
                    .opacity(phase ? 0 : 0.8)
            )
            .onAppear { if pulsing { startPulse() } }
            .onChange(of: pulsing) { _, on in
                if on { startPulse() } else { phase = false }
            }
    }

    private func startPulse() {
        phase = false
        withAnimation(.easeOut(duration: 1.2).repeatForever(autoreverses: false)) {
            phase = true
        }
    }
}

// MARK: - 空态（对应 .empty）

struct EmptyTip: View {
    let icon: String
    let text: String
    /// 可选主标题（如「还没有随想」）
    var title: String? = nil
    /// 可选底部操作提示（如「点击右上角 + 开始记录」）
    var hint: String? = nil
    /// 隐藏的占位行数：用于让两个并排空态内容等高、图标垂直对齐
    var hiddenLines: Int = 0
    var compact = false
    var body: some View {
        VStack(spacing: 10) {
            // SF Symbol 必须用 Image(systemName:)，Text 会把符号名当字符串渲染
            Image(systemName: icon)
                .font(.system(size: compact ? 28 : 40))
                .opacity(0.35)
                .grayscale(1)
            if let title {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(T.muted)
            }
            Text(text)
                .font(T.f(12.5))
                .foregroundStyle(T.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint)
                    .font(T.f(12))
                    .foregroundStyle(T.muted.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            // 隐藏占位行：补齐与相邻空态的行数差，保证图标垂直对齐
            ForEach(0..<hiddenLines, id: \.self) { _ in
                Text(" ")
                    .font(T.f(12.5))
                    .hidden()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, compact ? 30 : 70)
        .padding(.horizontal, 30)
    }
}

// MARK: - AI 总结 Tip（独立于正文的附属信息块）
//
// 定位：随想的 AI 总结不是富文本正文的一部分，而是一段独立的「Tip」——
// 灰色圆角卡片，小字号，可选中复制；右上角「小眼睛」= 折叠/展开（数据保留，
// 视觉收起成一行小条）。「彻底删除」由 AI 总结面板的「隐藏」按钮触发。

struct MuseSummaryTipView: View {
    let text: String
    /// 是否折叠（小眼睛收起态）
    var hidden: Bool = false
    /// 折叠 / 展开回调（小眼睛）
    var onToggle: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if hidden {
                // 折叠态：一行小条，点击展开
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(T.accent)
                        Text("AI 总结")
                            .font(.system(size: 11.5))
                            .foregroundStyle(T.muted)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(T.muted)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("展开 AI 总结")
            } else {
                // 展开态：灰色圆角卡片
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(T.accent)
                        Text("AI 总结")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(T.text)
                        Spacer(minLength: 0)
                        // 小眼睛：折叠（数据保留，视觉收起）
                        Button(action: onToggle) {
                            Image(systemName: "eye.slash")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(T.muted)
                                .frame(width: 22, height: 22)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("折叠 AI 总结")
                    }
                    Text("AI总结：\(text)")
                        .font(.system(size: 12))
                        .foregroundStyle(T.muted)
                        .lineSpacing(2)
                        .textSelection(.enabled)   // 可选中复制
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
            }
        }
    }
}

// MARK: - 毛玻璃背景（弹窗等静态层用，替代 CSS backdrop-filter）
// 定义在 Theme.swift（VisualEffectBackground）

