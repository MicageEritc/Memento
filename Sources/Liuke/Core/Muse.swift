import Foundation
import AppKit

// MARK: - 「随想」笔记模型（v2：元数据 + RTF 正文 + 附件）
//
// 产品定位：类似 macOS 备忘录 —— 用户**主动**记录想法、文字、灵感。
// 与瞬息/一念（自动截屏 + 模型分析）是完全独立的数据域，互不影响。
//
// 存储结构（2026-08-11 第六轮升级，从 <id>.json 单文件 → notes/{id}/ 目录）：
//   <outputDir>/随想/
//     ├── notes/
//     │    └── {noteId}/
//     │         ├── note.json          ← 仅元数据（id/title/groupId/createdAt/updatedAt/attachments）
//     │         ├── content.rtfd       ← 正文与格式（RTF 数据，不含附件内嵌）
//     │         └── attachments/       ← 图片/文件附件（独立文件，绝不 Base64）
//     ├── .groups.json                 ← 分组聚合（不变）
//     └── *.json                       ← 旧版单文件格式（读取兼容，保存时迁移到新结构）
//
// ⚠️ 富文本能力：正文 = NSAttributedString；格式 = 粗体/斜体/下划线/标题/列表/引用；
//    序列化用 RTF（content.rtfd 内是 RTF 数据），附件用「占位符 + attachments/ 文件」重建，
//    因此正文文件里没有任何 Base64。

struct MuseAttachment: Codable, Equatable, Hashable, Identifiable {
    /// 附件唯一 id（文件名 = id + 原扩展名）
    var id: String = ""
    /// 原始文件名（含扩展名）
    var name: String = ""
    /// 附件类型（UTType 的 identifier，未知则空）
    var type: String = ""
    /// 字节数
    var size: Int = 0
    var createdAt: String = ""

    /// 附件在磁盘上的文件名
    var fileName: String {
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? id : "\(id).\(ext)"
    }
}

struct MuseNote: Codable, Equatable, Hashable, Identifiable {

    /// 数据格式版本（v2 = 目录结构）
    var schema: String = MuseStore.schemaId
    var id: String = ""
    var title: String = ""
    /// 所属分组 id（nil = "全部随想"）
    var groupId: String? = nil
    /// 本地带时区偏移的 ISO 串
    var createdAt: String = ""
    var updatedAt: String = ""
    /// 附件元数据列表（实际文件在 attachments/ 目录）
    var attachments: [MuseAttachment] = []

    /// AI 总结 Tip（独立于正文，不属于富文本内容；nil = 未插入/已彻底删除）
    /// aiSummaryHidden = 折叠状态（小眼睛收起，数据保留，可再展开）。
    /// 「彻底删除」由 AI 面板的「隐藏」按钮触发（aiSummary 置 nil）。
    var aiSummary: String? = nil
    var aiSummaryHidden: Bool = false
    /// AI 总结结果缓存（生成后持久化，重启后复用，不再自动重复生成）
    var aiSummaryCache: String? = nil

    // ── 兼容字段（旧版单文件 JSON 读取用；新结构 note.json 不再写这些）──
    var pinned: Bool = false
    var tags: [String] = []
    var format: String = "plain"
    /// 旧版正文（从旧 *.json 的 content 字段读入；迁移后置空）
    var legacyContent: String? = nil

    init() {}

    init(id: String, title: String = "", groupId: String? = nil,
         createdAt: String, updatedAt: String) {
        self.id = id
        self.title = title
        self.groupId = groupId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: 展示派生

    /// 列表标题：标题为空时退回「新的随想」（正文首行由 UI 层从 RTF 提取后填充 preview）
    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "新的随想" : t
    }

    /// 列表第二行摘要：优先用保存时缓存的纯文本预览（由 list() 填充）
    var preview: String {
        if let p = plainPreview, !p.isEmpty { return p }
        return "无额外内容"
    }

    /// 纯文本预览缓存（list() 读 RTF 提取，不进 note.json）
    var plainPreview: String? = nil

    var updatedDate: Date? { DateUtil.parseISO(updatedAt) }
    var createdDate: Date? { DateUtil.parseISO(createdAt) }

    /// 列表排序：置顶优先 → 更新时间倒序 → id 倒序兜底
    static func order(_ a: MuseNote, _ b: MuseNote) -> Bool {
        if a.pinned != b.pinned { return a.pinned }
        if a.updatedAt != b.updatedAt { return a.updatedAt > b.updatedAt }
        return a.id > b.id
    }

    // MARK: 容错解码

