import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - AppState · 随想 AI 与导出
//
// 职责：把工具栏的「AI 总结 / 润色」与「... 导出」动作编排到具体能力。
// 铁律：AI 只是辅助编辑，绝不直接改写用户原始正文——
//   - 总结：仅生成摘要展示/复制，不落盘到正文。
//   - 润色：生成预览，用户点「使用润色结果」才由 applyMusePolish 回写。
//   - 三种导出只读取当前笔记，绝不修改/删除原始数据。

extension AppState {

    /// AI 面板模式（驱动 MusePanel 的 .sheet）
    enum MuseAISheet: Identifiable {
        case summary, polish
        var id: String { "\(self)" }
    }

    // MARK: AI 总结

    /// 点击「总结」：
    /// - 已有缓存（内存或笔记持久化的 aiSummaryCache）→ 直接显示上次总结，不重新请求；
    ///   面板内提供「再次总结」按钮。
    /// - 没有 → 立即生成。
    /// 缓存持久化在 note.json，重启 app 后仍可复用，不会重复自动生成。
    func requestMuseSummary() {
        guard let note = currentMuseNote else { return }
        // 优先内存缓存，其次笔记持久化缓存
        let cachedText: String?
        if let c = museCachedSummary, c.noteId == note.id, !c.text.isEmpty {
            cachedText = c.text
        } else if let disk = note.aiSummaryCache, !disk.isEmpty {
            cachedText = disk
            museCachedSummary = (note.id, disk)
        } else {
            cachedText = nil
        }
        if let t = cachedText, !t.isEmpty {
            museAISummary = t
            museAILoading = false
            museAIError = nil
            museAISheet = .summary
            return
        }
        summarizeMuseNow()
    }

