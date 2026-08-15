import SwiftUI
import AppKit

// MARK: - 「全景」页 —— “我的一天被 AI 理解后的回忆”
// 今日记忆概览（专注度环 + 活跃时长环）→ 今日关键词（软件 Top5）→ 活动分类（时间投入）→ 时间轨迹 → AI 回忆。

struct PanoramaPanel: View {
    @ObservedObject var app: AppState
    /// 专注度算法拆解默认收起，点 ⓘ 才展开（产品体验优先，工程透明可溯）
    @State private var showFocusDetail = false
    /// 待删除的历史记录（用于误删确认）
    @State private var deleteTarget: SummaryDoc?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                if app.panoramaTab == .insight {
                    insightView
                } else {
                    // 复盘优先：概览 → 核心回忆 → 时间轨迹 → 行为统计 → 今天的话题 → 趋势
                    PanelCard { hero }
                    PanelCard { aiSummary }
                    PanelCard { timeTrace }
                    PanelCard { categoryStats }
                    PanelCard { keywords }
                    if app.dailyTrend.count > 1 {
                        PanelCard { trend }
                    }
                }
            }
            // 边距全部内塞在内容 VStack 上（零外边距 ScrollView），与全局 6 页统一
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .padding(.horizontal, 40)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.top)
        // 顶栏：左侧 .navigation 放「范围分段 + 日期切换」，右侧 .primaryAction 放独立圆形 AI 总结按钮（参考录制按钮布局）。
        .toolbar {
            // 全局搜索为独立内容状态：搜索时清空整个 toolbar（不继承当前页面原有 items）
            if !app.isSearching {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 10) {
                        ScopeSegmentedControl(app: app)

                        if app.panoramaTab != .insight {
                            DateSwitcher(app: app, date: $app.summaryDate)
                        } else {
                            Button {
                                Task { await app.regenerateInsight() }
                            } label: {
                                Label(app.insightUpdating ? "更新中…" : "更新画像",
                                      systemImage: "arrow.clockwise")
                            }
                            .disabled(app.insightUpdating)
                        }
                    }
                }

                // AI 总结：最右侧独立圆形按钮，参考录制按钮布局：先 flexible spacer 推到最右，再用 .primaryAction
                if app.panoramaTab != .insight {
                    ToolbarSpacer(.flexible)

                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await generateForCurrentTab() }
                        } label: {
                            MuseCircleIcon(icon: app.summaryGenerating ? "arrow.clockwise" : "sparkles")
                        }
                        .buttonStyle(.plain)
                        .fixedSize()
                        .help(app.summaryGenerating ? "生成中…" : "重新生成当前页面 AI 回忆")
                        .disabled(app.summaryGenerating)
                    }
                }
            }
        }
        // 纯 SwiftUI 原生毛玻璃：toolbar 背景材质，滚动内容上滑时被模糊（macOS 26 原生，无 AppKit 兜底）
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
        .onChange(of: app.summaryDate) { _, _ in
            Task { await app.loadScroll() }
        }
        .task {
            if app.panoramaTab == .insight { await app.loadInsight() }
            else { await app.loadScroll() }
        }
        .confirmationDialog(
            "删除这条历史记录？",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { target in
            Button("删除", role: .destructive) {
                Task { await app.deleteSummaryHistory(target) }
            }
            Button("取消", role: .cancel) {
                deleteTarget = nil
            }
        } message: { target in
            Text("「\(target.generatedLabel)」的 AI 回忆将被永久删除，无法恢复。")
        }
    }

    private func pickAndGenerate(_ scope: SummaryScope) {
        app.summaryScope = scope
        Task {
            await app.loadScroll()
            await app.generateSummary()
        }
    }

    /// 根据当前 panoramaTab 重新生成对应 scope 的 AI 回忆。
    private func generateForCurrentTab() async {
        guard let scope = app.panoramaTab.summaryScope else { return }
        app.summaryScope = scope
        await app.loadScroll()
        await app.generateSummary()
    }

    // MARK: 今日概览 —— 弱化石「N 个瞬间」，先给结论；专注度算法拆解默认收起

    private var scopeTotal: Int {
        app.dailyTrend.reduce(0) { $0 + $1.1 }
    }

    private var scopeTitle: String {
        app.summaryScope == .day ? "今天" : "\(app.summaryScope.label)回顾"
    }

    /// 活动时长用当前 scope 的已分析记录数（不是「今天」统计），周/月/年才正确。
    private var activeHoursVal: Double {
        Double(app.breakdown.analyzed) * Double(app.cfg.intervalSec) / 3600
    }

    private var focusedMin: Int {
        let r = app.focusReport
        return r.focusedSec >= 60 ? r.focusedSec / 60 : 0
    }

    /// 概览副标题：日 → 活跃时段跨度；其余 → 日期范围。
    private var activeSpanText: String {
        if app.summaryScope == .day {
            let h = app.hourly
            guard h.contains(where: { $0 > 0 }) else { return app.rangeLabel }
            let first = h.firstIndex(where: { $0 > 0 })!
            let last = h.lastIndex(where: { $0 > 0 })!
            return "活跃 \(first):00 – \(last):00 · \(scopeTotal) 条记录"
        }
        return app.rangeLabel
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(scopeTitle)
                        .font(T.f(13, .medium))
                        .foregroundStyle(T.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(scopeTotal)")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(T.text)
                        Text("个瞬间")
                            .font(T.f(14, .medium))
                            .foregroundStyle(T.muted)
                    }
                    Text(activeSpanText)
                        .font(T.f(12))
                        .foregroundStyle(T.muted)
                }
                Spacer(minLength: 0)

                // 两个指标环：专注度 + 活跃时长（一样大，文字图标对齐）
                HStack(spacing: 26) {
                    FocusRing(progress: Double(focusPct) / 100,
                              valueText: "\(focusPct)%",
                              label: "专注度",
                              size: 72, lineWidth: 7)
                    FocusRing(progress: min(1, activeHoursVal / 12),
                              valueText: "\(app.activeHoursText)h",
                              label: "活跃时长",
                              size: 72, lineWidth: 7,
                              color: T.ok)
                }
            }

            // 一行事实：先告诉用户今天/本期到底怎么过的
            HStack(spacing: 8) {
                Text("活动 \(app.activeHoursText)h")
                if focusedMin > 0 { dot; Text("专注 \(focusedMin) 分钟") }
                let r = app.focusReport
                if r.interruptionCount > 0 { dot; Text("干扰 \(r.interruptionCount) 次") }
                if r.switchCount > 0 { dot; Text("切换 \(r.switchCount) 次") }
            }
            .font(T.f(11.5))
            .foregroundStyle(T.muted)

            // ⓘ 展开算法拆解（默认收起，产品优先、透明可溯）
            DisclosureGroup(isExpanded: $showFocusDetail) {
                focusBreakdown
                    .padding(.top, 6)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(T.muted)
                    Text("专注度如何计算")
                        .font(T.f(11.5))
                        .foregroundStyle(T.muted)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private var dot: some View {
        Text("·").foregroundStyle(T.muted.opacity(0.5))
    }

    /// 专注度四指标加权分解：每项的取值(0–100%)、权重、单项贡献，全部本地计算可复现。
    private var focusBreakdown: some View {
        let r = app.focusReport
        guard r.focusedSec + r.scatteredSec + r.idleSec > 0 else {
            return AnyView(EmptyView())
        }
        let rows: [(String, Double, Double, Color)] = [
            ("有效时间投入", r.effScore, 0.40, T.accent),
            ("活动连续性",   r.contScore, 0.25, Color(hex: 0x0891B2)),
            ("干扰 / 切换",  r.intrScore, 0.20, Color(hex: 0xEA580C)),
            ("AI 专注提示",  r.aiScore,   0.15, Color(hex: 0x7C3AED)),
        ]
        return AnyView(
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        Text(row.0)
                            .font(T.f(11.5))
                            .foregroundStyle(T.text)
                            .frame(width: 84, alignment: .leading)
                        ThinBar(value: row.1, color: row.3, height: 5)
                            .frame(width: 92)
                        Text("\(Int(row.1 * 100))%")
                            .font(T.f(11.5, .medium)).monospacedDigit()
                            .foregroundStyle(T.text)
                            .frame(width: 32, alignment: .trailing)
                        Text("×\(String(format: "%.2f", row.2))")
                            .font(T.f(10.5))
                            .foregroundStyle(T.muted)
                            .frame(width: 44, alignment: .leading)
                    }
                }
                Divider().padding(.vertical, 3)
                HStack(spacing: 8) {
                    Text("综合专注度")
                        .font(T.f(11.5, .semibold))
                        .foregroundStyle(T.text)
                        .frame(width: 84, alignment: .leading)
                    Spacer(minLength: 0)
                    Text("\(focusPct)%")
                        .font(T.f(13, .bold)).monospacedDigit()
                        .foregroundStyle(T.accent)
                        .frame(width: 32, alignment: .trailing)
                    Text("权重和 1.0")
                        .font(T.f(10.5))
                        .foregroundStyle(T.muted)
                        .frame(width: 44, alignment: .leading)
                }
            }
            .padding(.top, 4)
        )
    }

    /// 专注度：优先用本地时间序列算法（时长加权，含干扰/切换）；
    /// 老数据没有可用时间戳时退回「按记录条数」旧口径，保证不出现 0%。
    private var focusPct: Int {
        let r = app.focusReport
        return (r.focusedSec + r.scatteredSec) > 0 ? r.score : app.focus.score
    }

    // MARK: 今天的话题 —— 用软件名称（Top 5），随日/周/月/年联动

    private var keywords: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("今天的话题")
            let top = Array(app.topApps.prefix(5))
            if top.isEmpty {
                Text("该区间暂无应用记录")
                    .font(T.f(12.5)).foregroundStyle(T.muted)
            } else {
                HStack(spacing: 14) {
                    ForEach(Array(top.enumerated()), id: \.offset) { i, r in
                        Text(r.app)
                            .font(T.f(14, .semibold))
                            .foregroundStyle(keywordColor(i))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func keywordColor(_ i: Int) -> Color {
        let colors: [Color] = [
            T.accent, Color(hex: 0xEA580C), Color(hex: 0x0891B2),
            Color(hex: 0x7C3AED), Color(hex: 0xDB2777)
        ]
        return colors[i % colors.count]
    }

    // MARK: 活动分类统计 —— 9 类体系，展示时间投入（X小时X分钟）

    private var categoryStats: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("活动分类统计")
            let explain = categoryExplanation
            if !explain.isEmpty {
                Text(explain)
                    .font(T.f(12))
                    .foregroundStyle(T.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            let rows = categoryRows
            if rows.isEmpty {
                Text("暂无分类数据")
                    .font(T.f(12.5)).foregroundStyle(T.muted)
            } else {
                let maxV = max(1, rows.map(\.1).max() ?? 1)
                VStack(spacing: 10) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        HStack(spacing: 10) {
                            Circle()
                                .fill(CatStyle.color(row.0, i))
                                .frame(width: 8, height: 8)
                            Text(row.0)
                                .font(T.f(12.5))
                                .foregroundStyle(T.text)
                                .frame(width: 110, alignment: .leading)
                                .lineLimit(1)
                            ThinBar(
                                value: Double(row.1) / Double(maxV),
                                color: CatStyle.color(row.0, i),
                                height: 5
                            )
                            .frame(maxWidth: .infinity)
                            Text(durationText(row.1))
                                .font(T.f(12)).monospacedDigit()
                                .foregroundStyle(T.textDim)
                                .frame(minWidth: 74, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    /// 记录数 → 时间投入（X小时X分钟）
    private func durationText(_ count: Int) -> String {
        let secs = Double(count) * Double(app.cfg.intervalSec)
        let h = Int(secs) / 3600
        let m = (Int(secs) % 3600) / 60
        if h > 0 { return "\(h)小时\(m)分钟" }
        return "\(m)分钟"
    }

    /// 9 类固定顺序 + 「其他」兜底
    private var categoryRows: [(String, Int)] {
        let cats = app.breakdown.categories          // [(String, Int)]，已倒序
        var rows = ActivityCategory.all.map { name in
            (name, cats.first { $0.0 == name }?.1 ?? 0)
        }
        let other = cats.filter { !ActivityCategory.all.contains($0.0) }
            .reduce(0) { $0 + $1.1 }
        if other > 0 { rows.append(("其他", other)) }
        return rows.filter { $0.1 > 0 }
    }

    /// 活动分类一句话自动解释（本地统计 + 聚焦事实，不调用 AI）。
    private var categoryExplanation: String {
        let rows = categoryRows
        guard !rows.isEmpty else { return "" }
        let top = rows.prefix(2).map { $0.0 }
        let r = app.focusReport
        let activeH = max(0.5, Double(r.focusedSec + r.scatteredSec) / 3600)
        let fragPerH = Double(r.interruptionCount + r.switchCount) / activeH
        let tail = fragPerH >= 1 ? "，整体切换较频繁。" : "，节奏相对连贯。"
        return "主要集中在 \(top.joined(separator: " 与 "))" + tail
    }

    // MARK: 时间轨迹 —— “一天什么时候进入状态”

    private var timeTrace: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("时间轨迹")
            if app.hourly.allSatisfy({ $0 == 0 }) {
                Text("暂无数据")
                    .font(T.f(12.5)).foregroundStyle(T.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    let maxV = max(1, app.hourly.max() ?? 1)
                    GeometryReader { g in
                        HStack(spacing: 1) {
                            ForEach(0..<24, id: \.self) { h in
                                let v = app.hourly[h]
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(v > 0
                                          ? T.accent.opacity(max(0.12, Double(v) / Double(maxV)))
                                          : Color.clear)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(T.surface2)
                    )

                    HStack(spacing: 0) {
                        Text("0 时").frame(width: 36, alignment: .leading)
                        Spacer()
                        Text("6 时")
                        Spacer()
                        Text("12 时")
                        Spacer()
                        Text("18 时")
                        Spacer()
                        Text("24 时").frame(width: 36, alignment: .trailing)
                    }
                    .font(T.f(10)).foregroundStyle(T.muted)
                    .monospacedDigit()

                    Text("最活跃 \(activeWindowText)")
                        .font(T.f(12, .medium))
                        .foregroundStyle(T.accent)
                    if let cat = peakHourCategory, !cat.isEmpty {
                        Text("· \(cat)")
                            .font(T.f(12, .medium))
                            .foregroundStyle(T.muted)
                    }
                }
            }
        }
    }

    /// 最长连续活跃时段
    private var activeWindowText: String {
        var best = (start: 0, len: 0)
        var cur = (start: 0, len: 0)
        for (i, v) in app.hourly.enumerated() {
            if v > 0 {
                if cur.len == 0 { cur.start = i }
                cur.len += 1
                if cur.len > best.len { best = cur }
            } else {
                cur = (start: 0, len: 0)
            }
        }
        guard best.len > 0 else { return "暂无活跃数据" }
        return "\(best.start):00 - \(best.start + best.len):00"
    }

    /// 最活跃时段的主分类（来自逐小时分类统计），供时间轨迹点出「在做什么」。
    private var peakHourCategory: String? {
        guard app.hourly.contains(where: { $0 > 0 }) else { return nil }
        let peak = app.hourly.firstIndex(of: app.hourly.max() ?? 0) ?? 0
        let cats = peak < app.hourlyCats.count ? app.hourlyCats[peak] : [:]
        return cats.max(by: { $0.value < $1.value })?.key
    }

    // MARK: 使用趋势（周/月/年）

    private var trend: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("使用趋势")
            if app.dailyTrend.count > 31 {
                let buckets = PanoramaPanel.aggregate(app.dailyTrend, per: 7)
                VStack(alignment: .leading, spacing: 8) {
                    MiniBars(values: buckets.map(\.1), highlight: buckets.count - 1)
                        .frame(height: 60)
                    Text("每 7 天聚合 · \(buckets.count) 段")
                        .font(T.f(10)).foregroundStyle(T.muted)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    MiniBars(values: app.dailyTrend.map(\.1),
                             highlight: app.dailyTrend.count - 1)
                        .frame(height: 60)
                    HStack(spacing: 0) {
                        Text(shortLabel(app.dailyTrend.first?.0 ?? ""))
                            .font(T.f(10)).foregroundStyle(T.muted)
                        Spacer()
                        Text(shortLabel(app.dailyTrend.last?.0 ?? ""))
                            .font(T.f(10)).foregroundStyle(T.muted)
                    }
                }
            }
        }
    }

// MARK: - 范围分段控件（系统 segmented Picker：原生键盘导航与无障碍语义）

private struct ScopeSegmentedControl: View {
    @ObservedObject var app: AppState

    var body: some View {
        // 用 EmptyView 作 label 并去掉 .labelsHidden()，避免 macOS Segmented Picker
        // 把隐藏 label 渲染成第一个空 segment，导致「日」左侧多出分割线/圆角异常。
        Picker(selection: Binding(
            get: { app.panoramaTab },
            set: { t in
                app.panoramaTab = t
                if let s = t.summaryScope {
                    app.summaryScope = s
                    Task { await app.loadScroll() }
                } else {
                    Task { await app.loadInsight() }
                }
            }
        ), label: EmptyView()) {
            ForEach(PanoramaTab.allCases, id: \.self) { t in
                Text(t.label).tag(t)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
    }
}

    static func aggregate(_ trend: [(String, Int)], per: Int) -> [(String, Int)] {
        guard !trend.isEmpty else { return [] }
        var out: [(String, Int)] = []
        var i = 0
        while i < trend.count {
            let end = min(i + per, trend.count)
            let sum = trend[i..<end].reduce(0) { $0 + $1.1 }
            out.append((trend[i].0, sum))
            i = end
        }
        return out
    }

    private func shortLabel(_ ds: String) -> String {
        let parts = ds.split(separator: "-")
        guard parts.count >= 2 else { return ds }
        return "\(Int(parts[1]) ?? 0)/\(Int(parts[2]) ?? 0)"
    }

    // MARK: AI 回忆 —— 全景核心（个人助理总结风格）

    @ViewBuilder
    private var aiSummary: some View {
        let doc = app.summaryViewing ?? app.summaryDoc
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(T.accent)
                Text("\(app.summaryScope == .day ? "今日" : app.summaryScope.label)回忆")
                    .font(T.f(16, .bold))
                    .foregroundStyle(T.text)
                Spacer(minLength: 8)
                if doc != nil || app.summaryError != nil {
                    Button {
                        Task { await generateForCurrentTab() }
                    } label: {
                        Label("重新生成", systemImage: "arrow.clockwise")
                    }
                    .disabled(app.summaryGenerating)
                }
            }

            if app.summaryGenerating {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("本地模型正在回忆这段时间的屏幕轨迹…")
                        .font(T.f(12.5)).foregroundStyle(T.muted)
                }
                .padding(.vertical, 8)
            } else if let err = app.summaryError {
                VStack(alignment: .leading, spacing: 8) {
                    Text(err).font(T.f(12.5)).foregroundStyle(T.errText)
                    Button("重试") {
                        Task { await app.generateSummary() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if let d = doc {
                if let m = d.model, !m.isEmpty {
                    Text("由 \(d.modelLabel ?? m) 生成 · 仅基于本机日志")
                        .font(T.f(11)).foregroundStyle(T.muted)
                        .textSelection(.enabled)
                }
                // 单一 Text 承载 overview + 全部要点，用户可任意跨段拖动鼠标选择复制
                let body = ([d.overview] + d.sections)
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n\n")
                Text(body)
                    .font(T.f(14, .regular))
                    .lineSpacing(7)
                    .foregroundStyle(T.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 2)
                if !app.summaryHistory.isEmpty {
                    history
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("让本地模型把这段时间的屏幕轨迹，整理成一段属于你的回忆。")
                        .font(T.f(13.5))
                        .foregroundStyle(T.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        Task { await generateForCurrentTab() }
                    } label: {
                        Label("生成 AI 回忆", systemImage: "sparkles")
                            .font(T.f(13, .semibold))
                    }
                    .disabled(app.summaryGenerating)
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: 洞察 · 我的画像（本地统计聚合，不调用 AI）

    @ViewBuilder
    private var insightView: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 头部
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Text("我的画像")
                        .font(T.f(20, .bold))
                        .foregroundStyle(T.text)
                    if let p = app.behaviorProfile, !p.readiness.isEmpty {
                        Text(p.readiness)
                            .font(T.f(11, .medium))
                            .foregroundStyle(T.muted)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(T.surface2)
                            .clipShape(Capsule())
                    }
                }
                if let p = app.behaviorProfile, p.coveredDays > 0 {
                    Text("基于过去 \(p.profileDays) 天的数字活动\(p.coveredDays < 30 ? "（数据仍在积累）" : "")")
                        .font(T.f(12)).foregroundStyle(T.muted)
                }
            }

            if app.insightUpdating {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在聚合本机统计…")
                        .font(T.f(12.5)).foregroundStyle(T.muted)
                }
                .padding(.vertical, 8)
            } else if let p = app.behaviorProfile, p.coveredDays >= 7 {
                // 工作画像（语言归纳，低频手动生成，本轮由本地规则推导，不调模型）
                if !p.aiPortrait.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.aiPortrait)
                            .font(T.f(14, .semibold)).foregroundStyle(T.accent)
                        Text(p.aiSummary)
                            .font(T.f(11.5)).foregroundStyle(T.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("基于过去 \(p.aiRangeDays) 天活动数据 · 点右上角「更新画像」可刷新")
                            .font(T.f(10.5)).foregroundStyle(T.muted)
                    }
                    .padding(.top, 2)
                }
                PanelCard { workModesBlock(p) }
                PanelCard { activeRhythmBlock(p) }
                PanelCard { topicsBlock(p) }
                PanelCard { rhythmBlock(p) }
                if p.changesReady, !p.recentChanges.isEmpty { PanelCard { changesBlock(p) } }
                if !p.discoveries.isEmpty { PanelCard { discoveriesBlock(p) } }
                Text("画像由本机统计实时聚合，不调用 AI · 更新于 \(fmtInsightTime(p.generatedAt))")
                    .font(T.f(11)).foregroundStyle(T.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("数据积累中")
                        .font(T.f(15, .semibold)).foregroundStyle(T.text)
                    if let p = app.behaviorProfile {
                        Text("目前已有 \(p.coveredDays) 天记录。继续使用留刻，画像会逐渐稳定。")
                            .font(T.f(12.5)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    private func workModesBlock(_ p: BehaviorProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("工作方式")
            VStack(spacing: 10) {
                ForEach(p.workModes) { m in
                    HStack(spacing: 10) {
                        Text(m.key).font(T.f(12.5)).foregroundStyle(T.text)
                            .frame(width: 64, alignment: .leading)
                        GeometryReader { g in
                            Capsule()
                                .fill(T.accent.opacity(0.5))
                                .frame(width: max(4, g.size.width * CGFloat(m.sharePct) / 100), height: 6)
                                .frame(maxWidth: g.size.width, alignment: .leading)
                        }
                        .frame(height: 6)
                        .frame(maxWidth: 150)
                        Text(m.level)
                            .font(T.f(12.5, .semibold)).foregroundStyle(T.text)
                        Text("占有效活动 \(m.sharePct)%")
                            .font(T.f(10.5)).foregroundStyle(T.muted)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func activeRhythmBlock(_ p: BehaviorProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("活跃节奏")
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(0..<24, id: \.self) { h in
                        Capsule()
                            .fill(T.accent.opacity(max(0.12, Double(p.hourDensity[h]) / 100)))
                            .frame(height: max(4, Double(p.hourDensity[h]) / 100 * g.size.height))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(T.surface2)
            )
            HStack(spacing: 0) {
                Text("0 时").frame(width: 36, alignment: .leading)
                Spacer()
                Text("6 时")
                Spacer()
                Text("12 时")
                Spacer()
                Text("18 时")
                Spacer()
                Text("24 时").frame(width: 36, alignment: .trailing)
            }
            .font(T.f(10)).foregroundStyle(T.muted).monospacedDigit()
            if !p.peakRange.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(T.accent)
                    Text("最活跃：\(p.peakRange)")
                        .font(T.f(12, .medium)).foregroundStyle(T.text)
                }
            }
            Text("纵轴 = 活动密度（相对全天峰值），越深越集中")
                .font(T.f(10.5)).foregroundStyle(T.muted)
        }
    }

    private func topicsBlock(_ p: BehaviorProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(p.topicsLabel.isEmpty ? "长期关注" : p.topicsLabel)
            if p.topics.isEmpty {
                Text("暂无主题数据").font(T.f(12.5)).foregroundStyle(T.muted)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                    ForEach(p.topics, id: \.self) { t in
                        Text(t)
                            .font(T.f(12, .medium)).foregroundStyle(T.text)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(T.surface2)
                            .clipShape(Capsule())
                    }
                }
            }
        }
    }

    private func rhythmBlock(_ p: BehaviorProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("工作节奏")
            VStack(spacing: 10) {
                ForEach(p.rhythm) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(r.key).font(T.f(12.5)).foregroundStyle(T.text)
                                .frame(width: 84, alignment: .leading)
                            Text(r.value).font(T.f(13, .bold)).monospacedDigit()
                                .foregroundStyle(T.accent)
                            Spacer(minLength: 0)
                        }
                        if !r.hint.isEmpty {
                            Text(r.hint).font(T.f(10.5)).foregroundStyle(T.muted)
                                .padding(.leading, 92)
                        }
                    }
                }
            }
        }
    }

    private func changesBlock(_ p: BehaviorProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("近期变化")
            Text("过去 \(p.changeWindowDays) 天 vs 前 \(p.changeWindowDays) 天")
                .font(T.f(11)).foregroundStyle(T.muted)
            if !p.changesReady {
                Text("数据积累中，需要更多历史记录后才能判断长期趋势。")
                    .font(T.f(12.5)).foregroundStyle(T.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(p.recentChanges) { c in
                        HStack(spacing: 8) {
                            Text(c.key).font(T.f(12.5)).foregroundStyle(T.text)
                                .frame(width: 64, alignment: .leading)
                            if c.direction == 0, c.deltaPct == 0 {
                                Text("新增").font(T.f(12, .medium)).foregroundStyle(T.muted)
                            } else {
                                let arrow = c.direction > 0 ? "↑" : (c.direction < 0 ? "↓" : "→")
                                let good = c.polarity > 0
                                let col: Color = c.direction > 0
                                    ? (good ? T.ok : Color(hex: 0xEA580C))
                                    : (c.direction < 0 ? (good ? Color(hex: 0xEA580C) : T.ok) : T.muted)
                                Text(arrow).font(T.f(13, .bold)).foregroundStyle(col)
                                Text("\(abs(c.deltaPct))%").font(T.f(12, .medium)).monospacedDigit()
                                    .foregroundStyle(col)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func discoveriesBlock(_ p: BehaviorProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("留刻发现")
            VStack(alignment: .leading, spacing: 10) {
                ForEach(p.discoveries.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .top, spacing: 8) {
                            Text("·").foregroundStyle(T.accent)
                            Text(p.discoveries[i].text)
                                .font(T.f(13)).foregroundStyle(T.textDim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("依据：\(p.discoveries[i].evidence)")
                            .font(T.f(10.5)).foregroundStyle(T.muted)
                            .padding(.leading, 16)
                    }
                }
            }
        }
    }

    private func fmtInsightTime(_ iso: String) -> String {
        guard let d = DateUtil.parseISO(iso) else { return iso }
        let p = DateUtil.parts(d)
        return "\(p.month)月\(p.day)日 \(DateUtil.pad(p.hour)):\(DateUtil.pad(p.minute))"
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("历史生成")
                .font(T.f(11, .semibold))
                .foregroundStyle(T.muted)
                .padding(.top, 6)
            ForEach(app.summaryHistory) { h in
                HStack(spacing: 8) {
                    Button {
                        app.summaryViewing = h
                    } label: {
                        HStack(spacing: 8) {
                            Text(h.generatedLabel)
                                .font(T.f(11.5, .semibold)).monospacedDigit()
                                .foregroundStyle(T.accent)
                            Text(String(h.overview.prefix(36)) + (h.overview.count > 36 ? "…" : ""))
                                .font(T.f(11.5)).foregroundStyle(T.textDim)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button {
                        deleteTarget = h
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(T.muted)
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("删除这条历史记录")
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 4)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(T.f(13, .semibold))
            .tracking(0.5)
            .foregroundStyle(T.text)
    }
}

// MARK: - 轻量柱状图（Capsule 堆叠，无图表框架）

struct MiniBars: View {
    let values: [Int]
    var highlight: Int = -1

    var body: some View {
        let maxV = max(1, values.max() ?? 1)
        GeometryReader { g in
            let barW = min(9, max(2, (g.size.width - CGFloat(values.count) * 2) / CGFloat(max(1, values.count))))
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(values.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == highlight ? T.accent : T.accent.opacity(0.45))
                        .frame(width: barW, height: max(2, CGFloat(values[i]) / CGFloat(maxV) * g.size.height))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
