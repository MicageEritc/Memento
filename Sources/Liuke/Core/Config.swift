import Foundation

/// 清理规则
struct CleanupRules: Codable, Equatable {
    var enabled: Bool = false
    var maxShots: Int = 3000        // 0=不限制
    var olderThanDays: Int = 0      // 0=不限制
    var maxBytes: Int64 = 0         // 0=不限制（字节）
    var keepJson: Bool = true       // 图文分离绝杀：文本日志永远保留
}

// MARK: - 模型能力 / 类型 / 配置（可扩展的模型池）

/// 能力判定状态：未检测 / 支持 / 不支持
enum CapabilityState: String, Codable, CaseIterable {
    case unknown      // 未检测（无法可靠判断）
    case supported    // 支持
    case unsupported  // 不支持
}

/// 模型能力标签（由「立即检测」自动判定，不再手动勾选）
struct ModelCapabilities: Codable, Equatable {
    var text: CapabilityState = .unknown    // 文本输入/输出
    var vision: CapabilityState = .unknown  // 是否支持图片/视觉输入
    var supportsText: Bool { text == .supported }
    var supportsVision: Bool { vision == .supported }

    init(text: CapabilityState = .unknown, vision: CapabilityState = .unknown) {
        self.text = text
        self.vision = vision
    }

    // 兼容旧版 Bool 写法（true → supported，false → unsupported）
    private enum Keys: String, CodingKey { case text, vision }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        func pick(_ k: Keys, _ def: CapabilityState) -> CapabilityState {
            if let s = try? c.decodeIfPresent(CapabilityState.self, forKey: k) { return s }
            if let b = try? c.decodeIfPresent(Bool.self, forKey: k) { return b ? .supported : .unsupported }
            return def
        }
        text = pick(.text, .unknown)
        vision = pick(.vision, .unknown)
    }
}

/// 模型类型：本地模型 / 在线模型（旧「自定义」已废弃：公网地址一律判为在线）
enum ModelKind: String, Codable, CaseIterable {
    case local, online, custom
    var label: String {
        switch self {
        case .local:  return "本地模型"
        case .online: return "在线模型"
        case .custom: return "在线模型"  // 兼容旧数据：自定义一律按在线展示
        }
    }
    // 未知类型一律归入「在线模型」，避免解码失败
    init(from decoder: Decoder) throws {
        let s = try? decoder.singleValueContainer().decode(String.self)
        switch s {
        case "local":  self = .local
        default:       self = .online
        }
    }
}

/// 单个模型配置（可扩展集合，不写死 model1 / model2）
struct ModelProfile: Codable, Identifiable, Equatable {
    var id: String            // 稳定唯一 id（兼容旧 Keychain 引用）
    var name: String          // 显示名称，如「模型 A」
    var provider: String      // 提供方（本地模型 / 在线模型，展示用）
    var kind: ModelKind
    var endpoint: String      // API 地址（base，如 http://127.0.0.1:8000/v1）
    var apiKeyRef: String     // 兼容字段：Keychain 引用（v3 起弃用，改明文 apiKey）
    var apiKey: String        // API Key 明文（v3 起存 config.json，杜绝 Keychain 授权弹窗）
    var modelName: String     // 模型名（如 Qwen3.6-35B-A3B-4bit）
    var enabled: Bool
    var thinking: Bool        // 思考模式：开启则模型先输出思维链再给答案（DeepSeek: thinking; 本地 oMLX: enable_thinking）
    var capabilities: ModelCapabilities

    init(id: String = UUID().uuidString,
         name: String,
         provider: String,
         kind: ModelKind,
         endpoint: String,
         apiKeyRef: String = "",
         apiKey: String = "",
         modelName: String,
         enabled: Bool,
         thinking: Bool = true,
         capabilities: ModelCapabilities) {
        self.id = id
        self.name = name
        self.provider = provider
        self.kind = kind
        self.endpoint = endpoint
        self.apiKeyRef = apiKeyRef.isEmpty ? id : apiKeyRef
        self.apiKey = apiKey
        self.modelName = modelName
        self.enabled = enabled
        self.thinking = thinking
        self.capabilities = capabilities
    }

    /// 旧版单模型迁移用的稳定 id（避免每次启动重建 UUID 导致 key 丢失）
    static let legacyId = "model-a"
}