    enum CodingKeys: String, CodingKey {
        case schema, id, title, groupId, createdAt, updatedAt, attachments
        case pinned, tags, format, content
        case aiSummary, aiSummaryHidden, aiSummaryCache
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = ((try? c.decodeIfPresent(String.self, forKey: .schema)) ?? nil) ?? MuseStore.schemaId
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? ""
        title = ((try? c.decodeIfPresent(String.self, forKey: .title)) ?? nil) ?? ""
        groupId = (try? c.decodeIfPresent(String.self, forKey: .groupId)) ?? nil
        createdAt = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil) ?? ""
        updatedAt = ((try? c.decodeIfPresent(String.self, forKey: .updatedAt)) ?? nil) ?? createdAt
        attachments = ((try? c.decodeIfPresent([MuseAttachment].self, forKey: .attachments)) ?? nil) ?? []
        pinned = ((try? c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? nil) ?? false
        tags = ((try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil) ?? []
        format = ((try? c.decodeIfPresent(String.self, forKey: .format)) ?? nil) ?? "plain"
        // 旧版正文（content 字段）→ 迁移载体
        legacyContent = (try? c.decodeIfPresent(String.self, forKey: .content)) ?? nil
        aiSummary = (try? c.decodeIfPresent(String.self, forKey: .aiSummary)) ?? nil
        aiSummaryHidden = ((try? c.decodeIfPresent(Bool.self, forKey: .aiSummaryHidden)) ?? nil) ?? false
        aiSummaryCache = (try? c.decodeIfPresent(String.self, forKey: .aiSummaryCache)) ?? nil
    }

    /// 编码：只写元数据（note.json 不存正文/格式/兼容字段）
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schema, forKey: .schema)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(groupId, forKey: .groupId)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(attachments, forKey: .attachments)
        // AI 总结 Tip：独立数据，随 note.json 元数据保存
        try c.encodeIfPresent(aiSummary, forKey: .aiSummary)
        try c.encode(aiSummaryHidden, forKey: .aiSummaryHidden)
        try c.encodeIfPresent(aiSummaryCache, forKey: .aiSummaryCache)
        // 不写 pinned/tags/format/content（兼容字段 & 正文均不入 note.json）
    }
}

// MARK: - 随想存储层（v2：notes/{id}/ 目录结构，兼容旧单文件）