    /// 强制重新生成总结（「再次总结」按钮 / 首次请求）。
    private func summarizeMuseNow() {
        guard let note = currentMuseNote else { return }
        let att = liveAttributedSync(note)
        let plain = musePlainText(att)
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Dialogs.info("还没有可以总结的内容。")
            return
        }
        let full = "标题：\(note.title)\n\n\(plain)"
        museAILoading = true
        museAIError = nil
        museAISummary = ""
        museAISheet = .summary
        Task { [weak self] in
            let cfg = ConfigStore.shared.current
            guard let profile = ModelRouter.profile(for: .muse, in: cfg) else {
                await MainActor.run {
                    guard let self else { return }
                    self.museAILoading = false
                    self.museAIError = "未配置可用模型，请在「模型」设置中分配模型。"
                }
                return
            }
            await MainActor.run {
                guard let self else { return }
                self.museAIModelLabel = "\(profile.kind.label) · \(profile.modelName)"
                if self.modelOffline(profile.id) {
                    self.museAILoading = false
                    self.museAIError = "模型离线（\(profile.name)），无法进行 AI 总结。请确认本地模型已启动或检查网络。"
                    return
                }
            }
            let r = await MuseAI.summarize(text: full, profile: profile, cfg: cfg)
            await MainActor.run {
                guard let self else { return }
                self.museAILoading = false
                switch r {
                case .success(let t):
                    self.museAISummary = t
                    self.museCachedSummary = (note.id, t)
                    // 持久化缓存：写回 note.json，重启后仍可复用
                    Task {
                        var updated = note
                        updated.aiSummaryCache = t
                        await self.museStore.saveMeta(updated)
                        if let i = self.museNotes.firstIndex(where: { $0.id == updated.id }) {
                            self.museNotes[i] = updated
                        }
                    }
                case .failure(let e): self.museAIError = e.message
                }
            }
        }
    }

    /// 「再次总结」按钮：无视缓存，重新请求生成。
    func regenerateMuseSummary() {
        summarizeMuseNow()
    }

    // MARK: AI 润色

    func requestMusePolish() {
        guard let note = currentMuseNote else { return }
        let att = liveAttributedSync(note)
        let plain = musePlainText(att)
        guard !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Dialogs.info("还没有可以润色的内容。")
            return
        }
        musePolishOriginal = plain
        musePolishResult = ""
        museAILoading = true
        museAIError = nil
        museAISheet = .polish
        Task { [weak self] in
            let cfg = ConfigStore.shared.current
            guard let profile = ModelRouter.profile(for: .muse, in: cfg) else {
                await MainActor.run {
                    guard let self else { return }
                    self.museAILoading = false
                    self.museAIError = "未配置可用模型，请在「模型」设置中分配模型。"
                }
                return
            }
            await MainActor.run {
                guard let self else { return }
                self.museAIModelLabel = "\(profile.kind.label) · \(profile.modelName)"
                if self.modelOffline(profile.id) {
                    self.museAILoading = false
                    self.museAIError = "模型离线（\(profile.name)），无法进行 AI 润色。请确认本地模型已启动或检查网络。"
                    return
                }
            }
            let r = await MuseAI.polish(text: plain, profile: profile, cfg: cfg)
            await MainActor.run {
                guard let self else { return }
                self.museAILoading = false
                switch r {
                case .success(let t): self.musePolishResult = t
                case .failure(let e): self.museAIError = e.message
                }
            }
        }
    }

    /// 用户确认后，把润色结果写回编辑器（替换原文）。
    /// 仅在此时才修改正文；取消则 museAISheet = nil，原文不变。
    /// 替换前注册 undo（恢复原文），后悔时 cmd+z 可撤回。
    func applyMusePolish() {
        let text = musePolishResult
        guard !text.isEmpty else { return }
        let att = NSAttributedString(string: text, attributes: MuseRichText.defaultBodyAttrs())
        guard let tv = RichTextEditor.Coordinator.shared?.textView,
              let storage = tv.textStorage else { return }
        let old = storage.attributedSubstring(from: NSRange(location: 0, length: storage.length))
        if let um = tv.undoManager {
            um.registerUndo(withTarget: tv) { target in
                MuseFormatOps.restoreBody(target, old: old)
            }
            um.setActionName("AI 润色")
        }
        tv.textStorage?.beginEditing()
        tv.textStorage?.setAttributedString(MuseRichText.normalize(att))
        tv.textStorage?.endEditing()
        tv.didChangeText()   // 触发自动保存落盘
        museAISheet = nil
    }

    /// 把 AI 总结存为独立 Tip（不进富文本正文）：note.aiSummary + 落盘元数据。
    /// 规则：已有 AI 总结时禁止再次插入（需先「隐藏」= 彻底移除后才能再插入）。
    func applyMuseSummaryInsert() {
        let summary = museAISummary
        guard !summary.isEmpty else { return }
        guard let note = currentMuseNote else { return }
        // 已插入过 Tip → 拒绝（隐藏 = 彻底移除后才可再插）
        if let existing = note.aiSummary, !existing.isEmpty {
            Dialogs.info("已插入过 AI 总结", detail: "请先隐藏当前的 AI 总结（彻底移除），再插入新的。")
            museAISheet = nil
            return
        }
        // 写入 Tip + 落盘元数据（不动正文 RTF）
        Task { [weak self] in
            guard let self else { return }
            var updated = note
            updated.aiSummary = summary
            updated.updatedAt = DateUtil.isoLocal(Date())
            await self.museStore.saveMeta(updated)
            // 刷新内存列表
            if let i = self.museNotes.firstIndex(where: { $0.id == updated.id }) {
                self.museNotes[i] = updated
            }
        }
        museAISheet = nil
    }

    /// 小眼睛：折叠 / 展开 AI 总结 Tip（数据保留，仅视觉收起；不改 updatedAt 避免打乱排序）
    func toggleMuseSummaryTipHidden() {
        guard let note = currentMuseNote, note.aiSummary != nil else { return }
        Task { [weak self] in
            guard let self else { return }
            var updated = note
            updated.aiSummaryHidden.toggle()
            await self.museStore.saveMeta(updated)
            if let i = self.museNotes.firstIndex(where: { $0.id == updated.id }) {
                self.museNotes[i] = updated
            }
        }
    }

    /// AI 面板「隐藏」= 彻底删除 AI 总结 Tip（数据清除，正文区不留任何痕迹）。
    /// 之后按钮回到「插入」，可再次插入新的总结。
    func removeMuseSummaryTip() {
        guard let note = currentMuseNote, note.aiSummary != nil else { return }
        Log.shared.info("muse tip | REMOVE aiSummary=\(note.aiSummary?.prefix(20) ?? "")")
        Task { [weak self] in
            guard let self else { return }
            var updated = note
            updated.aiSummary = nil
            updated.aiSummaryHidden = false
            await self.museStore.saveMeta(updated)
            if let i = self.museNotes.firstIndex(where: { $0.id == updated.id }) {
                self.museNotes[i] = updated
                Log.shared.info("muse tip | REMOVE done, list updated i=\(i)")
            }
        }
    }

    // MARK: 导出 · 入口（弹面板）

    func requestMuseExportMarkdown() {
        guard let note = currentMuseNote else { return }
        let panel = NSOpenPanel()
        panel.title = "导出 Markdown 笔记"
        panel.prompt = "导出"
        panel.message = "将创建「\(note.displayTitle)」文件夹（含 .md 与 assets/）"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.begin { [weak self] resp in
            guard resp == .OK, let parent = panel.url else { return }
            Task { await self?.doExportMarkdown(note: note, parent: parent) }
        }
    }

    func requestMuseExportPDF() {
        guard let note = currentMuseNote else { return }
        let panel = NSSavePanel()
        panel.title = "导出 PDF"
        panel.prompt = "导出"
        panel.nameFieldStringValue = "\(note.displayTitle).pdf"
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { await self?.doExportPDF(note: note, url: url) }
        }
    }

    func requestMuseExportRaw() {
        guard let note = currentMuseNote else { return }
        let panel = NSSavePanel()
        panel.title = "导出原始文件"
        panel.prompt = "导出"
        panel.nameFieldStringValue = "\(note.displayTitle).zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.begin { [weak self] resp in
            guard resp == .OK, let url = panel.url else { return }
            Task { await self?.doExportRaw(note: note, url: url) }
        }
    }

    // MARK: 导出 · 实现

    private func doExportMarkdown(note: MuseNote, parent: URL) async {
        await flushMuseSaveAndWait()
        let att = await liveAttributed(note)
        let disk = await museStore.loadAttachments(id: note.id)
        let (md, assets) = MuseExport.buildMarkdown(title: note.displayTitle,
                                                     attributed: att, diskAttachments: disk)
        let ok = MuseExport.writeMarkdown(parent: parent, displayTitle: note.displayTitle, md: md, assets: assets)
        await MainActor.run {
            if ok {
                let folder = MuseExport.sanitizeFolder(note.displayTitle)
                Dialogs.info("已导出 Markdown 笔记",
                             detail: "\(parent.path)/\(folder)/\(folder).md")
            } else {
                Dialogs.info("导出失败", detail: "无法写入文件，请检查目录权限。")
            }
        }
    }

    private func doExportPDF(note: MuseNote, url: URL) async {
        await flushMuseSaveAndWait()
        let att = await liveAttributed(note)
        guard let data = MuseExport.makePDF(title: note.displayTitle, attributed: att) else {
            await MainActor.run { Dialogs.info("导出失败", detail: "PDF 生成出错。") }
            return
        }
        do { try data.write(to: url) }
        catch {
            await MainActor.run { Dialogs.info("导出失败", detail: error.localizedDescription) }
            return
        }
        await MainActor.run { Dialogs.info("已导出 PDF", detail: url.path) }
    }

    private func doExportRaw(note: MuseNote, url: URL) async {
        await flushMuseSaveAndWait()
        let noteDir = await museStore.noteDir(note.id)
        let ok = MuseExport.zipNoteDir(noteDir, title: note.displayTitle, to: url)
        await MainActor.run {
            if ok { Dialogs.info("已导出原始文件", detail: url.path) }
            else { Dialogs.info("导出失败", detail: "无法打包笔记目录，请检查权限。") }
        }
    }

    // MARK: 辅助

    /// 取当前编辑器实时内容；空则回退到磁盘加载。
    private func liveAttributed(_ note: MuseNote) async -> NSAttributedString {
        if let tv = RichTextEditor.Coordinator.shared?.textView, tv.attributedString().length > 0 {
            return tv.attributedString()
        }
        return await loadMuseRichText(id: note.id)
    }

    /// 同步取实时内容（在 @MainActor 调用方直接读，无需 await）
    private func liveAttributedSync(_ note: MuseNote) -> NSAttributedString {
        if let tv = RichTextEditor.Coordinator.shared?.textView, tv.attributedString().length > 0 {
            return tv.attributedString()
        }
        return NSAttributedString()
    }

    /// 纯文本（去除附件占位符 U+FFFC 与分割线标记）
    private func musePlainText(_ att: NSAttributedString) -> String {
        att.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: museDividerMarker, with: "")
    }

    /// 同步落盘当前待保存草稿（导出前确保磁盘内容最新），不改动笔记其他数据。
    func flushMuseSaveAndWait() async {
        museSaveTask?.cancel()
        museSaveTask = nil
        guard musePending != nil else { return }
        await commitMuseDraft()
    }
}
