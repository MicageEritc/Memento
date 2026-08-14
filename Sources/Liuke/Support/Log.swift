import Foundation

/// 轻量文件日志 —— 落到 ~/Library/Application Support/留刻/lens.log
/// 与原 Electron 版路径完全一致，方便老公排查问题时还是同一个文件。
final class Log: @unchecked Sendable {

    static let shared = Log()

    private let queue = DispatchQueue(label: "app.memento.lens.log", qos: .utility)
    private let maxBytes: Int = 2 * 1024 * 1024   // 超过 2MB 自动轮转一次

    private(set) lazy var fileURL: URL = {
        let dir = AppPaths.userData
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lens.log")
    }()

    private init() {}

    func info(_ msg: String)  { write("INFO", msg) }
    func warn(_ msg: String)  { write("WARN", msg) }
    func error(_ msg: String) { write("ERROR", msg) }

    private func write(_ level: String, _ msg: String) {
        let line = "[\(DateUtil.isoLocal(Date()))] [\(level)] \(msg)\n"
        #if DEBUG
        FileHandle.standardError.write(Data(line.utf8))
        #endif
        queue.async { [self] in
            rotateIfNeeded()
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: fileURL.path) {
                if let h = try? FileHandle(forWritingTo: fileURL) {
                    defer { try? h.close() }
                    _ = try? h.seekToEnd()
                    try? h.write(contentsOf: data)
                }
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > maxBytes else { return }
        let old = fileURL.deletingLastPathComponent().appendingPathComponent("lens.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
    }
}

/// 应用相关路径
enum AppPaths {

    /// ~/Library/Application Support/留刻 —— 与 Electron 版 app.getPath('userData') 保持一致，
    /// 这样 Swift 版启动即可读到旧的 config.json，用户无感迁移。
    static var userData: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("留刻")
    }

    static var configFile: URL { userData.appendingPathComponent("config.json") }

    static var home: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    static var defaultOutputDir: URL { home.appendingPathComponent("Documents/留刻") }

    /// .app 内的 Resources 目录；开发态（swift run）回退到仓库里的 Resources/
    static var resources: URL {
        if let r = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: r.appendingPathComponent("brand-logo.png").path) {
            return r
        }
        // 开发态兜底：<repo>/Resources
        let devPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Support
            .deletingLastPathComponent()   // Liuke
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // <repo>
            .appendingPathComponent("Resources")
        return devPath
    }

    static func resource(_ name: String) -> URL { resources.appendingPathComponent(name) }
}
