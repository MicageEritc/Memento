import AppKit
import UniformTypeIdentifiers

/// 系统对话框封装 —— 对应 Electron 版 `dialog:confirm` / `showSaveDialog` / `showOpenDialog`
@MainActor
enum Dialogs {

    private static var keyWindow: NSWindow? {
        NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
    }

    /// 删除确认（按钮顺序与原版一致：取消 / 删除，默认取消）
    @discardableResult
    static func confirmDelete(message: String, detail: String = "") -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = message
        a.informativeText = detail
        let del = a.addButton(withTitle: "删除")
        a.addButton(withTitle: "取消")
        del.hasDestructiveAction = true
        // 让「取消」成为 Esc / 默认安全出口
        a.buttons.last?.keyEquivalent = "\u{1b}"
        return a.runModal() == .alertFirstButtonReturn
    }

    /// 纯提示（对应原版用 confirm 弹的单纯消息）
    static func info(_ message: String, detail: String = "") {
        let a = NSAlert()
        a.alertStyle = .informational
        a.messageText = message
        a.informativeText = detail
        a.addButton(withTitle: "好")
        a.runModal()
    }

    /// 通用确认
    static func confirm(_ message: String, detail: String = "",
                        ok: String = "确定", cancel: String = "取消") -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = message
        a.informativeText = detail
        a.addButton(withTitle: ok)
        a.addButton(withTitle: cancel)
        a.buttons.last?.keyEquivalent = "\u{1b}"
        return a.runModal() == .alertFirstButtonReturn
    }

    /// 选择数据保存目录（对应 `cfg:pickFolder`）
    static func pickFolder(current: String) -> URL? {
        let p = NSOpenPanel()
        p.title = "选择保存目录"
        p.prompt = "选择"
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        if !current.isEmpty, FileManager.default.fileExists(atPath: current) {
            p.directoryURL = URL(fileURLWithPath: current)
        }
        return p.runModal() == .OK ? p.url : nil
    }

    /// 导出备份的保存位置（默认桌面，扩展名 .bak）
    static func saveBackup(defaultName: String) -> URL? {
        let p = NSSavePanel()
        p.title = "导出备份"
        p.prompt = "导出"
        p.nameFieldStringValue = defaultName
        p.directoryURL = AppPaths.home.appendingPathComponent("Desktop")
        p.canCreateDirectories = true
        p.allowedContentTypes = [bakType]
        p.allowsOtherFileTypes = false
        return p.runModal() == .OK ? p.url : nil
    }

    /// 选择要导入的 .bak
    static func openBackup() -> URL? {
        let p = NSOpenPanel()
        p.title = "导入备份"
        p.prompt = "导入"
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = false
        p.allowedContentTypes = [bakType]
        return p.runModal() == .OK ? p.url : nil
    }

    private static var bakType: UTType {
        UTType(filenameExtension: "bak") ?? .data
    }

    // MARK: - Finder

    /// 打开目录（对应 `fs:openFolder` → shell.openPath）
    static func openFolder(_ path: String) {
        guard !path.isEmpty else { return }
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        NSWorkspace.shared.open(url)
    }

    /// 在访达中定位文件（对应 `fs:reveal` → shell.showItemInFolder）
    static func reveal(_ path: String) {
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// 打开"系统设置 → 隐私与安全性 → 屏幕录制"（对应 `perm:open`）
    static func openScreenRecordingSettings() {
        let u = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        if let url = URL(string: u) { NSWorkspace.shared.open(url) }
    }
}
