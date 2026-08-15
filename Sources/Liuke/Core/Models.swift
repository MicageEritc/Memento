import Foundation

// MARK: - 容错解码工具

/// 单条解码失败不影响整个数组
struct Failable<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// summary 字段历史上有两种格式：字符串（新）与字符串数组（旧），两种都要能读能写
enum FlexSummary: Codable, Equatable, Hashable {
    case text(String)
    case list([String])

    var joined: String {
        switch self {
        case .text(let s): return s
        case .list(let a): return a.joined(separator: "；")
        }
    }

    var isEmpty: Bool { joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s); return }
        if let a = try? c.decode([String].self) { self = .list(a); return }
        self = .text("")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .text(let s): try c.encode(s)
        case .list(let a): try c.encode(a)
        }
    }
}

// MARK: - 记录

/// 一念「主动记忆价值类型」——用户主动定格时，这条记忆为什么值得留下。
/// 固定枚举，与一念 prompt 强约束一致；旧数据 / 瞬息数据无此字段时一律按「其他」处理。
enum MemoryIntent {
    static let all = [
        "项目里程碑", "设计参考", "知识收藏", "待办提醒",
        "灵感", "重要通知", "生活记录", "高光时刻", "其他"
    ]

    /// 把任意字符串归一化到枚举（未知 / 空 → 其他）
    static func normalize(_ raw: String?) -> String {
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return "其他" }
        if all.contains(s) { return s }
        // 宽松匹配（避免 AI 写近义词时整条落入「其他」）
        let loose: [(String, [String])] = [
            ("项目里程碑", ["里程碑", "项目", "进展", "上线"]),
            ("设计参考", ["设计", "参考", "配色", "灵感图", "素材"]),
            ("知识收藏", ["知识", "收藏", "文章", "干货", "学习"]),
            ("待办提醒", ["待办", "提醒", "todo", "任务", "日程"]),
            ("灵感", ["灵感", "idea", "点子"]),
            ("重要通知", ["通知", "公告", "告警", "消息"]),
            ("生活记录", ["生活", "日常", "家人", "美食", "旅行"]),
            ("高光时刻", ["高光", "成就", "获奖", "庆祝"])
        ]
        let lower = s.lowercased()
        for (canon, keys) in loose where keys.contains(where: { lower.contains($0) }) { return canon }
        return "其他"
    }
}

/// 9 类活动分类（固定枚举，与 analyzer prompt 强约束一致）
enum ActivityCategory {
    static let all = [
        "办公与文档", "沟通与协作", "阅读与研究", "编程开发",
        "设计与创作", "影音与娱乐", "生活与购物", "系统与工具", "待机与离席"
    ]

    /// 兼容历史上出现过的旧写法
    static func normalize(_ raw: String?) -> String {
        guard var s = raw?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return "其他" }
        let alias: [String: String] = [
            "设计创作": "设计与创作",
            "影音娱乐": "影音与娱乐",
            "生活购物": "生活与购物",
            "系统工具": "系统与工具",
            "待机离席": "待机与离席",
            "办公文档": "办公与文档",
            "沟通协作": "沟通与协作",
            "阅读研究": "阅读与研究",
            "空闲":     "待机与离席"
        ]
        if let m = alias[s] { s = m }
        return all.contains(s) ? s : (s.isEmpty ? "其他" : s)
    }
}

struct Activity: Codable, Equatable, Hashable {
    var title: String?
    var app: String?
    var category: String?
    /// 单帧 AI 判断的「瞬时 focus 线索」（专注/分散/空闲）。
    /// ⚠️ 这是「从当前画面推断的状态提示」，不是最终专注度——最终专注度由本地时间序列算法计算（见 FocusAnalyzer）。
    var focus: String?
    var summary: FlexSummary?
    var keywords: [String]?
    /// 一念专属：用户主动记忆的价值类型（项目里程碑/设计参考/…/其他）。
    /// 瞬息无此语义，留 nil；旧数据无此字段时也留 nil，读取时按「其他」兜底。
    var intent: String?

