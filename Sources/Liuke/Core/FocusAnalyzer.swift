import Foundation

/// 专注度分析（本地时间序列 + AI 语义线索，不额外调用模型）。
///
/// 设计原则（对应任务书「事实层 / 分析层 / AI 解释层」分离）：
/// - `Activity.focus` 是 AI 对「单帧画面」的瞬时判断（专注/分散/空闲），`category/app/title/keywords`
///   是 AI 对画面内容的理解 —— 二者合起来构成「AI 专注提示」这一核心指标。
/// - 其余指标由本地时间序列算出：连续有效活动段、空闲间隔、上下文切换率、打断率。
/// - 不需要对每一条数据额外调用模型。
///
/// 四指标统一口径：**每项都是 0…1（100 分最好、0 分最差）**，最终按 `Weight` 加权。
struct FocusAnalyzer {

    // MARK: - 权重（和 = 1，UI 直接引用，改这里即全局生效）

    /// 四指标权重：AI 专注提示为核心指标。
    enum Weight {
        /// AI 专注提示（截图内容 + 上下文判断「是否围绕同一任务持续工作」）
        static let ai: Double   = 0.60
        /// 有效时间投入（专注时长占已记录时长）
        static let eff: Double  = 0.15
        /// 活动连续性（连续有效活动时长 / 空闲间隔，纯行为数据）
        static let cont: Double = 0.15
        /// 任务稳定性（正向：无切换、无打断 = 100 分）
        static let stab: Double = 0.10
    }

    // MARK: - 调参常量

    /// 单条记录代表的时长上限（秒）。
    private static let maxSegSec = 600
    /// 采样步长未知时的兜底（秒）
    private static let defaultStepSec = 60
    /// 「连续性」满分目标：单段连续有效活动达到 25 分钟即满分
    private static let continuityTargetSec = 1500
    /// 「深度段」门槛：连续有效活动 ≥ 10 分钟才算一段深度工作
    private static let deepRunSec = 600
    /// 任务稳定性容忍度：加权变化率达到此值（= 一半的相邻采样都在换上下文/被打断）记 0 分
    private static let stabTolerance = 0.5
    /// AI 专注提示内部配比：帧级「专注 vs 分散」判断 : 内容级「同一任务」连贯度
    private static let aiFocusMix = 0.60
    private static let aiCohesionMix = 0.40
    /// 活动连续性内部配比：最长连续段 : 深度段覆盖率
    private static let contLongestMix = 0.55
    private static let contDeepMix = 0.45

    // MARK: - 数据结构

    /// 单条专注区间（供「深度工作」可视化 / 长期画像使用）
    struct FocusPeriod: Codable, Equatable {
        var startMs: Int64
        var endMs: Int64
        var focus: String          // 专注 / 分散 / 空闲
        var category: String
        var app: String
        var durationSec: Int { max(0, Int((endMs - startMs) / 1000)) }
    }

    struct Report: Equatable {
        /// 综合专注度（0–100）：ai×0.60 + eff×0.15 + cont×0.15 + stab×0.10
        var score: Int = 0
        var focusedSec: Int = 0
        var scatteredSec: Int = 0
        var idleSec: Int = 0
        /// 专注运行被打断的次数（每段「专注 → 分散/空闲」算一次）
        var interruptionCount: Int = 0
        /// 上下文切换次数（相邻有效采样之间 app 变化即计一次）
        var switchCount: Int = 0
        /// 连续专注区间（每段深度工作的起止，供可视化）
        var periods: [FocusPeriod] = []
        var focusRunCount: Int = 0

        // —— 四指标子分（0…1，统一「1 最好」）——
        /// 有效时间投入 15%
        var effScore: Double = 0
        /// 活动连续性 15%
        var contScore: Double = 0
        /// 任务稳定性 10%（正向：1 = 完全没有切换/打断）
        /// ⚠️ 字段名沿用历史（原「干扰/切换」），语义已是正向，落盘结构不变。
        var intrScore: Double = 0
        /// AI 专注提示 60%（核心）
        var aiScore: Double = 0

        // —— 可跨天合并的中间量（纯内存，不落盘）——
        /// 最长连续有效活动段（秒）
        var longestActiveSec: Int = 0
        /// 「深度段」（≥ deepRunSec）时长合计（秒）
        var deepActiveSec: Int = 0
        /// 任务一致性时长加权累加（分子 / 分母）
        var cohesionNum: Double = 0
        var cohesionDen: Double = 0
        /// 相邻采样对数（含空闲），用于打断率归一化
        var adjPairs: Int = 0
        /// 相邻「有效（非空闲）」采样对数，用于切换率归一化
        var activeAdjPairs: Int = 0

