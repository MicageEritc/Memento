import Foundation

/// 模型路由：根据 AI 功能解析应使用哪个模型配置。
/// 这是「多模型」的唯一来源 —— 瞬息/一念/全景/随想都经此取模型，不再各自保存 API 地址与 Key。
enum ModelRouter {

    /// 解析某功能当前应使用的模型。
    /// 优先使用分配且启用、且满足能力要求的模型；
    /// 若分配失效则回退到第一个满足条件的启用模型；再退到第一个启用模型。
    static func profile(for fn: AIFunction, in cfg: AppConfig) -> ModelProfile? {
        let all = cfg.models
        guard !all.isEmpty else { return nil }
        let enabled = all.filter { $0.enabled }

        if let assignedId = cfg.modelAssignments[fn.rawValue],
           let p = enabled.first(where: { $0.id == assignedId }),
           satisfies(p, fn: fn) {
            return p
        }
        if let fallback = enabled.first(where: { satisfies($0, fn: fn) }) {
            return fallback
        }
        return enabled.first ?? all.first
    }

    /// 该模型是否满足功能的能力要求（如瞬息/一念要求视觉能力）
    /// 仅「明确不支持图片」(unsupported) 才不满足；未检测(unknown) 放行，交由运行时兜底
    static func satisfies(_ p: ModelProfile, fn: AIFunction) -> Bool {
        if fn.requiresVision, p.capabilities.vision == .unsupported { return false }
        return true
    }

    /// 读取模型的实际 API Key。
    /// v3 起 API Key 明文存 config.json（`profile.apiKey`），彻底不再访问 Keychain，
    /// 从根上杜绝 macOS 钥匙串授权弹窗。仅当明文为空时，为兼容旧版回退读一次 Keychain。
    static func apiKey(for p: ModelProfile) -> String {
        if !p.apiKey.isEmpty { return p.apiKey }
        // 旧数据兼容：曾用 Keychain 存储（.v3 宽松 ACL，无弹窗风险）
        if !p.apiKeyRef.isEmpty {
            let k = KeychainStore.shared.get(forKey: p.apiKeyRef)
            if let k, !k.isEmpty { return k }
        }
        return ""
    }
}
