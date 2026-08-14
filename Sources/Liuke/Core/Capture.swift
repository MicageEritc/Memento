import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit

/// 一次抓屏的结果
struct GrabbedScreen {
    var image: CGImage
    var displayId: String
    var label: String
    var isPrimary: Bool
    var nativeWidth: Int
    var nativeHeight: Int
}

struct FrontApp {
    var proc: String
    var name: String
}

enum PermissionState: String {
    case granted, denied, notDetermined = "not-determined", unknown
}

enum CaptureError: LocalizedError {
    case noScreen
    case emptyImage
    case noPermission

    var errorDescription: String? {
        switch self {
        case .noScreen:     return "未能获取任何屏幕源（可能缺少「屏幕录制」权限）"
        case .emptyImage:   return "截图内容为空，请检查「屏幕录制」权限是否已授予"
        case .noPermission: return "缺少「屏幕录制」权限，请在系统设置中授予后重启留刻"
        }
    }
}

/// 屏幕捕获 —— 对应 Electron 版 capture.js，底层换成 ScreenCaptureKit
enum Capture {

    /// macOS 前台应用进程名 → 展示名映射（与原版 FRONT_APP_MAP 完全一致）
    private static let frontAppMap: [String: String] = [
        "wechat": "微信", "weixin": "微信",
        "wecom": "企业微信", "wxwork": "企业微信", "wework": "企业微信",
        "wps": "WPS", "wpsoffice": "WPS", "kwps": "WPS", "wpscloudsvr": "WPS",
        "microsoft excel": "Excel", "microsoft word": "Word", "microsoft powerpoint": "PowerPoint",
        "google chrome": "Chrome", "chrome": "Chrome", "chromium": "Chrome",
        "safari": "Safari", "firefox": "Firefox",
        "visual studio code": "VS Code", "code": "VS Code", "code helper": "VS Code",
        "douyin": "抖音", "tiktok": "抖音", "bilibili": "哔哩哔哩", "youtube": "YouTube",
        "notion": "Notion", "figma": "Figma", "xmind": "XMind", "typora": "Typora",
        "dingtalk": "钉钉", "钉钉": "钉钉", "feishu": "飞书", "lark": "飞书", "slack": "Slack",
        "netease music": "网易云音乐", "qqmusic": "QQ音乐",
        "iterm": "iTerm", "terminal": "终端", "alacritty": "终端", "warp": "Warp",
        "microsoft teams": "Teams", "团队": "Teams"
    ]

    // MARK: - 权限

    /// 实测状态缓存：系统 API 在新 bundle 首启时可能滞后，用真实抓屏结果兜底
    nonisolated(unsafe) private static var grabProbed = false
    nonisolated(unsafe) private static var grabFailed = false
    private static let stateLock = NSLock()

    static func reportGrabResult(_ err: Error?) {
        stateLock.lock(); defer { stateLock.unlock() }
        grabProbed = true
        grabFailed = (err != nil)
    }

    static func permissionStatus() -> PermissionState {
        // CGPreflightScreenCaptureAccess 不会弹窗，只查状态
        if CGPreflightScreenCaptureAccess() { return .granted }
        stateLock.lock()
        let probed = grabProbed
        let failed = grabFailed
        stateLock.unlock()
        if probed { return failed ? .denied : .granted }
        return .notDetermined
    }

    private static let requestedKey = "lens.screenCaptureRequested"

