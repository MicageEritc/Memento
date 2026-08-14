import Foundation

/// 专注度分析（本地时间序列算法，不调用任何 AI）。
///
/// 设计原则（对应任务书「事实层 / 分析层 / AI 解释层」分离）：
/// - `Activity.focus` 只是 AI 对「单帧画面」的瞬时判断（专注/分散/空闲），是一个线索，不是最终结论。
/// - 最终专注度必须由一段时间内的活动序列本地计算：连续相同活动持续时间、App/窗口切换频率、
///   分类稳定性、idle 秒数、记录间隔、屏幕变化、前台应用变化、活动连续性。
/// - 不需要对每一条数据额外调用模型。
///
/// 预留数据结构（供未来「专注度百分比 / 深度工作时长 / 频繁切换次数 / 干扰次数」使用）。
struct FocusAnalyzer {

    /// 单条专注区间（供未来「深度工作」可视化 / 长期画像使用）
    struct FocusPeriod: Codable, Equatable {
        var startMs: Int64
        var endMs: Int64
        var focus: String          // 专注 / 分散 / 空闲
        var category: String
        var app: String
        var durationSec: Int { max(0, Int((endMs - startMs) / 1000)) }
    }

    struct Report: Equatable {
        /// 专注度百分比（最终）：四指标加权之和 ×100，权重和 = 1。
        ///   公式：effScore×0.40 + contScore×0.25 + intrScore×0.20 + aiScore×0.15
        var score: Int = 0
        var focusedSec: Int = 0
        var scatteredSec: Int = 0
        var idleSec: Int = 0
        /// 专注运行被打断的次数（每段「非空闲→空闲/分散→再专注」算一次）
        var interruptionCount: Int = 0
        /// App / 上下文切换次数（连续非空闲记录之间 app 变化即计一次）
        var switchCount: Int = 0
        /// 连续专注区间（每段深度工作的起止，供未来可视化 / 连续性计算）
        var periods: [FocusPeriod] = []
        /// —— 四指标子分（0..1，供 UI 可追溯展示与高层聚合复算）——
        var focusRunCount: Int = 0     // 专注段数（= periods.count），用于连续性口径
        var effScore: Double = 0       // 有效时间投入 40%
        var contScore: Double = 0      // 活动连续性 25%
        var intrScore: Double = 0      // 干扰/切换 20%
        var aiScore: Double = 0        // AI 专注提示 15%
    }

    /// 把一次记录「代表」的时长上限（秒）。超过此值视为长时间无新活动（挂机/睡眠），不计入有效时长。
    private static let maxSegSec = 600

    /// 同一上下文合并的间隔阈值（秒）：相邻记录间隔小于此值且 app/分类相同，视为同一段。
    private static let mergeGapSec = 120

    /// 平均专注段长的目标（秒）：达到 25 分钟连续专注即「活动连续性」满分。
    private static let continuityTargetSec = 1500
    /// 每工作小时（活跃时长）干扰 + 切换次数上限：超过此值「干扰/切换」记 0 分。
    private static let disruptionsPerHourMax = 12.0

