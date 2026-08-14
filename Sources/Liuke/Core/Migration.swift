import Foundation

/// 数据目录迁移 / 旧路径修复 / 备份导入导出
/// 对应 Electron 版 main.js 中的：
///   rewriteOldPaths / rewriteAbsRoot / migrateDataDir / renameOrCopy / mergeDir
///   backup:export（tar -czf） / backup:import（tar -xzf）
enum Migration {

    private static let fm = FileManager.default
    private static let typeDirs = ["瞬息", "一念"]

    // MARK: - 目录搬迁

    /// 把旧目录下所有内容（瞬息 / 一念 / summary 等）移动或合并到新目录
    /// 对应 main.js `migrateDataDir(oldDir, newDir)`
    static func migrateDataDir(from oldDir: String, to newDir: String) throws {
        guard oldDir != newDir else { return }
        guard fm.fileExists(atPath: oldDir) else { return }
        try fm.createDirectory(atPath: newDir, withIntermediateDirectories: true)

        let names = (try? fm.contentsOfDirectory(atPath: oldDir)) ?? []
        for name in names {
            if name == ".DS_Store" { continue }
            let s = (oldDir as NSString).appendingPathComponent(name)
            let d = (newDir as NSString).appendingPathComponent(name)
            if isDir(s) {
                if fm.fileExists(atPath: d) {
                    try mergeDir(from: s, to: d)      // 目标已存在 → 递归合并
                } else {
                    try renameOrCopy(from: s, to: d)
                }
            } else if !fm.fileExists(atPath: d) {
                try renameOrCopy(from: s, to: d)
            }
        }
        // 旧目录若已空则删掉（非空则保留，不做破坏性操作）
        try? removeIfEmpty(oldDir)
    }

    /// rename 失败（跨卷 EXDEV 等）时降级为 复制 + 删除
    /// 对应 main.js `renameOrCopy(src, dst)`
    static func renameOrCopy(from src: String, to dst: String) throws {
        do {
            try fm.moveItem(atPath: src, toPath: dst)
        } catch {
            if fm.fileExists(atPath: dst) { try? fm.removeItem(atPath: dst) }
            try fm.copyItem(atPath: src, toPath: dst)
            try? fm.removeItem(atPath: src)
        }
    }

    /// 递归合并目录（备份恢复语义）：
    /// - 同名/同 ID 文件 → 以「备份源」为准覆盖（恢复即还原备份内容）；
    /// - 目标独有文件 → 保留不删（不破坏用户当前数据）；
    /// - 目录递归深入（随想 notes/{id}/ 与 attachments/ 均逐文件合并）。
    /// 对应 main.js `mergeDir(src, dst)`，但修正了「已存在则不恢复」的隐患。
    static func mergeDir(from src: String, to dst: String) throws {
        try fm.createDirectory(atPath: dst, withIntermediateDirectories: true)
        let names = (try? fm.contentsOfDirectory(atPath: src)) ?? []
        for name in names {
            if name == ".DS_Store" { continue }
            let s = (src as NSString).appendingPathComponent(name)
            let d = (dst as NSString).appendingPathComponent(name)
            if isDir(s) {
                try mergeDir(from: s, to: d)
            } else {
                // 冲突：先移除目标再搬入备份源（备份优先）
                if fm.fileExists(atPath: d) { try? fm.removeItem(atPath: d) }
                try renameOrCopy(from: s, to: d)
            }
        }
        try? removeIfEmpty(src)
    }

    // MARK: - 路径重写

    /// 保存目录变更后：把所有 record 里的截图绝对路径从 oldRoot 重写为 newRoot
    /// （否则 lens://shot 的"必须在 outputDir 下"校验会 403，图片全读不出来）
    /// 对应 main.js `rewriteAbsRoot(rootDir, oldRoot, newRoot)`
    @discardableResult
    static func rewriteAbsRoot(root rootDir: String, oldRoot: String, newRoot: String) throws -> Int {
        let oldNorm = trimSlash(URL(fileURLWithPath: oldRoot).standardizedFileURL.path)
        let newNorm = trimSlash(URL(fileURLWithPath: newRoot).standardizedFileURL.path)
        guard oldNorm != newNorm else { return 0 }

        let n = try rewriteAll(rootDir: rootDir) { p in
            let norm = p.replacingOccurrences(of: "\\", with: "/")
            if norm == oldNorm || norm.hasPrefix(oldNorm + "/") {
                return newNorm + String(norm.dropFirst(oldNorm.count))
            }
            return p
        }
        if n > 0 { Log.shared.info("已把 \(n) 条 record 的截图路径从 \(oldNorm) 重写到 \(newNorm)") }
        return n
    }

