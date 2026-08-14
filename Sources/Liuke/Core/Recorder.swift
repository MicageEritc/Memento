import Foundation
import AppKit
import CoreGraphics

/// 抓屏 + 编码后的结果（全部是值类型，方便跨线程传递）
struct ShotBundle: @unchecked Sendable {
    var primaryJpeg: Data?
    var extraJpegs: [(suffix: String, data: Data, label: String)] = []
    var analyzeJpeg: Data
    var hash: String
    /// 中心内容区 dHash（排除菜单栏/坞/边框），用于"App 不变但内容变化"的语义检测
    var contentHash: String
    var label: String
    var width: Int
    var height: Int
    var nativeWidth: Int
    var nativeHeight: Int
    var screens: Int
}

struct Counters: Equatable {
    var captured = 0
    var analyzed = 0
    var skipped = 0
    var failed = 0
    var dropped = 0
    var idle = 0
}

/// 调度器 —— 对应 recorder.js
@MainActor
final class Recorder: ObservableObject {

    private static let maxQueue = 3

    private let store: Store
    private let getConfig: () -> AppConfig

    @Published private(set) var running = false
    @Published private(set) var working = false
    @Published private(set) var queued = 0
    @Published private(set) var statusText = "未启动"
    @Published private(set) var lastError: String?
    @Published private(set) var counters = Counters()
    @Published private(set) var current: Activity?
    private(set) var currentId: String?
    private(set) var nextAt: TimeInterval = 0     // epoch ms
    private(set) var lastTickAt: TimeInterval = 0

    /// 有新记录（或记录被更新）；nil 表示"只需刷新列表"
    var onRecord: ((ActRecord?) -> Void)?
    var onPermission: ((PermissionState) -> Void)?
    var onLog: ((String, Bool) -> Void)?

    private var timer: Timer?
    private var lastHash: String?
    private var lastContentHash: String?
    private var lastFrontApp: String?
    private var lastWindowTitle: String?
    private var lastIdleState = false
    private var lastActivity: Activity?
    private var lastActivityId: String?
    private var idleLogged = false

    private struct Job {
        var date: Date
        var recordId: String
        var kind: RecordKind
        var jpeg: Data
    }
    private var pending: [Job] = []
    private var sleeping = false