    var summaryText: String { summary?.joined ?? "" }
    /// 归一化后的记忆价值类型（旧数据/瞬息 → 其他），供 UI 与安全过滤使用
    var intentValue: String { MemoryIntent.normalize(intent) }
    var displayTitle: String {
        let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        let s = summaryText
        return s.isEmpty ? "未识别活动" : String(s.prefix(30))
    }
    var displayCategory: String { ActivityCategory.normalize(category) }

    init(title: String? = nil, app: String? = nil, category: String? = nil,
         focus: String? = nil, summary: FlexSummary? = nil, keywords: [String]? = nil,
         intent: String? = nil) {
        self.title = title
        self.app = app
        self.category = category
        self.focus = focus
        self.summary = summary
        self.keywords = keywords
        self.intent = intent
    }

    /// 解码时把旧版/异写分类归一化到 9 类枚举。
    /// 例如 Electron 版空闲记录写 category: "空闲"，这里会映射成 "待机与离席"。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        app = try? c.decodeIfPresent(String.self, forKey: .app)
        if let raw = try? c.decodeIfPresent(String.self, forKey: .category) {
            category = ActivityCategory.normalize(raw)
        }
        focus = try? c.decodeIfPresent(String.self, forKey: .focus)
        summary = try? c.decodeIfPresent(FlexSummary.self, forKey: .summary)
        keywords = try? c.decodeIfPresent([String].self, forKey: .keywords)
        intent = try? c.decodeIfPresent(String.self, forKey: .intent)
    }
}

struct Usage: Codable, Equatable, Hashable {
    var prompt_tokens: Int?
    var completion_tokens: Int?
    var total_tokens: Int?
}

struct AnalysisInfo: Codable, Equatable, Hashable {
    var model: String?
    var latencyMs: Int?
    var usage: Usage?
    var error: String?
    var skippedReason: String?
    var changeDistance: Int?
    var reusedFrom: String?
}

struct DisplayInfo: Codable, Equatable, Hashable {
    var label: String?
    var width: Int?
    var height: Int?
    var nativeWidth: Int?
    var nativeHeight: Int?
    var screens: Int?
}

struct ShotRef: Codable, Equatable, Hashable {
    var abs: String?
    var rel: String?
    var label: String?
}

enum RecordStatus: String {
    case pending, analyzing, done, skipped, failed, dropped, idle
}

struct ActRecord: Codable, Equatable, Hashable, Identifiable {
    var id: String = ""
    var type: String?            // memento | yinian
    var timestamp: String?
    var time: String?
    var epochMs: Int64?
    var screenshot: String?
    var screenshotAbs: String?
    var screenshots: [ShotRef]?
    var imageBytes: Int?
    var imageHash: String?
    var changeDistance: Int?
    var appChanged: Bool?
    var titleChanged: Bool?
    var contextChanged: Bool?
    var display: DisplayInfo?
    var status: String?
    var idleSeconds: Int?
    var activity: Activity?
    var analysis: AnalysisInfo?
    /// 仅在搜索结果里回填，落盘时不写
    var date: String?

    var kind: RecordKind { type == "yinian" ? .yinian : .memento }
    var statusEnum: RecordStatus { RecordStatus(rawValue: status ?? "") ?? .pending }
    var when: Date { DateUtil.fromEpochMs(epochMs ?? 0) }

