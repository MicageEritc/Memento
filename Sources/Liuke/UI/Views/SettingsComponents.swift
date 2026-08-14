import SwiftUI
import AppKit

// MARK: - 设置类面板统一组件（模型 / 设置 / 关于 三页共用）
//
// 规范红线（2026-08-07 定稿，用户拍板）：
// 1. ScrollView 自身零 padding（Full-Bleed），所有边距加在内层 Content 上 —— 滚动条轨道三页绝对一致；
// 2. 卡片统一淡灰底 primary.opacity(0.03) + 浅边框 primary.opacity(0.06) + 圆角 10；
    // 3. 配置行统一 SettingRow：label 靠左、控件被 Spacer 物理强推最右、controlSize(.regular) 锁定原生尺寸；
    //    Toggle 行用 .controlSize(.small) 恢复精致小巧原生质感（macOS .regular 的 Switch 臃肿突兀）；
    // 4. 行间分割线 Divider().opacity(0.5)，恢复精致横线分割感；
    // 5. 绝对禁止在 ScrollView 里嵌套 Form（会导致滚动条粗细不一/轨道下沉）。

/// 分组卡片：标题 + 淡灰圆角底框 + 浅边框（替代原生 Form 分组外观，模型/设置/关于三页共用）
struct SettingSectionCard<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            VStack(spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
        }
    }
}

/// 配置行：label 靠左 + Spacer 物理强推控件最右 + controlSize(.regular) 锁定原生尺寸 + 行间分割线
struct SettingRow<Control: View>: View {
    let label: String
    var divider: Bool
    let control: Control

    init(_ label: String, divider: Bool = true, @ViewBuilder control: () -> Control) {
        self.label = label
        self.divider = divider
        self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.body)
                    .foregroundColor(.primary)
                Spacer()
                control
                    .controlSize(.regular)
            }
            .frame(height: 38)
            if divider {
                SettingDivider()
            }
        }
    }
}

/// 开关行：label 靠左 + 纯开关被 Spacer 强推最右（修复 Toggle 被拉伸变形 / 贴文字 Bug）
struct SettingToggleRow: View {
    let label: String
    var divider: Bool
    @Binding var isOn: Bool
    let onChange: () -> Void

    init(_ label: String, isOn: Binding<Bool>, divider: Bool = true, onChange: @escaping () -> Void = {}) {
        self.label = label
        self._isOn = isOn
        self.divider = divider
        self.onChange = onChange
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .font(.body)
                    .foregroundColor(.primary)
                Spacer()
                Toggle("", isOn: $isOn)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .frame(height: 38)
            if divider {
                SettingDivider()
            }
        }
        .onChange(of: isOn) { _, _ in onChange() }
    }
}

/// 行间分割线（精致浅色横线）
struct SettingDivider: View {
    var body: some View {
        Divider()
            .opacity(0.5)
    }
}

/// 内容展示卡片（全景页区块用）：贴近 Form.grouped 的灰色圆角分组观感，替代原生 Form 分组外壳。
/// 纯展示型区块（带内部自有标题）套此卡片，仅提供背景与边框，不额外渲染标题。
struct PanelCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            )
    }
}
