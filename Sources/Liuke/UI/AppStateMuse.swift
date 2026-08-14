import SwiftUI
import AppKit

/// 编辑区待落盘草稿（防抖自动保存的载体；content = 富文本）
struct MuseDraft: Equatable {
    var id: String
    var title: String
    var content: NSAttributedString
}

/// 分组编辑弹窗模式（2026-08-11 第四轮新增）
/// `.create` = 新建分组（输入初始名）
/// `.rename(id, name)` = 重命名分组（输入新名）
enum MuseGroupDialog: Equatable {
    case create
    case rename(id: String, name: String)
}

// MARK: - AppState · 随想模块
//
// 职责边界：只管「列表加载 / 新建 / 选中 / 自动保存 / 删除 / 分组」这些基础能力。
// 不含 AI 总结、全景分析、搜索索引 —— 那些留给后续迭代。
//
// 自动保存策略：
//   编辑器内部用 @State 持有草稿（打字不触发全局刷新，中文输入法不中断），
//   每次变更调 scheduleMuseSave 打点 → 防抖 700ms 落盘 → 回填列表元数据。
//   切换笔记 / 关闭编辑器 / 新建 / 删除前一律先 flushMuseSave，绝不丢字。
//
// 分组策略：
//   所有笔记按 `museCurrentGroupId` 过滤显示（nil = 全部随想）。
//   笔记的 groupId 与分组列表维护在 MuseGroupStore（独立聚合文件 .groups.json）。
//   删除分组不影响笔记（groupId 仍指向已删 id，UI 视为"全部"可见）。

extension AppState {

    /// 当前选中的随想（在当前分组过滤后的列表里取）
    var currentMuseNote: MuseNote? {
        guard let id = museSelectedId else { return nil }
        return museNotes.first { $0.id == id }
    }

    /// 当前分组过滤后的笔记列表（视图直接渲染这个）
    var filteredMuseNotes: [MuseNote] {
        guard let gid = museCurrentGroupId else { return museNotes }
        return museNotes.filter { $0.groupId == gid }
    }

    /// 当前分组显示名（nil = "全部随想"）
    var currentMuseGroupName: String {
        if let gid = museCurrentGroupId, let g = museGroups.first(where: { $0.id == gid }) {
            return g.name
        }
        return "全部随想"
    }

    /// 当前分组下笔记条数（用于 toolbar 下拉显数目）
    func museGroupCount(_ gid: String?) -> Int {
        if gid == nil { return museNotes.count }
        return museNotes.filter { $0.groupId == gid }.count
    }

    // MARK: 加载

    /// 读取全部随想；默认自动选中第一篇（列表非空且当前无有效选中时）
    func loadMuse(autoSelectFirst: Bool = true) async {
        museNotes = await museStore.list()
        if let sel = museSelectedId, museNotes.contains(where: { $0.id == sel }) { return }
        museSelectedId = autoSelectFirst ? filteredMuseNotes.first?.id : nil
    }

    /// 读取全部分组
    func loadMuseGroups() async {
        museGroups = await museGroupStore.list()
    }

    // MARK: 新建 / 选中

    /// 新建一篇空随想：立即落盘 + 插到列表最前 + 选中（编辑器随即获得焦点）
    /// 自动归属当前选中的分组（nil = "全部随想" 不写入 groupId）
    func newMuseNote() {
        flushMuseSave()
        Task {
            guard let note = await museStore.create(groupId: museCurrentGroupId) else {
                Dialogs.info("新建随想失败", detail: "无法写入随想目录，请检查设置里的保存目录权限。")
                return
            }
            museNotes.insert(note, at: 0)
            museNotes.sort(by: MuseNote.order)
            museSelectedId = note.id
            museSavedAt = ""
            Log.shared.info("muse created | id=\(note.id) group=\(museCurrentGroupId ?? "all")")
            await searchIndex.invalidateMuse()
        }
    }

    /// 切换选中：先把上一篇的未落盘草稿写下去
    func selectMuse(_ id: String?) {
        guard id != museSelectedId else { return }
        flushMuseSave()
        museSelectedId = id
        museSavedAt = ""
    }

    // MARK: 自动保存