    enum CodingKeys: String, CodingKey {
        case id, type, timestamp, time, epochMs, screenshot, screenshotAbs, screenshots
        case imageBytes, imageHash, changeDistance, appChanged, titleChanged, contextChanged, display, status, idleSeconds
        case activity, analysis, date
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? ""
        type = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
        timestamp = (try? c.decodeIfPresent(String.self, forKey: .timestamp)) ?? nil
        time = (try? c.decodeIfPresent(String.self, forKey: .time)) ?? nil
        if let v = ((try? c.decodeIfPresent(Int64.self, forKey: .epochMs)) ?? nil) {
            epochMs = v
        } else if let v = ((try? c.decodeIfPresent(Double.self, forKey: .epochMs)) ?? nil) {
            epochMs = Int64(v)
        }
        screenshot = (try? c.decodeIfPresent(String.self, forKey: .screenshot)) ?? nil
        screenshotAbs = (try? c.decodeIfPresent(String.self, forKey: .screenshotAbs)) ?? nil
        screenshots = (try? c.decodeIfPresent([ShotRef].self, forKey: .screenshots)) ?? nil
        imageBytes = (try? c.decodeIfPresent(Int.self, forKey: .imageBytes)) ?? nil
        imageHash = (try? c.decodeIfPresent(String.self, forKey: .imageHash)) ?? nil
        changeDistance = (try? c.decodeIfPresent(Int.self, forKey: .changeDistance)) ?? nil
        appChanged = (try? c.decodeIfPresent(Bool.self, forKey: .appChanged)) ?? nil
        titleChanged = (try? c.decodeIfPresent(Bool.self, forKey: .titleChanged)) ?? nil
        contextChanged = (try? c.decodeIfPresent(Bool.self, forKey: .contextChanged)) ?? nil
        display = (try? c.decodeIfPresent(DisplayInfo.self, forKey: .display)) ?? nil
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil
        idleSeconds = (try? c.decodeIfPresent(Int.self, forKey: .idleSeconds)) ?? nil
        activity = (try? c.decodeIfPresent(Activity.self, forKey: .activity)) ?? nil
        analysis = (try? c.decodeIfPresent(AnalysisInfo.self, forKey: .analysis)) ?? nil
        date = (try? c.decodeIfPresent(String.self, forKey: .date)) ?? nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(time, forKey: .time)
        try c.encodeIfPresent(epochMs, forKey: .epochMs)
        // screenshot 为 nil 时也要写出 null，与原版 JSON 一致
        try c.encode(screenshot, forKey: .screenshot)
        try c.encodeIfPresent(screenshotAbs, forKey: .screenshotAbs)
        try c.encodeIfPresent(screenshots, forKey: .screenshots)
        try c.encodeIfPresent(imageBytes, forKey: .imageBytes)
        try c.encodeIfPresent(imageHash, forKey: .imageHash)
        try c.encodeIfPresent(changeDistance, forKey: .changeDistance)
        try c.encodeIfPresent(appChanged, forKey: .appChanged)
        try c.encodeIfPresent(titleChanged, forKey: .titleChanged)
        try c.encodeIfPresent(contextChanged, forKey: .contextChanged)
        try c.encodeIfPresent(display, forKey: .display)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(idleSeconds, forKey: .idleSeconds)
        try c.encodeIfPresent(activity, forKey: .activity)
        try c.encodeIfPresent(analysis, forKey: .analysis)
        // date 是运行时附加字段，不落盘
    }
}

enum RecordKind: String {
    case memento   // 瞬息
    case yinian    // 一念

    var dirName: String { self == .yinian ? "一念" : "瞬息" }
    var display: String { self == .yinian ? "一念" : "瞬息" }
}

// MARK: - 小时日志文件

struct LogStats: Codable, Equatable {
    var total = 0
    var analyzed = 0
    var skipped = 0
    var failed = 0
    var pending: Int? = 0
}

struct HourLog: Codable {
    var schema: String = Store.schemaId
    var date: String = ""
    var hour: String = ""
    var hourRange: String = ""
    var timezone: String = TimeZone.current.identifier
    var device: String = Host.current().localizedName ?? "Mac"
    var model: String?
    var intervalSec: Int?
    var createdAt: String = ""
    var updatedAt: String = ""
    var stats: LogStats = LogStats()
    var records: [ActRecord] = []