// MARK: - ModelProfile 解码（兼容旧版：无 apiKey 字段 / apiKeyRef 缺省 / 无 thinking）
extension ModelProfile {
    private enum Keys: String, CodingKey {
        case id, name, provider, kind, endpoint, apiKeyRef, apiKey, modelName, enabled, thinking, capabilities
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = (try? c.decodeIfPresent(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "模型"
        provider = (try? c.decodeIfPresent(String.self, forKey: .provider)) ?? ""
        kind = (try? c.decodeIfPresent(ModelKind.self, forKey: .kind)) ?? .online
        endpoint = (try? c.decodeIfPresent(String.self, forKey: .endpoint)) ?? ""
        apiKeyRef = (try? c.decodeIfPresent(String.self, forKey: .apiKeyRef)) ?? ""
        if apiKeyRef.isEmpty { apiKeyRef = id }
        apiKey = (try? c.decodeIfPresent(String.self, forKey: .apiKey)) ?? ""
        modelName = (try? c.decodeIfPresent(String.self, forKey: .modelName)) ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
        thinking = (try? c.decodeIfPresent(Bool.self, forKey: .thinking)) ?? true
        capabilities = (try? c.decodeIfPresent(ModelCapabilities.self, forKey: .capabilities)) ?? ModelCapabilities()
    }
}

/// AI 功能入口（与路由一一对应）
enum AIFunction: String, CaseIterable, Identifiable {
    case moment, yinian, panorama, muse
    var id: String { rawValue }
    var title: String {
        switch self {
        case .moment:    return "瞬息"
        case .yinian:    return "一念"
        case .panorama:  return "全景"
        case .muse:      return "随想"
        }
    }
    /// 是否需要视觉（图片输入）能力
    var requiresVision: Bool { self == .moment || self == .yinian }
}

/// 应用配置 —— 字段与 Electron 版 config.js 的 DEFAULTS 一一对应，
/// JSON 完全兼容，可以直接读旧的 ~/Library/Application Support/留刻/config.json
struct AppConfig: Codable, Equatable {

    // 存储
    var outputDir: String = AppPaths.defaultOutputDir.path
    var keepScreenshots: Bool = true

    // 采集
    var intervalSec: Int = 20
    var saveWidth: Int = 1600
    var analyzeWidth: Int = 1280
    var jpegQuality: Int = 72
    var captureAllDisplays: Bool = false

    // 省算力策略
    var skipDuplicate: Bool = true
    var dupThreshold: Int = 4
    var saveDuplicateShots: Bool = true
    var skipWhenIdle: Bool = true
    var idleThresholdSec: Int = 180

    // 模型（旧版单字段，保留用于兼容旧 config.json 解码；新数据走 models 池）
    var apiBase: String = "http://127.0.0.1:8000/v1"
    var apiKey: String = "sk-omlx-0427"
    var model: String = "Qwen3.6-35B-A3B-4bit"

    // 模型池（可扩展集合；旧版单模型由 migrateModelPool 自动转为「模型 A」）
    var models: [ModelProfile] = []
    // 各 AI 功能 → 模型 id 分配（key 为 AIFunction.rawValue）
    var modelAssignments: [String: String] = [:]
    var summaryChars: Int = 100
    var temperature: Double = 0.3
    var maxTokens: Int = 700
    var requestTimeoutSec: Int = 240
    var retry: Int = 1

    // 周期总结（4096：推理模型思考过程也占 max_tokens，太小会只输出 thinking 无正文）
    var summaryMaxTokens: Int = 4096
    var summaryTimeoutSec: Int = 300

    // 存储与清理
    var cleanup: CleanupRules = CleanupRules()

    // 行为
    var autoStartCapture: Bool = true
    var launchAtLogin: Bool = false
    var showInDock: Bool = true
    var stayInTray: Bool = true

    var outputURL: URL { URL(fileURLWithPath: outputDir) }

    /// 与 config.js save() 中的 clamp 校验完全一致
    mutating func sanitize() {
        intervalSec      = clampVal(intervalSec == 0 ? 20 : intervalSec, 5, 3600)
        jpegQuality      = clampVal(jpegQuality == 0 ? 72 : jpegQuality, 30, 100)
        saveWidth        = clampVal(saveWidth == 0 ? 1600 : saveWidth, 640, 3840)
        analyzeWidth     = clampVal(analyzeWidth == 0 ? 1280 : analyzeWidth, 480, 2560)
        summaryChars     = clampVal(summaryChars == 0 ? 100 : summaryChars, 50, 150)
        dupThreshold     = clampVal(dupThreshold, 0, 20)
        idleThresholdSec = clampVal(idleThresholdSec == 0 ? 180 : idleThresholdSec, 30, 7200)
        temperature      = clampVal(temperature, 0, 2)
        maxTokens        = clampVal(maxTokens == 0 ? 700 : maxTokens, 64, 8192)
        requestTimeoutSec = clampVal(requestTimeoutSec == 0 ? 240 : requestTimeoutSec, 10, 3600)
        retry            = clampVal(retry, 0, 5)
        summaryMaxTokens = clampVal(summaryMaxTokens == 0 ? 4096 : summaryMaxTokens, 200, 16000)
        summaryTimeoutSec = clampVal(summaryTimeoutSec == 0 ? 300 : summaryTimeoutSec, 10, 3600)
        if outputDir.trimmingCharacters(in: .whitespaces).isEmpty {
            outputDir = AppPaths.defaultOutputDir.path
        }
        // 图文分离强制：文本日志永远保留（用户不可关闭）
        cleanup.keepJson = true
    }

