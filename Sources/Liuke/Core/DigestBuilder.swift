import Foundation

/// 时间分层摘要（Day → Week → Month → Year）的数据模型与本地构建器。
///
/// 核心原则（对应任务书「事实层 / 分析层 / AI 解释层」分离）：
/// - Digest 是**派生数据**，永远可以由原始 Activity 重新生成（Digest 损坏不影响事实层）。
/// - category 统计、focus 统计、top 活动、干扰次数**全部由代码计算**，AI 只负责理解与表达
///   （生成 overview / sections 叙事，并解释这些统计意味着什么）。
/// - 高层 Digest 由低层 Digest 组合而成；低层缺失时回退到原始记录（再不行回退 220 行采样）。
/// - 增量更新：高层 Digest 一旦生成，仅在其下层 Digest 发生变化时才需要重算。

// MARK: - 聚焦摘要（程序计算）

struct FocusDigest: Codable, Equatable {
    var focusedSec: Int = 0
    var scatteredSec: Int = 0
    var idleSec: Int = 0
    var score: Int = 0                 // 专注度百分比（四指标加权，与 FocusAnalyzer 口径一致）
    var interruptionCount: Int = 0
    /// 聚合/展示所需的子指标（供月/年从日聚合后复算，及 UI 可追溯）
    var switchCount: Int = 0
    var focusRunCount: Int = 0
    var effScore: Double = 0           // 有效时间投入 0.40
    var contScore: Double = 0          // 活动连续性 0.25
    var intrScore: Double = 0          // 干扰/切换 0.20
    var aiScore: Double = 0            // AI 专注提示 0.15

    var totalSec: Int { focusedSec + scatteredSec + idleSec }
    var focusedMin: Int { focusedSec / 60 }
    var scatteredMin: Int { scatteredSec / 60 }
    var idleMin: Int { idleSec / 60 }

    static let empty = FocusDigest()

    init() {}

    init(focusedSec: Int, scatteredSec: Int, idleSec: Int, score: Int, interruptionCount: Int,
         switchCount: Int = 0, focusRunCount: Int = 0,
         effScore: Double = 0, contScore: Double = 0, intrScore: Double = 0, aiScore: Double = 0) {
        self.focusedSec = focusedSec
        self.scatteredSec = scatteredSec
        self.idleSec = idleSec
        self.score = score
        self.interruptionCount = interruptionCount
        self.switchCount = switchCount
        self.focusRunCount = focusRunCount
        self.effScore = effScore
        self.contScore = contScore
        self.intrScore = intrScore
        self.aiScore = aiScore
    }

    /// 手写解码：Swift 合成解码不认属性默认值，缺字段会抛 keyNotFound
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func i(_ k: CodingKeys) -> Int { ((try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil) ?? 0 }
        func d(_ k: CodingKeys) -> Double { ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil) ?? 0 }
        focusedSec = i(.focusedSec)
        scatteredSec = i(.scatteredSec)
        idleSec = i(.idleSec)
        score = i(.score)
        interruptionCount = i(.interruptionCount)
        switchCount = i(.switchCount)
        focusRunCount = i(.focusRunCount)
        effScore = d(.effScore)
        contScore = d(.contScore)
        intrScore = d(.intrScore)
        aiScore = d(.aiScore)
    }
}

// MARK: - 摘要文档

struct ActivityDigest: Codable, Equatable, Identifiable {
    var key: String = ""
    var scope: String = "day"          // day | week | month | year
    var rangeLabel: String = ""
    var dateStrs: [String] = []

    // AI 解释层（可空；代码计算失败/未联网时仍保留统计层）
    var overview: String = ""
    var sections: [String] = []

    // 代码计算层（统计）
    var categoryCount: [String: Int] = [:]
    var categoryPercent: [String: Int] = [:]
    var focus: FocusDigest = .empty
    var topActivities: [String] = []     // 高频 app（Top N）
    var topProjects: [String] = []       // 高频关键词（Top N）

    // 溯源与层级
    var sourceLevel: String = "raw"      // raw | day | week | month
    var sourceDigestKeys: [String] = []  // 参与聚合的低层 digest key
    var childKeys: [String] = []         // 本 digest 覆盖的下层 digest key（增量更新用）