    /// 四指标加权，输出最终分(0–100)与四个子分(0..1)。
    /// 权重：有效时间投入 0.40 / 活动连续性 0.25 / 干扰·切换 0.20 / AI 专注提示 0.15（和 = 1）。
    /// - 有效时间投入 eff = 专注秒 / 总秒（含空闲）
    /// - AI 专注提示  ai  = 专注秒 / 活跃秒（专注+分散，不含空闲）—— 即 AI「专注 vs 分散」的判断，只占 15%
    /// - 活动连续性   cont = min(1, 平均专注段长 / continuityTargetSec)
    /// - 干扰·切换    intr = clamp(1 − (干扰+切换)/活跃小时 / disruptionsPerHourMax, 0, 1)
    static func computeScores(focusedSec: Int, scatteredSec: Int, idleSec: Int,
                              interruptionCount: Int, switchCount: Int,
                              focusRunCount: Int) -> (score: Int, eff: Double, cont: Double, intr: Double, ai: Double) {
        let total = Double(focusedSec + scatteredSec + idleSec)
        let eff = total > 0 ? Double(focusedSec) / total : 0
        let active = Double(focusedSec + scatteredSec)
        let ai = active > 0 ? Double(focusedSec) / active : 0
        let runs = max(1, focusRunCount)
        let avgRun = Double(focusedSec) / Double(runs)
        let cont = min(1.0, avgRun / Double(FocusAnalyzer.continuityTargetSec))
        let disruptions = Double(interruptionCount + switchCount)
        let hours = max(1, active) / 3600.0
        let perHour = disruptions / hours
        let intr = max(0.0, min(1.0, 1.0 - perHour / Double(FocusAnalyzer.disruptionsPerHourMax)))
        let s = Int((eff * 0.40 + cont * 0.25 + intr * 0.20 + ai * 0.15) * 100.0)
        return (max(0, min(100, s)), eff, cont, intr, ai)
    }

    /// 从一段活动序列计算专注报告（序列会被内部排序，调用方无需预排序）
    static func analyze(_ records: [ActRecord]) -> Report {
        let valid = records.compactMap { r -> (ms: Int64, focus: String, category: String, app: String)? in
            guard let ms = r.epochMs, ms > 0, r.statusEnum == .done else { return nil }
            let f = (r.activity?.focus).map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard ["专注", "分散", "空闲"].contains(f) else { return nil }
            let cat = r.activity?.displayCategory ?? "其他"
            let app = (r.activity?.app).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            return (ms, f, cat, app)
        }.sorted { $0.ms < $1.ms }

        guard !valid.isEmpty else { return Report() }

        // 1) 时间加权统计：每条记录代表「到下一跳」的时长（封顶 maxSegSec）
        var focusedSec = 0, scatteredSec = 0, idleSec = 0
        for i in 0..<valid.count {
            let cur = valid[i]
            let nextMs = (i + 1 < valid.count) ? valid[i + 1].ms : (cur.ms + Int64(min(IntervalGuess.sec, FocusAnalyzer.maxSegSec) * 1000))
            let gap = min(Int((nextMs - cur.ms) / 1000), FocusAnalyzer.maxSegSec)
            switch cur.focus {
            case "专注": focusedSec += gap
            case "分散": scatteredSec += gap
            default: idleSec += gap
            }
        }

        // 2) 干扰次数：统计「非空闲运行」被空闲/分散打断的次数
        var interruptionCount = 0
        var inFocusRun = false
        for i in 0..<valid.count {
            let f = valid[i].focus
            if f == "专注" {
                if !inFocusRun { inFocusRun = true }   // 新的一段专注开始
            } else {
                // 空闲或分散中断了专注
                if inFocusRun { interruptionCount += 1; inFocusRun = false }
            }
        }

        // 3) 上下文切换次数：连续非空闲记录之间 app 变化
        var switchCount = 0
        var lastApp: String? = nil
        for v in valid where v.focus != "空闲" {
            if let la = lastApp, la != v.app, !la.isEmpty, !v.app.isEmpty { switchCount += 1 }
            lastApp = v.app
        }

        // 4) 专注区间（合并相邻同 app/分类/专注 的段）
        //    每条记录代表「到下一跳」的时长（与第 1 步同口径、同封顶），
        //    这样各段时长之和 ≈ focusedSec，不会因为只取记录时刻而少算一个采样间隔。
        var periods: [FocusPeriod] = []
        for i in 0..<valid.count where valid[i].focus == "专注" {
            let v = valid[i]
            let nextMs = (i + 1 < valid.count)
                ? valid[i + 1].ms
                : (v.ms + Int64(min(IntervalGuess.sec, FocusAnalyzer.maxSegSec) * 1000))
            let segEnd = min(nextMs, v.ms + Int64(FocusAnalyzer.maxSegSec * 1000))
            if let last = periods.last,
               last.app == v.app, last.category == v.category,
               Int(v.ms - last.endMs) / 1000 <= FocusAnalyzer.mergeGapSec {
                periods[periods.count - 1] = FocusPeriod(
                    startMs: last.startMs, endMs: max(last.endMs, segEnd), focus: "专注",
                    category: v.category, app: v.app)
            } else {
                periods.append(FocusPeriod(startMs: v.ms, endMs: segEnd, focus: "专注",
                                           category: v.category, app: v.app))
            }
        }

        let (score, eff, cont, intr, ai) = FocusAnalyzer.computeScores(
            focusedSec: focusedSec, scatteredSec: scatteredSec, idleSec: idleSec,
            interruptionCount: interruptionCount, switchCount: switchCount,
            focusRunCount: periods.count)

        return Report(score: score, focusedSec: focusedSec, scatteredSec: scatteredSec,
                      idleSec: idleSec, interruptionCount: interruptionCount,
                      switchCount: switchCount, periods: periods,
                      focusRunCount: periods.count, effScore: eff, contScore: cont,
                      intrScore: intr, aiScore: ai)
    }

