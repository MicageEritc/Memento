import SwiftUI
import AppKit

// MARK: - 「瞬息」页 —— 核心记录入口

struct InstantPanel: View {
    @ObservedObject var app: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    if app.records.isEmpty {
                        EmptyTip(
                            icon: "◎",
                            text: "这一天还没有记录。点击右上角开启「瞬息」，系统将按设定的间隔自动记录屏幕，并理解你在做什么。"
                        )
                    } else {
                        ForEach(app.records) { r in
                            MomentCard(record: r, app: app)
                                .id(r.id)
                        }
                    }
                }
                .padding(20)
                // 内容左对齐：滚动条出现/消失时不会改变左侧起点，避免帖子偏移
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 滚动条遵循系统行为：按需显示（overlay 细滚动条）
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.top)
            .onChange(of: app.breatheId) { _, id in
                guard let id, app.tab == .instant else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .toolbar {
            // 全局搜索为独立内容状态：搜索时清空整个 toolbar（不继承当前页面原有 items）
            if !app.isSearching {
                ToolbarItem(placement: .navigation) {
                    DateSwitcher(app: app, date: $app.currentDate)
                }
                // .primaryAction 在 macOS detail toolbar 上天然排最右区域；
                // 不手动 offset/padding，避免按钮被 toolbar 边界裁剪变形。
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .primaryAction) {
                    RecordToggle(app: app)
                }
            }
        }
        // 纯 SwiftUI 原生毛玻璃：toolbar 背景材质，滚动内容上滑时被模糊（macOS 26 原生，无 AppKit 兜底）
        // 搜索已迁移到 Sidebar（.searchable 挂 sidebar，toolbar 不再放搜索框）
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
        .onChange(of: app.currentDate) { _, _ in
            Task { await app.reload() }
        }
    }

    private func dateLabel(_ ds: String) -> String {
        let today = DateUtil.ymd(Date())
        if ds == today { return "今天" }
        let yest = DateUtil.ymd(DateUtil.addDays(Date(), -1))
        if ds == yest { return "昨天" }
        return ds
    }
}

// MARK: - 「一念」页 —— 用户主动保存的重要瞬间

struct YinianPanel: View {
    @ObservedObject var app: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    if app.yinianRecords.isEmpty {
                        EmptyTip(
                            icon: "✦",
                            text: app.filterByDate
                                ? "这一天还没有一念。切换顶部日期可查看其他天的精选，或点「定格一念」保存当前屏幕。"
                                : "还没有一念。在顶部状态栏点击「定格一念」，手动保存当前屏幕里值得留存的瞬间，它就会出现在这里。"
                        )
                    } else {
                        ForEach(app.yinianRecords) { r in
                            YinianCard(record: r, app: app)
                                .id(r.id)
                        }
                    }
                }
                .padding(20)
                // 内容左对齐：滚动条出现/消失时不会改变左侧起点，避免帖子偏移
                .frame(maxWidth: 880, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // 滚动条遵循系统行为：按需显示（overlay 细滚动条）
            .scrollIndicators(.automatic)
            .defaultScrollAnchor(.top)
            .onChange(of: app.breatheId) { _, id in
                guard let id, app.tab == .yinian else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .toolbar {
                // 全局搜索为独立内容状态：搜索时清空整个 toolbar（不继承当前页面原有 items）
                if !app.isSearching {
                    ToolbarItem(placement: .navigation) {
                        // 包装 binding：用户切日期 → setYinianDate → 进入按日期过滤
                        DateSwitcher(app: app, date: Binding(
                            get: { app.yinianDate },
                            set: { app.setYinianDate($0) }
                        ))
                    }
                    // .primaryAction 在 macOS detail toolbar 上天然排最右区域；
                    // 不手动 offset/padding，避免按钮被 toolbar 边界裁剪变形。
                    ToolbarSpacer(.flexible)
                    ToolbarItem(placement: .primaryAction) {
                        RecordToggle(app: app)
                    }
                }
            }
        // 纯 SwiftUI 原生毛玻璃：toolbar 背景材质，滚动内容上滑时被模糊（macOS 26 原生，无 AppKit 兜底）
        // 搜索已迁移到 Sidebar（.searchable 挂 sidebar，toolbar 不再放搜索框）
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
        .onAppear {
            // 每次切回一念页 → 复位：恢复「全部一念」且日期回今天
            app.resetYinianFilter()
        }
    }

    /// 状态条日期文案（今天/昨天/具体日期，与瞬息页一致）
    private func dateLabel(_ ds: String) -> String {
        let today = DateUtil.ymd(Date())
        if ds == today { return "今天" }
        let yest = DateUtil.ymd(DateUtil.addDays(Date(), -1))
        if ds == yest { return "昨天" }
        return ds
    }
}

