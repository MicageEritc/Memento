import SwiftUI
import AppKit

// MARK: - 颜色主题（语义化：全部颜色随系统外观自动适配浅色/深色模式）

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: 动态颜色辅助（light/dark 双值，跟随系统外观实时切换）

private func hex(_ v: UInt32, _ a: Double = 1) -> NSColor {
    let r: CGFloat = CGFloat((v >> 16) & 0xFF) / 255
    let g: CGFloat = CGFloat((v >> 8) & 0xFF) / 255
    let b: CGFloat = CGFloat(v & 0xFF) / 255
    return NSColor(srgbRed: r, green: g, blue: b, alpha: CGFloat(a))
}

/// light/dark 双值动态色
private func dyn(_ l: NSColor, _ d: NSColor) -> Color {
    Color(nsColor: NSColor(name: NSColor.Name("liuke.dynamic")) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
    })
}

/// 同色相双值：深色模式默认提高透明度增强可见性；lift>0 时深色端向白色提亮
private func dyn(_ v: UInt32, la: Double = 1, da: Double = 1, lift: Double = 0) -> Color {
    let l = hex(v, la)
    var d = hex(v, da)
    if lift > 0, let lifted = hex(v).blended(withFraction: lift, of: .white) {
        d = lifted.withAlphaComponent(da)
    }
    return dyn(l, d)
}

/// 提亮版动态色：浅色端原色，深色端向白色提亮 lift 比例（用于深色下的数据可视化/前景色）
private func liftDyn(_ v: UInt32, lift: Double) -> Color {
    let l = hex(v)
    let d = hex(v).blended(withFraction: lift, of: .white) ?? hex(v)
    return dyn(l, d)
}

enum T {
    // 背景 / 表面（浅色端沿用品牌浅灰，深色端取 macOS 标准深灰阶）
    static let bg = dyn(hex(0xFAFAFC, 0.55), hex(0x161618, 0.55))
    static let bgSidebar = dyn(hex(0xF4F4F7, 0.45), hex(0x1E1E20, 0.45))
    static let surface = dyn(hex(0xFFFFFF, 0.62), hex(0x2A2A2C, 0.62))
    static let surface2 = dyn(hex(0xF8F8FA, 0.55), hex(0x232325, 0.55))
    static let surfaceHover = dyn(hex(0xF2F2F4, 0.70), hex(0x38383A, 0.70))

    // 边框 / 分隔（深色端反转为白色透明度）
    static let border = dyn(hex(0x000000, 0.08), hex(0xFFFFFF, 0.14))
    static let borderStrong = dyn(hex(0x000000, 0.14), hex(0xFFFFFF, 0.24))
    static let divider = dyn(hex(0x000000, 0.06), hex(0xFFFFFF, 0.10))

    // 文本 / 语义（绑定系统标签色，自动适配外观与辅助功能）
    static let text = Color(nsColor: .labelColor)
    static let textDim = Color(nsColor: .secondaryLabelColor)
    static let muted = Color(nsColor: .tertiaryLabelColor)
    static let accent = dyn(hex(0x0071E3), hex(0x4DA3FF))
    static let accent2 = dyn(hex(0x005BB5), hex(0x7ABAFF))
    static let accentSoft = dyn(hex(0x0071E3, 0.10), hex(0x4DA3FF, 0.22))
    static let ok = Color(nsColor: .systemGreen)
    static let okSoft = dyn(hex(0x34C759, 0.18), hex(0x30D158, 0.28))
    static let okText = dyn(hex(0x1D7D32), hex(0x7BD88A))
    static let warn = Color(nsColor: .systemOrange)
    static let warnSoft = dyn(hex(0xFF9500, 0.12), hex(0xFF9F0A, 0.22))
    static let warnText = dyn(hex(0x9A5C00), hex(0xFFCC66))
    static let err = Color(nsColor: .systemRed)
    static let errSoft = dyn(hex(0xFF3B30, 0.12), hex(0xFF453A, 0.22))
    static let errText = dyn(hex(0xC41C14), hex(0xFF8A80))

    // 一念金色（品牌色，深色端提亮保证对比度）
    static let gold = dyn(hex(0xF0B34B), hex(0xF5C878))
    static let goldBg1 = dyn(hex(0xFFFAF0), hex(0x2A2317))
    static let goldText = dyn(hex(0x8A5A00), hex(0xF2CE85))
    static let goldChipA = dyn(hex(0xFFF3D6), hex(0x3A2F18))
    static let goldChipB = dyn(hex(0xFFE6A8), hex(0x4A3C1E))
    static let yinianSum = dyn(hex(0x5A3A05), hex(0xF5D48A))

