import Foundation

// MARK: - 结果类型

struct AnalyzeResult {
    var ok = false
    var app = "未知"
    var title = ""
    var category = "其他"
    var focus = ""
    var summary = ""
    var keywords: [String] = []
    /// 一念专属：用户主动记忆的价值类型（项目里程碑/设计参考/…/其他）。瞬息无此语义。
    var intent: String? = nil
    var raw = ""
    var latencyMs = 0
    var usage: Usage?
    var model = ""
    var error: String?
}

struct PingResult {
    var ok = false
    var models: [String] = []
    var hasModel = false
    var type = "unknown"     // local | online | unknown
    var latencyMs = 0
    var error: String?
}

struct SummarizeResult {
    var ok = false
    var overview = ""
    var sections: [String] = []
    var categoryPercent: [String: Int] = [:]
    var raw = ""
    var model = ""
    var latencyMs = 0
    var error: String?
}

// MARK: - 分析器

/// 模型分析 —— 对应 analyzer.js，调用 OpenAI 兼容接口（本地 oMLX / 在线均可）
enum Analyzer {

    // 提示词分层重构：角色 / 任务 / 输出 Schema / 字段定义 / 业务规则 / 特殊情况
    // ⚠️ 与旧版逐字一致的核心约束全部保留，只是改成了清晰的层次，避免 System/User 重复堆规则。
    static let systemPrompt = """
        # 角色
        你是一个精准的用户行为分析引擎，专门从屏幕截图识别用户此刻最重要的数字活动。

        # 任务
        观察截图，用一段连贯文字（不超过指定字数）精准总结用户当前的核心工作内容或意图。
        不是描述界面，而是直接说「用户正在做什么、内容是什么」。

        # 输出 Schema
        严格输出 JSON：{ "app", "title", "category", "focus", "summary", "keywords" }

        # 字段定义
        - app：屏幕上最主要的应用/网站通用名（不要带「网页版/客户端/在线」后缀，看不出填 未知）。
        - title：不超过 15 字的一句话标题，概括此刻在做的事。
        - category：严格从 9 类里选一个（见业务规则）。
        - focus：仅表示「从当前画面推断的瞬时状态线索」，三选一：专注 / 分散 / 空闲。
        - summary：一段不超过指定字数的连续总结文字。
        - keywords：3 个以内关键词数组。

        # 业务规则
        1. 不描述普通 OS UI（Dock 栏、任务栏、浏览器名、窗口位置）。
        2. 不说「用户正在使用浏览器」「屏幕中央显示」这类废话。
        3. 直接说正在进行的核心事情，尽可能提取具体实体（公司名/软件名/文章标题/数据）。
        4. 不编造看不清的信息；不确定用「未知」而不是猜测。
        5. 多窗口时选信息价值最高的活动。
        6. App 名称归一化：抖音网页版/抖音精选→抖音；Chrome 浏览器→Chrome；VS Code - file.ts→VS Code。
        7. 微信 / 微信公众号 / 企业微信 必须严格区分（界面特征判定）。
        8. WPS 与 Microsoft Office 必须严格区分（WPS 全家桶→WPS，仅 Office 功能区→Excel/Word/PowerPoint）。
        9. 分类枚举（大小写不敏感，严格选最贴近的一个）：
           办公与文档  Word/Excel/PPT/Notion/石墨/腾讯文档/WPS/邮件
           沟通与协作  微信/企业微信/钉钉/Slack/Teams/会议/即时聊天
           阅读与研究  浏览器阅读/知乎/公众号/RSS/论文/书/新闻
           编程开发    VS Code/IDEA/终端/GitHub/调试/写代码
           设计与创作  Figma/Photoshop/Sketch/剪映/PR/画画/写歌
           影音与娱乐  B站/抖音/YouTube/网易云/游戏/影视
           生活与购物  淘宝/京东/美团/外卖/小红书/健康/健身
           系统与工具  设置/文件管理/无明确内容/系统设置
           待机与离席  锁屏/离开/桌面空白/壁纸

        # 特殊情况
        - focus 只是「瞬时画面线索」，不是科学意义上的最终专注度（最终专注度由本地算法按时间序列计算）。
        - 视频/文章必须通过标题或字幕识别内容属性：学习/技术类→专注，娱乐/搞笑类→分散。
        """

    static let yinianSystemPrompt = """
        # 角色
        你是用户的个人灵感与高光记忆提取助手。用户刚刚主动按下「一念」定格，意味着他认定这一刻值得被记住。

        # 任务
        从用户主动定格的瞬间中提炼「为什么这条值得留下」，而不只是描述画面。

        # 输出 Schema
        严格输出 JSON：{ "app", "title", "category", "focus", "summary", "keywords", "intent" }

        # 字段定义
        - app / title / category / focus / summary / keywords：同瞬息规则。
        - intent：这条记忆的价值类型，固定枚举二选一：
          项目里程碑 / 设计参考 / 知识收藏 / 待办提醒 / 灵感 / 重要通知 / 生活记录 / 高光时刻 / 其他。

        # 业务规则
        1. 拒绝废话：不出现「用户正在看」「屏幕上显示」等机械描述，直接切入核心内容。
        2. 提取干货：原汁原味提取金句、核心代码、关键数据、标题或重要通知。
        3. 解读价值：用一句话点明这份记录为什么值得保存（对应 intent 的选择理由）。
        4. 成段输出，文字凝练，富有洞察力（summary 不超过 100 字）。
        5. 不编造截图中不存在的信息；无法确定 intent 时填「其他」。

        # 特殊情况
        - 一念回答的是「为什么这一刻值得留下」，瞬息回答的是「我刚才在做什么」——两者语义不同。
        - intent 帮助用户长期检索与回看主动记忆，请尽量选最贴切的枚举而非一律「其他」。
        """