    enum CodingKeys: String, CodingKey {
        case schema, date, hour, hourRange, timezone, device, model, intervalSec
        case createdAt, updatedAt, stats, records
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = ((try? c.decodeIfPresent(String.self, forKey: .schema)) ?? nil) ?? Store.schemaId
        date = ((try? c.decodeIfPresent(String.self, forKey: .date)) ?? nil) ?? ""
        hour = ((try? c.decodeIfPresent(String.self, forKey: .hour)) ?? nil) ?? ""
        hourRange = ((try? c.decodeIfPresent(String.self, forKey: .hourRange)) ?? nil) ?? ""
        timezone = ((try? c.decodeIfPresent(String.self, forKey: .timezone)) ?? nil) ?? TimeZone.current.identifier
        device = ((try? c.decodeIfPresent(String.self, forKey: .device)) ?? nil) ?? "Mac"
        model = (try? c.decodeIfPresent(String.self, forKey: .model)) ?? nil
        intervalSec = (try? c.decodeIfPresent(Int.self, forKey: .intervalSec)) ?? nil
        createdAt = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil) ?? ""
        updatedAt = ((try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil) ?? ""
        stats = ((try? c.decodeIfPresent(LogStats.self, forKey: .stats)) ?? nil) ?? LogStats()
        // 坏记录跳过，不让整个文件读不出来
        let raw = ((try? c.decodeIfPresent([Failable<ActRecord>].self, forKey: .records)) ?? nil) ?? []
        records = raw.compactMap { $0.value }.filter { !$0.id.isEmpty }
    }
}

// MARK: - 统计结果

struct SideStats: Equatable {
    var total = 0
    var analyzed = 0
    var skipped = 0
    var failed = 0
    var categories: [String: Int] = [:]
    var apps: [String: Int] = [:]
}

struct TodayStats: Equatable {
    var memento = SideStats()
    var yinian = SideStats()
    var yinianCount: Int { yinian.analyzed }
}

struct StorageStats: Equatable {
    var root = ""
    var shotCount = 0
    var shotBytes: Int64 = 0
    var jsonCount = 0
    var jsonBytes: Int64 = 0
    var totalBytes: Int64 { shotBytes + jsonBytes }
}

struct CleanupResult: Equatable {
    var deletedShots = 0
    var freedBytes: Int64 = 0
    var keptJson = 0
}

struct CategoryBreakdown: Equatable {
    var total = 0
    var analyzed = 0
    /// 已按数量倒序
    var categories: [(String, Int)] = []

    static func == (l: CategoryBreakdown, r: CategoryBreakdown) -> Bool {
        l.total == r.total && l.analyzed == r.analyzed &&
        l.categories.count == r.categories.count &&
        zip(l.categories, r.categories).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }
}

struct AppCount: Equatable, Identifiable {
    var app: String
    var count: Int
    var id: String { app }
}

struct FocusBreakdown: Equatable {
    var focused = 0    // 专注
    var scattered = 0  // 分散
    var idle = 0       // 空闲

    var total: Int { focused + scattered + idle }

    /// 托盘速览口径：专注 /（专注 + 分散），不计空闲
    /// （1:1 对应 main.js `data:todayOverview` 里的 focusPct）
    var score: Int {
        let base = focused + scattered
        guard base > 0 else { return 0 }
        return Int((Double(focused) / Double(base) * 100).rounded())
    }

    /// 全景圆环口径：专注 / 全部（含空闲）
    /// （1:1 对应 renderer.js drawFocus 里的 pct，与 score 故意不同，勿合并）
    var panelPct: Int {
        guard total > 0 else { return 0 }
        return Int((Double(focused) * 100 / Double(total)).rounded())
    }
}

// MARK: - 周期总结