        // —— 拆解展示用（0…1）——
        /// AI 帧级判断：专注时长 / 有效活动时长
        var focusRatio: Double = 0
        /// AI 内容级判断：相邻有效采样「围绕同一任务」的时长加权连贯度
        var cohesion: Double = 0

        var activeSec: Int { focusedSec + scatteredSec }
        var totalSec: Int { focusedSec + scatteredSec + idleSec }
    }

    // MARK: - 打分

    /// 四指标加权，输出最终分(0–100) + 各子分(0…1)。
    ///
    /// - AI 专注提示 ai   = 专注/有效时长 ×0.60 + 同一任务连贯度 ×0.40
    /// - 有效时间投入 eff = 专注时长 / 已记录时长（含空闲）
    /// - 活动连续性 cont  = min(1, 最长连续段/25min) ×0.55 + 深度段覆盖率 ×0.45
    /// - 任务稳定性 stab  = 1 − (0.6×切换率 + 0.4×打断率) / 0.5，无切换无打断 → 1.0
    ///
    /// ⚠️ cont / stab 都是「率」或「段长」，与记录条数无关：用户持续工作时不会因为记录变多而下降。
    static func computeScores(focusedSec: Int, scatteredSec: Int, idleSec: Int,
                              interruptionCount: Int, switchCount: Int,
                              longestActiveSec: Int, deepActiveSec: Int,
                              cohesionNum: Double, cohesionDen: Double,
                              adjPairs: Int, activeAdjPairs: Int)
    -> (score: Int, eff: Double, cont: Double, stab: Double, ai: Double,
        focusRatio: Double, cohesion: Double) {

        let total = Double(focusedSec + scatteredSec + idleSec)
        let active = Double(focusedSec + scatteredSec)

        // ① 有效时间投入
        let eff = total > 0 ? Double(focusedSec) / total : 0

        // ② AI 专注提示（核心）
        let focusRatio = active > 0 ? Double(focusedSec) / active : 0
        // 没有可比较的相邻对（单条记录 / 老数据）时退回帧级判断，避免无端记 0
        let cohesion = cohesionDen > 0
            ? max(0, min(1, cohesionNum / cohesionDen))
            : focusRatio
        let ai = active > 0 ? (focusRatio * aiFocusMix + cohesion * aiCohesionMix) : 0

        // ③ 活动连续性（纯时间序列）
        let longest = min(1.0, Double(longestActiveSec) / Double(continuityTargetSec))
        let deepShare = active > 0 ? min(1.0, Double(deepActiveSec) / active) : 0
        let cont = active > 0 ? (longest * contLongestMix + deepShare * contDeepMix) : 0

        // ④ 任务稳定性（正向）
        let swRate = activeAdjPairs > 0 ? Double(switchCount) / Double(activeAdjPairs) : 0
        let irRate = adjPairs > 0 ? Double(interruptionCount) / Double(adjPairs) : 0
        let penalty = swRate * 0.6 + irRate * 0.4
        let stab = active > 0 ? max(0.0, min(1.0, 1.0 - penalty / stabTolerance)) : 0

        return (finalScore(eff: eff, cont: cont, stab: stab, ai: ai),
                eff, cont, stab, ai, focusRatio, cohesion)
    }

    /// 由四个子分（0…1）算综合分（0–100）。供高层 Digest 聚合复用，权重口径唯一。
    static func finalScore(eff: Double, cont: Double, stab: Double, ai: Double) -> Int {
        let s = (ai * Weight.ai + eff * Weight.eff + cont * Weight.cont + stab * Weight.stab) * 100
        return max(0, min(100, Int(s.rounded())))
    }

    // MARK: - 主分析

    /// 单帧事实（AI 输出 + 时间戳）
    private struct Frame {
        var ms: Int64
        var focus: String
        var category: String
        var app: String
        var tokens: Set<String>        // AI 提取的关键词（归一化）
        var titleChars: Set<Character> // AI 命名的标题字符集（中英文都能算重叠）
        var hasTitle: Bool
    }