    /// 当序列末端没有下一跳时，给一个保守的代表时长（秒）
    private enum IntervalGuess {
        static let sec = 60
    }

    /// 跨天/跨区间合并多份日报告。
    /// ⚠️ 必须按天分别 analyze 再 merge：跨天直接 analyze 会把「昨晚→今早」的空档算成一段活动时长。
    static func merge(_ reports: [Report]) -> Report {
        var out = Report()
        for r in reports {
            out.focusedSec += r.focusedSec
            out.scatteredSec += r.scatteredSec
            out.idleSec += r.idleSec
            out.interruptionCount += r.interruptionCount
            out.switchCount += r.switchCount
            out.focusRunCount += r.focusRunCount
            out.periods.append(contentsOf: r.periods)
        }
        let (score, eff, cont, intr, ai) = FocusAnalyzer.computeScores(
            focusedSec: out.focusedSec, scatteredSec: out.scatteredSec, idleSec: out.idleSec,
            interruptionCount: out.interruptionCount, switchCount: out.switchCount,
            focusRunCount: out.focusRunCount)
        out.score = score
        out.effScore = eff; out.contScore = cont; out.intrScore = intr; out.aiScore = ai
        // 区间越长 periods 越多：只保留最长的若干段，避免 Digest/内存无节制膨胀
        if out.periods.count > 200 {
            out.periods = out.periods.sorted { $0.durationSec > $1.durationSec }.prefix(200).map { $0 }
        }
        return out
    }

    /// 把 FocusBreakdown（旧口径：按记录计数）转换为 Report（时间加权）。供兼容/对照使用。
    static func report(from breakdown: FocusBreakdown, totalSec: Int = 0) -> Report {
        let base = breakdown.focused + breakdown.scattered
        // 时间未知时按记录数等比摊派（仅作近似）
        let unit = totalSec > 0 ? max(1, totalSec / max(1, base)) : IntervalGuess.sec
        let focusedSec = breakdown.focused * unit
        let scatteredSec = breakdown.scattered * unit
        let idleSec = breakdown.idle * unit
        let runs = (focusedSec + scatteredSec + idleSec) > 0 ? 1 : 0
        let (score, eff, cont, intr, ai) = FocusAnalyzer.computeScores(
            focusedSec: focusedSec, scatteredSec: scatteredSec, idleSec: idleSec,
            interruptionCount: 0, switchCount: 0, focusRunCount: runs)
        return Report(score: score, focusedSec: focusedSec, scatteredSec: scatteredSec, idleSec: idleSec,
                      interruptionCount: 0, switchCount: 0, periods: [],
                      focusRunCount: runs, effScore: eff, contScore: cont, intrScore: intr, aiScore: ai)
    }
}