    /// 把所有 record 里的"老版本路径"重写为新版 瞬息/一念 路径（每次启动跑一次，幂等）
    /// 覆盖两种历史路径：
    ///   1. v0.x:   留刻/YYYY-MM/screenshots/...   → 留刻/瞬息/YYYY-MM/screenshots/...
    ///   2. v1.0rc: 留刻/截图日志/...              → 留刻/...
    /// 对应 main.js `rewriteOldPaths(rootDir)`
    @discardableResult
    static func rewriteOldPaths(root rootDir: String) throws -> Int {
        let rootResolved = URL(fileURLWithPath: rootDir).standardizedFileURL.path

        let n = try rewriteAll(rootDir: rootDir) { p in
            let norm = p.replacingOccurrences(of: "\\", with: "/")
            // 规则 1：留刻/(YYYY-MM)/screenshots/ → 留刻/瞬息/(YYYY-MM)/screenshots/
            if let m = matchV0(norm),
               URL(fileURLWithPath: m.head).standardizedFileURL.path.hasPrefix(rootResolved),
               !norm.contains("/留刻/瞬息/"), !norm.contains("/留刻/一念/") {
                return m.head + "瞬息/" + m.month + m.tail
            }
            // 规则 2：留刻/截图日志/ → 留刻/
            if norm.contains("/留刻/截图日志/") {
                return norm.replacingOccurrences(of: "/留刻/截图日志/", with: "/留刻/")
            }
            return p
        }
        if n > 0 { Log.shared.info("已重写 \(n) 条 record 的旧截图绝对路径") }
        return n
    }

    /// `^(.*/留刻/)(\d{4}-\d{2})(/screenshots/.*)$`
    private static func matchV0(_ norm: String) -> (head: String, month: String, tail: String)? {
        guard let shotRange = norm.range(of: "/screenshots/") else { return nil }
        let before = String(norm[norm.startIndex..<shotRange.lowerBound])   // .../留刻/YYYY-MM
        let tail = String(norm[shotRange.lowerBound...])                    // /screenshots/...
        guard let slash = before.lastIndex(of: "/") else { return nil }
        let month = String(before[before.index(after: slash)...])
        guard isYearMonth(month) else { return nil }
        let head = String(before[before.startIndex...slash])                // .../留刻/
        guard head.hasSuffix("/留刻/") else { return nil }
        return (head, month, tail)
    }

    /// 遍历 瞬息/一念 下所有小时日志，对每条 record 的截图路径套用 transform，有变化才原子回写
    private static func rewriteAll(rootDir: String, transform: (String) -> String) throws -> Int {
        var rewritten = 0
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]

