import Foundation

// MARK: - 随想 AI 助手（总结 / 润色）
//
// 复用应用已配置好的 OpenAI 兼容模型（ConfigStore.shared.current），
// 纯文本调用 /chat/completions，不处理图片。
//
// AI 定位（产品铁律）：只做辅助编辑，绝不直接改动用户原始正文。
// - 总结：生成摘要，供用户查看/复制，不写入正文。
// - 润色：生成润色稿，用户确认后才由调用方回写（applyMusePolish）。

/// AI 调用失败（携带给用户看的中文错误信息）
struct MuseAIError: Error {
    let message: String
    var localizedDescription: String { message }
}

enum MuseAI {

    /// 纯文本对话：复用 Analyzer 的友好错误翻译与思考链清洗。
    private static func chat(system: String, user: String, profile: ModelProfile, cfg: AppConfig) async -> Result<String, MuseAIError> {
        guard !profile.endpoint.isEmpty else {
            return .failure(MuseAIError(message: "未配置 AI 模型（API 地址为空），请在「模型」设置中分配模型。"))
        }
        let body: [String: Any] = {
            var b: [String: Any] = [
                "model": profile.modelName,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user]
                ],
                "max_tokens": 2048,
                "temperature": 0.4,
                "top_p": 0.9,
                "stream": false
            ]
            Analyzer.applyThinking(&b, profile: profile)
            return b
        }()
        var base = profile.endpoint
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + "/chat/completions") else {
            return .failure(MuseAIError(message: "AI 接口地址无效：\(profile.endpoint)"))
        }
        let key = ModelRouter.apiKey(for: profile)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key.isEmpty ? "none" : key)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let started = Date()
        do {
            let (data, resp) = try await session(timeoutSec: cfg.requestTimeoutSec).data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                let txt = String(data: data.prefix(300), encoding: .utf8) ?? ""
                return .failure(MuseAIError(message: Analyzer.friendlyError("HTTP \(code) \(txt)")))
            }
            let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let choice = (root["choices"] as? [[String: Any]])?.first ?? [:]
            let msg = choice["message"] as? [String: Any] ?? [:]
            let content = (msg["content"] as? String) ?? (msg["reasoning_content"] as? String) ?? ""
            let cleaned = Analyzer.stripThinking(content).trimmingCharacters(in: .whitespacesAndNewlines)
            if cleaned.isEmpty { return .failure(MuseAIError(message: "AI 返回内容为空，请重试。")) }
            return .success(cleaned)
        } catch {
            return .failure(MuseAIError(message: Analyzer.friendlyError(error.localizedDescription)))
        }
    }

    /// AI 总结：把随想正文压缩成一段简洁中文摘要（≤200 字）。
    static func summarize(text: String, profile: ModelProfile, cfg: AppConfig) async -> Result<String, MuseAIError> {
        let sys = "你是一个写作助手，负责把用户的随想内容总结成简洁、准确的中文摘要。只基于原文事实，不编造原文没有的内容。"
        let user = "请用一段简洁、连贯的中文总结下面的随想内容，保留核心要点与关键信息，不超过 200 字。" +
                   "只输出摘要本身，不要解释、不要分点、不要使用 markdown 代码块：\n\n\(text)"
        return await chat(system: sys, user: user, profile: profile, cfg: cfg)
    }

    /// AI 润色：优化语言表达、通顺度与结构，保留原文核心意思，
    /// 不擅自增加原文没有表达的事实或观点。返回润色后的全文（纯文本）。
    static func polish(text: String, profile: ModelProfile, cfg: AppConfig) async -> Result<String, MuseAIError> {
        let sys = "你是一个中文写作润色助手，负责优化用户随想的语言表达、语句通顺度与段落结构。"
        let user = "请润色下面的中文随想：优化语言表达、语句通顺度和段落结构，保留原文的核心意思与原有事实，" +
                   "不要擅自增加原文没有表达的事实、观点或虚构细节。直接返回润色后的全文，" +
                   "不要任何解释、不要使用 markdown 代码块、不要用 ``` 包裹：\n\n\(text)"
        return await chat(system: sys, user: user, profile: profile, cfg: cfg)
    }

    private static func session(timeoutSec: Int) -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = Double(max(5, timeoutSec))
        c.timeoutIntervalForResource = Double(max(5, timeoutSec))
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }
}