    enum CodingKeys: String, CodingKey {
        case outputDir, keepScreenshots
        case intervalSec, saveWidth, analyzeWidth, jpegQuality, captureAllDisplays
        case skipDuplicate, dupThreshold, saveDuplicateShots, skipWhenIdle, idleThresholdSec
        case apiBase, apiKey, model, summaryChars, temperature, maxTokens, requestTimeoutSec, retry
        case summaryMaxTokens, summaryTimeoutSec
        case cleanup
        case autoStartCapture, launchAtLogin, showInDock, stayInTray
        case models, modelAssignments
    }

    // 缺字段时用默认值填补（旧 config.json 没有新字段也不会崩）
    init() {}

    // MARK: - 模型池迁移（旧单模型 → 模型池）

    /// 旧版本单模型配置（apiBase/apiKey/model）自动升级为「模型 A」+ 四个功能全指向它。
    /// 幂等：已迁移则只补全缺失分配。
    /// - Returns: 是否发生了结构性变更（调用方据此决定是否立即落盘）
    mutating func migrateModelPool() -> Bool {
        if models.isEmpty {
            let id = ModelProfile.legacyId
            let kind: ModelKind = isLocalEndpoint(apiBase) ? .local : .online
            let profile = ModelProfile(
                id: id,
                name: "模型 A",
                provider: kind == .local ? "本地模型" : "在线模型",
                kind: kind,
                endpoint: apiBase.isEmpty ? "http://127.0.0.1:8000/v1" : apiBase,
                apiKeyRef: id,
                apiKey: apiKey,   // 旧明文 key 直接带入（不再迁 Keychain）
                modelName: model.isEmpty ? "Qwen3.6-35B-A3B-4bit" : model,
                enabled: !apiBase.isEmpty,
                // 旧版 Qwen 默认多模态，视为支持视觉
                capabilities: ModelCapabilities(text: .supported, vision: .supported)
            )
            models = [profile]
            modelAssignments = [
                AIFunction.moment.rawValue: id,
                AIFunction.yinian.rawValue: id,
                AIFunction.panorama.rawValue: id,
                AIFunction.muse.rawValue: id
            ]
            apiKey = ""
            return true
        }
        // 已迁移：仅补全可能缺失的功能分配
        let before = modelAssignments
        ensureAssignments()
        return before != modelAssignments
    }

    /// 回收遗留 key（兼容 Keychain 时代的旧数据）：
    /// 若某模型明文 apiKey 为空、且 Keychain 存在遗留非空 key，则读取并写入明文，之后不再碰 Keychain。
    /// - Returns: 是否发生了回收（调用方据此决定是否落盘）
    mutating func recoverOrphanedKeysIfNeeded() -> Bool {
        var changed = false
        for i in models.indices where models[i].apiKey.isEmpty && !models[i].apiKeyRef.isEmpty {
            if let k = KeychainStore.shared.get(forKey: models[i].apiKeyRef), !k.isEmpty {
                models[i].apiKey = k
                changed = true
            }
        }
        return changed
    }

    /// 本地模型 key 兜底：若某模型 endpoint 是本地（回环/私网）且 key 为空，
    /// 用 AppConfig 默认 apiKey（本地 oMLX 默认值）写入明文。
    /// - Returns: 是否写入了至少一个本地默认 key
    mutating func seedLocalDefaultKeysIfNeeded() -> Bool {
        let fallback = AppConfig().apiKey
        guard !fallback.isEmpty else { return false }
        var changed = false
        for i in models.indices where isLocalEndpoint(models[i].endpoint) && models[i].apiKey.isEmpty {
            models[i].apiKey = fallback
            changed = true
            Log.shared.warn("model[\(models[i].name)] 本地模型 key 兜底：写入默认 key")
        }
        return changed
    }

    /// 保证四个功能都有合法分配（缺失时落到第一个启用模型）
    private mutating func ensureAssignments() {
        guard let first = models.first(where: { $0.enabled })?.id ?? models.first?.id else { return }
        for fn in AIFunction.allCases {
            let assigned = modelAssignments[fn.rawValue]
            let valid = assigned.flatMap { id in models.contains(where: { $0.id == id && $0.enabled }) } ?? false
            if !valid {
                modelAssignments[fn.rawValue] = first
            }
        }
    }