    /// 仅未决定时请求一次；已授权/已拒绝都不弹窗
    @discardableResult
    static func requestPermissionIfNeeded() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            reportGrabResult(nil)
            UserDefaults.standard.set(true, forKey: requestedKey)
            return true
        }
        if UserDefaults.standard.bool(forKey: requestedKey) {
            return false
        }
        // 触发系统授权请求（仅首次）
        let ok = CGRequestScreenCaptureAccess()
        UserDefaults.standard.set(true, forKey: requestedKey)
        if ok { reportGrabResult(nil); return true }
        // 再用 SCShareableContent 兜底探测一次
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if !content.displays.isEmpty {
                reportGrabResult(nil)
                return true
            }
        } catch {
            reportGrabResult(error)
        }
        return false
    }

    static func openPermissionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - 前台应用 / 窗口标题

    @MainActor private static var frontAppCache: FrontApp?
    @MainActor private static var frontAppCacheAt: TimeInterval = 0

    /// 前台应用。用 NSWorkspace 直接取，不需要辅助功能权限（比原版 osascript 更快更稳）
    @MainActor
    static func getFrontApp() -> FrontApp? {
        let now = Date().timeIntervalSince1970
        if let c = frontAppCache, now - frontAppCacheAt < 5 { return c }
        guard let app = NSWorkspace.shared.frontmostApplication else {
            frontAppCache = nil
            frontAppCacheAt = now
            return nil
        }
        let proc = app.localizedName
            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? "未知"
        let name = frontAppMap[proc.lowercased()] ?? proc
        let fa = FrontApp(proc: proc, name: name)
        frontAppCache = fa
        frontAppCacheAt = now
        return fa
    }

    /// 当前打开的窗口标题（去重，最多 6 个）。用 CGWindowList，只需录屏权限。
    static func getWindowTitles() -> [String] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var seen = Set<String>()
        var out: [String] = []
        for info in list {
            // 过滤掉无标题、系统层的窗口
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            guard layer == 0 else { continue }
            let title = ((info[kCGWindowName as String] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !seen.contains(title) else { continue }
            seen.insert(title)
            out.append(title)
            if out.count >= 6 { break }
        }
        // CGWindowName 需要录屏权限才有值；拿不到就退回用应用名
        if out.isEmpty {
            var apps = Set<String>()
            for info in list {
                if let owner = info[kCGWindowOwnerName as String] as? String, !owner.isEmpty {
                    apps.insert(owner)
                }
                if apps.count >= 6 { break }
            }
            out = Array(apps).sorted()
        }
        return out
    }

    // MARK: - 抓屏

    private struct DisplayMeta {
        var displayID: CGDirectDisplayID
        var scale: Double
        var index: Int
    }

    @MainActor
    private static func displayMetas() -> [CGDirectDisplayID: DisplayMeta] {
        var out: [CGDirectDisplayID: DisplayMeta] = [:]
        for (i, s) in NSScreen.screens.enumerated() {
            guard let num = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let id = CGDirectDisplayID(num.uint32Value)
            out[id] = DisplayMeta(displayID: id, scale: Double(s.backingScaleFactor), index: i)
        }
        return out
    }

    /// 抓取屏幕（主屏，或开启多屏时抓全部）
    static func grab(_ cfg: AppConfig) async throws -> [GrabbedScreen] {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw CaptureError.noPermission
        }
        guard !content.displays.isEmpty else { throw CaptureError.noScreen }

        let mainID = CGMainDisplayID()
        let metas = await MainActor.run { displayMetas() }

        var targets: [SCDisplay]
        if cfg.captureAllDisplays && content.displays.count > 1 {
            // 主屏排最前，其余按 displayID 稳定排序
            targets = content.displays.sorted { a, b in
                if a.displayID == mainID { return true }
                if b.displayID == mainID { return false }
                return a.displayID < b.displayID
            }
        } else {
            targets = [content.displays.first(where: { $0.displayID == mainID }) ?? content.displays[0]]
        }

        // 以最大的一块屏为准算目标框（与原版 thumbnailSize 语义一致）
        var maxW = 0, maxH = 0
        for d in targets {
            let scale = metas[d.displayID]?.scale ?? 2.0
            let w = Int((Double(d.width) * scale).rounded())
            let h = Int((Double(d.height) * scale).rounded())
            if w > maxW { maxW = w; maxH = h }
        }
        let targetW = min(cfg.saveWidth, maxW > 0 ? maxW : cfg.saveWidth)
        let ratio = maxW > 0 ? Double(targetW) / Double(maxW) : 1
        let targetH = max(1, Int((Double(maxH > 0 ? maxH : 900) * ratio).rounded()))

        var out: [GrabbedScreen] = []
        for d in targets {
            let scale = metas[d.displayID]?.scale ?? 2.0
            let nativeW = Int((Double(d.width) * scale).rounded())
            let nativeH = Int((Double(d.height) * scale).rounded())

            // fit 进 (targetW, targetH) 框，保持宽高比
            let s = min(Double(targetW) / Double(max(1, nativeW)),
                        Double(targetH) / Double(max(1, nativeH)), 1.0)
            let outW = max(2, Int((Double(nativeW) * s).rounded()) & ~1)   // 偶数宽，SCK 更友好
            let outH = max(2, Int((Double(nativeH) * s).rounded()) & ~1)

            let filter = SCContentFilter(display: d, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = outW
            config.height = outH
            config.scalesToFit = true
            config.showsCursor = false          // 与原版一致：不含光标，避免误判画面变化
            config.captureResolution = .best
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.colorSpaceName = CGColorSpace.sRGB

            do {
                let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let idx = (metas[d.displayID]?.index ?? out.count)
                out.append(GrabbedScreen(
                    image: img,
                    displayId: String(d.displayID),
                    label: "屏幕 \(idx + 1)",
                    isPrimary: d.displayID == mainID,
                    nativeWidth: nativeW,
                    nativeHeight: nativeH
                ))
            } catch {
                Log.shared.warn("display \(d.displayID) capture failed: \(error.localizedDescription)")
                continue
            }
        }

        guard !out.isEmpty else { throw CaptureError.emptyImage }
        return out
    }
}
