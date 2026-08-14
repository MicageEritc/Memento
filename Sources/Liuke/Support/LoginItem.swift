import Foundation
import ServiceManagement

/// 开机自启 —— 对应 Electron 版 `app.setLoginItemSettings({ openAtLogin })`
///
/// macOS 13+ 用 SMAppService.mainApp（系统设置里可见、可被用户关掉）；
/// 更老的系统降级为 LaunchAgent plist（写到 ~/Library/LaunchAgents）。
enum LoginItem {

    private static let agentLabel = "app.memento.lens.launcher"

    /// 当前是否已开启（读不到就返回 nil，调用方沿用配置里的值）
    static var isEnabled: Bool? {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return true
            case .notRegistered, .notFound: return false
            default: return nil          // .requiresApproval 等 → 让用户自己在系统设置里处理
            }
        }
        return FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    static func set(enabled: Bool) {
        // 开发态（swift run，不是 .app）不注册，避免把命令行可执行文件写进登录项
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }

        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
            } catch {
                Log.shared.warn("设置开机自启失败：\(error.localizedDescription)")
            }
            return
        }
        legacySet(enabled: enabled)
    }

    // MARK: - macOS 12 及更早：LaunchAgent

    private static var agentPlistURL: URL {
        AppPaths.home
            .appendingPathComponent("Library/LaunchAgents")
            .appendingPathComponent("\(agentLabel).plist")
    }

    private static func legacySet(enabled: Bool) {
        let url = agentPlistURL
        let fm = FileManager.default
        if !enabled {
            try? fm.removeItem(at: url)
            return
        }
        let appPath = Bundle.main.bundleURL.path
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": ["/usr/bin/open", "-a", appPath],
            "RunAtLoad": true
        ]
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.shared.warn("写入 LaunchAgent 失败：\(error.localizedDescription)")
        }
    }
}