struct SummaryDoc: Codable, Equatable, Identifiable {
    var key: String = ""
    var scope: String = "day"          // day | week | month | year
    var rangeLabel: String = ""
    var dateStrs: [String] = []
    var overview: String = ""
    var sections: [String] = []
    var category_percent: [String: Int] = [:]
    var raw: String?
    var model: String?
    var modelLabel: String?          // 分配的模型显示名（如「模型 B · agnes-2.0-flash」）
    var latencyMs: Int?
    var generatedAt: String = ""
    var recordCount: Int = 0

    // ── 分层摘要 / 聚焦层（新增，全部带默认值，旧 JSON 缺字段可正常解码）──
    /// 数据来源层级：raw(直接原始) | day | week | month | year（表示本总结基于哪一层 Digest 生成）
    var sourceLevel: String = "raw"
    /// 参与聚合的底层 Digest key 列表（如 week 总结 = 7 个 day digest key）
    var sourceDigestKeys: [String] = []
    /// 由本地算法计算的专注度百分比（基于时间占比，不含空闲）
    var focusScore: Int = 0
    /// 专注情况的自然语言小结（由 AI 基于 focusScore 等事实生成，可空）
    var focusSummary: String = ""
    /// 高频活动（app + 标题，代码统计 Top N）
    var topActivities: [String] = []
    /// 高频主题/项目关键词（代码统计 Top N）
    var topProjects: [String] = []
    /// 干扰次数（专注运行被打断的次数，本地算法计算）
    var interruptionCount: Int = 0

    var id: String { generatedAt.isEmpty ? key : generatedAt }

    /// 历史列表里显示的「N月N日 HH:mm」
    var generatedLabel: String {
        guard let d = DateUtil.parseISO(generatedAt) else { return generatedAt }
        let p = DateUtil.parts(d)
        return "\(p.month)月\(p.day)日 \(DateUtil.pad(p.hour)):\(DateUtil.pad(p.minute))"
    }

    /// 空文档（所有字段用声明处默认值）——自定义 init 会抑制成员初始化器，显式补一个
    init() {}

    enum CodingKeys: String, CodingKey {
        case key, scope, rangeLabel, dateStrs, overview, sections, category_percent
        case raw, model, modelLabel, latencyMs, generatedAt, recordCount
        case sourceLevel, sourceDigestKeys, focusScore, focusSummary
        case topActivities, topProjects, interruptionCount
    }

    /// ⚠️ 必须手写解码：Swift 合成的 `init(from:)` **不会**使用属性默认值，
    /// 缺字段就直接抛 keyNotFound。老版本写下的 summary JSON 没有 sourceLevel /
    /// focusScore 等新字段，若用合成解码会导致「历史 AI 回忆全部读不出来」。
    /// 这里逐字段 decodeIfPresent + 默认值，保证旧文档 100% 可读。
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func s(_ k: CodingKeys, _ d: String = "") -> String {
            ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) ?? d
        }
        func i(_ k: CodingKeys, _ d: Int = 0) -> Int {
            ((try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil) ?? d
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
        category_percent = ((try? c.decodeIfPresent([String: Int].self, forKey: .category_percent)) ?? nil) ?? [:]
        raw = try? c.decodeIfPresent(String.self, forKey: .raw)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        modelLabel = try? c.decodeIfPresent(String.self, forKey: .modelLabel)
        latencyMs = try? c.decodeIfPresent(Int.self, forKey: .latencyMs)
        generatedAt = s(.generatedAt)
        recordCount = i(.recordCount)
        sourceLevel = s(.sourceLevel, "raw")
        sourceDigestKeys = arr(.sourceDigestKeys)
        focusScore = i(.focusScore)
        focusSummary = s(.focusSummary)
        topActivities = arr(.topActivities)
        topProjects = arr(.topProjects)
        interruptionCount = i(.interruptionCount)
    }

    /// 由分层 Digest 派生 SummaryDoc（保持旧 key 格式 `summary-<scope>-<首日期>`，面板照常读取）。
    /// 统计字段（category_percent / focusScore / topActivities …）全部来自代码计算的 digest，
    /// AI 只贡献 overview / sections。Digest 损坏也不影响：SummaryDoc 仍可只承载统计层。
    init(from d: ActivityDigest, scope: String, rangeLabel: String, dates: [String]) {
        self.init()
        self.key = "summary-\(scope)-\(dates.first ?? rangeLabel)"
        self.scope = scope
        self.rangeLabel = rangeLabel
        self.dateStrs = dates
        self.overview = d.overview
        self.sections = d.sections
        self.category_percent = d.categoryPercent
        self.model = d.model
        self.modelLabel = d.modelLabel
        self.latencyMs = d.latencyMs
        self.generatedAt = d.generatedAt
        self.recordCount = d.recordCount
        self.sourceLevel = d.sourceLevel
        self.sourceDigestKeys = d.sourceDigestKeys
        self.focusScore = d.focus.score
        self.topActivities = d.topActivities
        self.topProjects = d.topProjects
        self.interruptionCount = d.focus.interruptionCount
    }
}