    /// 从一段活动序列计算专注报告（序列会被内部排序，调用方无需预排序）
    static func analyze(_ records: [ActRecord]) -> Report {
        let valid: [Frame] = records.compactMap { r -> Frame? in
            guard let ms = r.epochMs, ms > 0, r.statusEnum == .done else { return nil }
            let f = (r.activity?.focus).map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard ["专注", "分散", "空闲"].contains(f) else { return nil }
            let act = r.activity
            let cat = act?.displayCategory ?? "其他"
            let app = (act?.app).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            var tk = Set<String>()
            for k in act?.keywords ?? [] {
                let s = k.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !s.isEmpty, s.count <= 16 { tk.insert(s) }
            }
            let title = (act?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let chars = Set(title.lowercased().filter { !$0.isWhitespace && !$0.isPunctuation })
            return Frame(ms: ms, focus: f, category: cat, app: app,
                         tokens: tk, titleChars: chars, hasTitle: !chars.isEmpty)
        }.sorted { $0.ms < $1.ms }

        guard !valid.isEmpty else { return Report() }

        // 采样步长（下四分位间隔）：所有「相邻 / 中断」判定都以它为基准，
        // 20s 采样与 300s 采样得到同一口径的分数，不受记录密度影响。
        let step = typicalStep(valid.map(\.ms))
        // 相邻阈值：超过 2.5 个采样步长视为中断（暂停录制 / 离席 / 休眠）
        let adjGap = min(maxSegSec, max(45, Int(Double(step) * 2.5)))
        // 短暂空闲桥接上限：不超过 3 个采样步长的空闲不打断「连续有效活动段」
        let bridgeIdle = min(300, max(60, step * 3))

        // 0) 每条记录代表的时长；到下一条超过相邻阈值时只算一个步长
        //    （否则一次午休就会给休息前那一帧凭空加 10 分钟活动）
        var seg = [Int](repeating: 0, count: valid.count)
        var rawGap = [Int](repeating: 0, count: valid.count)
        for i in 0..<valid.count {
            let g = (i + 1 < valid.count) ? Int((valid[i + 1].ms - valid[i].ms) / 1000) : step
            rawGap[i] = max(0, g)
            seg[i] = rawGap[i] <= adjGap ? min(rawGap[i], maxSegSec) : min(step, maxSegSec)
        }

        // 1) 时长加权统计
        var focusedSec = 0, scatteredSec = 0, idleSec = 0
        for i in 0..<valid.count {
            switch valid[i].focus {
            case "专注": focusedSec += seg[i]
            case "分散": scatteredSec += seg[i]
            default:    idleSec += seg[i]
            }
        }

        // 2) 打断次数 + 相邻对数（打断率分母）
        var interruptionCount = 0
        var inFocusRun = false
        var adjPairs = 0
        for i in 0..<valid.count {
            if valid[i].focus == "专注" {
                inFocusRun = true
            } else if inFocusRun {
                interruptionCount += 1
                inFocusRun = false
            }
            if i + 1 < valid.count, rawGap[i] <= adjGap { adjPairs += 1 }
        }

        // 3) 上下文切换次数 + 相邻有效对数（切换率分母）
        //    只统计「真正相邻」的两条有效记录，跨越长空档不算切换。
        var switchCount = 0
        var activeAdjPairs = 0
        var prevActive: Int? = nil
        for i in 0..<valid.count where valid[i].focus != "空闲" {
            defer { prevActive = i }
            guard let p = prevActive else { continue }
            let dist = Int((valid[i].ms - valid[p].ms) / 1000)
            guard dist <= adjGap else { continue }
            activeAdjPairs += 1
            if !valid[p].app.isEmpty, !valid[i].app.isEmpty, valid[p].app != valid[i].app {
                switchCount += 1
            }
        }

        // 4) 任务一致性（AI 内容层）：相邻有效采样之间「是否还在同一件事上」，按时长加权
        var cohesionNum = 0.0, cohesionDen = 0.0
        prevActive = nil
        for i in 0..<valid.count where valid[i].focus != "空闲" {
            defer { prevActive = i }
            guard let p = prevActive else { continue }
            let dist = Int((valid[i].ms - valid[p].ms) / 1000)
            guard dist <= adjGap else { continue }
            let w = Double(max(1, seg[i]))
            cohesionNum += similarity(valid[p], valid[i]) * w
            cohesionDen += w
        }

        // 5) 连续有效活动段（不看 app，只看「有没有在干活」）
        var runs: [Int] = []
        var cur = 0, idleAcc = 0
        for i in 0..<valid.count {
            if valid[i].focus == "空闲" {
                idleAcc += seg[i]
                if idleAcc > bridgeIdle {
                    if cur > 0 { runs.append(cur); cur = 0 }
                    idleAcc = 0
                }
                continue
            }
            if cur > 0, idleAcc > 0 { cur += idleAcc }   // 短暂空闲桥接进本段
            idleAcc = 0
            cur += seg[i]
            if rawGap[i] > adjGap { runs.append(cur); cur = 0 }   // 长空档 → 本段结束
        }
        if cur > 0 { runs.append(cur) }
        let longestActiveSec = runs.max() ?? 0
        let deepActiveSec = runs.filter { $0 >= deepRunSec }.reduce(0, +)

        // 6) 专注区间（合并相邻同 app/分类的专注段，供深度工作可视化）
        var periods: [FocusPeriod] = []
        for i in 0..<valid.count where valid[i].focus == "专注" {
            let v = valid[i]
            let segEnd = v.ms + Int64(seg[i] * 1000)
            if let last = periods.last,
               last.app == v.app, last.category == v.category,
               Int(v.ms - last.endMs) / 1000 <= adjGap {
                periods[periods.count - 1] = FocusPeriod(
                    startMs: last.startMs, endMs: max(last.endMs, segEnd), focus: "专注",
                    category: v.category, app: v.app)
            } else {
                periods.append(FocusPeriod(startMs: v.ms, endMs: segEnd, focus: "专注",
                                           category: v.category, app: v.app))
            }
        }

        let m = computeScores(focusedSec: focusedSec, scatteredSec: scatteredSec, idleSec: idleSec,
                              interruptionCount: interruptionCount, switchCount: switchCount,
                              longestActiveSec: longestActiveSec, deepActiveSec: deepActiveSec,
                              cohesionNum: cohesionNum, cohesionDen: cohesionDen,
                              adjPairs: adjPairs, activeAdjPairs: activeAdjPairs)

        var out = Report()
        out.score = m.score
        out.focusedSec = focusedSec
        out.scatteredSec = scatteredSec
        out.idleSec = idleSec
        out.interruptionCount = interruptionCount
        out.switchCount = switchCount
        out.periods = periods
        out.focusRunCount = periods.count
        out.effScore = m.eff
        out.contScore = m.cont
        out.intrScore = m.stab
        out.aiScore = m.ai
        out.longestActiveSec = longestActiveSec
        out.deepActiveSec = deepActiveSec
        out.cohesionNum = cohesionNum
        out.cohesionDen = cohesionDen
        out.adjPairs = adjPairs
        out.activeAdjPairs = activeAdjPairs
        out.focusRatio = m.focusRatio
        out.cohesion = m.cohesion
        return out
    }

    // MARK: - AI 语义相似度（判断「是否还在同一个任务上」）

    /// 两帧之间的任务相似度（0…1）：分类 / 应用 / 关键词 / 标题四个维度，
    /// 缺失的维度自动退出加权（老数据没有 keywords 也不会被判成不连贯）。
    private static func similarity(_ a: Frame, _ b: Frame) -> Double {
        var s = 0.0, w = 0.0
        // 分类（AI 语义归类）
        w += 0.30
        if a.category == b.category { s += 0.30 }
        // 应用（AI 识别的前台应用）
        if !a.app.isEmpty, !b.app.isEmpty {
            w += 0.25
            if a.app == b.app { s += 0.25 }
        }
        // 关键词交集（AI 从画面内容提取的主题）
        if !a.tokens.isEmpty, !b.tokens.isEmpty {
            w += 0.30
            let inter = Double(a.tokens.intersection(b.tokens).count)
            let denom = Double(max(1, min(a.tokens.count, b.tokens.count)))
            s += 0.30 * min(1.0, inter / denom)
        }
        // 标题重叠（AI 对当前在做什么的一句话命名）
        if a.hasTitle, b.hasTitle {
            w += 0.15
            let inter = Double(a.titleChars.intersection(b.titleChars).count)
            let denom = Double(max(1, min(a.titleChars.count, b.titleChars.count)))
            s += 0.15 * min(1.0, inter / denom)
        }
        return w > 0 ? min(1.0, s / w) : 0
    }

    /// 采样步长估计：取间隔的下四分位（对长空档鲁棒），夹在 5…600 秒
    private static func typicalStep(_ ms: [Int64]) -> Int {
        guard ms.count >= 2 else { return defaultStepSec }
        var gaps: [Int] = []
        gaps.reserveCapacity(ms.count - 1)
        for i in 1..<ms.count {
            let g = Int((ms[i] - ms[i - 1]) / 1000)
            if g > 0 { gaps.append(g) }
        }
        guard !gaps.isEmpty else { return defaultStepSec }
        gaps.sort()
        let q = gaps[min(gaps.count - 1, gaps.count / 4)]
        return max(5, min(maxSegSec, q))
    }

    // MARK: - 合并

    /// 跨天/跨区间合并多份日报告。
    /// ⚠️ 必须按天分别 analyze 再 merge：跨天直接 analyze 会把「昨晚→今早」的空档算成一段活动时长。
    /// 中间量（最长段取 max、深度段/连贯度累加）都可合并，所以合并后的分数与逐日口径一致。
    static func merge(_ reports: [Report]) -> Report {
        var out = Report()
        for r in reports {
            out.focusedSec += r.focusedSec
            out.scatteredSec += r.scatteredSec
            out.idleSec += r.idleSec
            out.interruptionCount += r.interruptionCount
            out.switchCount += r.switchCount
            out.focusRunCount += r.focusRunCount
            out.longestActiveSec = max(out.longestActiveSec, r.longestActiveSec)
            out.deepActiveSec += r.deepActiveSec
            out.cohesionNum += r.cohesionNum
            out.cohesionDen += r.cohesionDen
            out.adjPairs += r.adjPairs
            out.activeAdjPairs += r.activeAdjPairs
            out.periods.append(contentsOf: r.periods)
        }
        let m = computeScores(focusedSec: out.focusedSec, scatteredSec: out.scatteredSec,
                              idleSec: out.idleSec, interruptionCount: out.interruptionCount,
                              switchCount: out.switchCount, longestActiveSec: out.longestActiveSec,
                              deepActiveSec: out.deepActiveSec, cohesionNum: out.cohesionNum,
                              cohesionDen: out.cohesionDen, adjPairs: out.adjPairs,
                              activeAdjPairs: out.activeAdjPairs)
        out.score = m.score
        out.effScore = m.eff
        out.contScore = m.cont
        out.intrScore = m.stab
        out.aiScore = m.ai
        out.focusRatio = m.focusRatio
        out.cohesion = m.cohesion
        // 区间越长 periods 越多：只保留最长的若干段，避免 Digest/内存无节制膨胀
        if out.periods.count > 200 {
            out.periods = out.periods.sorted { $0.durationSec > $1.durationSec }.prefix(200).map { $0 }
        }
        return out
    }

    /// 把 FocusBreakdown（旧口径：按记录计数）近似成 Report。仅供无时间戳的老数据兜底对照。
    static func report(from breakdown: FocusBreakdown, totalSec: Int = 0) -> Report {
        let base = breakdown.focused + breakdown.scattered
        let unit = totalSec > 0 ? max(1, totalSec / max(1, base)) : defaultStepSec
        let focusedSec = breakdown.focused * unit
        let scatteredSec = breakdown.scattered * unit
        let idleSec = breakdown.idle * unit
        // 无时间序列 → 连续性/稳定性按「单段、无切换」的中性假设处理
        let m = computeScores(focusedSec: focusedSec, scatteredSec: scatteredSec, idleSec: idleSec,
                              interruptionCount: 0, switchCount: 0,
                              longestActiveSec: focusedSec, deepActiveSec: focusedSec,
                              cohesionNum: 0, cohesionDen: 0,
                              adjPairs: 0, activeAdjPairs: 0)
        var out = Report()
        out.score = m.score
        out.focusedSec = focusedSec
        out.scatteredSec = scatteredSec
        out.idleSec = idleSec
        out.focusRunCount = (focusedSec + scatteredSec + idleSec) > 0 ? 1 : 0
        out.effScore = m.eff
        out.contScore = m.cont
        out.intrScore = m.stab
        out.aiScore = m.ai
        out.longestActiveSec = focusedSec
        out.deepActiveSec = focusedSec
        out.focusRatio = m.focusRatio
        out.cohesion = m.cohesion
        return out
    }
}