actor MuseStore {

    static let schemaId = "liuke/muse-note@2"
    static let dirName = "随想"
    static let notesDirName = "notes"
    static let contentFileName = "content.rtfd"
    static let metaFileName = "note.json"
    static let attachmentsDirName = "attachments"

    private var rootPath: String
    private let fm = FileManager.default

    init(root: String) { rootPath = root }

    func setRoot(_ path: String) { rootPath = path }

    /// <root>/随想
    var dir: URL { URL(fileURLWithPath: rootPath).appendingPathComponent(MuseStore.dirName) }
    /// <root>/随想/notes
    var notesDir: URL { dir.appendingPathComponent(MuseStore.notesDirName) }
    /// <root>/随想/notes/{id}
    func noteDir(_ id: String) -> URL { notesDir.appendingPathComponent(id) }
    func metaURL(_ id: String) -> URL { noteDir(id).appendingPathComponent(MuseStore.metaFileName) }
    func contentURL(_ id: String) -> URL { noteDir(id).appendingPathComponent(MuseStore.contentFileName) }
    func attachmentsDir(_ id: String) -> URL { noteDir(id).appendingPathComponent(MuseStore.attachmentsDirName) }
    /// 旧版单文件路径 <root>/随想/{id}.json
    func legacyFileURL(_ id: String) -> URL { dir.appendingPathComponent("\(id).json") }

    var dirPath: String { dir.path }

    /// id 形如 20260811T104512-a3f9c1（文件名即时间序）
    nonisolated static func newId(_ date: Date = Date()) -> String {
        let d = DateUtil.ymd(date).replacingOccurrences(of: "-", with: "")
        let t = DateUtil.hms(date).replacingOccurrences(of: "-", with: "")
        var bytes = [UInt8](repeating: 0, count: 3)
        for i in 0..<3 { bytes[i] = UInt8.random(in: 0...255) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(d)T\(t)-\(hex)"
    }

    private func decoder() -> JSONDecoder { JSONDecoder() }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    @discardableResult
    func ensureDirs() -> Bool {
        (try? fm.createDirectory(at: notesDir, withIntermediateDirectories: true)) != nil
    }

    @discardableResult
    func ensureNoteDirs(_ id: String) -> Bool {
        (try? fm.createDirectory(at: attachmentsDir(id), withIntermediateDirectories: true)) != nil
    }

    // MARK: 查询

    /// 全部随想（新结构 notes/{id} + 旧结构根目录 *.json，混合兼容）
    func list() -> [MuseNote] {
        ensureDirs()
        var out: [MuseNote] = []

        // 新结构：notes/*/note.json
        if let dirs = try? fm.contentsOfDirectory(atPath: notesDir.path) {
            for d in dirs where !d.hasPrefix(".") {
                let metaPath = metaURL(d).path
                guard fm.fileExists(atPath: metaPath),
                      let data = try? Data(contentsOf: metaURL(d)),
                      var note = try? decoder().decode(MuseNote.self, from: data) else { continue }
                note.id = d
                note.plainPreview = readPlainPreview(note.id)
                out.append(note)
            }
        }

        // 旧结构：根目录 *.json（无对应 notes/{id} 目录的）
        if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            for n in names where n.hasSuffix(".json") && !n.hasPrefix(".") {
                let id = String(n.dropLast(5))
                // 已迁移到新结构的不重复读
                if fm.fileExists(atPath: metaURL(id).path) { continue }
                guard let data = try? Data(contentsOf: dir.appendingPathComponent(n)),
                      var note = try? decoder().decode(MuseNote.self, from: data) else { continue }
                note.id = id
                out.append(note)
            }
        }

        out.sort(by: MuseNote.order)
        return out
    }

    /// 读取正文 RTF 数据（content.rtfd；旧笔记无新结构时退回 legacyContent 转纯文本 RTF）
    func loadContent(id: String) -> Data? {
        guard !id.isEmpty else { return nil }
        let url = contentURL(id)
        if fm.fileExists(atPath: url.path) {
            return try? Data(contentsOf: url)
        }
        // 旧笔记：无 RTF 文件 → 用 legacyContent 生成纯文本 RTF（后续保存自动落盘）
        if let note = loadMeta(id: id), let text = note.legacyContent {
            return MuseRichText.makePlainRTF(text)
        }
        return nil
    }

    /// 附件列表 + 磁盘文件 URL（按 note.attachments 顺序）
    func loadAttachments(id: String) -> [(MuseAttachment, URL)] {
        guard let note = loadMeta(id: id) else { return [] }
        let ad = attachmentsDir(id)
        return note.attachments.compactMap { a in
            let url = ad.appendingPathComponent(a.fileName)
            return fm.fileExists(atPath: url.path) ? (a, url) : nil
        }
    }

    /// 读取某个附件文件数据
    func loadAttachmentData(noteId: String, fileName: String) -> Data? {
        try? Data(contentsOf: attachmentsDir(noteId).appendingPathComponent(fileName))
    }

    /// 写入单个附件文件（覆盖）
    @discardableResult
    func writeAttachment(noteId: String, fileName: String, data: Data) -> Bool {
        ensureNoteDirs(noteId)
        let url = attachmentsDir(noteId).appendingPathComponent(fileName)
        do {
            try data.write(to: url)
            return true
        } catch {
            Log.shared.error("muse attachment write failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 删除单个附件文件
    @discardableResult
    func deleteAttachment(noteId: String, fileName: String) -> Bool {
        let url = attachmentsDir(noteId).appendingPathComponent(fileName)
        guard fm.fileExists(atPath: url.path) else { return false }
        do {
            try fm.removeItem(at: url)
            return true
        } catch {
            Log.shared.error("muse attachment delete failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 清空某篇笔记的附件目录（保存时先清旧再写新，避免孤儿文件）
    func clearAllAttachments(noteId: String) {
        let dir = attachmentsDir(noteId)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for n in names {
            try? fm.removeItem(at: dir.appendingPathComponent(n))
        }
    }

    func loadMeta(id: String) -> MuseNote? {
        guard !id.isEmpty else { return nil }
        let url = metaURL(id)
        if fm.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           var note = try? decoder().decode(MuseNote.self, from: data) {
            note.id = id
            return note
        }
        // 旧结构回退
        let legacy = legacyFileURL(id)
        if fm.fileExists(atPath: legacy.path),
           let data = try? Data(contentsOf: legacy),
           var note = try? decoder().decode(MuseNote.self, from: data) {
            note.id = id
            return note
        }
        return nil
    }

    func count() -> Int {
        ensureDirs()
        var c = 0
        if let dirs = try? fm.contentsOfDirectory(atPath: notesDir.path) {
            c += dirs.filter { fm.fileExists(atPath: metaURL($0).path) }.count
        }
        if let names = try? fm.contentsOfDirectory(atPath: dir.path) {
            c += names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") && !fm.fileExists(atPath: metaURL(String($0.dropLast(5))).path) }.count
        }
        return c
    }

    /// 从 RTF 提取纯文本预览（列表第二行用）
    private func readPlainPreview(_ id: String) -> String? {
        guard let data = loadContent(id: id),
              let att = MuseRichText.attributed(fromRTF: data) else { return nil }
        let text = att.string.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : String(text.prefix(80))
    }

    // MARK: 增删改

    /// 新建一篇空随想：建目录 + 空 note.json + 空 content.rtfd
    @discardableResult
    func create(title: String = "", groupId: String? = nil) -> MuseNote? {
        ensureDirs()
        let now = Date()
        let stamp = DateUtil.isoLocal(now)
        let note = MuseNote(id: MuseStore.newId(now), title: title, groupId: groupId,
                            createdAt: stamp, updatedAt: stamp)
        guard ensureNoteDirs(note.id),
              writeMeta(note),
              writeContent(id: note.id, rtf: MuseRichText.makePlainRTF("")) else { return nil }
        return note
    }

    /// 原子写 note.json
    @discardableResult
    private func writeMeta(_ note: MuseNote) -> Bool {
        guard !note.id.isEmpty else { return false }
        ensureNoteDirs(note.id)
        guard let data = try? encoder().encode(note) else { return false }
        let url = metaURL(note.id)
        let tmp = url.appendingPathExtension("tmp\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try data.write(to: tmp)
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
            try fm.moveItem(at: tmp, to: url)
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            Log.shared.error("muse meta save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 原子写 content.rtfd
    @discardableResult
    func writeContent(id: String, rtf: Data) -> Bool {
        guard !id.isEmpty else { return false }
        ensureNoteDirs(id)
        let url = contentURL(id)
        let tmp = url.appendingPathExtension("tmp\(ProcessInfo.processInfo.processIdentifier)")
        do {
            try rtf.write(to: tmp)
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
            try fm.moveItem(at: tmp, to: url)
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            Log.shared.error("muse content save failed: \(error.localizedDescription)")
            return false
        }
    }

    /// 仅保存元数据（标题/分组/附件列表变更时用，不动正文 RTF）
    @discardableResult
    func saveMeta(_ note: MuseNote) -> Bool {
        writeMeta(note)
    }

    /// 保存整篇（元数据 + 正文 RTF + 附件文件）。原子性：先写附件/正文，最后写 meta。
    @discardableResult
    func save(note: MuseNote, rtf: Data, attachmentFiles: [(MuseAttachment, Data)]) -> Bool {
        guard !note.id.isEmpty else { return false }
        // 0. 清空旧附件（避免孤儿）
        clearAllAttachments(noteId: note.id)
        // 1. 写附件文件
        for (a, data) in attachmentFiles {
            if !writeAttachment(noteId: note.id, fileName: a.fileName, data: data) {
                Log.shared.warn("muse attachment save skipped | \(a.fileName)")
            }
        }
        // 2. 写正文
        guard writeContent(id: note.id, rtf: rtf) else { return false }
        // 3. 写元数据（最后，成功即代表整篇保存完成）
        return writeMeta(note)
    }

    /// 删除整篇（目录递归删除；兼容旧结构单文件）
    @discardableResult
    func delete(id: String) -> Bool {
        guard !id.isEmpty else { return false }
        var any = false
        let nd = noteDir(id)
        if fm.fileExists(atPath: nd.path) {
            do { try fm.removeItem(at: nd); any = true }
            catch { Log.shared.error("muse delete dir failed: \(error.localizedDescription)") }
        }
        let legacy = legacyFileURL(id)
        if fm.fileExists(atPath: legacy.path) {
            do { try fm.removeItem(at: legacy); any = true }
            catch { Log.shared.error("muse delete legacy failed: \(error.localizedDescription)") }
        }
        return any
    }

    /// 旧笔记迁移：把根目录 {id}.json 迁移为 notes/{id}/ 新结构
    @discardableResult
    func migrateLegacy(id: String) -> Bool {
        guard let note = loadMeta(id: id), let text = note.legacyContent else { return false }
        let rtf = MuseRichText.makePlainRTF(text)
        guard ensureNoteDirs(id),
              writeContent(id: id, rtf: rtf) else { return false }
        var migrated = note
        migrated.legacyContent = nil
        guard writeMeta(migrated) else { return false }
        // 删除旧单文件
        let legacy = legacyFileURL(id)
        if fm.fileExists(atPath: legacy.path) {
            do {
                try fm.removeItem(at: legacy)
            } catch {
                Log.shared.warn("muse legacy remove failed: \(error.localizedDescription)")
            }
        }
        Log.shared.info("muse migrated | id=\(id)")
        return true
    }
}
