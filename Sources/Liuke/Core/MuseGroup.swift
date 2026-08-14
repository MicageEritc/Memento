import Foundation

// MARK: - 「随想」分组模型
//
// 用途：把随想按文件夹式分组（账号管理 / AI 摘要 / 自定义 等），参考 macOS 备忘录的「智能文件夹」体验。
// 存储：与随想笔记同级目录下聚合文件 `_groups.json`（前缀下划线避免被笔记 list() 误读）。
// 笔记归属：通过 `MuseNote.groupId` 关联，nil = 「全部随想」全局根。

struct MuseGroup: Codable, Equatable, Hashable, Identifiable {

    /// 数据格式版本
    var schema: String = MuseGroupStore.schemaId
    var id: String = ""
    var name: String = ""
    var createdAt: String = ""
    /// 排序权重（用户拖拽前按创建顺序，可由「重命名/创建」统一刷新）
    var sortOrder: Int = 0

    init() {}

    init(id: String, name: String, createdAt: String, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.sortOrder = sortOrder
    }

    // MARK: 容错解码

    enum CodingKeys: String, CodingKey {
        case schema, id, name, createdAt, sortOrder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schema = ((try? c.decodeIfPresent(String.self, forKey: .schema)) ?? nil) ?? MuseGroupStore.schemaId
        id = ((try? c.decodeIfPresent(String.self, forKey: .id)) ?? nil) ?? ""
        name = ((try? c.decodeIfPresent(String.self, forKey: .name)) ?? nil) ?? ""
        createdAt = ((try? c.decodeIfPresent(String.self, forKey: .createdAt)) ?? nil) ?? ""
        sortOrder = ((try? c.decodeIfPresent(Int.self, forKey: .sortOrder)) ?? nil) ?? 0
    }

    /// 分组排序：sortOrder 升序 → 名字兜底
    static func order(_ a: MuseGroup, _ b: MuseGroup) -> Bool {
        if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
        return a.name < b.name
    }
}

// MARK: - 分组存储层（独立 actor，避免与 MuseStore 互相阻塞）

actor MuseGroupStore {

    static let schemaId = "liuke/muse-group@1"
    /// 聚合文件名（点前缀 = 隐藏文件，自然被 MuseStore.list() 的 `!hasPrefix(".")` 过滤掉）
    static let filename = ".groups.json"

    private var rootPath: String
    private let fm = FileManager.default

    init(root: String) { rootPath = root }

    func setRoot(_ path: String) { rootPath = path }

    private var fileURL: URL {
        URL(fileURLWithPath: rootPath)
            .appendingPathComponent(MuseStore.dirName)
            .appendingPathComponent(MuseGroupStore.filename)
    }

    private func ensureDir() -> Bool {
        let dir = URL(fileURLWithPath: rootPath).appendingPathComponent(MuseStore.dirName)
        return (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil
    }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    // MARK: 读写

    /// 读取全部分组（按 sortOrder 排序）
    func list() -> [MuseGroup] {
        guard let data = try? Data(contentsOf: fileURL),
              let groups = try? JSONDecoder().decode([MuseGroup].self, from: data) else {
            return []
        }
        return groups.sorted(by: MuseGroup.order)
    }

    /// 原子写：先写 .tmp 再 move，防止写一半留坏文件
    @discardableResult
    private func save(_ groups: [MuseGroup]) -> Bool {
        guard ensureDir(),
              let data = try? encoder().encode(groups) else { return false }
        let tmp = fileURL.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
            if fm.fileExists(atPath: fileURL.path) { try? fm.removeItem(at: fileURL) }
            try fm.moveItem(at: tmp, to: fileURL)
            return true
        } catch {
            try? fm.removeItem(at: tmp)
            Log.shared.error("muse group save failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: CRUD

    /// 新建分组（自动分配 sortOrder = max + 1）
    @discardableResult
    func create(name: String) -> MuseGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        var groups = list()
        let maxOrder = groups.map(\.sortOrder).max() ?? -1
        let group = MuseGroup(
            id: "g_" + UUID().uuidString.prefix(8).lowercased(),
            name: trimmed,
            createdAt: DateUtil.isoLocal(Date()),
            sortOrder: maxOrder + 1
        )
        groups.append(group)
        return save(groups) ? group : nil
    }

    /// 重命名分组
    @discardableResult
    func rename(id: String, newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        var groups = list()
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups[idx].name = trimmed
        return save(groups)
    }

    /// 删除分组（笔记不动，groupId 保持原值；UI 层列表过滤时仅按当前 groupId 过滤，
    /// 已删除的 groupId 视同 nil —— 即回到「全部随想」可见）
    @discardableResult
    func delete(id: String) -> Bool {
        var groups = list()
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return false }
        groups.remove(at: idx)
        return save(groups)
    }
}