// MARK: - 瞬息记录卡：左图右文字 + 操作按钮 hover 才出现

struct MomentCard: View {
    let record: ActRecord
    @ObservedObject var app: AppState

    @State private var hovering = false

    private var a: Activity { record.activity ?? Activity() }
    private var status: RecordStatus { record.statusEnum }
    private var isYinian: Bool { record.kind == .yinian }
    private var breathing: Bool { app.breatheId == record.id }

    private var title: String {
        let t = (a.title ?? "").trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        if isYinian { return "一念 · 手动留存的瞬间" }
        let s = StatusLabel.of(status)
        return s.isEmpty ? "—" : s
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbArea
            VStack(alignment: .leading, spacing: 6) {
                titleRow
                tagsRow
                summaryBody
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isYinian ? T.gold.opacity(0.55) : T.border,
                              lineWidth: isYinian ? 1.5 : 1)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(breathing ? T.accent : Color.clear, lineWidth: 2)
                .allowsHitTesting(false)
        )
        .opacity((status == .analyzing || status == .pending) ? 0.85 : 1)
        .onHover { hovering = $0 }
    }

    // MARK: 左侧缩略图 + 操作按钮 hover 才显示（默认完全隐藏，layout 不变）

    private var thumbArea: some View {
        ZStack {
            if let abs = record.screenshotAbs, ThumbCache.shared.exists(abs) {
                Thumb(path: abs, width: 180, height: 112, radius: 8, maskText: "查看大图") {
                    app.lightboxPath = abs
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(T.surface2)
                    Text(status == .idle ? "◍" : "⧗")
                        .font(.system(size: 26))
                        .foregroundStyle(T.muted)
                }
                .frame(width: 180, height: 112)
            }
        }
        .overlay(alignment: .topTrailing) {
            // hover 才显示的文件夹 / 删除按钮
            HStack(spacing: 3) {
                if let abs = record.screenshotAbs, ThumbCache.shared.exists(abs) {
                    Button {
                        Dialogs.reveal(abs)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(T.text)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.92))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("在访达中显示")
                    .opacity(hovering ? 1 : 0)
                }
                Button {
                    Task { await app.deleteRecord(record) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(T.err)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.92))
                        )
                }
                .buttonStyle(.plain)
                .help("删除这条记录")
                .opacity(hovering ? 1 : 0)
            }
            .padding(6)
            // 让按钮本身不接收事件（避免遮挡 thumb 的点击 → 灯箱）
            .allowsHitTesting(hovering)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(T.f(14, .semibold))
                .foregroundStyle(T.text)
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            Text(record.time ?? "")
                .font(T.mono(11)).monospacedDigit()
                .foregroundStyle(T.muted)
                .fixedSize()
        }
    }

    private var tagsRow: some View {
        WrapHStack(spacing: 5, lineSpacing: 5) {
            if isYinian {
                Text("一念")
                    .font(T.f(10.5, .semibold))
                    .foregroundStyle(T.goldText)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(T.goldChipA))
                    .overlay(Capsule().strokeBorder(T.gold, lineWidth: 1))
            }
            if let c = a.category, !c.isEmpty, c != "未知" {
                let s = CatStyle.chip(c)
                Text(c)
                    .font(T.f(10.5, .semibold))
                    .foregroundStyle(s.fg)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(s.bg))
                    .overlay(Capsule().strokeBorder(s.bd, lineWidth: 1))
            }
            if let ap = a.app, !ap.isEmpty, ap != "未知" {
                Text("应用：\(ap)")
                    .font(T.f(10.5))
                    .foregroundStyle(T.textDim)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(T.surface2))
                    .overlay(Capsule().strokeBorder(T.border, lineWidth: 1))
            }
            if let f = a.focus, !f.isEmpty, f != "未知" {
                let (bg, fg, bd) = focusStyle(f)
                Text(f)
                    .font(T.f(10.5, .semibold))
                    .foregroundStyle(fg)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(bg))
                    .overlay(Capsule().strokeBorder(bd, lineWidth: 1))
            }
            if let m = record.analysis?.model, !m.isEmpty, m != "未知" {
                Text("模型：\(m)")
                    .font(T.f(10.5))
                    .foregroundStyle(T.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(T.surface2))
                    .overlay(Capsule().strokeBorder(T.border, lineWidth: 1))
            }
            if let ms = record.analysis?.latencyMs, ms > 0 {
                Text(String(format: "%.1fs", Double(ms) / 1000))
                    .font(T.f(10.5))
                    .foregroundStyle(T.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(T.surface2))
                    .overlay(Capsule().strokeBorder(T.border, lineWidth: 1))
            }
            // 截图无变化（Recorder 判定 skipped，沿用上次分析）：标签放在最后
            if status == .skipped {
                Text("无变化")
                    .font(T.f(10.5, .semibold))
                    .foregroundStyle(T.textDim)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(T.surface2))
                    .overlay(Capsule().strokeBorder(T.border, lineWidth: 1))
            }
        }
    }

    private func focusStyle(_ s: String) -> (Color, Color, Color) {
        if s.contains("专注") { return (T.okSoft, T.okText, T.ok.opacity(0.35)) }
        if s.contains("分散") { return (T.warnSoft, T.warnText, T.warn.opacity(0.35)) }
        return (T.surface2, T.textDim, T.border)
    }

    @ViewBuilder
    private var summaryBody: some View {
        switch status {
        case .analyzing, .pending:
            Text("本地模型分析中…")
                .font(.callout).foregroundStyle(T.muted)
        case .failed:
            Text(record.analysis?.error ?? "分析失败")
                .font(.callout).foregroundStyle(T.errText)
                .fixedSize(horizontal: false, vertical: true)
        default:
            let s = a.summaryText
            if !s.isEmpty {
                Text(s)
                    .font(T.f(12.5))
                    .lineSpacing(3)
                    .foregroundStyle(T.textDim)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("无总结")
                    .font(.callout).foregroundStyle(T.muted)
            }
        }
    }
}