    init(store: Store, getConfig: @escaping () -> AppConfig) {
        self.store = store
        self.getConfig = getConfig

        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.running else { return }
                self.sleeping = true
                self.clearTimer()
                self.setStatus("系统休眠，已暂停")
            }
        }
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sleeping = false
                guard self.running else { return }
                self.schedule(ms: 3000)
                self.setStatus("已从休眠恢复")
            }
        }
    }

    // MARK: - 状态

    private func setStatus(_ text: String, isError: Bool = false) {
        statusText = text
        if isError { lastError = text }
        onLog?(text, isError)
    }

    // MARK: - 控制

    func start() {
        guard !running else { return }
        running = true
        lastError = nil
        setStatus("已启动")
        Task { await tick(manual: false) }
    }

    func stop() {
        guard running else { return }
        running = false
        clearTimer()
        nextAt = 0
        setStatus("已停止")
    }

    @discardableResult
    func toggle() -> Bool {
        running ? stop() : start()
        return running
    }

    /// 立即采集一次（不影响原有节奏）
    func captureNow() {
        Task { await tick(manual: true) }
    }

    private func clearTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func schedule(ms: Int) {
        clearTimer()
        guard running, !sleeping else { return }
        nextAt = Date().timeIntervalSince1970 * 1000 + Double(ms)
        let t = Timer(timeInterval: Double(ms) / 1000.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.tick(manual: false) }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        objectWillChange.send()
    }

    /// 系统空闲秒数（无键鼠输入）
    private func systemIdleSeconds() -> Int {
        let anyType = CGEventType(rawValue: ~0) ?? .null
        let v = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyType)
        return v.isFinite && v > 0 ? Int(v) : 0
    }

    // MARK: - 单轮采集

    func tick(manual: Bool) async {
        let cfg = getConfig()
        let intervalMs = max(5, cfg.intervalSec) * 1000
        lastTickAt = Date().timeIntervalSince1970 * 1000

        // 空闲跳过：只在刚进入空闲时留一条记录
        if !manual && cfg.skipWhenIdle {
            let idleSec = systemIdleSeconds()
            if idleSec >= cfg.idleThresholdSec {
                if !idleLogged {
                    idleLogged = true
                    lastIdleState = true
                    counters.idle += 1
                    let now = Date()
                    var rec = ActRecord()
                    rec.id = Store.newId(now)
                    rec.type = RecordKind.memento.rawValue
                    rec.timestamp = DateUtil.isoLocal(now)
                    rec.time = DateUtil.clockTime(now)
                    rec.epochMs = DateUtil.epochMs(now)
                    rec.screenshot = nil
                    rec.status = "idle"
                    rec.idleSeconds = idleSec
                    rec.activity = Activity(
                        title: "离开电脑",
                        app: "",
                        category: "待机与离席",
                        focus: "空闲",
                        summary: .list(["用户已 \(Int((Double(idleSec) / 60).rounded())) 分钟无键鼠操作，判定为离开或挂机。"]),
                        keywords: ["空闲"]
                    )
                    rec.analysis = AnalysisInfo(skippedReason: "system-idle")
                    await store.appendRecord(now, rec, kind: .memento)
                    onRecord?(nil)
                }
                setStatus("系统空闲 \(Int((Double(idleSec) / 60).rounded())) 分钟，暂不采集")
                if running { schedule(ms: intervalMs) }
                return
            }
            if idleLogged { idleLogged = false }
        }

        do {
            let bundle = try await captureAndProcess(cfg, kind: .memento)
            Capture.reportGrabResult(nil)
            onPermission?(.granted)

            let now = Date()

            // —— 变化检测：视觉差 OR 前台 App OR 窗口标题 OR 内容区 OR Idle 状态，任一变化即重新分析 ——
            // 旧逻辑只看整张截图像素差；新逻辑在语义层补强，避免"App 不变但内容变了"被误判为无变化。
            let dist = lastHash.map { ImageUtil.hamming($0, bundle.hash) } ?? 64
            let contentDist = lastContentHash.map { ImageUtil.hamming($0, bundle.contentHash) } ?? 64
            let frontAppName = Capture.getFrontApp()?.name
            let windowTitle = Capture.getWindowTitles().first ?? frontAppName ?? ""
            let appChanged = frontAppName != lastFrontApp
            let titleChanged = windowTitle != lastWindowTitle
            let contextChanged = lastContentHash != nil && contentDist > cfg.dupThreshold
            // 上一轮处于空闲、本轮已恢复活跃 → 视为 Idle 状态变化，需重新分析
            let idleChanged = lastIdleState

            let visualChanged = lastHash != nil && dist > cfg.dupThreshold
            let changed = visualChanged || contextChanged || appChanged || titleChanged || idleChanged
            // dupThreshold 只控制"视觉变化"阈值；其它语义信号一旦变化即触发分析
            let unchanged = cfg.skipDuplicate && lastHash != nil && !changed

            // 滑动窗口：无论是否跳过，本轮信号都更新为"当前"，供下次比较
            lastHash = bundle.hash
            lastContentHash = bundle.contentHash
            lastFrontApp = frontAppName
            lastWindowTitle = windowTitle
            lastIdleState = false

            // 存图
            var shotAbs: String?
            var shotRel: String?
            var shotBytes = 0
            var extraRefs: [ShotRef] = []
            if cfg.keepScreenshots && (!unchanged || cfg.saveDuplicateShots), let jpeg = bundle.primaryJpeg {
                if let saved = try? await store.saveScreenshot(now, jpeg, suffix: "", kind: .memento) {
                    shotAbs = saved.abs
                    shotRel = saved.rel
                    shotBytes = saved.bytes
                }
                for e in bundle.extraJpegs {
                    if let info = try? await store.saveScreenshot(now, e.data, suffix: e.suffix, kind: .memento) {
                        extraRefs.append(ShotRef(abs: info.abs, rel: info.rel, label: e.label))
                    }
                }
            }

            counters.captured += 1

            var rec = ActRecord()
            rec.id = Store.newId(now)
            rec.type = RecordKind.memento.rawValue
            rec.timestamp = DateUtil.isoLocal(now)
            rec.time = DateUtil.clockTime(now)
            rec.epochMs = DateUtil.epochMs(now)
            rec.screenshot = shotRel
            rec.screenshotAbs = shotAbs
            rec.screenshots = extraRefs
            rec.imageBytes = shotBytes
            rec.imageHash = bundle.hash
            rec.changeDistance = lastHash != nil ? dist : nil
            rec.appChanged = appChanged
            rec.titleChanged = titleChanged
            rec.contextChanged = contextChanged
            rec.display = DisplayInfo(label: bundle.label,
                                      width: bundle.width, height: bundle.height,
                                      nativeWidth: bundle.nativeWidth, nativeHeight: bundle.nativeHeight,
                                      screens: bundle.screens)
            rec.status = "pending"

            if unchanged, let last = lastActivity {
                rec.status = "skipped"
                rec.activity = last
                rec.analysis = AnalysisInfo(model: cfg.model,
                                            skippedReason: "no-change",
                                            changeDistance: dist,
                                            reusedFrom: lastActivityId)
                counters.skipped += 1
                await store.appendRecord(now, rec, kind: .memento)
                setStatus("活动无变化（视觉差 \(dist) · 内容差 \(contentDist)），沿用上次判断")
                onRecord?(rec)
                if running { schedule(ms: intervalMs) }
                return
            }

            // 需要分析
            rec.status = "analyzing"
            await store.appendRecord(now, rec, kind: .memento)
            onRecord?(rec)

            enqueue(Job(date: now, recordId: rec.id, kind: .memento, jpeg: bundle.analyzeJpeg))
            setStatus("已截屏，等待模型分析…")
        } catch {
            Capture.reportGrabResult(error)
            let msg = error.localizedDescription
            setStatus("采集失败：\(msg)", isError: true)
            let lower = msg.lowercased()
            if msg.contains("权限") || msg.contains("屏幕录制")
                || lower.contains("permission") || lower.contains("screen capture") {
                onPermission?(Capture.permissionStatus())
            }
        }

        if running { schedule(ms: intervalMs) }
    }

    /// 抓屏 + 图像处理（nonisolated → 在后台线程跑，不卡 UI）
    nonisolated private func captureAndProcess(_ cfg: AppConfig, kind: RecordKind) async throws -> ShotBundle {
        let shots = try await Capture.grab(cfg)
        guard let primary = shots.first(where: { $0.isPrimary }) ?? shots.first else {
            throw CaptureError.emptyImage
        }
        let quality = cfg.jpegQuality
        let hash = ImageUtil.dHash(primary.image)
        let contentHash = ImageUtil.dHash(ImageUtil.cropCenter(primary.image))

        var primaryJpeg: Data?
        var extras: [(String, Data, String)] = []
        if cfg.keepScreenshots {
            primaryJpeg = ImageUtil.jpeg(ImageUtil.fitWidth(primary.image, cfg.saveWidth), quality: quality)
            for (i, s) in shots.enumerated() where s.displayId != primary.displayId {
                if let d = ImageUtil.jpeg(ImageUtil.fitWidth(s.image, cfg.saveWidth), quality: quality) {
                    extras.append(("_d\(i + 1)", d, s.label))
                }
            }
        }

        // 送模型的图：多屏拼全景，单屏直接缩
        let analyzeImg: CGImage = shots.count > 1
            ? (ImageUtil.joinScreens(shots.map { $0.image }, maxWidth: cfg.analyzeWidth)
               ?? ImageUtil.fitWidth(primary.image, cfg.analyzeWidth))
            : ImageUtil.fitWidth(primary.image, cfg.analyzeWidth)
        guard let analyzeJpeg = ImageUtil.jpeg(analyzeImg, quality: min(quality, 80)) else {
            throw CaptureError.emptyImage
        }

        return ShotBundle(
            primaryJpeg: primaryJpeg,
            extraJpegs: extras.map { (suffix: $0.0, data: $0.1, label: $0.2) },
            analyzeJpeg: analyzeJpeg,
            hash: hash,
            contentHash: contentHash,
            label: primary.label,
            width: primary.image.width,
            height: primary.image.height,
            nativeWidth: primary.nativeWidth,
            nativeHeight: primary.nativeHeight,
            screens: shots.count
        )
    }

    // MARK: - 分析队列

    private func enqueue(_ job: Job) {
        while pending.count >= Recorder.maxQueue {
            let dropped = pending.removeFirst()
            counters.dropped += 1
            Task { [store] in
                await store.updateRecord(dropped.date, id: dropped.recordId, kind: dropped.kind) { r in
                    r.status = "dropped"
                    r.analysis = AnalysisInfo(skippedReason: "queue-overflow")
                }
            }
        }
        pending.append(job)
        queued = pending.count
        Task { await drain() }
    }

    private func drain() async {
        guard !working else { return }
        working = true
        queued = pending.count

        while !pending.isEmpty {
            let job = pending.removeFirst()
            queued = pending.count
            let cfg = getConfig()
            setStatus("模型分析中…")

            let frontApp = Capture.getFrontApp()
            let titles = await Task.detached(priority: .utility) { Capture.getWindowTitles() }.value
            let fn: AIFunction = (job.kind == .yinian) ? .yinian : .moment
            let profile = ModelRouter.profile(for: fn, in: cfg)
            let res: AnalyzeResult
            if let p = profile {
                res = await Analyzer.analyzeWithRetry(job.jpeg, profile: p, cfg: cfg, kind: job.kind,
                                                      frontApp: frontApp, windowTitles: titles)
            } else {
                var f = AnalyzeResult()
                f.ok = false
                f.error = "未配置可用模型，请在「模型」设置中分配模型。"
                res = f
            }

            if res.ok {
                let activity = Activity(
                    title: res.title,
                    app: res.app,
                    category: res.category,
                    focus: res.focus,
                    summary: .text(res.summary),
                    keywords: res.keywords,
                    intent: res.intent
                )
                lastActivity = activity
                lastActivityId = job.recordId
                current = activity
                currentId = job.recordId
                counters.analyzed += 1
                let updated = await store.updateRecord(job.date, id: job.recordId, kind: job.kind) { r in
                    r.status = "done"
                    r.activity = activity
                    r.analysis = AnalysisInfo(model: res.model, latencyMs: res.latencyMs,
                                              usage: res.usage, error: nil)
                }
                setStatus("已记录：\(res.title)")
                onRecord?(updated)
            } else {
                counters.failed += 1
                let friendly = Analyzer.friendlyError(res.error)
                let updated = await store.updateRecord(job.date, id: job.recordId, kind: job.kind) { r in
                    r.status = "failed"
                    r.activity = nil
                    r.analysis = AnalysisInfo(model: profile?.modelName ?? "—", error: friendly)
                }
                setStatus("分析失败：\(friendly)", isError: true)
                onRecord?(updated)
            }
        }

        working = false
        setStatus(running ? "待命中" : "已停止")
    }

    // MARK: - 一念（用户主动定格）

    struct YinianOutcome {
        var ok: Bool
        var record: ActRecord?
        var error: String?
    }

    /// 等模型分析完成再返回
    func captureYinian() async -> YinianOutcome {
        await captureYinianCore(waitAnalysis: true)
    }

    /// 只保证截图落盘就返回，分析后台跑（状态栏面板用，避免卡住）
    @discardableResult
    func captureYinianShot() async -> YinianOutcome {
        await captureYinianCore(waitAnalysis: false)
    }

    private func captureYinianCore(waitAnalysis: Bool) async -> YinianOutcome {
        let cfg = getConfig()
        do {
            let bundle = try await captureAndProcess(cfg, kind: .yinian)
            Capture.reportGrabResult(nil)
            onPermission?(.granted)

            let now = Date()
            var shotAbs: String?
            var shotRel: String?
            var shotBytes = 0
            var extraRefs: [ShotRef] = []
            if cfg.keepScreenshots, let jpeg = bundle.primaryJpeg {
                if let saved = try? await store.saveScreenshot(now, jpeg, suffix: "", kind: .yinian) {
                    shotAbs = saved.abs; shotRel = saved.rel; shotBytes = saved.bytes
                }
                for e in bundle.extraJpegs {
                    if let info = try? await store.saveScreenshot(now, e.data, suffix: e.suffix, kind: .yinian) {
                        extraRefs.append(ShotRef(abs: info.abs, rel: info.rel, label: e.label))
                    }
                }
            }

            var rec = ActRecord()
            rec.id = Store.newId(now)
            rec.type = RecordKind.yinian.rawValue
            rec.timestamp = DateUtil.isoLocal(now)
            rec.time = DateUtil.clockTime(now)
            rec.epochMs = DateUtil.epochMs(now)
            rec.screenshot = shotRel
            rec.screenshotAbs = shotAbs
            rec.screenshots = extraRefs
            rec.imageBytes = shotBytes
            rec.display = DisplayInfo(label: bundle.label,
                                      width: bundle.width, height: bundle.height,
                                      nativeWidth: bundle.nativeWidth, nativeHeight: bundle.nativeHeight,
                                      screens: bundle.screens)
            rec.status = "pending"

            counters.captured += 1
            setStatus("一念·定格中…")
            await store.appendRecord(now, rec, kind: .yinian)

            if !waitAnalysis { onRecord?(rec) }

            let recId = rec.id
            let analysisJpeg = bundle.analyzeJpeg

            let run: @MainActor () async -> YinianOutcome = { [weak self] in
                guard let self else { return YinianOutcome(ok: false, record: nil, error: "已退出") }
                let frontApp = Capture.getFrontApp()
                let titles = await Task.detached(priority: .utility) { Capture.getWindowTitles() }.value
                let profile = ModelRouter.profile(for: .yinian, in: cfg)
                let res: AnalyzeResult
                if let p = profile {
                    res = await Analyzer.analyzeWithRetry(analysisJpeg, profile: p, cfg: cfg, kind: .yinian,
                                                          frontApp: frontApp, windowTitles: titles)
                } else {
                    var f = AnalyzeResult()
                    f.ok = false
                    f.error = "未配置可用模型，请在「模型」设置中分配模型。"
                    res = f
                }
                if res.ok {
                    let activity = Activity(title: res.title, app: res.app, category: res.category,
                                            focus: res.focus, summary: .text(res.summary),
                                            keywords: res.keywords, intent: res.intent)
                    self.counters.analyzed += 1
                    let updated = await self.store.updateRecord(now, id: recId, kind: .yinian) { r in
                        r.status = "done"
                        r.activity = activity
                        r.analysis = AnalysisInfo(model: res.model, latencyMs: res.latencyMs,
                                                  usage: res.usage, error: nil)
                    }
                    self.setStatus("一念已记录：\(res.title)")
                    self.onRecord?(updated)
                    return YinianOutcome(ok: true, record: updated, error: nil)
                } else {
                    self.counters.failed += 1
                    let friendly = Analyzer.friendlyError(res.error)
                    let updated = await self.store.updateRecord(now, id: recId, kind: .yinian) { r in
                        r.status = "failed"
                        r.analysis = AnalysisInfo(model: profile?.modelName ?? "—", error: friendly)
                    }
                    self.setStatus("一念分析失败：\(friendly)", isError: true)
                    self.onRecord?(updated)
                    return YinianOutcome(ok: false, record: updated, error: friendly)
                }
            }

            if waitAnalysis {
                return await run()
            }
            Task { _ = await run() }
            return YinianOutcome(ok: true, record: rec, error: nil)
        } catch {
            Capture.reportGrabResult(error)
            let msg = error.localizedDescription
            setStatus("一念失败：\(msg)", isError: true)
            return YinianOutcome(ok: false, record: nil, error: msg)
        }
    }
}