    /// 判断 API 地址是否为本地/内网（回环或私有网段）
    private func isLocalEndpoint(_ base: String) -> Bool {
        guard let u = URL(string: base), let h = u.host, !h.isEmpty else { return true }
        if h == "127.0.0.1" || h == "localhost" || h == "::1" { return true }
        if h.hasPrefix("10.") || h.hasPrefix("192.168.") { return true }
        if h.hasPrefix("172.") {
            let seg = h.split(separator: ".")
            if seg.count > 1, let n = Int(seg[1]), n >= 16, n <= 31 { return true }
        }
        return false
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppConfig()
        func s(_ k: CodingKeys, _ def: String) -> String {
            ((try? c.decodeIfPresent(String.self, forKey: k)) ?? nil) ?? def
        }
        func i(_ k: CodingKeys, _ def: Int) -> Int {
            if let v = ((try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil) { return v }
            if let v = ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil) { return Int(v) }
            return def
        }
        func b(_ k: CodingKeys, _ def: Bool) -> Bool { ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? def }
        func dbl(_ k: CodingKeys, _ def: Double) -> Double { ((try? c.decodeIfPresent(Double.self, forKey: k)) ?? nil) ?? def }

        outputDir        = s(.outputDir, d.outputDir)
        keepScreenshots  = b(.keepScreenshots, d.keepScreenshots)
        intervalSec      = i(.intervalSec, d.intervalSec)
        saveWidth        = i(.saveWidth, d.saveWidth)
        analyzeWidth     = i(.analyzeWidth, d.analyzeWidth)
        jpegQuality      = i(.jpegQuality, d.jpegQuality)
        captureAllDisplays = b(.captureAllDisplays, d.captureAllDisplays)
        skipDuplicate    = b(.skipDuplicate, d.skipDuplicate)
        dupThreshold     = i(.dupThreshold, d.dupThreshold)
        saveDuplicateShots = b(.saveDuplicateShots, d.saveDuplicateShots)
        skipWhenIdle     = b(.skipWhenIdle, d.skipWhenIdle)
        idleThresholdSec = i(.idleThresholdSec, d.idleThresholdSec)
        apiBase          = s(.apiBase, d.apiBase)
        apiKey           = s(.apiKey, d.apiKey)
        model            = s(.model, d.model)
        // 真正读取模型池与功能分配（之前漏解码，导致每次启动重建、用户配置跨重启丢失）
        models          = (try? c.decodeIfPresent([ModelProfile].self, forKey: .models)) ?? []
        modelAssignments = (try? c.decodeIfPresent([String: String].self, forKey: .modelAssignments)) ?? [:]
        summaryChars     = i(.summaryChars, d.summaryChars)
        temperature      = dbl(.temperature, d.temperature)
        maxTokens        = i(.maxTokens, d.maxTokens)
        requestTimeoutSec = i(.requestTimeoutSec, d.requestTimeoutSec)
        retry            = i(.retry, d.retry)
        summaryMaxTokens = i(.summaryMaxTokens, d.summaryMaxTokens)
        summaryTimeoutSec = i(.summaryTimeoutSec, d.summaryTimeoutSec)
        cleanup          = ((try? c.decodeIfPresent(CleanupRules.self, forKey: .cleanup)) ?? nil) ?? d.cleanup
        autoStartCapture = b(.autoStartCapture, d.autoStartCapture)
        launchAtLogin    = b(.launchAtLogin, d.launchAtLogin)
        showInDock       = b(.showInDock, d.showInDock)
        stayInTray       = b(.stayInTray, d.stayInTray)
    }
}

/// 全局配置存取（单例，主线程使用）
@MainActor
final class ConfigStore {

    static let shared = ConfigStore()

    private(set) var current: AppConfig

    private init() {
        var cfg = AppConfig()
        if let data = try? Data(contentsOf: AppPaths.configFile),
           let disk = try? JSONDecoder().decode(AppConfig.self, from: data) {
            cfg = disk
        }
        let migrated = cfg.migrateModelPool()
        let recovered = cfg.recoverOrphanedKeysIfNeeded()
        // 本地模型 key 兜底：若仍解析为空，用默认本地 key（sk-omlx-0427）写入新 Keychain
        // 避免每次 ad-hoc 重签后本地检测因 key 缺失而失败
        let seeded = cfg.seedLocalDefaultKeysIfNeeded()
        cfg.sanitize()
        current = cfg
        if migrated || recovered || seeded { persist() }
    }

    @discardableResult
    func update(_ mutate: (inout AppConfig) -> Void) -> AppConfig {
        var next = current
        mutate(&next)
        next.sanitize()
        current = next
        persist()
        return current
    }

    @discardableResult
    func replace(_ cfg: AppConfig) -> AppConfig {
        var next = cfg
        next.sanitize()
        current = next
        persist()
        return current
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: AppPaths.userData, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let data = try enc.encode(current)
            try data.write(to: AppPaths.configFile, options: .atomic)
        } catch {
            Log.shared.error("config save failed: \(error.localizedDescription)")
        }
    }
}