    static func buildUserPrompt(chars: Int, frontApp: FrontApp?, windowTitles: [String]) -> String {
        var hints: [String] = []
        if !windowTitles.isEmpty {
            let tlist = windowTitles.prefix(6).joined(separator: " / ")
            hints.append("【屏幕窗口标题 - 最高优先级】当前屏幕上打开的窗口标题：\(tlist)\n→ app 字段必须严格基于这个标题判断，绝不要自行臆测：标题含「微信公众号」或「公众号」→ app 写「微信公众号」；标题含「微信」→ app 写「微信」；含「企业微信」/「WeCom」/「客户联系」/「工作台」→ app 写「企业微信」；含「WPS」→ app 写「WPS」；含「Microsoft Excel」/「MS Excel」→ app 写「Excel」；含「Microsoft Word」→ app 写「Word」；含「Notion」「Figma」「Chrome」等就对应写。")
        }
        if let fa = frontApp, !fa.name.isEmpty, fa.name != "未知" {
            hints.append("【系统检测 - 前台应用】\(fa.name)（进程名 \(fa.proc)）。")
        }
        let appHint = hints.isEmpty ? "" : "\n" + hints.joined(separator: "\n") + "\n"

        let lines: [String] = [
            "这是用户电脑屏幕的截图（可能包含主屏与副屏拼接在一起的全景画面）。请用一段不超过 \(chars) 字的连续文字，精准总结用户当前的核心工作内容或意图。\(appHint)",
            "",
            "严格按以下 JSON 格式输出，不要输出任何解释、markdown 代码块或多余文字：",
            "{",
            "  \"app\": \"屏幕上最主要的应用或网站通用名（不要带「网页版」「客户端」「在线」等后缀，看不出则填 未知），例：Chrome 看 YouTube 直接写 YouTube，浏览器看抖音直接写 抖音\",",
            "  \"title\": \"不超过15字的一句话标题，概括用户此刻在做的事\",",
            "  \"category\": \"严格从下列 9 个分类中选一个: 办公与文档 / 沟通与协作 / 阅读与研究 / 编程开发 / 设计与创作 / 影音与娱乐 / 生活与购物 / 系统与工具 / 待机与离席\",",
            "  \"focus\": \"专注\" 或 \"分散\" 或 \"空闲\"（三选一，严格按下表判断）,",
            "  \"summary\": \"一段不超过 \(chars) 字的连续总结文字\",",
            "  \"keywords\": [\"关键词1\", \"关键词2\", \"关键词3\"]",
            "}",
            "",
            "【summary 写作要求】",
            "- 输出一段连贯的话，禁止用分号、编号、换行或列表分点。",
            "- 禁止描述操作系统UI（Dock栏/任务栏/浏览器名称/窗口位置等），直接说\"在做什么、内容是什么\"。",
            "- 尽量包含具体实体：公司名、软件名、数据标题、文章标题等。",
            "- 错误示范：\"用户正在使用Edge浏览器。屏幕中央显示了泽攸科技的官网主页。屏幕底部是Dock栏。\"",
            "- 正确示范：\"正在浏览泽攸科技官网的产品介绍页面，重点关注科技创新与精密量测技术相关内容。\"",
            "",
            "【分类枚举的强约束】只能使用下面 9 个键之一，大小写不敏感，请根据下表严格选用最贴近的一个：",
            "  办公与文档  Word/Excel/PPT/Notion/石墨/腾讯文档/WPS/邮件撰写",
            "  沟通与协作  微信/企业微信/钉钉/Slack/Teams/邮件/会议/即时聊天",
            "  阅读与研究  浏览器阅读文章/知乎/公众号/RSS/学术论文/书/新闻",
            "  编程开发    VS Code/IDEA/终端/GitHub/Stack Overflow/调试/写代码",
            "  设计与创作  Figma/Photoshop/Sketch/剪映/PR/画画/写歌",
            "  影音与娱乐  B站/抖音/YouTube/网易云/QQ音乐/游戏/影视",
            "  生活与购物  淘宝/京东/美团/外卖/小红书/健康/健身",
            "  系统与工具  设置/文件管理/浏览器无明确内容/系统设置/控制中心",
            "  待机与离席  锁屏/离开电脑/桌面空白/桌面壁纸",
            "",
            "【focus 三选一强约束】根据截图内容，将用户当前状态严格分类为以下三种之一（必须三选一）：",
            "  空闲：锁屏、屏保、纯桌面或静止无焦点界面。",
            "  专注：前台为开发/设计/写作工具，或正在阅读专业文档、技术/科普/学习类视频、工作沟通。",
            "  分散：前台为短视频、娱乐信息流（微博/小红书/八卦）、购物网站、游戏、纯闲聊/斗图。",
            "  特别注意：若画面为视频或文章，必须通过标题/字幕识别内容属性——学习/技术类视频算\"专注\"，娱乐/搞笑类视频算\"分散\"。",
            "",
            "【app 名称归一化】同一款产品的不同入口都统一为同一个名字，例如：",
            "  抖音网页版 / 抖音精选网页版 / 抖音桌面版 → 抖音",
            "  YouTube 主页 / YouTube 首页 / yt.com → YouTube",
            "  谷歌浏览器 / Chrome 浏览器 → Chrome",
            "  VS Code - file.ts → VS Code",
            "不要在 app 字段输出 URL、域名、文件路径或带「网页版」后缀的版本名。",
            "",
            "【微信 与 微信公众号 与 企业微信 必须严格区分】三者是完全不同的概念，按界面特征判断：",
            "  微信公众号（阅读公众号文章）：界面是文章排版页（标题+正文+文首公众号名称/头像+「XX人读过」+关注/在看/点赞按钮），或公众号主页（历史文章列表）→ app 写「微信公众号」",
            "  微信（个人微信）：Mac 版绿色顶栏、聊天列表/私聊/微信群、朋友圈、视频号、文件传输助手 → app 写「微信」（注意：即使在微信里聊客户、谈生意，只要界面是聊天，就写 微信）",
            "  企业微信（Mac 版）：左侧一列工作面板（消息/邮件/文档/日程/待办/会议/智能文档/智能总结/工作台/通讯录/微盘/高级功能）、消息列表项尾部带「@微信」「@企微」标记、出现「客户联系」「审批」「打卡」字样 → app 写「企业微信」",
            "",
            "【WPS 与 Microsoft Office 必须严格区分】",
            "  WPS Office 全家桶（WPS 文字 / WPS 表格 / WPS 演示 / WPS PDF）→ app 统一写 WPS，不要写成 Excel/Word/PowerPoint；",
            "  只有 Microsoft Office（MS Excel / MS Word / MS PowerPoint）界面才写 Excel / Word / PowerPoint。",
            "  判断依据：界面含\"WPS\"字样、WPS 特有的紫色图标/启动器 → WPS；含 Office 功能区（Ribbon）、Microsoft 品牌 → 对应 Office 应用。",
            "",
            "【多窗口画面】若截图拼接了主屏+副屏多个应用，app 取\"用户正在操作或信息量最大\"的那个，summary 围绕它展开。"
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: - 文本解析

    static func stripThinking(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var s = text
        if let re = try? NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>", options: [.caseInsensitive]) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        if let re = try? NSRegularExpression(pattern: "</?think>", options: [.caseInsensitive]) {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func extractJson(_ text: String) -> [String: Any]? {
        guard !text.isEmpty else { return nil }
        var candidates: [String] = []
        // ```json ... ```
        if let re = try? NSRegularExpression(pattern: "```(?:json)?\\s*([\\s\\S]*?)```", options: [.caseInsensitive]),
           let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) {
            candidates.append(String(text[r]))
        }
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            candidates.append(String(text[first...last]))
        }
        candidates.append(text)
        for c in candidates {
            let t = c.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = t.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            return obj
        }
        return nil
    }