    // 字体
    static func f(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .system(size: size, weight: w)
    }
    static func mono(_ size: CGFloat, _ w: Font.Weight = .regular) -> Font {
        .system(size: size, weight: w, design: .monospaced)
    }
}

// MARK: - 分类 → 展示配色（light/dark 自适应）

enum CatStyle {
    /// chip 三元组：背景、文字、描边（深色端：背景/描边提高透明度、文字提亮）
    static func chip(_ name: String) -> (bg: Color, fg: Color, bd: Color) {
        switch name {
        case "办公与文档": return chipC(0x0071E3, 0x005BB5)
        case "沟通与协作": return chipC(0xFF6B00, 0xB34D00)
        case "阅读与研究": return chipC(0x00A3A3, 0x007A7A)
        case "编程开发":   return chipC(0x5E5CE6, 0x413FC7)
        case "设计与创作": return chipC(0xFF2D92, 0xB3005D)
        case "影音与娱乐": return chipC(0xBF5AF2, 0x8A3BB8)
        case "生活与购物": return chipC(0x30B350, 0x1D7D32)
        case "系统与工具": return chipC(0x6E6E73, 0x3A3A3C)
        case "待机与离席": return chipC(0x8E8E93, 0x55555C)
        default:
            return (T.surface2, T.textDim, T.border)
        }
    }

    private static func chipC(_ base: UInt32, _ fgHex: UInt32) -> (bg: Color, fg: Color, bd: Color) {
        (dyn(hex(base, 0.10), hex(base, 0.28)),
         liftDyn(fgHex, lift: 0.45),
         dyn(hex(base, 0.30), hex(base, 0.55)))
    }

    /// 饼图 / 进度条配色（深色端统一提亮，保证深底上的可辨识度）
    static let palette: [String: Color] = [
        "办公与文档": liftDyn(0x2563EB, lift: 0.25),
        "沟通与协作": liftDyn(0xEA580C, lift: 0.25),
        "阅读与研究": liftDyn(0x0891B2, lift: 0.25),
        "编程开发":   liftDyn(0x7C3AED, lift: 0.25),
        "设计与创作": liftDyn(0xDB2777, lift: 0.25),
        "影音与娱乐": liftDyn(0xCA8A04, lift: 0.25),
        "生活与购物": liftDyn(0x16A34A, lift: 0.25),
        "系统与工具": liftDyn(0x475569, lift: 0.35),
        "待机与离席": liftDyn(0x6B7280, lift: 0.30),
        "其他":       liftDyn(0x94A3B8, lift: 0.20)
    ]

    /// 非标准分类按黄金角动态分配色相（与 renderer.js colorForCategory 完全一致）
    static func color(_ key: String, _ i: Int) -> Color {
        if let c = palette[key] { return c }
        var hue = (Double(i) * 137.508).truncatingRemainder(dividingBy: 360)
        hue = (hue + 360).truncatingRemainder(dividingBy: 360)
        return Color.fromHSL(h: hue, s: 0.72, l: 0.48)
    }

    /// 展示顺序（对应 CAT_DISPLAY）
    static let display = ActivityCategory.all
}

extension Color {
    /// CSS hsl() → sRGB 精确换算（SwiftUI 的 Color(hue:saturation:brightness:) 是 HSB，与 CSS HSL 不同）
    static func fromHSL(h: Double, s: Double, l: Double) -> Color {
        let c = (1 - abs(2 * l - 1)) * s
        let hp = h / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var (r, g, b): (Double, Double, Double)
        switch hp {
        case 0..<1: (r, g, b) = (c, x, 0)
        case 1..<2: (r, g, b) = (x, c, 0)
        case 2..<3: (r, g, b) = (0, c, x)
        case 3..<4: (r, g, b) = (0, x, c)
        case 4..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        let m = l - c / 2
        return Color(.sRGB, red: r + m, green: g + m, blue: b + m, opacity: 1)
    }
}

// MARK: - 状态文案（对应 renderer.js STATUS_LABEL）

enum StatusLabel {
    static func of(_ s: RecordStatus) -> String {
        switch s {
        case .done: return ""
        case .analyzing: return "分析中"
        case .pending: return "定格中"
        case .skipped: return "无变化"
        case .failed: return "失败"
        case .dropped: return "已丢弃"
        case .idle: return "待机中"
        }
    }
}

// MARK: - 毛玻璃背景（替代 CSS backdrop-filter + macOS vibrancy）

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blending: NSVisualEffectView.BlendingMode = .behindWindow
    var emphasized = false

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .followsWindowActiveState
        v.isEmphasized = emphasized
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
        v.isEmphasized = emphasized
    }
}