// MARK: - 一念卡：左图右文字 + 金色主题 + 操作按钮 hover 才显示

struct YinianCard: View {
    let record: ActRecord
    @ObservedObject var app: AppState

    @State private var hovering = false

    private var a: Activity { record.activity ?? Activity() }
    private var status: RecordStatus { record.statusEnum }
    private var breathing: Bool { app.breatheId == record.id }

    private var title: String {
        let t = (a.title ?? "").trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { return t }
        return "一念 · 手动留存的瞬间"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            thumbArea
            VStack(alignment: .leading, spacing: 6) {
                titleRow
                tagsRow
                summaryBody
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(T.gold.opacity(0.55), lineWidth: 1.5)
                .allowsHitTesting(false)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(breathing ? T.accent : Color.clear, lineWidth: 2)
                .allowsHitTesting(false)
        )
        .opacity((status == .analyzing || status == .pending) ? 0.85 : 1)
        .onHover { hovering = $0 }
    }

    private var thumbArea: some View {
        ZStack {
            if let abs = record.screenshotAbs, ThumbCache.shared.exists(abs) {
                Thumb(path: abs, width: 180, height: 112, radius: 8, maskText: "查看大图") {
                    app.lightboxPath = abs
                }
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(T.goldBg1)
                    Text("✦").font(.system(size: 28)).foregroundStyle(T.gold)
                }
                .frame(width: 180, height: 112)
            }
        }
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 3) {
                if let abs = record.screenshotAbs, ThumbCache.shared.exists(abs) {
                    Button {
                        Dialogs.reveal(abs)
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(T.text)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.white.opacity(0.92))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("在访达中显示")
                    .opacity(hovering ? 1 : 0)
                }
                Button {
                    Task { await app.deleteRecord(record) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(T.err)
                        .frame(width: 22, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.92))
                        )
                }
                .buttonStyle(.plain)
                .help("删除")
                .opacity(hovering ? 1 : 0)
            }
            .padding(6)
            .allowsHitTesting(hovering)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(T.f(14, .semibold))
                .foregroundStyle(T.text)
                .lineLimit(1)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            HStack(spacing: 4) {
                Text(record.date ?? "")
                    .font(T.mono(11)).monospacedDigit()
                    .foregroundStyle(T.goldText)
                Text(record.time ?? "")
                    .font(T.mono(11)).monospacedDigit()
                    .foregroundStyle(T.muted)
            }
        }
    }

    private var tagsRow: some View {
        WrapHStack(spacing: 5, lineSpacing: 5) {
            Text("一念")
                .font(T.f(10.5, .semibold))
                .foregroundStyle(T.goldText)
                .lineLimit(1)
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(T.goldChipA))
                .overlay(Capsule().strokeBorder(T.gold, lineWidth: 1))
            // 记忆价值类型（一念专属）：旧数据无 intent → 归一化为「其他」，不展示以免噪音
            if let raw = a.intent, !raw.isEmpty {
                let iv = MemoryIntent.normalize(raw)
                if iv != "其他" {
                    Text(iv)
                        .font(T.f(10.5, .semibold))
                        .foregroundStyle(T.accent2)
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(T.accentSoft))
                        .overlay(Capsule().strokeBorder(T.accent.opacity(0.35), lineWidth: 1))
                        .help("这条一念的记忆价值类型（由 AI 判定）")
                }
            }
            if let c = a.category, !c.isEmpty, c != "未知" {
                let s = CatStyle.chip(c)
                Text(c)
                    .font(T.f(10.5, .semibold))
                    .foregroundStyle(s.fg)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(s.bg))
                    .overlay(Capsule().strokeBorder(s.bd, lineWidth: 1))
            }
            if let ap = a.app, !ap.isEmpty, ap != "未知" {
                Text("应用：\(ap)")
                    .font(T.f(10.5))
                    .foregroundStyle(T.textDim)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(T.surface2))
                    .overlay(Capsule().strokeBorder(T.border, lineWidth: 1))
            }
            if let f = a.focus, !f.isEmpty, f != "未知" {
                let (bg, fg, bd) = focusStyle(f)
                Text(f)
                    .font(T.f(10.5, .semibold))
                    .foregroundStyle(fg)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(bg))
                    .overlay(Capsule().strokeBorder(bd, lineWidth: 1))
            }
            if let m = record.analysis?.model, !m.isEmpty, m != "未知" {
                Text("模型：\(m)")
                    .font(T.f(10.5))
                    .foregroundStyle(T.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(T.surface2))
                    .overlay(Capsule().strokeBorder(T.border, lineWidth: 1))
            }
            if let ms = record.analysis?.latencyMs, ms > 0 {
                Text(String(format: "%.1fs", Double(ms) / 1000))
                    .font(T.f(10.5))
                    .foregroundStyle(T.muted)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(T.surface2))
                    .overlay(Capsule().strokeBorder(T.border, lineWidth: 1))
            }
            // 截图无变化（Recorder 判定 skipped，沿用上次分析）：标签放在最后
            if status == .skipped {
                Text("无变化")
                    .font(T.f(10.5, .semibold))
                    .foregroundStyle(T.textDim)
                    .lineLimit(1)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(T.surface2))
                    .overlay(Capsule().strokeBorder(T.border, lineWidth: 1))
            }
        }
    }

    private func focusStyle(_ s: String) -> (Color, Color, Color) {
        if s.contains("专注") { return (T.okSoft, T.okText, T.ok.opacity(0.35)) }
        if s.contains("分散") { return (T.warnSoft, T.warnText, T.warn.opacity(0.35)) }
        return (T.surface2, T.textDim, T.border)
    }

    @ViewBuilder
    private var summaryBody: some View {
        switch status {
        case .analyzing, .pending:
            Text("本地模型分析中…")
                .font(.callout).foregroundStyle(T.muted)
        default:
            let s = a.summaryText
            if !s.isEmpty {
                Text(s)
                    .font(T.f(12.5))
                    .lineSpacing(3)
                    .foregroundStyle(T.textDim)
                    .lineLimit(8)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                Text("无总结")
                    .font(.callout).foregroundStyle(T.muted)
            }
        }
    }
}

// MARK: - 自动换行的水平堆叠（Layout 协议）

struct WrapHStack: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, maxLineW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > maxW {
                maxLineW = max(maxLineW, x - spacing)
                x = 0
                y += lineH + lineSpacing
                lineH = 0
            }
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
        maxLineW = max(maxLineW, x - spacing)
        return CGSize(width: maxW.isFinite ? maxW : max(0, maxLineW), height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX
                y += lineH + lineSpacing
                lineH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}

// MARK: - 屏幕录制权限横幅

struct PermBanner: View {
    @ObservedObject var app: AppState

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("需要「屏幕录制」权限")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color(hex: 0x7F1D1D))
                Text("请在系统设置 → 隐私与安全性 → 屏幕录制中勾选「留刻」，然后重启应用。")
                    .font(.callout)
                    .foregroundStyle(Color(hex: 0x991B1B))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                LKButton(title: "前往系统设置", kind: .warn) {
                    Dialogs.openScreenRecordingSettings()
                }
                Button("已授权，忽略") {
                    app.dismissPermBanner()
                }
            }
            .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xFFF2F2))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0xFFD1D1)).frame(height: 1)
        }
    }
}