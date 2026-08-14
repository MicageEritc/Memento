import Foundation
import AppKit

// MARK: - 全局搜索统一结果（瞬息 / 一念 / 随想 三类共用）
//
// 设计原则（与现有架构兼容，不动任何存储结构）：
// - 复用 Store.searchAll 的「分词 + 子串 AND」基础匹配逻辑（中文分词留待未来升级）。
// - 瞬息/一念从 Store 一次性抽出的 ActRecord 缓存里匹配；随想从 MuseStore 抽出并缓存 RTF 纯文本。
// - 每条结果带 rank（相关度权重）与 terms（命中词），供 UI 排序与高亮，不修改原始数据。

struct SearchHit: Identifiable {
    enum Kind: String, CaseIterable, Hashable {
        case memento   // 瞬息
        case yinian    // 一念
        case muse      // 随想
        var title: String {
            switch self {
            case .memento: return "瞬息"
            case .yinian:  return "一念"
            case .muse:    return "随想"
            }
        }
    }

    var id: String
    var kind: Kind
    var title: String
    /// 摘要 / 命中片段（随想用正文片段；瞬息/一念留空，沿用原有日期/分类展示）
    var snippet: String
    /// 主时间标签：瞬息/一念=日期(YYYY-MM-DD)，随想=更新日期
    var dateLabel: String
    /// 瞬息/一念=时间(HH:mm)；随想=nil
    var timeLabel: String?
    /// 随想分组名（若有）
    var groupLabel: String?
    /// 瞬息/一念分类
    var categoryLabel: String?
    /// 相关度权重（越大越靠前）：标题>关键词/分组/附件>正文>摘要
    var rank: Int
    /// 命中的查询词（用于 UI 高亮）
    var terms: [String]

    // 跳转载荷
    var record: ActRecord?
    var museId: String?
}

// MARK: - 搜索索引（内存缓存 + RTF 纯文本缓存）
//
// 性能策略（对应需求 #8/#9）：启动或数据变化时建立索引，用户输入时只在内存里匹配，
// 不再每次搜索都重扫所有历史 JSON。随想正文 RTF→纯文本按 (id, mtime) 缓存，文件没变不重解析。