    /// 纯文本兜底：按编号 / 换行拆句
    static func looseSentences(_ text: String, _ n: Int) -> [String] {
        let bulletRe = try? NSRegularExpression(pattern: "^\\s*(?:[-*•]|\\d+[.、)）])\\s*")
        var lines = text.components(separatedBy: .newlines).map { line -> String in
            var l = line
            if let re = bulletRe {
                l = re.stringByReplacingMatches(in: l, range: NSRange(l.startIndex..., in: l), withTemplate: "")
            }
            return l.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        if lines.count < 2 {
            var parts: [String] = []
            var buf = ""
            for ch in text {
                buf.append(ch)
                if "。！？!?".contains(ch) {
                    let t = buf.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { parts.append(t) }
                    buf = ""
                }
            }
            let tail = buf.trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { parts.append(tail) }
            lines = parts
        }
        return Array(lines.prefix(max(0, n)))
    }

    static func normalize(_ raw: String, chars: Int) -> AnalyzeResult {
        let cleaned = stripThinking(raw)
        var result = AnalyzeResult()
        result.raw = cleaned

        if let obj = extractJson(cleaned) {
            let appVal = (obj["app"] as? String) ?? (obj["application"] as? String) ?? "未知"
            result.app = String(appVal.prefix(60))
            result.title = String(((obj["title"] as? String) ?? "").prefix(60))
            result.category = String(((obj["category"] as? String) ?? "其他").prefix(20))
            result.focus = String(((obj["focus"] as? String) ?? "").prefix(10))

            if let s = obj["summary"] as? String {
                result.summary = s.trimmingCharacters(in: .whitespacesAndNewlines)
            } else if let arr = obj["summary"] as? [Any] {
                // 旧格式兼容：数组去重后合并成一段
                var seen = Set<String>()
                var parts: [String] = []
                let punct = CharacterSet(charactersIn: "，。！？、；：,.!?;: \t\n")
                for item in arr {
                    let t = String(describing: item).trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.isEmpty { continue }
                    let key = t.components(separatedBy: punct).joined()
                    if seen.contains(key) { continue }
                    seen.insert(key)
                    parts.append(t)
                }
                result.summary = parts.joined(separator: "；")
            }
            if let kw = obj["keywords"] as? [Any] {
                result.keywords = kw.map { String(describing: $0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .prefix(8)
                    .map { $0 }
            }
            if let rawIntent = obj["intent"] as? String {
                result.intent = MemoryIntent.normalize(rawIntent)
            }
        }

        if result.summary.isEmpty {
            result.summary = looseSentences(cleaned, chars).joined(separator: "；")
        }
        result.summary = String(result.summary.prefix(chars))
        if result.title.isEmpty {
            result.title = String((result.summary.isEmpty ? "未识别活动" : result.summary).prefix(30))
        }
        return result
    }

    // MARK: - 网络

    private static func endpoint(_ base: String, _ path: String) -> URL? {
        var b = base.trimmingCharacters(in: .whitespaces)
        while b.hasSuffix("/") { b.removeLast() }
        return URL(string: b + path)
    }

    private static func session(timeoutSec: Int) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = Double(max(5, timeoutSec))
        c.timeoutIntervalForResource = Double(max(5, timeoutSec))
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }

    /// 按模型配置注入思考模式参数（保证「思考模式」开关真实生效）：
    /// - 本地 oMLX / Qwen：`chat_template_kwargs.enable_thinking`
    /// - DeepSeek（v4-flash/v4-pro 等）：`thinking.type = enabled/disabled`（官方文档）
    /// - 其他在线模型：不注入（遵守其各自默认行为）
    static func applyThinking(_ body: inout [String: Any], profile: ModelProfile) {
        let ep = profile.endpoint.lowercased()
        let isLocal = profile.kind == .local || ep.contains("127.0.0.1") || ep.contains("localhost")
        if isLocal {
            body["chat_template_kwargs"] = ["enable_thinking": profile.thinking]
        } else if ep.contains("deepseek") {
            body["thinking"] = ["type": profile.thinking ? "enabled" : "disabled"]
        }
    }

    private static func parseUsage(_ any: Any?) -> Usage? {
        guard let d = any as? [String: Any] else { return nil }
        var u = Usage()
        u.prompt_tokens = d["prompt_tokens"] as? Int
        u.completion_tokens = d["completion_tokens"] as? Int
        u.total_tokens = d["total_tokens"] as? Int
        return u
    }

    /// 分析一张截图
    static func analyze(_ jpeg: Data, profile: ModelProfile, cfg: AppConfig, kind: RecordKind,
                        frontApp: FrontApp?, windowTitles: [String]) async throws -> AnalyzeResult {
        let isYinian = (kind == .yinian)
        let chars = isYinian ? 100 : (cfg.summaryChars > 0 ? cfg.summaryChars : 100)
        let sysPrompt = isYinian ? yinianSystemPrompt : systemPrompt

        let b64 = jpeg.base64EncodedString()
        var body: [String: Any] = [
            "model": profile.modelName,
            "messages": [
                ["role": "system", "content": sysPrompt],
                ["role": "user", "content": [
                    ["type": "image_url",
                     "image_url": ["url": "data:image/jpeg;base64," + b64]],
                    ["type": "text",
                     "text": buildUserPrompt(chars: chars, frontApp: frontApp, windowTitles: windowTitles)]
                ]]
            ],
            "max_tokens": cfg.maxTokens > 0 ? cfg.maxTokens : 700,
            "temperature": cfg.temperature,
            "top_p": 0.9,
            "stream": false
        ]
        // 思考模式开关（本地 oMLX: enable_thinking；DeepSeek: thinking.type）
        Analyzer.applyThinking(&body, profile: profile)

        guard let url = endpoint(profile.endpoint, "/chat/completions") else {
            throw NSError(domain: "Liuke", code: 2, userInfo: [NSLocalizedDescriptionKey: "API 地址无效：\(profile.endpoint)"])
        }
        let key = ModelRouter.apiKey(for: profile)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key.isEmpty ? "none" : key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let started = Date()
        let (data, resp) = try await session(timeoutSec: cfg.requestTimeoutSec).data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let txt = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw NSError(domain: "Liuke", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) \(txt)"])
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "Liuke", code: 3, userInfo: [NSLocalizedDescriptionKey: "模型返回不是合法 JSON"])
        }
        let choice = (root["choices"] as? [[String: Any]])?.first ?? [:]
        let msg = choice["message"] as? [String: Any] ?? [:]
        let content = (msg["content"] as? String) ?? (msg["reasoning_content"] as? String) ?? ""

        var out = normalize(content, chars: chars)
        out.ok = true
        out.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
        out.usage = parseUsage(root["usage"])
        out.model = (root["model"] as? String) ?? profile.modelName
        return out
    }

