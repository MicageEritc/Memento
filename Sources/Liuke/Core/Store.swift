import Foundation

/// 存储层 —— 对应 Electron 版 store.js
///
/// 目录结构（与旧版完全一致，可直接读老数据）：
///   ~/Documents/留刻/
///     ├── 瞬息/YYYY-MM/screenshots/YYYY-MM-DD/*.jpg
///     ├── 瞬息/YYYY-MM/YYYY-MM-DD_HH.json
///     ├── 一念/…（同构）
///     └── summary/{key}.json + summary/history/{key}.json
///
/// 用 actor 保证所有读改写串行执行，等价于原版的 _serial 队列。
actor Store {

    static let schemaId = "memento-lens/hourly-activity-log@1"

    private var cfg: AppConfig
    private let fm = FileManager.default

    init(cfg: AppConfig) {
        self.cfg = cfg
    }

    func setConfig(_ c: AppConfig) { cfg = c }

    nonisolated static func newId(_ date: Date) -> String {
        let d = DateUtil.ymd(date).replacingOccurrences(of: "-", with: "")
        let t = DateUtil.hms(date).replacingOccurrences(of: "-", with: "")
        var bytes = [UInt8](repeating: 0, count: 3)
        for i in 0..<3 { bytes[i] = UInt8.random(in: 0...255) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(d)T\(t)-\(hex)"
    }

    // MARK: - 路径

    var root: URL { URL(fileURLWithPath: cfg.outputDir) }
    var rootPath: String { cfg.outputDir }

    private func typeDir(_ kind: RecordKind) -> URL {
        root.appendingPathComponent(kind.dirName)
    }

    struct Paths {
        var baseDir: URL
        var monthDir: URL
        var shotDir: URL
        var logFile: URL
    }

    func paths(_ date: Date, _ kind: RecordKind = .memento) -> Paths {
        let base = typeDir(kind)
        let month = base.appendingPathComponent(DateUtil.ym(date))
        let shot = month.appendingPathComponent("screenshots").appendingPathComponent(DateUtil.ymd(date))
        let log = month.appendingPathComponent("\(DateUtil.ymd(date))_\(DateUtil.pad(DateUtil.hour(date))).json")
        return Paths(baseDir: base, monthDir: month, shotDir: shot, logFile: log)
    }

    // MARK: - 截图落盘

    struct SavedShot {
        var abs: String
        var rel: String
        var relRoot: String
        var name: String
        var bytes: Int
    }

    @discardableResult
    func saveScreenshot(_ date: Date, _ jpeg: Data, suffix: String = "", kind: RecordKind = .memento) throws -> SavedShot {
        let p = paths(date, kind)
        try fm.createDirectory(at: p.shotDir, withIntermediateDirectories: true)
        let name = "\(DateUtil.ymd(date))_\(DateUtil.hms(date))\(suffix).jpg"
        let abs = p.shotDir.appendingPathComponent(name)
        try jpeg.write(to: abs, options: .atomic)
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let relRoot = abs.path.hasPrefix(rootPrefix)
            ? String(abs.path.dropFirst(rootPrefix.count))
            : abs.path
        return SavedShot(abs: abs.path, rel: relRoot, relRoot: relRoot, name: name, bytes: jpeg.count)
    }

    // MARK: - 日志读写

    private func decoder() -> JSONDecoder { JSONDecoder() }

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return e
    }

    private func readLog(_ file: URL, _ date: Date) -> HourLog {
        if let data = try? Data(contentsOf: file),
           let log = try? decoder().decode(HourLog.self, from: data),
           !log.date.isEmpty || !log.records.isEmpty {
            return log
        }
        let h = DateUtil.hour(date)
        var log = HourLog()
        log.schema = Store.schemaId
        log.date = DateUtil.ymd(date)
        log.hour = DateUtil.pad(h)
        log.hourRange = "\(DateUtil.pad(h)):00-\(DateUtil.pad((h + 1) % 24)):00"
        log.timezone = TimeZone.current.identifier
        log.device = Host.current().localizedName ?? "Mac"
        log.model = cfg.model
        log.intervalSec = cfg.intervalSec
        log.createdAt = DateUtil.isoLocal(Date())
        log.updatedAt = DateUtil.isoLocal(Date())
        log.stats = LogStats()
        log.records = []
        return log
    }

    /// 只读地拿某个日志文件（不存在返回 nil）
    private func loadLogIfExists(_ file: URL) -> HourLog? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? decoder().decode(HourLog.self, from: data)
    }

    private func recalc(_ log: inout HourLog) {
        var s = LogStats()
        s.total = log.records.count
        var pending = 0
        for r in log.records {
            switch r.status {
            case "done": s.analyzed += 1
            case "skipped": s.skipped += 1
            case "failed": s.failed += 1
            default: pending += 1
            }
        }
        s.pending = pending
        log.stats = s
    }

    private func writeAtomic(_ file: URL, _ log: HourLog) throws {
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder().encode(log)
        let tmp = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier).tmp")
        try data.write(to: tmp)
        if fm.fileExists(atPath: file.path) { try? fm.removeItem(at: file) }
        try fm.moveItem(at: tmp, to: file)
    }

    // MARK: - 增删改

    @discardableResult
    func appendRecord(_ date: Date, _ record: ActRecord, kind: RecordKind? = nil) -> ActRecord {
        let k = kind ?? (record.type == "yinian" ? .yinian : .memento)
        var rec = record
        rec.type = k.rawValue
        let p = paths(date, k)
        var log = readLog(p.logFile, date)
        log.records.append(rec)
        log.records.sort { ($0.epochMs ?? 0) < ($1.epochMs ?? 0) }
        log.model = cfg.model
        log.intervalSec = cfg.intervalSec
        log.updatedAt = DateUtil.isoLocal(Date())
        recalc(&log)
        do { try writeAtomic(p.logFile, log) } catch {
            Log.shared.error("appendRecord write failed: \(error.localizedDescription)")
        }
        return rec
    }

    @discardableResult
    func updateRecord(_ date: Date, id: String, kind: RecordKind = .memento,
                      _ patch: (inout ActRecord) -> Void) -> ActRecord? {
        let p = paths(date, kind)
        var log = readLog(p.logFile, date)
        guard let idx = log.records.firstIndex(where: { $0.id == id }) else { return nil }
        var r = log.records[idx]
        patch(&r)
        r.type = kind.rawValue
        log.records[idx] = r
        log.updatedAt = DateUtil.isoLocal(Date())
        recalc(&log)
        do { try writeAtomic(p.logFile, log) } catch {
            Log.shared.error("updateRecord write failed: \(error.localizedDescription)")
        }
        return r
    }

    /// 按 id 扫描最近 7 天 × 24 小时 × 2 类别，删记录并同步删截图
    @discardableResult
    func deleteRecord(id: String) -> Bool {
        let today = Date()
        for back in 0..<7 {
            let day = DateUtil.addDays(today, -back)
            for h in 0..<24 {
                let d = DateUtil.atHour(day, h)
                for k in [RecordKind.memento, .yinian] {
                    let p = paths(d, k)
                    guard var log = loadLogIfExists(p.logFile) else { continue }
                    guard let idx = log.records.firstIndex(where: { $0.id == id }) else { continue }
                    let removed = log.records.remove(at: idx)
                    log.updatedAt = DateUtil.isoLocal(Date())
                    recalc(&log)
                    try? writeAtomic(p.logFile, log)
                    var toDelete: [String] = []
                    if let a = removed.screenshotAbs, !a.isEmpty { toDelete.append(a) }
                    for s in removed.screenshots ?? [] {
                        if let a = s.abs, !a.isEmpty { toDelete.append(a) }
                    }
                    for path in toDelete { try? fm.removeItem(atPath: path) }
                    return true
                }
            }
        }
        return false
    }

    // MARK: - 查询

    /// 最近 N 条（跨小时/跨天回溯 72 小时，瞬息+一念合并）
    func recent(limit: Int = 40, kind: RecordKind? = nil) -> [ActRecord] {
        var out: [ActRecord] = []
        let now = Date()
        let kinds: [RecordKind] = kind.map { [$0] } ?? [.memento, .yinian]
        var back = 0
        while back < 72 && out.count < limit {
            let d = now.addingTimeInterval(Double(-back) * 3600)
            for k in kinds {
                let p = paths(d, k)
                if let log = loadLogIfExists(p.logFile) {
                    for var r in log.records.reversed() {
                        if r.type == nil { r.type = k.rawValue }
                        out.append(r)
                        if out.count >= limit { break }
                    }
                }
                if out.count >= limit { break }
            }
            back += 1
        }
        return out
    }

    /// 今日统计（瞬息 / 一念 分开）
    func todayStats() -> TodayStats {
        let now = Date()
        var result = TodayStats()
        func collect(_ kind: RecordKind, into target: inout SideStats) {
            for h in 0...DateUtil.hour(now) {
                let d = DateUtil.atHour(now, h)
                guard let log = loadLogIfExists(paths(d, kind).logFile) else { continue }
                for r in log.records {
                    target.total += 1
                    switch r.status {
                    case "done": target.analyzed += 1
                    case "skipped": target.skipped += 1
                    case "failed": target.failed += 1
                    default: break
                    }
                    if let c = r.activity?.category, !c.isEmpty {
                        target.categories[c, default: 0] += 1
                    }
                    if let a = r.activity?.app, !a.isEmpty, a != "未知" {
                        target.apps[a, default: 0] += 1
                    }
                }
            }
        }
        collect(.memento, into: &result.memento)
        collect(.yinian, into: &result.yinian)
        return result
    }

    /// 某一天全部记录（时间正序）
    func dayRecords(_ dateStr: String, kind: RecordKind? = nil) -> [ActRecord] {
        guard let d = DateUtil.parseDateStr(dateStr) else { return [] }
        let kinds: [RecordKind] = kind.map { [$0] } ?? [.memento, .yinian]
        var out: [ActRecord] = []
        for k in kinds {
            for h in 0..<24 {
                let probe = DateUtil.atHour(d, h)
                guard let log = loadLogIfExists(paths(probe, k).logFile) else { continue }
                for var r in log.records {
                    if r.type == nil { r.type = k.rawValue }
                    out.append(r)
                }
            }
        }
        out.sort { ($0.epochMs ?? 0) < ($1.epochMs ?? 0) }
        return out
    }

    /// 一组日期下、某类型原始小时日志文件的最大 mtime（epoch 秒）。
    /// 用于 Digest 新鲜度判定：**仅 stat 文件、不解码**，保持派生数据读取的廉价优势。
    /// 按月归并后逐月扫描，年范围也只需 ~12 次目录列举。
    func maxLogMtime(forDates dates: [String], kind: RecordKind = .memento) -> Int64 {
        var byMonth: [String: Set<String>] = [:]
        for ds in dates {
            guard ds.count >= 10 else { continue }
            let ym = String(ds.prefix(7))
            byMonth[ym, default: []].insert(String(ds.prefix(10)))   // "YYYY-MM-DD"
        }
        let base = typeDir(kind)
        var maxTs: Int64 = 0
        for (ym, daySet) in byMonth {
            let monthDir = base.appendingPathComponent(ym)
            guard let files = try? fm.contentsOfDirectory(atPath: monthDir.path) else { continue }
            for f in files where f.hasSuffix(".json") && f.count == 18 {
                let dayPart = String(f.prefix(10))
                guard daySet.contains(dayPart) else { continue }
                let fp = monthDir.appendingPathComponent(f)
                if let m = (try? fm.attributesOfItem(atPath: fp.path))?[.modificationDate] as? Date {
                    let ts = Int64(m.timeIntervalSince1970)
                    if ts > maxTs { maxTs = ts }
                }
            }
        }
        return maxTs
    }

    /// 多日 focus 分布（只算瞬息）
    func focusBreakdown(_ dateStrs: [String]) -> FocusBreakdown {
        var out = FocusBreakdown()
        for ds in dateStrs {
            for r in dayRecords(ds, kind: .memento) {
                switch r.activity?.focus {
                case "专注": out.focused += 1
                case "分散": out.scattered += 1
                case "空闲": out.idle += 1
                default: break
                }
            }
        }
        return out
    }

    /// 全部记录总数（瞬息 + 一念，不计入截图文件数），一次扫描同时返回两类计数
    func totalCounts() -> (instant: Int, yinian: Int) {
        var instant = 0
        var yinian = 0
        for kind in [RecordKind.memento, RecordKind.yinian] {
            let base = root.appendingPathComponent(kind.dirName)
            guard let months = try? fm.contentsOfDirectory(atPath: base.path) else { continue }
            for mo in months {
                guard mo.count == 7, mo.dropFirst(4).first == "-" else { continue }
                let monthDir = base.appendingPathComponent(mo)
                guard let files = try? fm.contentsOfDirectory(atPath: monthDir.path) else { continue }
                for f in files where f.hasSuffix(".json") && f.count == 18 {
                    guard let log = loadLogIfExists(monthDir.appendingPathComponent(f)) else { continue }
                    if kind == .memento { instant += log.records.count } else { yinian += log.records.count }
                }
            }
        }
        return (instant, yinian)
    }

    /// 可用日期（倒序去重）
    func availableDates() -> [String] {
        var dates = Set<String>()
        func collect(_ sub: String) {
            let base = root.appendingPathComponent(sub)
            guard let months = try? fm.contentsOfDirectory(atPath: base.path) else { return }
            for mo in months {
                guard mo.count == 7, mo.dropFirst(4).first == "-",
                      Int(mo.prefix(4)) != nil, Int(mo.suffix(2)) != nil else { continue }
                guard let files = try? fm.contentsOfDirectory(atPath: base.appendingPathComponent(mo).path) else { continue }
                for f in files {
                    // YYYY-MM-DD_HH.json
                    guard f.hasSuffix(".json"), f.count == 18 else { continue }
                    let ds = String(f.prefix(10))
                    if DateUtil.parseDateStr(ds) != nil { dates.insert(ds) }
                }
            }
        }
        collect("瞬息")
        collect("一念")
        collect("截图日志")   // 兼容旧版目录
        return dates.sorted().reversed()
    }

    /// 全局搜索（多关键词 AND，最新在前）
    func searchAll(_ query: String, limit: Int = 200, kind: RecordKind? = nil) -> [ActRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let keywords = q.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !keywords.isEmpty else { return [] }

        var allLogs: [(String, URL)] = []   // (文件名, 完整路径)
        let dirs: [String] = kind.map { [$0.dirName] } ?? ["瞬息", "一念"]
        for t in dirs {
            let base = root.appendingPathComponent(t)
            guard let months = try? fm.contentsOfDirectory(atPath: base.path) else { continue }
            for mo in months {
                guard mo.count == 7, mo.dropFirst(4).first == "-" else { continue }
                let monthDir = base.appendingPathComponent(mo)
                guard let files = try? fm.contentsOfDirectory(atPath: monthDir.path) else { continue }
                for f in files where f.hasSuffix(".json") && f.count == 18 {
                    allLogs.append((f, monthDir.appendingPathComponent(f)))
                }
            }
        }
        // 文件名倒序 = 日期降序，先读最新
        allLogs.sort { $0.0 > $1.0 }

        var out: [ActRecord] = []
        for (name, url) in allLogs {
            if out.count >= limit { break }
            guard let log = loadLogIfExists(url) else { continue }
            let ds = String(name.prefix(10))
            for var r in log.records.reversed() {
                if Store.matches(r, keywords) {
                    r.date = ds
                    out.append(r)
                    if out.count >= limit { break }
                }
            }
        }
        return out
    }

    /// 一次性抽出全部瞬息/一念记录（跨所有月份 JSON，date/type 已回填，最新在前）。
    /// 供搜索索引建立内存缓存用：避免 `searchAll` 每次搜索都重扫所有历史 JSON。
    func collectAllRecords() -> [ActRecord] {
        var allLogs: [(String, URL, String)] = []   // (文件名, 完整路径, 类型目录名)
        for t in ["瞬息", "一念"] {
            let base = root.appendingPathComponent(t)
            guard let months = try? fm.contentsOfDirectory(atPath: base.path) else { continue }
            for mo in months where mo.count == 7 && mo.dropFirst(4).first == "-" {
                let monthDir = base.appendingPathComponent(mo)
                guard let files = try? fm.contentsOfDirectory(atPath: monthDir.path) else { continue }
                for f in files where f.hasSuffix(".json") && f.count == 18 {
                    allLogs.append((f, monthDir.appendingPathComponent(f), t))
                }
            }
        }
        // 文件名倒序 = 日期降序，先读最新
        allLogs.sort { $0.0 > $1.0 }

        let kindOf: (String) -> RecordKind = { $0 == "一念" ? .yinian : .memento }
        var out: [ActRecord] = []
        for (name, url, dirName) in allLogs {
            guard let log = loadLogIfExists(url) else { continue }
            let ds = String(name.prefix(10))
            for var r in log.records {
                if r.type == nil || r.type!.isEmpty {
                    r.type = kindOf(dirName).rawValue
                }
                r.date = ds
                out.append(r)
            }
        }
        return out
    }

    /// 全部一念记录（按时间倒序，最新在前；date 字段回填）
    func allYinian(limit: Int = 400) -> [ActRecord] {
        let base = root.appendingPathComponent(RecordKind.yinian.dirName)
        var logs: [(String, URL)] = []
        guard let months = try? fm.contentsOfDirectory(atPath: base.path) else { return [] }
        for mo in months {
            guard mo.count == 7, mo.dropFirst(4).first == "-" else { continue }
            let monthDir = base.appendingPathComponent(mo)
            guard let files = try? fm.contentsOfDirectory(atPath: monthDir.path) else { continue }
            for f in files where f.hasSuffix(".json") && f.count == 18 {
                logs.append((f, monthDir.appendingPathComponent(f)))
            }
        }
        logs.sort { $0.0 > $1.0 }   // 文件名倒序 = 日期降序
        var out: [ActRecord] = []
        for (name, url) in logs {
            if out.count >= limit { break }
            guard let log = loadLogIfExists(url) else { continue }
            let ds = String(name.prefix(10))
            for var r in log.records.reversed() where r.type == "yinian" {
                r.date = ds
                out.append(r)
                if out.count >= limit { break }
            }
        }
        return out
    }

    nonisolated static func matches(_ r: ActRecord, _ keywords: [String]) -> Bool {
        let a = r.activity
        let blob = [
            a?.app ?? "", a?.title ?? "", a?.category ?? "", a?.focus ?? "",
            a?.summaryText ?? "", (a?.keywords ?? []).joined(separator: " "), r.time ?? ""
        ].joined(separator: " ").lowercased()
        return keywords.allSatisfy { blob.contains($0) }
    }

    /// 按日期 + 关键词（最新在前）；limit <= 0 表示不截断
    func listByDate(_ dateStr: String, search: String = "", limit: Int = 300, kind: RecordKind? = nil) -> [ActRecord] {
        var recs = dayRecords(dateStr, kind: kind)
        recs.reverse()
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            recs = recs.filter { Store.matches($0, [q]) }
        }
        return limit > 0 ? Array(recs.prefix(limit)) : recs
    }

    /// 分类占比（饼图用；默认只看瞬息）
    func categoryBreakdown(_ dateStrs: [String], kind: RecordKind = .memento) -> CategoryBreakdown {
        var cats: [String: Int] = [:]
        var total = 0, analyzed = 0
        for ds in dateStrs {
            for r in dayRecords(ds, kind: kind) {
                total += 1
                if r.status == "done" { analyzed += 1 }
                if let c = r.activity?.category, !c.isEmpty { cats[c, default: 0] += 1 }
            }
        }
        var out = CategoryBreakdown()
        out.total = total
        out.analyzed = analyzed
        out.categories = cats.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ($0.key, $0.value) }
        return out
    }

    /// Top N 应用（只算已分析记录）
    func appTopList(_ dateStrs: [String], limit: Int = 5, kind: RecordKind = .memento) -> [AppCount] {
        var counter: [String: Int] = [:]
        for ds in dateStrs {
            for r in dayRecords(ds, kind: kind) {
                guard r.status == "done" else { continue }
                guard let app = r.activity?.app, !app.isEmpty, app != "未知" else { continue }
                counter[app, default: 0] += 1
            }
        }
        return counter.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit)
            .map { AppCount(app: $0.key, count: $0.value) }
    }

    // MARK: - 存储统计与清理

    private struct ShotEntry {
        var url: URL
        var mtime: TimeInterval
        var bytes: Int64
    }

    private func walk(_ dir: URL, onFile: (URL, String) -> Void) {
        guard let en = fm.enumerator(at: dir,
                                     includingPropertiesForKeys: [.isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return }
        for case let url as URL in en {
            let name = url.lastPathComponent
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            onFile(url, name.lowercased())
        }
    }

    func storageStats() -> StorageStats {
        var s = StorageStats()
        s.root = rootPath
        walk(root) { url, lower in
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return }
            if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") {
                s.shotCount += 1
                s.shotBytes += size
            } else if lower.hasSuffix(".json") {
                s.jsonCount += 1
                s.jsonBytes += size
            }
        }
        return s
    }

    /// 清理截图（图文分离：JSON 永远保留）
    func cleanup(_ rules: CleanupRules) -> CleanupResult {
        var shots: [ShotEntry] = []
        walk(root) { url, lower in
            guard lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") else { return }
            guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                  let size = attrs[.size] as? Int64 else { return }
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            shots.append(ShotEntry(url: url, mtime: mtime, bytes: size))
        }
        shots.sort { $0.mtime < $1.mtime }   // 最早在前

        let now = Date().timeIntervalSince1970
        let cutoff = rules.olderThanDays > 0 ? now - Double(rules.olderThanDays) * 86400 : 0
        var toDelete = Set<String>()

        // 规则1：按时间期限
        if cutoff > 0 {
            for s in shots where s.mtime < cutoff { toDelete.insert(s.url.path) }
        }
        // 规则2：按数量上限
        if rules.maxShots > 0 && shots.count > rules.maxShots {
            var kept = 0
            for s in shots {
                if toDelete.contains(s.url.path) { continue }
                if kept < rules.maxShots { kept += 1 } else { toDelete.insert(s.url.path) }
            }
        }
        // 规则3：按容量上限
        if rules.maxBytes > 0 {
            var used = shots.reduce(Int64(0)) { toDelete.contains($1.url.path) ? $0 : $0 + $1.bytes }
            for s in shots {
                if toDelete.contains(s.url.path) { continue }
                if used > rules.maxBytes {
                    toDelete.insert(s.url.path)
                    used -= s.bytes
                }
            }
        }

        var res = CleanupResult()
        for s in shots where toDelete.contains(s.url.path) {
            if (try? fm.removeItem(at: s.url)) != nil {
                res.deletedShots += 1
                res.freedBytes += s.bytes
            }
        }
        // 规则4：图文分离 —— JSON 永远保留，只统计数量
        if rules.keepJson {
            var count = 0
            walk(root) { _, lower in if lower.hasSuffix(".json") { count += 1 } }
            res.keptJson = count
        }
        return res
    }

    // MARK: - 周期总结缓存

    func summaryDir() -> URL { root.appendingPathComponent("summary") }

    func readSummary(_ key: String) -> SummaryDoc? {
        let f = summaryDir().appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: f) else { return nil }
        return try? decoder().decode(SummaryDoc.self, from: data)
    }

    func writeSummary(_ key: String, _ doc: SummaryDoc) {
        let dir = summaryDir()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? encoder().encode(doc) else { return }
        try? data.write(to: dir.appendingPathComponent("\(key).json"), options: .atomic)
    }

    func appendSummaryHistory(_ key: String, _ doc: SummaryDoc) {
        let dir = summaryDir().appendingPathComponent("history")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("\(key).json")
        var arr: [SummaryDoc] = []
        if let data = try? Data(contentsOf: f),
           let old = try? decoder().decode([SummaryDoc].self, from: data) {
            arr = old
        }
        arr.insert(doc, at: 0)
        if arr.count > 30 { arr = Array(arr.prefix(30)) }
        guard let data = try? encoder().encode(arr) else { return }
        try? data.write(to: f, options: .atomic)
    }

    func listSummaryHistory(_ key: String) -> [SummaryDoc] {
        let f = summaryDir().appendingPathComponent("history").appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: f),
              let arr = try? decoder().decode([SummaryDoc].self, from: data) else { return [] }
        return arr
    }

    func deleteSummaryHistory(_ key: String, generatedAt: String) {
        let f = summaryDir().appendingPathComponent("history").appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: f),
              var arr = try? decoder().decode([SummaryDoc].self, from: data) else { return }
        arr.removeAll { $0.generatedAt == generatedAt }
        guard let out = try? encoder().encode(arr) else { return }
        try? out.write(to: f, options: .atomic)
    }

    /// 单次遍历区间，产出饼图/TopApp/聚焦/趋势所需的全部统计，避免 loadScroll 对同一天重复读 3 次。
    struct ScopeStats {
        var categories: [(String, Int)] = []
        var total = 0
        var analyzed = 0
        var topApps: [AppCount] = []
        /// 全量 App 计数（不截断 Top5），供洞察页识别 AI 类应用 / 长期主题。
        var allApps: [AppCount] = []
        /// 旧口径：按「记录条数」统计的专注/分散/空闲（全景圆环沿用此口径，勿改）
        var focus = FocusBreakdown()
        /// 新口径：本地时间序列算法算出的真实专注报告（时长加权 + 干扰/切换次数 + 专注时段）
        var focusReport = FocusAnalyzer.Report()
        var trend: [(String, Int)] = []
        var hourly: [Int] = []
        /// 逐小时分类计数（仅 includeHourly 时填充，24 段），供时间轨迹按活动类型着色。
        var hourlyCats: [[String: Int]] = []
    }

    func scopeStats(dates: [String], includeHourly: Bool = false) -> ScopeStats {
        var cats: [String: Int] = [:]
        var apps: [String: Int] = [:]
        var fb = FocusBreakdown()
        var trend: [(String, Int)] = []
        var hourly = Array(repeating: 0, count: 24)
        var hourlyCats = Array(repeating: [String: Int](), count: 24)
        var total = 0, analyzed = 0
        var dayReports: [FocusAnalyzer.Report] = []

        for ds in dates {
            let recs = dayRecords(ds, kind: .memento)
            // 专注度按「天」独立计算再合并：跨天直接算会把夜间空档当成活动时长
            dayReports.append(FocusAnalyzer.analyze(recs))
            var dayCount = 0
            for r in recs {
                total += 1
                dayCount += 1
                if r.statusEnum == .done { analyzed += 1 }
                if let c = r.activity?.category, !c.isEmpty { cats[c, default: 0] += 1 }
                if let a = r.activity?.app, !a.isEmpty, a != "未知" { apps[a, default: 0] += 1 }
                switch r.activity?.focus {
                case "专注": fb.focused += 1
                case "分散": fb.scattered += 1
                case "空闲": fb.idle += 1
                default: break
                }
                if includeHourly, let t = r.time, t.count >= 2, let hh = Int(t.prefix(2)) {
                    hourly[hh] += 1
                    if let c = r.activity?.category, !c.isEmpty { hourlyCats[hh][c, default: 0] += 1 }
                }
            }
            trend.append((ds, dayCount))
        }

        let catArr = cats.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { ($0.key, $0.value) }
        let appArr = apps.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        let allApps = appArr.map { AppCount(app: $0.key, count: $0.value) }
        let topApps = Array(allApps.prefix(5))

        var s = ScopeStats()
        s.categories = catArr
        s.total = total
        s.analyzed = analyzed
        s.topApps = topApps
        s.allApps = allApps
        s.focus = fb
        s.focusReport = FocusAnalyzer.merge(dayReports)
        s.trend = trend
        s.hourly = hourly
        s.hourlyCats = hourlyCats
        return s
    }

    // MARK: - 分层摘要（Day/Week/Month/Year Digest）

    /// 摘要根目录：<root>/summary/digest/<scope>/<key>.json
    func digestDir(forScope scope: String) -> URL {
        root.appendingPathComponent("summary").appendingPathComponent("digest").appendingPathComponent(scope)
    }

    func readDigest(key: String) -> ActivityDigest? {
        // key 形如 "day-2026-08-13"：scope 是第一段
        let scope = key.split(separator: "-").first.map(String.init) ?? "day"
        let f = digestDir(forScope: scope).appendingPathComponent("\(key).json")
        guard let data = try? Data(contentsOf: f) else { return nil }
        return try? decoder().decode(ActivityDigest.self, from: data)
    }

    func writeDigest(_ d: ActivityDigest) {
        let dir = digestDir(forScope: d.scope)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? encoder().encode(d) else { return }
        let f = dir.appendingPathComponent("\(d.key).json")
        try? data.write(to: f, options: .atomic)
    }

    /// 列出某 scope 下所有 digest key（按 key 倒序，最新在前）
    func listDigestKeys(scope: String) -> [String] {
        let dir = digestDir(forScope: scope)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
            .sorted(by: >)
    }

    // MARK: - 备份 / 恢复

    /// 导出：把 瞬息/ 一念/ summary/ 随想/ 下所有 JSON 打成一个大文件
    ///
    /// ⚠️ 局限（刻意保留，勿当作完整备份）：只收 **文本 JSON**，
    /// 不含截图、随想正文 `content.rtfd`、随想附件等二进制。
    /// 完整备份请用设置页的「导出备份（.bak）」→ `Migration.tarCreate`（整目录 tar）。
    /// 当前 UI 走的是 tar 路径，本函数仅作兼容保留。
    func exportBackup(to dest: URL) throws -> Int {
        struct Entry: Codable { var path: String; var content: String }
        var entries: [Entry] = []
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for sub in ["瞬息", "一念", "summary", MuseStore.dirName] {
            let dir = root.appendingPathComponent(sub)
            guard fm.fileExists(atPath: dir.path) else { continue }
            walk(dir) { url, lower in
                guard lower.hasSuffix(".json") else { return }
                guard let txt = try? String(contentsOf: url, encoding: .utf8) else { return }
                let rel = url.path.hasPrefix(rootPrefix)
                    ? String(url.path.dropFirst(rootPrefix.count)) : url.lastPathComponent
                entries.append(Entry(path: rel, content: txt))
            }
        }
        struct Backup: Codable {
            var app = "留刻"
            var version = AppInfo.version
            var exportedAt: String
            var fileCount: Int
            var files: [Entry]
        }
        let backup = Backup(exportedAt: DateUtil.isoLocal(Date()), fileCount: entries.count, files: entries)
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        try e.encode(backup).write(to: dest, options: .atomic)
        return entries.count
    }

    /// 导入：把备份文件里的 JSON 还原回数据目录（同名覆盖）
    func importBackup(from src: URL) throws -> Int {
        struct Entry: Codable { var path: String; var content: String }
        struct Backup: Codable { var files: [Entry]? }
        let data = try Data(contentsOf: src)
        guard let backup = try? decoder().decode(Backup.self, from: data),
              let files = backup.files, !files.isEmpty else {
            throw NSError(domain: "Liuke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "备份文件格式无法识别"])
        }
        var n = 0
        for f in files {
            // 只允许写回数据目录内部，防止路径穿越
            guard !f.path.contains(".."), !f.path.hasPrefix("/") else { continue }
            let dest = root.appendingPathComponent(f.path)
            try? fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? f.content.write(to: dest, atomically: true, encoding: .utf8)) != nil { n += 1 }
        }
        return n
    }
}