    // AI 元信息
    var model: String?
    var modelLabel: String?
    var latencyMs: Int?
    var generatedAt: String = ""
    var recordCount: Int = 0

    /// 源数据新鲜度：覆盖日期下原始记录文件的最大 mtime（epoch 秒）。
    /// 任何原始记录文件比它更新 → 视为陈旧、需重建（见 AppState.loadOrBuildDigest）。
    var sourceMaxTs: Int64 = 0

    var id: String { key }

    init() {}

    enum CodingKeys: String, CodingKey {
        case key, scope, rangeLabel, dateStrs, overview, sections
        case categoryCount, categoryPercent, focus, topActivities, topProjects
        case sourceLevel, sourceDigestKeys, childKeys
        case model, modelLabel, latencyMs, generatedAt, recordCount, sourceMaxTs
    }

    /// 手写解码：同 SummaryDoc——合成解码不认默认值，缺字段会整份 Digest 读不出来。
    /// Digest 是派生数据，宁可字段缺省为 0/空，也不能因为一个字段缺失就报废整份摘要。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys, _ d: String = "") -> String {
            ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) ?? d
        }
        func arr(_ k: CodingKeys) -> [String] {
            ((try? c.decodeIfPresent([String].self, forKey: k)) ?? nil) ?? []
        }
        key = s(.key)
        scope = s(.scope, "day")
        rangeLabel = s(.rangeLabel)
        dateStrs = arr(.dateStrs)
        overview = s(.overview)
        sections = arr(.sections)
        categoryCount = ((try? c.decodeIfPresent([String: Int].self, forKey: .categoryCount)) ?? nil) ?? [:]
        categoryPercent = ((try? c.decodeIfPresent([String: Int].self, forKey: .categoryPercent)) ?? nil) ?? [:]
        focus = ((try? c.decodeIfPresent(FocusDigest.self, forKey: .focus)) ?? nil) ?? .empty
        topActivities = arr(.topActivities)
        topProjects = arr(.topProjects)
        sourceLevel = s(.sourceLevel, "raw")
        sourceDigestKeys = arr(.sourceDigestKeys)
        childKeys = arr(.childKeys)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        modelLabel = try? c.decodeIfPresent(String.self, forKey: .modelLabel)
        latencyMs = try? c.decodeIfPresent(Int.self, forKey: .latencyMs)
        generatedAt = s(.generatedAt)
        recordCount = ((try? c.decodeIfPresent(Int.self, forKey: .recordCount)) ?? nil) ?? 0
        sourceMaxTs = ((try? c.decodeIfPresent(Int64.self, forKey: .sourceMaxTs)) ?? nil) ?? 0
    }

    /// 给 AI 的「事实数据块」：把代码算好的统计变成可直接解释的文本（AI 不重算）。
    func computedDataBlock() -> String {
        var lines: [String] = []
        if !categoryPercent.isEmpty {
            let sorted = categoryPercent.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            let parts = sorted.map { "\($0.key) \($0.value)%" }.joined(separator: "、")
            lines.append("【分类时长占比】\(parts)")
        }
        if focus.totalSec > 0 {
            lines.append("【专注情况】专注度 \(focus.score)%；专注约 \(focus.focusedMin) 分钟，分散约 \(focus.scatteredMin) 分钟，空闲约 \(focus.idleMin) 分钟；干扰 \(focus.interruptionCount) 次")
        }
        if !topActivities.isEmpty {
            lines.append("【高频应用】" + topActivities.prefix(8).joined(separator: "、"))
        }
        if !topProjects.isEmpty {
            lines.append("【高频主题】" + topProjects.prefix(10).joined(separator: "、"))
        }
        lines.append("【记录数】\(recordCount)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - 构建器

enum DigestBuilder {

    // MARK: key 推导

    static func dayKey(_ date: String) -> String { "day-\(date)" }
    static func weekKey(_ date: String) -> String { "week-\(date)" }
    static func monthKey(_ ym: String) -> String { "month-\(ym)" }
    static func yearKey(_ y: String) -> String { "year-\(y)" }

    /// 日期序列 → 各层覆盖的 digest key（用于读取/级联）
    static func childKeys(forScope scope: String, dates: [String]) -> [String] {
        switch scope {
        case "day":
            return dates.compactMap { $0 == dates.first ? DigestBuilder.dayKey($0) : nil }
        case "week":
            // 7 个 day key
            return dates.map { DigestBuilder.dayKey($0) }
        case "month":
            // 该月所有周一 → week key
            return weekKeysInDates(dates)
        case "year":
            // 该年所有月 → month key
            return monthKeysInDates(dates)
        default:
            return []
        }
    }

    static func weekKeysInDates(_ dates: [String]) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        for d in dates {
            guard let date = DateUtil.parseDateStr(d) else { continue }
            let monday = DateUtil.weekDates(of: date).first ?? d
            let k = DigestBuilder.weekKey(monday)
            if !seen.contains(k) { seen.insert(k); keys.append(k) }
        }
        return keys
    }

    static func monthKeysInDates(_ dates: [String]) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()
        for d in dates {
            guard d.count >= 7 else { continue }
            let ym = String(d.prefix(7))
            let k = DigestBuilder.monthKey(ym)
            if !seen.contains(k) { seen.insert(k); keys.append(k) }
        }
        return keys
    }

    // MARK: 统计工具

    /// 从原始记录统计分类（计数 + 占比，占比归一化到和=100）
    static func categoryStats(records: [ActRecord]) -> (count: [String: Int], percent: [String: Int]) {
        var count: [String: Int] = [:]
        for r in records where r.statusEnum == .done {
            let c = r.activity?.displayCategory ?? "其他"
            count[c, default: 0] += 1
        }
        let total = count.values.reduce(0, +)
        guard total > 0 else { return (count, [:]) }
        var percent: [String: Int] = [:]
        var acc = 0
        for (k, v) in count.sorted(by: { $0.value > $1.value }) {
            let p = Int((Double(v) / Double(total) * 100).rounded())
            percent[k] = p
            acc += p
        }
        // 四舍五入误差补偿到占比最大的分类
        let diff = 100 - acc
        if diff != 0, let maxK = percent.max(by: { $0.value < $1.value })?.key {
            percent[maxK] = (percent[maxK] ?? 0) + diff
        }
        return (count, percent)
    }

    /// 高频 app（Top N，按记录数）
    static func topApps(records: [ActRecord], limit: Int = 8) -> [String] {
        var counter: [String: Int] = [:]
        for r in records where r.statusEnum == .done {
            guard let app = r.activity?.app, !app.isEmpty, app != "未知" else { continue }
            counter[app, default: 0] += 1
        }
        return counter.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { "\($0.key)（\($0.value)）" }
    }

    /// 高频主题关键词（跨记录聚合，去重）
    static func topKeywords(records: [ActRecord], limit: Int = 10) -> [String] {
        var counter: [String: Int] = [:]
        for r in records where r.statusEnum == .done {
            for kw in r.activity?.keywords ?? [] where !kw.isEmpty && kw.count <= 12 {
                counter[kw, default: 0] += 1
            }
        }
        return counter.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map { $0.key }
    }

    // MARK: 构建 Day

    static func buildDay(date: String, records: [ActRecord]) -> ActivityDigest {
        let (count, percent) = categoryStats(records: records)
        let report = FocusAnalyzer.analyze(records)
        let focus = FocusDigest(focusedSec: report.focusedSec, scatteredSec: report.scatteredSec,
                                idleSec: report.idleSec, score: report.score,
                                interruptionCount: report.interruptionCount,
                                switchCount: report.switchCount, focusRunCount: report.focusRunCount,
                                effScore: report.effScore, contScore: report.contScore,
                                intrScore: report.intrScore, aiScore: report.aiScore)
        var d = ActivityDigest()
        d.key = DigestBuilder.dayKey(date)
        d.scope = "day"
        d.rangeLabel = date
        d.dateStrs = [date]
        d.categoryCount = count
        d.categoryPercent = percent
        d.focus = focus
        d.topActivities = topApps(records: records)
        d.topProjects = topKeywords(records: records)
        d.sourceLevel = "raw"
        d.sourceDigestKeys = []
        d.childKeys = []
        d.recordCount = records.filter { $0.statusEnum == .done }.count
        return d
    }

    // MARK: 构建高层（由低层 digest 组合）

    static func buildFromChildren(scope: String, rangeLabel: String, dateStrs: [String],
                                   children: [ActivityDigest]) -> ActivityDigest {
        var count: [String: Int] = [:]
        var focusedSec = 0, scatteredSec = 0, idleSec = 0, interruption = 0, sw = 0, runs = 0
        var activities: [String: Int] = [:]
        var projects: [String: Int] = [:]
        var childKeys: [String] = []
        var recordTotal = 0

        for c in children {
            for (k, v) in c.categoryCount { count[k, default: 0] += v }
            focusedSec += c.focus.focusedSec
            scatteredSec += c.focus.scatteredSec
            idleSec += c.focus.idleSec
            interruption += c.focus.interruptionCount
            sw += c.focus.switchCount
            runs += c.focus.focusRunCount
            // topActivities 形如「Xcode（32）」：必须拆出应用名再累加次数，
            // 否则「Xcode（32）」和「Xcode（15）」会被当成两个不同的应用。
            for a in c.topActivities {
                let p = parseCounted(a)
                activities[p.name, default: 0] += p.count
            }
            for p in c.topProjects { projects[p, default: 0] += 1 }
            childKeys.append(c.key)
            recordTotal += c.recordCount
        }

        let (_, percent) = normalizePercent(count)
        let (score, eff, cont, intr, ai) = FocusAnalyzer.computeScores(
            focusedSec: focusedSec, scatteredSec: scatteredSec, idleSec: idleSec,
            interruptionCount: interruption, switchCount: sw, focusRunCount: runs)
        let focus = FocusDigest(focusedSec: focusedSec, scatteredSec: scatteredSec, idleSec: idleSec,
                                score: score, interruptionCount: interruption,
                                switchCount: sw, focusRunCount: runs,
                                effScore: eff, contScore: cont, intrScore: intr, aiScore: ai)

        var d = ActivityDigest()
        d.key = keyForScope(scope, rangeLabel: rangeLabel, dateStrs: dateStrs)
        d.scope = scope
        d.rangeLabel = rangeLabel
        d.dateStrs = dateStrs
        d.categoryCount = count
        d.categoryPercent = percent
        d.focus = focus
        d.topActivities = activities
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(8).map { "\($0.key)（\($0.value)）" }
        d.topProjects = projects
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(10).map { $0.key }
        d.sourceLevel = scope == "week" ? "day" : (scope == "month" ? "week" : "month")
        d.sourceDigestKeys = childKeys
        d.childKeys = childKeys
        d.recordCount = recordTotal
        return d
    }

    /// 拆解「名称（次数）」；无括号计数时次数按 1
    static func parseCounted(_ s: String) -> (name: String, count: Int) {
        guard s.hasSuffix("）"), let open = s.lastIndex(of: "（") else { return (s, 1) }
        let numStr = String(s[s.index(after: open)..<s.index(before: s.endIndex)])
        guard let n = Int(numStr) else { return (s, 1) }
        return (String(s[s.startIndex..<open]), n)
    }

    /// 占比归一化（与 categoryStats 相同逻辑，作用于已合并的 count）
    private static func normalizePercent(_ count: [String: Int]) -> ([String: Int], [String: Int]) {
        let total = count.values.reduce(0, +)
        guard total > 0 else { return (count, [:]) }
        var percent: [String: Int] = [:]
        var acc = 0
        for (k, v) in count.sorted(by: { $0.value > $1.value }) {
            let p = Int((Double(v) / Double(total) * 100).rounded())
            percent[k] = p
            acc += p
        }
        let diff = 100 - acc
        if diff != 0, let maxK = percent.max(by: { $0.value < $1.value })?.key {
            percent[maxK] = (percent[maxK] ?? 0) + diff
        }
        return (count, percent)
    }

    static func keyForScope(_ scope: String, rangeLabel: String, dateStrs: [String]) -> String {
        switch scope {
        case "day": return DigestBuilder.dayKey(dateStrs.first ?? rangeLabel)
        case "week": return DigestBuilder.weekKey(dateStrs.first ?? rangeLabel)
        case "month": return DigestBuilder.monthKey(String((dateStrs.first ?? rangeLabel).prefix(7)))
        case "year": return DigestBuilder.yearKey(String((dateStrs.first ?? rangeLabel).prefix(4)))
        default: return "\(scope)-\(rangeLabel)"
        }
    }
}