    /// 带重试
    static func analyzeWithRetry(_ jpeg: Data, profile: ModelProfile, cfg: AppConfig, kind: RecordKind,
                                 frontApp: FrontApp?, windowTitles: [String]) async -> AnalyzeResult {
        let attempts = max(1, cfg.retry + 1)
        var lastErr: String = "未知错误"
        for i in 0..<attempts {
            do {
                return try await analyze(jpeg, profile: profile, cfg: cfg, kind: kind, frontApp: frontApp, windowTitles: windowTitles)
            } catch {
                lastErr = error.localizedDescription
                if i < attempts - 1 {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
        var r = AnalyzeResult()
        r.ok = false
        r.app = ""
        r.title = "分析失败"
        r.category = ""
        r.summary = ""
        r.error = lastErr
        return r
    }

    /// 由 API 地址自动判定模型类型：本地 / 在线
    /// 规则：回环/私有地址 → 本地；其它所有公网地址 → 在线（不再有「自定义」类型）
    static func detectKind(_ base: String) -> ModelKind {
        guard let u = URL(string: base), let h = u.host, !h.isEmpty else { return .online }
        if h == "127.0.0.1" || h == "localhost" || h == "::1" { return .local }
        if h.hasPrefix("10.") || h.hasPrefix("192.168.") { return .local }
        if h.hasPrefix("172.") {
            let seg = h.split(separator: ".")
            if seg.count > 1, let n = Int(seg[1]), n >= 16, n <= 31 { return .local }
        }
        // 公网地址统一为「在线」（提供方由 deriveProvider 细分）
        return .online
    }

    /// 由 API 地址推断提供方（已知云端 → 厂商名；本地 → 本地；未知域名 → 取主域名首段）
    static func deriveProvider(_ base: String, kind: ModelKind) -> String {
        if kind == .local { return "本地" }
        guard let u = URL(string: base), let h = u.host, !h.isEmpty else { return "在线" }
        let map: [(String, String)] = [
            ("deepseek", "DeepSeek"), ("openai", "OpenAI"), ("anthropic", "Claude"),
            ("googleapis", "Gemini"), ("moonshot", "Kimi"), ("dashscope", "通义千问"),
            ("bigmodel", "智谱"), ("zhipuai", "智谱"), ("siliconflow", "硅基流动"),
            ("volcengine", "豆包"), ("ark.cn", "豆包"), ("groq", "Groq"),
            ("cohere", "Cohere"), ("perplexity", "Perplexity"), ("together", "Together"),
            ("x.ai", "Grok"), ("agnes", "Agnes")
        ]
        for (k, v) in map where h.contains(k) { return v }
        // 未知域名：取主机名第一段（去掉 api/apihub 等通用前缀）
        let parts = h.split(separator: ".")
        guard let first = parts.first else { return "在线" }
        let sub = String(first)
        let skip: Set<String> = ["api", "apihub", "gateway", "open", "www"]
        if parts.count > 2, skip.contains(sub.lowercased()) {
            return String(parts[1]).capitalized
        }
        return sub.capitalized
    }

    /// 模型完整检测结果
    struct DetectResult {
        var ok = false
        var kind: ModelKind = .custom
        var provider: String = ""
        var capabilities = ModelCapabilities()
        var latencyMs = 0
        var hasModel = false
        var models: [String] = []
        var error: String?
    }

    /// 完整检测：连通性 + 自动判定类型 + 提供方 + 文本/视觉能力。
    /// probeVision=true 时会真实发送一张极小图片探测视觉能力；无法判定时标记「未检测」。
    static func detect(profile: ModelProfile, probeVision: Bool = true) async -> DetectResult {
        var out = DetectResult()
        out.kind = detectKind(profile.endpoint)
        out.provider = deriveProvider(profile.endpoint, kind: out.kind)

        guard let url = endpoint(profile.endpoint, "/models") else {
            out.error = "API 地址无效"
            return out
        }
        let key = ModelRouter.apiKey(for: profile)
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key.isEmpty ? "none" : key)", forHTTPHeaderField: "Authorization")
        let started = Date()
        do {
            let (data, resp) = try await session(timeoutSec: 6).data(for: req)
            out.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                out.error = "HTTP \(code)"
                return out
            }
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let list = (root["data"] as? [[String: Any]]) ?? []
            out.models = list.compactMap { $0["id"] as? String }
            out.hasModel = profile.modelName.isEmpty || out.models.contains(profile.modelName)
            out.ok = true
            out.capabilities.text = .supported
            if probeVision {
                out.capabilities.vision = await probeVisionCapability(profile: profile, key: key)
            }
        } catch {
            out.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            out.error = error.localizedDescription
            out.capabilities.text = .unknown
            out.capabilities.vision = .unknown
        }
        return out
    }

    // 1x1 透明 PNG（用于视觉能力探测）
    private static let tinyPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
    private static func tinyPNG() -> Data { Data(base64Encoded: tinyPNGBase64) ?? Data() }

    /// 真实发送一张极小图片，判断模型是否接受视觉输入
    private static func probeVisionCapability(profile: ModelProfile, key: String) async -> CapabilityState {
        guard let url = endpoint(profile.endpoint, "/chat/completions"), !profile.modelName.isEmpty else { return .unknown }
        let b64 = tinyPNG().base64EncodedString()
        let body: [String: Any] = [
            "model": profile.modelName,
            "messages": [["role": "user", "content": [
                ["type": "image_url", "image_url": ["url": "data:image/png;base64," + b64]],
                ["type": "text", "text": "用一句话描述这张图片。"]
            ]]],
            "max_tokens": 16,
            "temperature": 0,
            "stream": false
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key.isEmpty ? "none" : key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await session(timeoutSec: 12).data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { return .supported }
            let txt = String(data: data.prefix(600), encoding: .utf8) ?? ""
            return indicatesNoVision(txt) ? .unsupported : .unknown
        } catch {
            return .unknown
        }
    }

    /// 错误文案是否表明模型「不支持图片输入」（而非鉴权/网络/模型名等无关错误）
    private static func indicatesNoVision(_ text: String) -> Bool {
        let l = text.lowercased()
        let pats = ["image_url", "invalid_request_error", "expected `text", "expected \"text",
                    "content parts", "messages.0.content", "multimodal", "does not support vision",
                    "image input is not", "unsupported modality", "vision is not supported",
                    "image inputs are not", "this model does not", "cannot process image"]
        return pats.contains { l.contains($0) }
    }

    /// 兼容旧调用：返回 local / online / custom 字符串
    static func apiType(_ base: String) -> String { detectKind(base).rawValue }

    /// 探测服务可用性
    static func ping(profile: ModelProfile) async -> PingResult {
        var out = PingResult()
        out.type = apiType(profile.endpoint)
        guard let url = endpoint(profile.endpoint, "/models") else {
            out.error = "API 地址无效"
            return out
        }
        let key = ModelRouter.apiKey(for: profile)
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key.isEmpty ? "none" : key)", forHTTPHeaderField: "Authorization")
        let started = Date()
        do {
            let (data, resp) = try await session(timeoutSec: 4).data(for: req)
            out.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                out.error = "HTTP \(code)"
                return out
            }
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let list = (root["data"] as? [[String: Any]]) ?? []
            out.models = list.compactMap { $0["id"] as? String }
            out.hasModel = out.models.contains(profile.modelName)
            out.ok = true
        } catch {
            out.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            out.error = error.localizedDescription
        }
        return out
    }

    // MARK: - 周期总结

    /// 角色与任务（AI 解释层的总纲；统计交给代码，AI 只理解与表达）
    static let summarySystem =
        "# 角色\n你是时间管理复盘助手，负责根据用户一段时间的事实数据，生成客观、有洞察的复盘报告。\n" +
        "# 任务\n基于代码已算好的统计事实（分类占比、专注度、高频应用/主题）与关键活动，理解这段时间用户把时间花在哪里、" +
        "在做什么、专注与分心模式如何。\n" +
        "# 输出 Schema\nJSON：{ \"overview\", \"sections\", \"category_percent\" }\n" +
        "# 业务规则\n" +
        "- 只基于提供的事实分析，不编造日志中没有的活动。\n" +
        "- category_percent 优先直接使用「代码已算好的占比」，不要重新估算；仅当未提供时才自行估算（各分类和为 100）。\n" +
        "- 年度叙事可以有温度，但必须建立在真实聚合数据之上，禁止凭空编故事。\n" +
        "# 特殊情况\n- 对未知/不足的样本保持保守，注明「样本不足」而非臆测。"

    static let summaryStyle: [String: String] = [
        "day": [
            "【核心目标】还原微观事实与产出：",
            "· 关注「今天具体干成了什么」——列出真正推进的事情与可见产出；",
            "· 关注「时间块怎么分布的」——上午/下午/晚上的精力走向与切换；",
            "· 关注「有哪些干扰」——打断、刷屏、长时间空闲等。",
            "【语言风格】结构清晰、客观干练，兼顾时间线与产出。"
        ].joined(separator: "\n"),
        "week": [
            "【核心目标】提炼项目进展与时间占比：",
            "· 归纳「本周在哪些核心项目（如：留刻开发、图标设计）上投入最多」；",
            "· 总结「阶段性里程碑完成了什么」——哪些事在本周有了关键推进或收尾。",
            "【语言风格】项目导向，结合占比趋势，突出 weekly milestone。"
        ].joined(separator: "\n"),
        "month": [
            "【核心目标】提取月度主题与习惯变化：",
            "· 总结「这一个月的主旋律是什么」（例如：8 月是留刻 1.0 的研发冲刺月）；",
            "· 观察工作与生活重心的转移、习惯的养成或松懈。",
            "【语言风格】主题化、趋势化，提炼月度关键词。"
        ].joined(separator: "\n"),
        "year": [
            "【核心目标】感性叙事与人生足迹：",
            "· 摒弃细枝末节，用「3~4 个年度篇章」回顾这一年的生长、探索与高光时刻；",
            "· 赋予时光以仪式感，把这一年讲成一个完整的故事。",
            "【语言风格】故事化、有温度、富有共鸣与总结沉淀感。"
        ].joined(separator: "\n")
    ]

    /// 旧版路径（直接把原始活动行喂给 AI）。仅作为「无 Digest 可复用」时的兜底，
    /// 新架构主路径走 `buildDigestSummaryPrompt`（代码统计 + AI 解释）。
    static func buildSummaryPrompt(scope: String, rangeLabel: String, lines: [String]) -> String {
        let joined = lines.joined(separator: "\n")
        let style = summaryStyle[scope] ?? summaryStyle["day"]!
        return [
            summarySystem,
            "",
            "下面是用户在「\(rangeLabel)」期间、由本地模型对屏幕截图逐条分析得到的活动记录（已按时间顺序整理，最多 \(lines.count) 条）：",
            "",
            joined,
            "",
            style,
            "",
            "输出要求：",
            "1. 先用 1 句话给出总体结论（例如该周期主要在做的事、总投入时长感）。",
            "2. 接着给出 3-5 段文字，内容围绕上述核心目标展开；若日志中存在明显的时间浪费或空闲，温和地指出，并给一句可执行的小建议。",
            "3. 最后输出一个 JSON：category_percent 直接沿用上面代码统计的占比（不要重算）；只列出占比>0 的分类。",
            "",
            "严格按如下 JSON 格式在文末输出（前面是自由文字复盘，最后才是 JSON，二者都要有）：",
            "{",
            "  \"overview\": \"一句话总体结论\",",
            "  \"sections\": [\"段落1\", \"段落2\", \"段落3\", \"段落4\"],",
            "  \"category_percent\": { \"办公与文档\": 60, \"沟通与协作\": 20, \"编程开发\": 10, \"待机与离席\": 10 }",
            "}",
            "",
            "注意：日/周段落精炼（每段 40–60 字），月/年可适当展开；语言平实、符合上述周期的风格定位。"
        ].joined(separator: "\n")
    }

    /// 新架构主路径：把「代码算好的统计事实 + 关键活动事实」交给 AI 解释，AI 不重算统计。
    static func buildDigestSummaryPrompt(scope: String, rangeLabel: String,
                                          statsBlock: String, facts: String) -> String {
        let style = summaryStyle[scope] ?? summaryStyle["day"]!

        // 篇幅与段落数随周期放大：日/周保持精炼，月约 300 字、年约 800 字。
        let (segHint, lenHint, tailNote): (String, String, String) = {
            switch scope {
            case "day":
                return ("3 段左右",
                        "整体精炼，约 80–140 字",
                        "段落精炼，每段 40–60 字；")
            case "week":
                return ("3–4 段",
                        "整体约 150–220 字",
                        "段落精炼，每段 40–60 字；")
            case "month":
                return ("4–6 段",
                        "整体约 250–350 字",
                        "月度正文约 250–350 字，须覆盖七个信息层：①总览 ②时间投入与节奏 ③专注度与干扰 ④主要活动与项目 ⑤分类占比与重心 ⑥一念高光时刻 ⑦可改进的小建议；")
            case "year":
                return ("4–6 段",
                        "整体约 650–950 字",
                        "年度正文约 650–950 字，须以事实数据中的「月度脉络」为骨架讲清真实年度变化（年初→年中→年末的重心迁移、专注趋势、关键项目与高光），Year 专注度是全年聚合值而非单月复用；")
            default:
                return ("3–5 段", "整体精炼", "段落精炼；")
            }
        }()

        return [
            summarySystem,
            "",
            "下面是用户在「\(rangeLabel)」期间的【事实数据】（已由本地代码从原始活动统计/聚合得到，可直接采信，无需你重新计算）：",
            "",
            statsBlock,
            "",
            "关键活动事实（供你叙事与解读，不要求逐条复述）：",
            facts.isEmpty ? "（无）" : facts,
            "",
            style,
            "",
            "输出要求：",
            "1. 先用 1 句话给出总体结论（这段时间主要在做的事、时间投入感、专注情况）。",
            "2. 接着给出 \(segHint) 文字（\(lenHint)），围绕上述核心目标展开，对统计事实做出「为什么」的解读（例如某分类占比高意味着什么、专注度高低说明什么、有哪些干扰与可改进点）。",
            "3. 若有关键的一念主动记忆（高光/里程碑/待办），可在叙事中点出。",
            "4. 最后输出一个 JSON：category_percent 直接沿用上面「分类时长占比」的占比（不要重算）；只列占比>0 的分类。",
            "",
            "严格按如下 JSON 格式在文末输出（前面是自由文字复盘，最后才是 JSON，二者都要有）：",
            "{",
            "  \"overview\": \"一句话总体结论\",",
            "  \"sections\": [\"段落1\", \"段落2\", \"段落3\", \"段落4\"],",
            "  \"category_percent\": { \"办公与文档\": 60, \"沟通与协作\": 20, \"编程开发\": 10, \"待机与离席\": 10 }",
            "}",
            "",
            "注意：\(tailNote)语言平实、符合上述周期的风格定位；一切结论必须建立在上面的事实数据之上。"
        ].joined(separator: "\n")
    }

    static func parseSummary(_ text: String) -> SummarizeResult {
        let cleaned = stripThinking(text)
        var out = SummarizeResult()
        out.raw = cleaned
        if let obj = extractJson(cleaned) {
            if let o = obj["overview"] as? String { out.overview = String(o.prefix(300)) }
            if let arr = obj["sections"] as? [Any] {
                out.sections = arr.map { String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .prefix(6).map { $0 }
            }
            if let cp = obj["category_percent"] as? [String: Any] {
                for (k, v) in cp {
                    let n: Double? = (v as? Double) ?? (v as? Int).map(Double.init) ?? Double(String(describing: v))
                    if let n, n > 0 { out.categoryPercent[k] = Int(n.rounded()) }
                }
            }
        }
        if out.sections.isEmpty {
            out.sections = cleaned.components(separatedBy: .newlines)
                .map { line -> String in
                    var l = line
                    while let f = l.first, " \t0123456789.、)）-—".contains(f) { l.removeFirst() }
                    return l.trimmingCharacters(in: .whitespaces)
                }
                .filter { $0.count > 6 && $0.count < 200 }
                .prefix(6).map { $0 }
        }
        return out
    }

    static func summarize(lines: [String], scope: String, rangeLabel: String, profile: ModelProfile, cfg: AppConfig) async -> SummarizeResult {
        let prompt = buildSummaryPrompt(scope: scope, rangeLabel: rangeLabel, lines: lines)
        return await coreSummarize(promptBody: prompt, profile: profile, cfg: cfg)
    }

    /// 新架构主路径：把「代码统计 + 关键事实」交给 AI 解释（AI 不重算统计）。
    static func summarizeDigest(scope: String, rangeLabel: String,
                                 statsBlock: String, facts: String,
                                 profile: ModelProfile, cfg: AppConfig) async -> SummarizeResult {
        let prompt = buildDigestSummaryPrompt(scope: scope, rangeLabel: rangeLabel,
                                                statsBlock: statsBlock, facts: facts)
        return await coreSummarize(promptBody: prompt, profile: profile, cfg: cfg)
    }

    /// 网络核心（两种摘要公共）：发请求、解析、空内容校验。
    private static func coreSummarize(promptBody: String, profile: ModelProfile, cfg: AppConfig) async -> SummarizeResult {
        var body: [String: Any] = [
            "model": profile.modelName,
            "messages": [
                ["role": "system", "content": summarySystem],
                ["role": "user", "content": promptBody]
            ],
            "max_tokens": cfg.summaryMaxTokens > 0 ? cfg.summaryMaxTokens : 1400,
            "temperature": 0.4,
            "top_p": 0.9,
            "stream": false
        ]
        // 思考模式开关：DeepSeek 思考模式下 temperature/top_p 不生效，关思考后参数才有效
        Analyzer.applyThinking(&body, profile: profile)
        var out = SummarizeResult()
        guard let url = endpoint(profile.endpoint, "/chat/completions") else {
            out.error = "API 地址无效"
            return out
        }
        let key = ModelRouter.apiKey(for: profile)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key.isEmpty ? "none" : key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let started = Date()
        do {
            let (data, resp) = try await session(timeoutSec: cfg.summaryTimeoutSec).data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let txt = String(data: data.prefix(200), encoding: .utf8) ?? ""
                out.error = Analyzer.friendlyError("HTTP \(code) \(txt)")
                return out
            }
            let root = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let choice = (root["choices"] as? [[String: Any]])?.first ?? [:]
            let msg = choice["message"] as? [String: Any] ?? [:]
            let content = (msg["content"] as? String) ?? ""
            var parsed = parseSummary(content)
            // 内容为空校验：推理模型（如 deepseek-v4-flash）思考过程也占用 max_tokens，
            // 预算耗尽时 content 为空、只有 reasoning_content —— 此时必须报错而非静默生成空白回忆
            let reasoning = (msg["reasoning_content"] as? String) ?? ""
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (parsed.overview.isEmpty && parsed.sections.isEmpty) {
                parsed.ok = false
                parsed.error = reasoning.isEmpty
                    ? "模型未返回有效内容（返回为空），请重试或更换模型。"
                    : "模型思考内容过长，未输出总结正文。请增大「单次请求超时」或更换为非推理模型。"
                parsed.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
                return parsed
            }
            parsed.ok = true
            parsed.model = (root["model"] as? String) ?? profile.modelName
            parsed.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            return parsed
        } catch {
            out.error = error.localizedDescription
            out.latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            return out
        }
    }

    /// 把模型 API 返回的晦涩错误翻译成用户能看懂的话（对应 recorder.js friendlyError）
    /// ⚠️ 匹配顺序铁律：先鉴权 → 再连接/离线 → 最后才是"不支持图像"。
    ///    错误 JSON 里常有 `code: "invalid_request_error"`，若 image 分支在前会误判为"不支持图像"。
    static func friendlyError(_ msg: String?) -> String {
        let s = msg ?? ""
        let lower = s.lowercased()
        func has(_ pats: [String]) -> Bool { pats.contains { lower.contains($0) } }

        // 1) 鉴权失败（401/unauthorized/api key 相关）—— 优先于一切，防止 invalid_request 误判
        if has(["401", "unauthorized", "invalid api key", "api key is invalid", "authentication fails"]) {
            return "API Key 无效或未授权，请检查「模型」设置中的 API Key"
        }
        // 2) 连接/离线
        if has(["could not connect", "connection refused", "cannot connect", "failed to connect",
                "offline", "无法连接", "拒绝连接", "connection reset", "network is unreachable"]) {
            return "模型离线，无法执行操作。请确认本地模型（oMLX）已启动，或检查网络与模型地址。"
        }
        if has(["timeout", "timed out", "abort", "已超时", "请求超时"]) {
            return "请求超时，请检查网络或增大超时时间"
        }
        if lower.contains("403") { return "接口拒绝访问（403），请检查权限或账号额度" }
        if has(["429", "rate limit", "rate-limit", "ratelimit"]) { return "请求频率受限（429），请稍后再试或降低截屏频率" }
        // 3) 不支持图像（仅瞬息/一念分析截图时才可能遇到）
        if has(["image_url", "unknown variant", "expected `text", "expected \"text", "expected 'text", "unsupported modality"]) {
            return "当前模型不支持图像输入（纯文本模型），请在设置中更换支持视觉的模型，如 gpt-4o-mini、qwen-vl-max、glm-4v 等"
        }
        if has(["invalid_request"]) {
            return "请求参数有误（invalid_request），请检查模型名是否正确"
        }
        return s
    }
}