        for t in typeDirs {
            let typeBase = (rootDir as NSString).appendingPathComponent(t)
            guard isDir(typeBase) else { continue }
            let months = (try? fm.contentsOfDirectory(atPath: typeBase)) ?? []
            for mo in months.sorted() {
                let monthDir = (typeBase as NSString).appendingPathComponent(mo)
                guard isYearMonth(mo), isDir(monthDir) else { continue }
                let files = (try? fm.contentsOfDirectory(atPath: monthDir)) ?? []
                for f in files.sorted() {
                    guard isHourLogName(f) else { continue }
                    let fp = (monthDir as NSString).appendingPathComponent(f)
                    guard let data = fm.contents(atPath: fp),
                          var log = try? decoder.decode(HourLog.self, from: data) else { continue }

                    var changed = false
                    for i in log.records.indices {
                        if let abs = log.records[i].screenshotAbs, !abs.isEmpty {
                            let next = transform(abs)
                            if next != abs { log.records[i].screenshotAbs = next; changed = true; rewritten += 1 }
                        }
                        if var shots = log.records[i].screenshots, !shots.isEmpty {
                            var shotChanged = false
                            for j in shots.indices {
                                guard let abs = shots[j].abs, !abs.isEmpty else { continue }
                                let next = transform(abs)
                                if next != abs { shots[j].abs = next; shotChanged = true }
                            }
                            if shotChanged {
                                log.records[i].screenshots = shots
                                if !changed { rewritten += 1 }
                                changed = true
                            }
                        }
                    }
                    if changed, let out = try? encoder.encode(log) {
                        let tmp = fp + ".\(ProcessInfo.processInfo.processIdentifier).tmp"
                        if (try? out.write(to: URL(fileURLWithPath: tmp), options: .atomic)) != nil {
                            _ = try? fm.replaceItemAt(URL(fileURLWithPath: fp),
                                                      withItemAt: URL(fileURLWithPath: tmp))
                            try? fm.removeItem(atPath: tmp)
                        }
                    }
                }
            }
        }
        return rewritten
    }

    // MARK: - 备份 / 恢复（tar，与 Electron 版 .bak 完全兼容）

    /// `tar -czf <archive> -C <sourceDir> .`
    static func tarCreate(archive: String, sourceDir: String) async throws {
        guard fm.fileExists(atPath: sourceDir) else {
            throw err("保存目录不存在")
        }
        try await run("/usr/bin/tar", ["-czf", archive, "-C", sourceDir, "."])
        Log.shared.info("已导出备份：\(archive)")
    }

    /// 需要「递归合并」的数据域顶层目录（4 个数据域一视同仁）
    /// 瞬息 / 一念：月份目录 + 小时日志 + screenshots
    /// summary：AI 总结 + digest/
    /// 随想：notes/{id}/{note.json,content.rtfd,attachments/} + .groups.json
    private static let mergeTopDirs: Set<String> = ["瞬息", "一念", "summary", "随想"]

    /// 数据完整性快照（导入前后各取一次做对比日志）
    struct DataStats {
        var hourLogs = 0        // 瞬息 + 一念 小时日志文件数
        var records = 0         // 两者 record 总条数
        var screenshots = 0     // screenshots/ 下图片文件数
        var summaries = 0       // summary/ 下 summary-*.json
        var digests = 0         // summary/digest/**/*.json
        var notes = 0           // 随想 笔记数（新结构 notes/{id}/note.json + 旧结构根 *.json）
        var museAttachments = 0 // 随想附件文件数

        var line: String {
            "小时日志 \(hourLogs) · 瞬息/一念记录 \(records) · 截图 \(screenshots)"
            + " · 总结 \(summaries) · digest \(digests) · 随想 \(notes) · 随想附件 \(museAttachments)"
        }
    }

    /// 统计一个数据根目录的关键数量（只读，不改任何文件）
    static func dataStats(root rootDir: String) -> DataStats {
        var st = DataStats()
        guard isDir(rootDir) else { return st }
        let decoder = JSONDecoder()

        // 瞬息 / 一念
        for t in typeDirs {
            let typeBase = (rootDir as NSString).appendingPathComponent(t)
            guard isDir(typeBase) else { continue }
            for mo in (try? fm.contentsOfDirectory(atPath: typeBase)) ?? [] {
                let monthDir = (typeBase as NSString).appendingPathComponent(mo)
                guard isYearMonth(mo), isDir(monthDir) else { continue }
                for f in (try? fm.contentsOfDirectory(atPath: monthDir)) ?? [] {
                    let fp = (monthDir as NSString).appendingPathComponent(f)
                    if isHourLogName(f) {
                        st.hourLogs += 1
                        if let data = fm.contents(atPath: fp),
                           let log = try? decoder.decode(HourLog.self, from: data) {
                            st.records += log.records.count
                        }
                    } else if f == "screenshots", isDir(fp) {
                        for day in (try? fm.contentsOfDirectory(atPath: fp)) ?? [] {
                            let dayDir = (fp as NSString).appendingPathComponent(day)
                            guard isDir(dayDir) else { continue }
                            let imgs = ((try? fm.contentsOfDirectory(atPath: dayDir)) ?? [])
                                .filter { $0 != ".DS_Store" }
                            st.screenshots += imgs.count
                        }
                    }
                }
            }
        }

        // summary（含 digest 子树）
        let sumDir = (rootDir as NSString).appendingPathComponent("summary")
        if isDir(sumDir) {
            for f in (try? fm.contentsOfDirectory(atPath: sumDir)) ?? [] {
                if f.hasSuffix(".json") { st.summaries += 1 }
            }
            let digestRoot = (sumDir as NSString).appendingPathComponent("digest")
            if isDir(digestRoot) {
                for scope in (try? fm.contentsOfDirectory(atPath: digestRoot)) ?? [] {
                    let sd = (digestRoot as NSString).appendingPathComponent(scope)
                    guard isDir(sd) else { continue }
                    st.digests += ((try? fm.contentsOfDirectory(atPath: sd)) ?? [])
                        .filter { $0.hasSuffix(".json") }.count
                }
            }
        }

        // 随想
        let museDir = (rootDir as NSString).appendingPathComponent(MuseStore.dirName)
        if isDir(museDir) {
            let notesDir = (museDir as NSString).appendingPathComponent(MuseStore.notesDirName)
            var newIDs = Set<String>()
            if isDir(notesDir) {
                for id in (try? fm.contentsOfDirectory(atPath: notesDir)) ?? [] {
                    let nd = (notesDir as NSString).appendingPathComponent(id)
                    guard isDir(nd) else { continue }
                    let meta = (nd as NSString).appendingPathComponent("note.json")
                    guard fm.fileExists(atPath: meta) else { continue }
                    newIDs.insert(id)
                    st.notes += 1
                    let ad = (nd as NSString).appendingPathComponent(MuseStore.attachmentsDirName)
                    if isDir(ad) {
                        st.museAttachments += ((try? fm.contentsOfDirectory(atPath: ad)) ?? [])
                            .filter { $0 != ".DS_Store" }.count
                    }
                }
            }
            // 旧结构：随想/{id}.json（排除 .groups.json 与已迁移的）
            for f in (try? fm.contentsOfDirectory(atPath: museDir)) ?? [] {
                guard f.hasSuffix(".json"), !f.hasPrefix(".") else { continue }
                let id = String(f.dropLast(5))
                if !newIDs.contains(id) { st.notes += 1 }
            }
        }
        return st
    }

    /// 解压 .bak 并恢复到 outputDir，返回恢复的顶层项数
    /// 对应 main.js `backup:import`
    ///
    /// 恢复语义（4 个数据域一致）：
    /// - 瞬息 / 一念 / summary / 随想 → 递归 mergeDir，同名文件以备份为准覆盖，
    ///   目标独有文件保留；**绝不因为目标目录已存在就整体跳过**。
    /// - 旧版平铺 YYYY-MM 目录 → 并入 瞬息/。
    /// - 其它未知目录 → 同样递归合并（而不是"存在就跳过"）。
    /// - 顶层散文件（如 config 快照）→ 覆盖写入。
    static func importBackup(archive: String, outputDir: String) async throws -> Int {
        let tmpDir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("liuke-restore-\(Int(Date().timeIntervalSince1970 * 1000))")
        defer { try? fm.removeItem(atPath: tmpDir) }

        try fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        try await run("/usr/bin/tar", ["-xzf", archive, "-C", tmpDir])

        try fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

        // 完整性校验：恢复前 / 备份包内 / 恢复后
        let before = dataStats(root: outputDir)
        let inPack = dataStats(root: tmpDir)
        Log.shared.info("备份恢复 · 恢复前本地：\(before.line)")
        Log.shared.info("备份恢复 · 备份包内：\(inPack.line)")

        let entries = (try? fm.contentsOfDirectory(atPath: tmpDir)) ?? []
        var restored = 0
        for name in entries {
            if name == ".DS_Store" { continue }
            let s = (tmpDir as NSString).appendingPathComponent(name)
            if mergeTopDirs.contains(name), isDir(s) {
                try mergeDir(from: s, to: (outputDir as NSString).appendingPathComponent(name))
            } else if isDir(s), isYearMonth(name) {
                // 旧版平铺月份目录 → 并入 瞬息/
                let d = ((outputDir as NSString).appendingPathComponent("瞬息") as NSString)
                    .appendingPathComponent(name)
                try mergeDir(from: s, to: d)
            } else if isDir(s) {
                // 未知目录：也走合并，避免"目标已存在 → 整体丢失"
                try mergeDir(from: s, to: (outputDir as NSString).appendingPathComponent(name))
            } else {
                // 顶层散文件：以备份为准覆盖
                let d = (outputDir as NSString).appendingPathComponent(name)
                if fm.fileExists(atPath: d) { try? fm.removeItem(atPath: d) }
                try? renameOrCopy(from: s, to: d)
            }
            restored += 1
        }
        // 修复旧路径引用
        _ = try? rewriteOldPaths(root: outputDir)

        let after = dataStats(root: outputDir)
        Log.shared.info("备份恢复 · 恢复后本地：\(after.line)")
        // 恢复后任一维度低于备份包 → 说明有内容没落地，明确告警（不静默）
        var missing: [String] = []
        if after.hourLogs < inPack.hourLogs { missing.append("小时日志 \(after.hourLogs)/\(inPack.hourLogs)") }
        if after.records < inPack.records { missing.append("记录 \(after.records)/\(inPack.records)") }
        if after.screenshots < inPack.screenshots { missing.append("截图 \(after.screenshots)/\(inPack.screenshots)") }
        if after.summaries < inPack.summaries { missing.append("总结 \(after.summaries)/\(inPack.summaries)") }
        if after.digests < inPack.digests { missing.append("digest \(after.digests)/\(inPack.digests)") }
        if after.notes < inPack.notes { missing.append("随想 \(after.notes)/\(inPack.notes)") }
        if after.museAttachments < inPack.museAttachments {
            missing.append("随想附件 \(after.museAttachments)/\(inPack.museAttachments)")
        }
        if missing.isEmpty {
            Log.shared.info("备份恢复 · 完整性校验通过（\(restored) 个顶层项）")
        } else {
            Log.shared.error("备份恢复 · 完整性校验异常，以下维度少于备份包：\(missing.joined(separator: "、"))")
        }
        Log.shared.info("已导入备份：\(archive)（\(restored) 项）")
        return restored
    }

    // MARK: - 小工具

    private static func run(_ launchPath: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = args
            let errPipe = Pipe()
            p.standardError = errPipe
            p.standardOutput = Pipe()
            p.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else {
                    let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                     encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    cont.resume(throwing: err(msg.isEmpty
                        ? "tar 执行失败（code \(proc.terminationStatus)）" : msg))
                }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "Liuke.Migration", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private static func isDir(_ path: String) -> Bool {
        var d: ObjCBool = false
        return fm.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }

    private static func removeIfEmpty(_ path: String) throws {
        let left = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        let real = left.filter { $0 != ".DS_Store" }
        if real.isEmpty { try? fm.removeItem(atPath: path) }
    }

    private static func trimSlash(_ s: String) -> String {
        var out = s
        while out.count > 1 && out.hasSuffix("/") { out.removeLast() }
        return out
    }

    /// `^\d{4}-\d{2}$`
    private static func isYearMonth(_ s: String) -> Bool {
        let c = Array(s)
        guard c.count == 7, c[4] == "-" else { return false }
        return c[0].isNumber && c[1].isNumber && c[2].isNumber && c[3].isNumber
            && c[5].isNumber && c[6].isNumber
    }

    /// `^\d{4}-\d{2}-\d{2}_\d{2}\.json$`
    private static func isHourLogName(_ s: String) -> Bool {
        guard s.hasSuffix(".json") else { return false }
        let stem = String(s.dropLast(5))
        let c = Array(stem)
        guard c.count == 13, c[4] == "-", c[7] == "-", c[10] == "_" else { return false }
        for i in [0, 1, 2, 3, 5, 6, 8, 9, 11, 12] where !c[i].isNumber { return false }
        return true
    }
}