actor SearchIndex {

    // 瞬息/一念：一次性抽出的全部 record（带 date/type）
    private var recordsCache: [ActRecord]?
    private var recordsDirty = true

    // 随想：可搜索条目（标题/分组/附件名/正文纯文本）
    private struct MuseEntry {
        let id: String
        let title: String
        let groupName: String?
        let updatedAt: String
        let attachmentNames: [String]
        let bodyOriginal: String   // 原始正文（用于片段 & 高亮）
        let bodyLower: String      // 小写正文（用于匹配）
    }
    private var museCache: [MuseEntry]?
    private var museDirty = true

    // 随想正文纯文本缓存：noteId -> (内容 mtime, 纯文本)
    private var plainCache: [String: (TimeInterval, String)] = [:]

    // MARK: 失效标记（数据变化时由 AppState 调用）

    func invalidateRecords() { recordsDirty = true }
    func invalidateMuse() { museDirty = true }

    // MARK: 主入口

    /// 全局搜索（瞬息/一念/随想 混合；filter: ""=全部, memento, yinian, muse）
    func search(_ query: String,
                filter: String?,
                store: Store,
                museStore: MuseStore,
                groupStore: MuseGroupStore) async -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let terms = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }

        // 确保索引是最新的（仅 dirty 时重建）
        if recordsDirty || recordsCache == nil {
            recordsCache = await store.collectAllRecords()
            recordsDirty = false
        }
        if museDirty || museCache == nil {
            museCache = await buildMuseEntries(museStore: museStore, groupStore: groupStore)
            museDirty = false
        }

        let f = filter ?? ""
        var hits: [SearchHit] = []

        let wantRecords = f != "muse"
        let wantMuse = (f == "" || f == "muse")

        if wantRecords {
            for r in recordsCache ?? [] {
                if f == "memento", r.kind != .memento { continue }
                if f == "yinian",  r.kind != .yinian  { continue }
                if let hit = hitForRecord(r, terms: terms) { hits.append(hit) }
            }
        }
        if wantMuse {
            for e in museCache ?? [] {
                if let hit = hitForMuse(e, terms: terms) { hits.append(hit) }
            }
        }

        // 排序：相关度降序；同分按时间降序（ISO 串可直接比较）
        hits.sort {
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            return $0.dateLabel > $1.dateLabel
        }
        return Array(hits.prefix(2000))
    }

    // MARK: 瞬息 / 一念

    private func hitForRecord(_ r: ActRecord, terms: [String]) -> SearchHit? {
        let a = r.activity
        let title = (a?.title ?? "").lowercased()
        let appn  = (a?.app ?? "").lowercased()
        let cat   = (a?.category ?? "").lowercased()
        let focus = (a?.focus ?? "").lowercased()
        let summary = (a?.summaryText ?? "").lowercased()
        let keywords = (a?.keywords ?? []).joined(separator: " ").lowercased()
        let time  = (r.time ?? "").lowercased()
        // 一念的记忆价值类型（如「项目里程碑」）也可被搜到；瞬息/旧数据为空串，不影响匹配
        let intent = (a?.intent.map { MemoryIntent.normalize($0) } ?? "").lowercased()

        // 基础匹配：沿用 Store.matches 的 AND 子串逻辑
        let blob = [title, appn, cat, focus, summary, keywords, time, intent]
        let allHit = terms.allSatisfy { t in blob.contains { $0.contains(t) } }
        guard allHit else { return nil }

        // 权重（标题 > 关键词/记忆类型 > 分类/应用 > 摘要）
        var rank = 0
        for t in terms {
            if title.contains(t)      { rank += 3 }
            if keywords.contains(t)    { rank += 2 }
            if !intent.isEmpty, intent.contains(t) { rank += 2 }
            if cat.contains(t) || appn.contains(t) || focus.contains(t) { rank += 1 }
            if summary.contains(t)     { rank += 1 }
        }

        // 标题展示（与旧 SearchResultRow 保持一致）
        let t = (a?.title ?? "").trimmingCharacters(in: .whitespaces)
        let displayTitle: String
        if !t.isEmpty {
            displayTitle = t
        } else if r.kind == .yinian {
            displayTitle = "一念 · 手动留存的瞬间"
        } else {
            displayTitle = StatusLabel.of(r.statusEnum).isEmpty ? "—" : StatusLabel.of(r.statusEnum)
        }

        // 生成正文片段（复用随想的 makeSnippet 逻辑）
        let bodyForSnippet = a?.summaryText ?? ""
        let snippet = makeSnippet(text: bodyForSnippet, terms: terms, title: displayTitle)

        return SearchHit(
            id: "rec:\(r.id)",
            kind: r.kind == .yinian ? .yinian : .memento,
            title: displayTitle,
            snippet: snippet,
            dateLabel: r.date ?? "",
            timeLabel: r.time,
            groupLabel: nil,
            categoryLabel: (a?.category ?? "").isEmpty || (a?.category ?? "") == "未知" ? nil : a?.category,
            rank: rank,
            terms: terms,
            record: r,
            museId: nil
        )
    }

    // MARK: 随想

    private func buildMuseEntries(museStore: MuseStore, groupStore: MuseGroupStore) async -> [MuseEntry] {
        let notes = await museStore.list()
        let groups = await groupStore.list()
        let groupMap = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })

        var out: [MuseEntry] = []
        for note in notes {
            let (text, _) = await loadPlainText(museStore: museStore, id: note.id)
            let original = text ?? ""
            out.append(MuseEntry(
                id: note.id,
                title: note.title,
                groupName: note.groupId.flatMap { groupMap[$0] },
                updatedAt: note.updatedAt,
                attachmentNames: note.attachments.map { $0.name },
                bodyOriginal: original,
                bodyLower: original.lowercased()
            ))
        }
        return out
    }

    /// 读取随想正文纯文本（RTF→纯文本），按内容 mtime 缓存，文件未变不重解析
    private func loadPlainText(museStore: MuseStore, id: String) async -> (String?, TimeInterval) {
        let url = await museStore.contentURL(id)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        if let cached = plainCache[id], cached.0 == mtime {
            return (cached.1, mtime)
        }
        let data = await museStore.loadContent(id: id)
        let text = data
            .flatMap { MuseRichText.attributed(fromRTF: $0) }?
            .string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let t = text ?? ""
        plainCache[id] = (mtime, t)
        return (t, mtime)
    }

    private func hitForMuse(_ e: MuseEntry, terms: [String]) -> SearchHit? {
        let title = e.title.lowercased()
        let group = (e.groupName ?? "").lowercased()
        let attach = e.attachmentNames.joined(separator: " ").lowercased()
        let body = e.bodyLower

        // 基础匹配：标题/分组/附件名/正文 任一处命中即算该词命中（AND）
        let allHit = terms.allSatisfy { t in
            title.contains(t) || group.contains(t) || attach.contains(t) || body.contains(t)
        }
        guard allHit else { return nil }

        // 权重：标题 > 附件名/分组 > 正文
        var rank = 0
        for t in terms {
            if title.contains(t) { rank += 3 }
            else if attach.contains(t) { rank += 2 }
            else if group.contains(t) { rank += 2 }
            else if body.contains(t) { rank += 1 }
        }

        let snippet = makeSnippet(text: e.bodyOriginal, terms: terms, title: e.title)
        let dateLabel = String(e.updatedAt.prefix(10))   // ISO 本地串前 10 位 = YYYY-MM-DD

        return SearchHit(
            id: "muse:\(e.id)",
            kind: .muse,
            title: e.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新的随想" : e.title,
            snippet: snippet,
            dateLabel: dateLabel,
            timeLabel: nil,
            groupLabel: (e.groupName ?? "").isEmpty ? nil : e.groupName,
            categoryLabel: nil,
            rank: rank,
            terms: terms,
            record: nil,
            museId: e.id
        )
    }

    /// 生成正文摘要片段：优先取首个命中词附近的窗口；都未在正文命中则取正文开头；
    /// 标题命中但正文无命中时同样回退到正文开头。
    private func makeSnippet(text: String, terms: [String], title: String) -> String {
        guard !text.isEmpty else { return "无额外内容" }
        let lower = text.lowercased()
        for t in terms where !t.isEmpty {
            if let r = lower.range(of: t) {
                let start = text.index(r.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
                let end = text.index(r.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
                var s = String(text[start..<end])
                if start != text.startIndex { s = "…" + s }
                if end != text.endIndex { s = s + "…" }
                return s
            }
        }
        return String(text.prefix(80))
    }
}