    /// 编辑器每次输入调用；700ms 内的连续输入合并成一次落盘
    func scheduleMuseSave(id: String, title: String, content: NSAttributedString) {
        musePending = MuseDraft(id: id, title: title, content: content)
        museSaveTask?.cancel()
        museSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.commitMuseDraft()
        }
    }

    /// 立即落盘（切换笔记 / 离开页面 / 删除前调用）
    func flushMuseSave() {
        museSaveTask?.cancel()
        museSaveTask = nil
        guard musePending != nil else { return }
        Task { await commitMuseDraft() }
    }

    /// 把待落盘草稿写进文件并回填列表
    func commitMuseDraft() async {
        guard let draft = musePending else { return }
        musePending = nil

        var note: MuseNote
        if let hit = museNotes.first(where: { $0.id == draft.id }) {
            note = hit
        } else if let disk = await museStore.loadMeta(id: draft.id) {
            note = disk
        } else {
            return   // 笔记已被删除，草稿直接丢弃
        }

        // 富文本 → RTF + 附件提取
        let rtf = MuseRichText.rtfData(draft.content)
        let attachmentFiles = MuseRichText.extractAttachments(from: draft.content)
        note.attachments = attachmentFiles.map { $0.0 }
        Log.shared.info("muse save | draftLen=\(draft.content.length) rtfLen=\(rtf.count)")

        // 标题/正文都没变就不写盘（避免选中切换时无谓刷新 updatedAt 打乱排序）
        let sameTitle = note.title == draft.title
        let sameBody = rtf == (await museStore.loadContent(id: note.id) ?? Data())
        if sameTitle, sameBody { return }

        note.title = draft.title
        note.updatedAt = DateUtil.isoLocal(Date())

        guard await museStore.save(note: note, rtf: rtf, attachmentFiles: attachmentFiles) else {
            Log.shared.warn("muse autosave failed | id=\(note.id)")
            return
        }

        // 刷新列表预览（提取纯文本首 80 字）
        note.plainPreview = String(MuseRichText.plainText(draft.content)
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        if let i = museNotes.firstIndex(where: { $0.id == note.id }) {
            museNotes[i] = note
        } else {
            museNotes.append(note)
        }
        museNotes.sort(by: MuseNote.order)
        museSavedAt = DateUtil.clockShort(Date())
        // 正文/标题/附件已变 → 标记随想搜索索引失效（下次搜索重建，不阻塞保存）
        await searchIndex.invalidateMuse()
    }

    /// 加载一篇笔记的富文本内容（RTF + 附件重建）；旧笔记自动迁移到新结构
    func loadMuseRichText(id: String) async -> NSAttributedString {
        guard !id.isEmpty else { return NSAttributedString() }
        // 旧笔记（仍含 legacyContent）→ 先迁移，再读新结构
        if let meta = await museStore.loadMeta(id: id), meta.legacyContent != nil {
            _ = await museStore.migrateLegacy(id: id)
        }
        let rtf = await museStore.loadContent(id: id) ?? Data()
        let attachments = await museStore.loadAttachments(id: id)
        // 读入附件数据（懒加载：只取当前磁盘存在的）
        var withData: [(MuseAttachment, Data)] = []
        for (meta, url) in attachments {
            if let d = try? Data(contentsOf: url) {
                withData.append((meta, d))
            }
        }
        let att = MuseRichText.rebuildAttachments(rtfData: rtf, attachments: withData)
        return att
    }

    // MARK: 删除

    /// 删除一篇随想（不可撤销，走系统确认弹窗），删完自动选中相邻一篇
    func deleteMuse(_ note: MuseNote) {
        flushMuseSave()
        guard Dialogs.confirmDelete(
            message: "确定要删除「\(note.displayTitle)」吗？",
            detail: "这篇随想的文字会被永久删除，此操作不可撤销。"
        ) else { return }

        Task {
            let idx = museNotes.firstIndex(where: { $0.id == note.id })
            let ok = await museStore.delete(id: note.id)
            guard ok else {
                Dialogs.info("未找到这篇随想（可能已被删除）")
                await loadMuse()
                return
            }
            museNotes.removeAll { $0.id == note.id }
            if museSelectedId == note.id {
                // 优先选中原位置的下一篇，没有则上一篇
                if let i = idx, i < museNotes.count {
                    museSelectedId = museNotes[i].id
                } else {
                    museSelectedId = museNotes.last?.id
                }
            }
            museSavedAt = ""
            Log.shared.info("muse deleted | id=\(note.id)")
            await searchIndex.invalidateMuse()
        }
    }

    /// 在访达中打开随想目录（设置/右键入口备用）
    func revealMuseDir() {
        Task {
            let path = await museStore.dirPath
            _ = await museStore.ensureDirs()
            Dialogs.openFolder(path)
        }
    }

    // MARK: 分组

    /// 切换当前分组（nil = 全部随想）；切换后自动重选过滤后列表中的第一篇
    func setMuseCurrentGroup(_ gid: String?) {
        flushMuseSave()
        museCurrentGroupId = gid
        // 重新选一个新分组里第一篇（避免仍选已过滤出去的笔记）
        museSelectedId = filteredMuseNotes.first?.id
        museSavedAt = ""
    }

    /// 新建分组（弹窗 input 用）
    func createMuseGroup(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        Task {
            guard let g = await museGroupStore.create(name: trimmed) else { return }
            await loadMuseGroups()
            // 新建后自动切到这个分组，并自动选中过滤列表第一篇
            setMuseCurrentGroup(g.id)
            await searchIndex.invalidateMuse()
            Log.shared.info("muse group created | id=\(g.id) name=\(g.name)")
        }
    }

    /// 重命名分组
    func renameMuseGroup(id: String, newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return }
        Task {
            _ = await museGroupStore.rename(id: id, newName: trimmed)
            await loadMuseGroups()
            await searchIndex.invalidateMuse()
            Log.shared.info("muse group renamed | id=\(id) name=\(trimmed)")
        }
    }

    /// 删除分组（笔记不动，UI 视为 nil 分组）
    func deleteMuseGroup(_ id: String) {
        Task {
            _ = await museGroupStore.delete(id: id)
            let wasCurrent = (museCurrentGroupId == id)
            await loadMuseGroups()
            if wasCurrent {
                setMuseCurrentGroup(nil)
            }
            await searchIndex.invalidateMuse()
            Log.shared.info("muse group deleted | id=\(id)")
        }
    }

    /// 把一篇笔记移动到指定分组（nil = 移回"全部随想"）
    func moveMuseToGroup(noteId: String, groupId: String?) {
        flushMuseSave()
        Task {
            guard var note = museNotes.first(where: { $0.id == noteId }) else { return }
            note.groupId = groupId
            guard await museStore.saveMeta(note) else { return }
            if let i = museNotes.firstIndex(where: { $0.id == noteId }) {
                museNotes[i] = note
            }
            // 若当前分组过滤不包含这条笔记，列表里看不到它（不报错）
            Log.shared.info("muse moved | id=\(noteId) group=\(groupId ?? "all")")
            await searchIndex.invalidateMuse()
        }
    }
}