// MARK: - 洞察 · 长期行为画像（全部由本地统计推导，不调用任何 AI）

/// 工作方式中的一个正向工作类型维度：真实占比 + 文字等级（不再是 0–100 评分条）。
struct WorkMode: Identifiable, Equatable {
    var key: String
    /// 占有效活动记录的真实占比（0–100，恒 ≤ 100）。
    var sharePct: Int
    /// 文字等级：高 / 较高 / 中 / 较低 / 低（基于真实占比，可理解）。
    var level: String
    var id: String { key }
}

/// 工作节奏中的一个真实数值指标（由代码计算，不调 AI）。
struct RhythmMetric: Identifiable, Equatable {
    var key: String
    /// 已格式化的数值（如「28 分钟」「3.4 小时」「6.2 次/小时」「8 次/天」「62%」）。
    var value: String
    /// 简短说明（可选）。
    var hint: String
    var id: String { key }
}

/// 留刻发现的一条：客观事实 + 它的依据（事实与推断分开）。
struct DiscoverItem: Equatable {
    var text: String
    var evidence: String
}

/// 近期变化的一项（对比上一等长度窗口）：direction 1=↑ / -1=↓ / 0=持平。
struct BehaviorChange: Identifiable, Equatable {
    var key: String
    var deltaPct: Int
    var direction: Int
    /// 指标极性：1 正向（增加为好，用积极色）/ -1 负向（增加为负担，用中性/警示色）。
    var polarity: Int = 1
    var id: String { key }
}

/// 洞察页「我的画像」数据：仅在打开洞察页时由本地统计聚合计算，不调用模型。
/// 缓存于内存（同一会话不重复计算）；跨会话重算，无需后台任务。
struct BehaviorProfile: Equatable {
    /// 近 90 天内有数据的天数 —— 决定画像成熟度门槛。
    var coveredDays: Int = 0
    /// 成熟度标签：数据积累中 / 初步画像 / 稳定画像 / 长期画像
    var readiness: String = ""
    /// 画像真实覆盖天数（顶部与发现的时间口径统一用这个值，绝不写死 90）。
    var profileDays: Int = 0
    /// 工作方式：正向工作类型维度（内容生产 / 探索研究 / 技术实践 / 沟通协作 / 深度工作），真实占比 + 文字等级。
    var workModes: [WorkMode] = []
    /// 活跃节奏：24 小时密度（相对当天峰值 0–100），供横向条带展示。
    var hourDensity: [Int] = Array(repeating: 0, count: 24)
    /// 最活跃时段（真实，如「09:00–12:00」）。
    var peakRange: String = ""
    /// 长期关注主题（基于 Activity 文本关键词聚类提取的真实 Topic，非分类名）。
    var topics: [String] = []
    /// 主题区标题：「长期关注」(≥30 天) 或「当前高频主题」(<30 天)。
    var topicsLabel: String = ""
    /// 工作节奏：由代码计算的真实数值指标（平均连续活动 / 日均有效活动 / 切换频率 / 干扰次数 / 专注度）。
    var rhythm: [RhythmMetric] = []
    /// 近期变化比较窗口天数（如 14）。
    var changeWindowDays: Int = 0
    /// 是否拥有两个等长度周期（历史足够才显示趋势，否则显示「数据积累中」）。
    var changesReady: Bool = false
    /// 近期变化（仅当 changesReady 时有效）。
    var recentChanges: [BehaviorChange] = []
    /// 留刻发现：本地规则生成的客观结论（事实 + 依据，非人格判断，不给主动建议）。
    var discoveries: [DiscoverItem] = []
    /// 生成时间（isoUTC），用于「更新画像」后刷新。
    var generatedAt: String = ""
    /// AI 工作画像缓存（低频、手动触发）：名称如「探索 · 创作型」。本轮由本地规则生成，未接入模型调用。
    var aiPortrait: String = ""
    var aiSummary: String = ""
    var aiRangeDays: Int = 0
}

/// 洞察画像的静态配置（AI 应用识别词、成熟度门槛）。
enum BehaviorProfileKit {
    /// AI 类应用识别关键词（大小写不敏感子串匹配）
    static let aiKeywords: [String] = [
        "AI", "ChatGPT", "Claude", "Gemini", "通义", "千问", "豆包", "文心",
        "Kimi", "DeepSeek", "Copilot", "元宝", "Groq", "Perplexity", "Ollama",
        "智谱", "讯飞星火", "Mistral", "Cursor", "Windsurf", "Notion AI", "Poe"
    ]
    /// 成熟度标签：按近 90 天有数据天数分档（<7 / 7–30 / 30–90 / ≥90）。
    static func readiness(_ days: Int) -> String {
        switch days {
        case ..<7:    return "数据积累中"
        case 7..<30:  return "初步画像"
        case 30..<90: return "稳定画像"
        default:       return "长期画像"
        }
    }

    /// 长期关注主题词典：从 Activity 的 title / summary / keywords 真实文本命中，绝不凭空创造。
    /// 关键词尽量用长词/明确词，避免短子串（如「AI」「app」「tem」）误命中普通英文。
    static let topicLexicon: [(String, [String])] = [
        ("AI 工具",   ["chatgpt", "claude", "gemini", "千问", "deepseek", "大模型", "prompt", "kimi",
                       "豆包", "copilot", "cursor", "智能体", "gpt", "文心", "通义", "ai 工具"]),
        ("公众号内容", ["公众号", "推文", "选题", "排版", "科普", "seo", "sem", "获客", "线索", "新媒体", "文案"]),
        ("软件开发",   ["swift", "python", "代码", "开发", "xcode", "bug", "接口", "前端", "后端",
                        "github", "git", "部署", "调试", "编程"]),
        ("材料科学",   ["样品杆", "原位", "电镜", "材料", "纳米", "表征", "科研", "论文", "实验", "原子"]),
        ("产品设计",   ["设计", "原型", "figma", "交互", "界面", "配色", "视觉"]),
        ("阅读研究",   ["阅读", "文献", "研究", "资料", "pdf", "学术", "综述"]),
        ("沟通协作",   ["会议", "邮件", "微信", "飞书", "讨论", "评审", "客户"]),
        ("生活记录",   ["生活", "家人", "美食", "旅行", "购物", "日常"])
    ]

    /// 在一段文本里命中哪些主题（去重，按词典顺序返回）。命中少则不返回，不会出现凭空主题。
    static func matchTopics(in text: String) -> [String] {
        let lower = text.lowercased()
        return topicLexicon.compactMap { topic, keys in
            keys.contains(where: { lower.contains($0.lowercased()) }) ? topic : nil
        }
    }
}
