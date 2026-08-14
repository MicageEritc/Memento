import SwiftUI
import AppKit
import Combine

/// 主导航（侧栏一级导航）
/// 瞬息 = 自动捕获 + 一念标记的完整时间流（截图回忆流）
/// 一念 = 用户主动保存的重要瞬间（独立精选入口）
/// 随想 = 用户主动书写的想法/灵感（类 macOS 备忘录，纯文本，不依赖截屏）
/// 全景 = 基于全部记录的 AI 分析、统计与复盘
enum MainTab: String, CaseIterable, Identifiable {
    case instant, yinian, muse, panorama, model, settings, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .instant:  return "瞬息"
        case .yinian:   return "一念"
        case .muse:     return "随想"
        case .panorama: return "全景"
        case .model:    return "模型"
        case .settings: return "设置"
        case .about:    return "关于"
        }
    }

    var icon: String {
        switch self {
        case .instant:  return "circle.inset.filled"
        case .yinian:   return "sparkles"
        case .muse:     return "square.and.pencil"
        case .panorama: return "chart.bar.xaxis"
        case .model:    return "cpu"
        case .settings: return "gearshape"
        case .about:    return "info.circle"
        }
    }

    /// 侧栏分组
    enum Group { case server, general }
    var group: Group {
        switch self {
        case .instant, .yinian, .muse, .panorama: return .server
        case .model, .settings, .about:           return .general
        }
    }
}

/// 全景时间范围（对应 .seg-btn data-scope）
enum SummaryScope: String, CaseIterable {
    case day, week, month, year
    var label: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        case .year: return "年"
        }
    }
}

/// 全景顶部五个平级标签：日 / 周 / 月 / 年 / 洞察。
/// 其中 day/week/month/year 复用 SummaryScope 的总结链路；insight 是独立的「我的画像」页。
enum PanoramaTab: String, CaseIterable {
    case day, week, month, year, insight
    var label: String {
        switch self {
        case .day: return "日"
        case .week: return "周"
        case .month: return "月"
        case .year: return "年"
        case .insight: return "洞察"
        }
    }
    /// insight 无对应总结 scope；其余映射回 SummaryScope。
    var summaryScope: SummaryScope? {
        switch self {
        case .day: return .day
        case .week: return .week
        case .month: return .month
        case .year: return .year
        case .insight: return nil
        }
    }
}

/// 模型服务卡状态（对应 pingService 的三态）
struct ServiceState {
    var stateText = "检测中"
    var stateKind: TagKind = .plain
    var typeText = "—"
    var typeKind: TagKind = .plain
    var typeHelp = ""
    var modelText = "—"
    var apiText = ""
    var latencyText = "—"
    var offline = false
}

@MainActor
final class AppState: ObservableObject {

    // MARK: 依赖
    let store: Store
    let recorder: Recorder

    // MARK: 配置
    @Published var cfg: AppConfig

    // MARK: 记录器状态（对应 renderer.js 的 STATE）
    @Published var running = false
    @Published var working = false
    @Published var statusText = "正在初始化…"
    @Published var lastError: String?
    /// 下一次抓屏的 epoch 毫秒（0 = 无）
    @Published var nextAt: TimeInterval = 0
    /// 倒计时（0...1 进度 + 剩余秒文案）
    @Published var countdownProgress: Double = 0
    @Published var countdownText = "—"

    // MARK: 主区数据
    @Published var tab: MainTab = .instant
    /// 侧栏可见性：绑定 NavigationSplitView.columnVisibility。
    /// 必须用可变绑定（不能 .constant）——原生「隐藏侧栏」按钮才真正生效。
    @Published var sidebarVisible: NavigationSplitViewVisibility = .all
    @Published var currentDate: String = DateUtil.ymd(Date())
    /// 一念页独立日期（与瞬息解耦：两页各自切日期，互不干扰）
    @Published var yinianDate: String = DateUtil.ymd(Date())
    /// 一念页过滤开关：false = 展示全部一念（默认，每次切回一念页自动复位）；
    /// true = 用户主动在顶部切了日期，按 yinianDate 过滤展示。
    @Published var filterByDate = false
    @Published var records: [ActRecord] = []
    @Published var yinianRecords: [ActRecord] = []
    /// 展开状态（对应 renderer.js expanded Set）
    @Published var expandedIds: Set<String> = []
    /// 搜索命中后定位闪烁的记录 id（对应 .breathe）
    @Published var breatheId: String?

    // MARK: 侧栏数据
    @Published var stats: TodayStats = TodayStats()
    @Published var storage: StorageStats = StorageStats()
    @Published var totalCaptured = 0
    @Published var totalInstant = 0
    @Published var totalYinian = 0
    @Published var svc = ServiceState()
    /// 每个模型的服务状态（按模型 id 索引）
    @Published var svcByModel: [String: ServiceState] = [:]
    @Published var permission: PermissionState = .unknown
    @Published var permBannerDismissed = UserDefaults.standard.bool(forKey: "lens.permBannerDismissed")

    // MARK: 洞察数据
    @Published var summaryScope: SummaryScope = .day
    @Published var summaryDate: String = DateUtil.ymd(Date())
    /// 全景顶部五个平级标签（日/周/月/年/洞察）。
    @Published var panoramaTab: PanoramaTab = .day
    /// 洞察页「我的画像」：仅在打开洞察页时由本地统计聚合计算（不调用 AI），内存缓存。
    @Published var behaviorProfile: BehaviorProfile?
    @Published var insightUpdating = false
    @Published var insightError: String?
    @Published var breakdown = CategoryBreakdown()
    @Published var topApps: [AppCount] = []
    /// 旧口径：按记录条数的专注/分散/空闲（托盘速览沿用）
    @Published var focus = FocusBreakdown()
    /// 新口径：本地时间序列算法算出的真实专注报告（时长加权 + 干扰/切换次数 + 专注时段）
    @Published var focusReport = FocusAnalyzer.Report()
    /// 24 小时分布（day scope 才有值）
    @Published var hourly: [Int] = []
    /// 逐小时分类计数（day scope 才有值），供时间轨迹按活动类型着色。
    @Published var hourlyCats: [[String: Int]] = []
    /// 区间内按天记录数（周/月/年趋势）
    @Published var dailyTrend: [(String, Int)] = []
    @Published var summaryDoc: SummaryDoc?
    @Published var summaryHistory: [SummaryDoc] = []
    @Published var summaryGenerating = false
    @Published var summaryError: String?
    /// 点历史记录后临时展示的那一份（nil 表示展示 summaryDoc）
    @Published var summaryViewing: SummaryDoc?

    // MARK: 随想（主动书写，独立数据域；方法见 AppStateMuse.swift）
    /// 全部随想（置顶优先 + 更新时间倒序）
    @Published var museNotes: [MuseNote] = []
    /// 当前选中的随想 id（nil = 未选中，编辑区显示空态）
    @Published var museSelectedId: String?
    /// 搜索跳转：进入随想笔记后定位到关键词（定位后由编辑器清空）
    @Published var museJumpKeyword: String? = nil
    /// 跳转令牌：每次点击搜索结果 +1，编辑器据此判断是否触发定位（即使停留同一篇）
    @Published var museJumpToken: Int = 0
    /// 「已保存 HH:mm」提示（自动保存成功后刷新）
    @Published var museSavedAt: String = ""
    let museStore: MuseStore
    /// 全局搜索索引（瞬息/一念/随想 统一索引 + RTF 纯文本缓存）
    let searchIndex = SearchIndex()
    /// 自动保存防抖任务与待落盘草稿（仅随想模块内部使用）
    var museSaveTask: Task<Void, Never>?
    var musePending: MuseDraft?

    // MARK: 随想分组（2026-08-11 第四轮新增）
    @Published var museGroups: [MuseGroup] = []
    @Published var museCurrentGroupId: String? = nil   // nil = 全部随想
    let museGroupStore: MuseGroupStore
    /// 分组编辑弹窗状态（nil = 关；其余 = 弹窗模式 + 初始值）
    @Published var museGroupDialog: MuseGroupDialog? = nil

    // MARK: 随想 AI / 导出（方法见 AppStateMuseAI.swift）
    /// AI 面板模式（nil = 关；summary = 总结结果；polish = 润色预览）
    @Published var museAISheet: MuseAISheet? = nil
    @Published var museAILoading = false
    @Published var museAIError: String? = nil
    @Published var museAISummary = ""
    /// 上次生成总结的缓存（noteId, text）：同一篇笔记再次点「总结」直接复用，不重复请求
    var museCachedSummary: (noteId: String, text: String)? = nil
    @Published var musePolishOriginal = ""
    @Published var musePolishResult = ""
    /// 当前随想 AI 使用的模型显示名（如「在线模型 · agnes-2.0-flash」），用于面板里展示
    @Published var museAIModelLabel = ""

    // MARK: 弹层
    @Published var lightboxPath: String?
    /// 主窗口弱引用（由 AppDelegate 注入，便于调试时定位窗口）
    weak var mainWindow: NSWindow?

    // MARK: 全局搜索焦点信号
    /// 键盘快捷键 ⌘K/⌘F 触发时自增，SearchBar 监听此信号把焦点切到 TextField。
    /// 避免跨视图传递 @FocusState。
    @Published var searchFocusSignal: Int = 0
    /// 点击窗口空白处（搜索框外）触发自增，SearchBar 监听此信号收起并取消搜索。
    /// 用于覆盖「未输入字、点纯空白不失焦」时搜索框无法缩回的情况。
    @Published var searchCollapseSignal: Int = 0
    /// 搜索框当前是否展开（由 CollapsibleSearchBar 同步），供 mouseDown 监听判断。
    @Published var searchExpanded: Bool = false

    // MARK: 设置页反馈文案
    @Published var cleanHint = ""
    @Published var cleaning = false
    @Published var backupHint = ""
    @Published var backupBusy = false

    // MARK: 全局搜索
    @Published var searchQuery = ""
    @Published var searchFilter: String = ""     // "" | memento | yinian | muse
    @Published var searchResults: [SearchHit] = []
    @Published var searchBusy = false
    @Published var searchHasRun = false

    /// 是否处于全局搜索状态（搜索关键词非空）。
    /// 用于让搜索视为独立内容状态：进入后清空各页面原有 toolbar。
    var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var pingBusy = false
    private var pingTimer: Timer?
    private var countdownTimer: Timer?
    private var searchTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    /// 托盘面板需要刷新时的回调（由 TrayController 注入）
    var onDataChanged: (() -> Void)?

    // MARK: - 初始化

    init() {
        let c = ConfigStore.shared.current
        cfg = c
        let s = Store(cfg: c)
        store = s
        museStore = MuseStore(root: c.outputDir)
        museGroupStore = MuseGroupStore(root: c.outputDir)
        recorder = Recorder(store: s, getConfig: { ConfigStore.shared.current })

        recorder.onRecord = { [weak self] rec in
            Task { @MainActor in await self?.handlePushRecord(rec) }
        }
        recorder.onPermission = { [weak self] p in
            Task { @MainActor in self?.permission = p }
        }
        recorder.onLog = { text, isError in
            if isError { Log.shared.error(text) } else { Log.shared.info(text) }
        }

        // 调试入口（无副作用）：LENS_TAB=instant|yinian|panorama|model|settings|about 切初始页；LENS_SEARCH=1 启动即打开搜索
        let env = ProcessInfo.processInfo.environment
        if let t = env["LENS_TAB"], let tab = MainTab(rawValue: t) {
            self.tab = tab
        }
        if env["LENS_SEARCH"] == "1" {
            // 调试：启动即 focus 搜索框
            searchFocusSignal += 1
        }
        // 调试：LENS_COLLAPSE=1 启动即隐藏侧栏（验证 columnVisibility 绑定生效）
        if env["LENS_COLLAPSE"] == "1" {
            sidebarVisible = .detailOnly
        }
    }

    // MARK: - 启动（对应 app:bootstrap + boot()）

    func bootstrap() async {
        // 权限：先读状态，未决定时才请求一次；已授权/已拒绝都不重复弹窗
        let status = Capture.permissionStatus()
        permission = status
        if status == .notDetermined {
            let granted = await Capture.requestPermissionIfNeeded()
            permission = granted ? .granted : Capture.permissionStatus()
        }

        syncRecorderState()
        // 启动时加载当天完整记录（与 reload 一致），避免 recent(limit:60) 截断导致一念/早期记录漏显
        records = await store.listByDate(currentDate, search: "", limit: 0)
        yinianRecords = await loadYinian()
        stats = await store.todayStats()
        storage = await store.storageStats()
        await refreshTotals()
        await loadMuse()
        await loadMuseGroups()

        observeRecorder()
        startTimers()

        if cfg.autoStartCapture { recorder.start() }
        await pingService()
    }

    private var cancellables = Set<AnyCancellable>()

    private func observeRecorder() {
        // Recorder 是 @MainActor ObservableObject，订阅它的变化并同步到本地 @Published
        recorder.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // objectWillChange 在写入前触发，下一个 runloop 再读才拿得到新值
                DispatchQueue.main.async { self?.syncRecorderState() }
            }
            .store(in: &cancellables)
    }

    private func syncRecorderState() {
        running = recorder.running
        working = recorder.working
        statusText = recorder.statusText
        lastError = recorder.lastError
        nextAt = recorder.nextAt
    }

    /// 状态卡的标题与灯（对应 renderState）
    var statusTitle: String { working ? "分析中" : running ? "记录中" : "已暂停" }
    var orbColor: Color? {
        if working { return T.accent }
        if running { return T.ok }
        if lastError != nil { return T.err }
        return nil
    }
    var orbPulsing: Bool { working || (!running && lastError != nil) }

    private func startTimers() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickCountdown() }
        }
        pingTimer?.invalidate()
        // 每 60 秒静默检测一次模型服务连通性
        pingTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pingService(silent: true) }
        }
    }

    /// 对应 renderer.js tickCountdown()
    private func tickCountdown() {
        guard running, nextAt > 0 else {
            countdownProgress = 0
            countdownText = "—"
            return
        }
        let totalMs = Double(cfg.intervalSec) * 1000
        let leftMs = max(0, nextAt - Date().timeIntervalSince1970 * 1000)
        countdownProgress = totalMs > 0 ? min(1, (totalMs - leftMs) / totalMs) : 0
        countdownText = "\(Int(ceil(leftMs / 1000)))s"
    }

    // MARK: - 数据刷新（对应 reload()）

    /// 活跃时长（小时，估算）：已分析记录 × 间隔秒 / 3600
    var activeHoursText: String {
        let h = Double(stats.memento.analyzed) * Double(cfg.intervalSec) / 3600
        return String(format: "%.1f", h)
    }

    /// 一念数据源：
    /// - filterByDate == false：全部一念（默认，精选收藏不默认显示空页）
    /// - filterByDate == true：按一念页所选日期（yinianDate）过滤
    private func loadYinian() async -> [ActRecord] {
        if filterByDate {
            return await store.listByDate(yinianDate, kind: .yinian)
        }
        return await store.allYinian(limit: 400)
    }

    func reload() async {
        records = await store.listByDate(currentDate, search: "", limit: 0)
        yinianRecords = await loadYinian()
        stats = await store.todayStats()
        await refreshTotals()
        if tab == .panorama {
            if panoramaTab == .insight { await loadInsight() } else { await loadScroll() }
        }
        // AI 分析可能在 reload 周期内更新了记录摘要，标记搜索缓存失效（下次搜索才重建）
        Task { await searchIndex.invalidateRecords() }
    }

    /// 一次扫描刷新三类总数：瞬息总数 / 一念总数 / 全部
    private func refreshTotals() async {
        let c = await store.totalCounts()
        totalInstant = c.instant
        totalYinian = c.yinian
        totalCaptured = c.instant + c.yinian
    }

    func refreshStorage() async {
        storage = await store.storageStats()
    }

    /// 对应 push:record 的增量更新
    /// 性能：todayStats（读全部小时文件）+ storageStats（全目录扫描）很贵，
    /// 每 20 秒一条记录就全算一次会卡 —— 节流：统计最多 8s 一次、存储最多 15s 一次。
    private var lastStatsAt: TimeInterval = 0
    private var lastStorageAt: TimeInterval = 0

    private func handlePushRecord(_ rec: ActRecord?) async {
        let now = Date().timeIntervalSince1970
        if now - lastStatsAt > 8 || lastStatsAt == 0 {
            stats = await store.todayStats()
            lastStatsAt = now
        }
        if now - lastStorageAt > 15 || lastStorageAt == 0 {
            storage = await store.storageStats()
            lastStorageAt = now
        }
        onDataChanged?()

        // 一念列表：始终随新记录刷新（正看当天则更新，看历史日期则无变化）
        yinianRecords = await loadYinian()

        // 新记录进索引：标记瞬息/一念搜索缓存失效（下次搜索才重建，不阻塞当前帧）
        Task { await searchIndex.invalidateRecords() }

        guard currentDate == DateUtil.ymd(Date()) else { return }
        guard let r = rec else {
            await reload()
            return
        }
        if let i = records.firstIndex(where: { $0.id == r.id }) {
            records[i] = r
        } else {
            records.insert(r, at: 0)
        }
        records.sort { ($0.epochMs ?? 0) > ($1.epochMs ?? 0) }
    }

    // MARK: - 控制

    func toggleRecording() {
        _ = recorder.toggle()
        syncRecorderState()
        onDataChanged?()
    }

    func startRecording() {
        recorder.start()
        syncRecorderState()
        onDataChanged?()
    }

    func stopRecording() {
        recorder.stop()
        syncRecorderState()
        onDataChanged?()
    }

    /// 「定格一念」
    @discardableResult
    func captureYinian() async -> Recorder.YinianOutcome {
        let r = await recorder.captureYinian()
        await reload()
        return r
    }

    // MARK: - 日期切换

    func setDate(_ d: String) {
        currentDate = d
        Task { await reload() }
    }

    /// 一念页：用户主动在顶部切日期 → 进入「按日期过滤」视图
    func setYinianDate(_ d: String) {
        yinianDate = d
        filterByDate = true
        Task { await reload() }
    }

    /// 一念页：切回一念时复位 —— 恢复「全部一念」且日期回今天。
    /// 只有真的变了才 reload，避免每次出现都无谓刷库。
    func resetYinianFilter() {
        let today = DateUtil.ymd(Date())
        let changed = filterByDate || yinianDate != today
        filterByDate = false
        yinianDate = today
        if changed {
            Task { await reload() }
        }
    }

    var isToday: Bool { currentDate == DateUtil.ymd(Date()) }
    var isYesterday: Bool { currentDate == DateUtil.ymd(DateUtil.addDays(Date(), -1)) }

    // MARK: - 配置保存（对应 cfg:save，实时保存 + 目录迁移）

    /// 实时保存（debounce 200ms，与 renderer.js liveSave 一致）
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            await self?.commitConfig()
        }
    }

    /// 立刻落盘配置（不改 outputDir 的普通字段）
    func commitConfig() async {
        let before = ConfigStore.shared.current
        let next = ConfigStore.shared.replace(cfg)
        cfg = next
        await store.setConfig(next)
        LoginItem.set(enabled: next.launchAtLogin)
        if before.stayInTray != next.stayInTray {
            NotificationCenter.default.post(name: .lensTrayToggled, object: nil)
        } else {
            NotificationCenter.default.post(name: .lensTrayRefresh, object: nil)
        }
        await pingService(silent: true)
        await refreshStorage()
    }

    /// 更改保存目录（含数据迁移 + 绝对路径重写）
    func changeOutputDir(to newPath: String) async {
        let before = ConfigStore.shared.current
        let oldRoot = URL(fileURLWithPath: before.outputDir).standardizedFileURL.path
        let newRoot = URL(fileURLWithPath: newPath).standardizedFileURL.path
        if oldRoot != newRoot {
            do {
                try Migration.migrateDataDir(from: oldRoot, to: newRoot)
                try Migration.rewriteAbsRoot(root: newRoot, oldRoot: oldRoot, newRoot: newRoot)
                Log.shared.info("保存目录已变更：\(oldRoot) → \(newRoot)（数据已迁移 + 路径已重写）")
            } catch {
                Log.shared.warn("目录迁移失败：\(error.localizedDescription)")
            }
        }
        cfg.outputDir = newPath
        let next = ConfigStore.shared.replace(cfg)
        cfg = next
        await store.setConfig(next)
        // 随想目录随数据根目录一起搬迁（migrateDataDir 已整体搬过文件，这里只切根路径）
        await museStore.setRoot(next.outputDir)
        await museGroupStore.setRoot(next.outputDir)
        await reload()
        await refreshStorage()
        await refreshTotals()
        await loadMuse()
        await loadMuseGroups()
    }

    // MARK: - 模型服务检测（对应 pingService）

    /// 该模型是否处于「确认离线」状态（最近一次探测结果为离线）。
    /// 尚未探测过（svcByModel 无记录）时视为在线放行，交给请求自身报错。
    func modelOffline(_ id: String) -> Bool {
        svcByModel[id]?.offline == true
    }

    /// 探测所有已配置模型的服务可用性（轻量：仅刷新在线状态，不探测视觉能力）
    func pingService(silent: Bool = false) async {
        for m in cfg.models { await pingStatusOnly(id: m.id, silent: silent) }
        // 旧 svc 保留首个模型状态，兼容任何历史引用
        if let first = cfg.models.first, let st = svcByModel[first.id] { svc = st }
    }

    /// 轻量状态刷新：仅确认在线/离线 + 模型是否加载，不写回类型/能力（避免保存时循环）
    private func pingStatusOnly(id: String, silent: Bool) async {
        guard let p = cfg.models.first(where: { $0.id == id }) else { return }
        var st = ServiceState()
        st.apiText = p.endpoint
        if p.endpoint.isEmpty {
            st.stateText = "未配置"; st.stateKind = .plain
            st.typeText = "—"; st.modelText = "—"; st.latencyText = "—"
            svcByModel[id] = st
            return
        }
        if !silent { st.stateText = "检测中" }
        let r = await Analyzer.ping(profile: p)
        st.offline = false
        st.typeText = p.kind.label
        st.latencyText = r.latencyMs > 0 ? "\(r.latencyMs) ms" : "—"
        if r.ok {
            st.stateText = r.hasModel ? "在线" : "模型未加载"
            st.stateKind = r.hasModel ? .ok : .warn
            st.modelText = r.hasModel ? p.modelName : (r.models.isEmpty ? "无" : r.models.joined(separator: ", "))
        } else {
            st.stateText = "离线"; st.stateKind = .err; st.offline = true
            st.modelText = r.error ?? "连接失败"
        }
        svcByModel[id] = st
    }

    /// 立即检测：完整探测（连通 + 自动类型 + 提供方 + 文本/视觉能力），结果写回模型配置并持久化
    func pingModel(id: String, silent: Bool = false) async {
        guard !pingBusy else { return }
        pingBusy = true
        defer { pingBusy = false }
        guard let idx = cfg.models.firstIndex(where: { $0.id == id }) else { return }

        var st = ServiceState()
        st.apiText = cfg.models[idx].endpoint
        if cfg.models[idx].endpoint.isEmpty {
            st.stateText = "未配置"; st.stateKind = .plain
            st.typeText = "—"; st.modelText = "—"; st.latencyText = "—"
            svcByModel[id] = st
            return
        }
        if !silent { st.stateText = "检测中" }
        let r = await Analyzer.detect(profile: cfg.models[idx], probeVision: true)

        // 写回自动判定结果（持久化，作为「自动检测的类型 / 能力」）
        cfg.models[idx].kind = r.kind
        cfg.models[idx].provider = r.provider.isEmpty ? (r.kind == .local ? "本地模型" : "在线模型") : r.provider
        cfg.models[idx].capabilities = r.capabilities

        st.offline = false
        st.typeText = r.kind.label
        st.latencyText = r.latencyMs > 0 ? "\(r.latencyMs) ms" : "—"
        if r.ok {
            st.stateText = r.hasModel ? "在线" : "模型未加载"
            st.stateKind = r.hasModel ? .ok : .warn
            st.modelText = r.hasModel ? cfg.models[idx].modelName : (r.models.isEmpty ? "无" : r.models.joined(separator: ", "))
        } else {
            st.stateText = "离线"; st.stateKind = .err; st.offline = true
            st.modelText = r.error ?? "连接失败"
        }
        svcByModel[id] = st
        scheduleSave()
    }

    // MARK: - 模型池管理

    /// 读取某模型在配置中的 API Key（明文存 config.json，不再访问 Keychain）
    func modelApiKey(_ id: String) -> String {
        guard let p = cfg.models.first(where: { $0.id == id }) else { return "" }
        return ModelRouter.apiKey(for: p)
    }

    /// 写入某模型的 API Key（明文存 config.json；兼容旧数据先尝试写入 Keychain 以便迁移）
    func setModelApiKey(_ id: String, _ value: String) {
        guard let i = cfg.models.firstIndex(where: { $0.id == id }) else { return }
        // 旧数据 Keychain 迁移：若之前 key 在 Keychain 里（apiKeyRef 有效），同步写一份明文到 config，
        // 之后一律走明文（Keychain 不再访问）
        cfg.models[i].apiKey = value
        scheduleSave()
    }

    /// 新增第二个模型（最多 2 个）
    func addModel() {
        guard cfg.models.count < 2 else { return }
        let id = UUID().uuidString
        let idx = cfg.models.count + 1
        let p = ModelProfile(id: id, name: "模型 \(idx)", provider: "", kind: .online,
                             endpoint: "", modelName: "", enabled: false,
                             capabilities: ModelCapabilities())
        cfg.models.append(p)
        scheduleSave()
    }

    /// 删除模型（至少保留 1 个）。被删模型的 AI 功能分配回退到首个启用模型。
    func removeModel(_ id: String) {
        guard cfg.models.count > 1,
              let idx = cfg.models.firstIndex(where: { $0.id == id }) else { return }
        cfg.models.remove(at: idx)
        // 把指向被删模型的分配回退到剩余首个启用模型
        let fallback = cfg.models.first(where: { $0.enabled })?.id ?? cfg.models.first?.id
        for (fn, mid) in cfg.modelAssignments where mid == id {
            if let fb = fallback { cfg.modelAssignments[fn] = fb }
            else { cfg.modelAssignments.removeValue(forKey: fn) }
        }
        svcByModel.removeValue(forKey: id)
        scheduleSave()
    }

    /// 将某 AI 功能分配到指定模型
    func assign(_ fn: AIFunction, to id: String) {
        cfg.modelAssignments[fn.rawValue] = id
        scheduleSave()
    }

    /// 某功能当前选中的模型 id
    func selectedModelId(for fn: AIFunction) -> String? {
        cfg.modelAssignments[fn.rawValue]
    }

    // MARK: - 全景（对应 renderScroll）

    var scopeDates: [String] { AppState.datesInScope(summaryScope, summaryDate) }
    var rangeLabel: String {
        let d = scopeDates
        return "\(d.first ?? summaryDate) ~ \(d.last ?? summaryDate)"
    }
    var currentSummaryKey: String {
        let dates = scopeDates
        return "summary-\(summaryScope.rawValue)-\(dates.first ?? summaryDate)"
    }

    func loadScroll() async {
        let dates = scopeDates
        // 单次遍历产出饼图 / TopApp / 聚焦 / 趋势 / 24h 分布，避免对同一天重复读 3 次
        let stats = await store.scopeStats(dates: dates, includeHourly: summaryScope == .day)
        breakdown = CategoryBreakdown(analyzed: stats.analyzed, categories: stats.categories)
        topApps = stats.topApps
        focus = stats.focus
        focusReport = stats.focusReport
        dailyTrend = stats.trend
        hourly = (summaryScope == .day) ? stats.hourly : []
        hourlyCats = (summaryScope == .day) ? stats.hourlyCats : []

        let key = "summary-\(summaryScope.rawValue)-\(dates.first ?? summaryDate)"
        summaryDoc = await store.readSummary(key)
        summaryHistory = await store.listSummaryHistory(key)
        summaryViewing = nil
        summaryError = nil
    }

    // MARK: - 洞察 · 我的画像（本地统计聚合，不调用 AI）

    /// 近 N 天日期串（含今天），本地日历。
    private func lastNDates(_ n: Int, from base: Date = Date()) -> [String] {
        let cal = Calendar.current
        return (0..<n).map { i in
            let d = cal.date(byAdding: .day, value: -i, to: base) ?? base
            return DateUtil.ymd(d)
        }
    }

    /// 打开洞察页时调用：聚合近 90 天本地统计生成「我的画像」。不调用任何模型。
    /// 结果缓存于 `behaviorProfile`；再次打开复用，点「更新画像」才重算。
    func loadInsight() async {
        insightUpdating = true
        insightError = nil
        defer { insightUpdating = false }
        let avail = await store.availableDates()
        let availSet = Set(avail)
        let window90 = lastNDates(90)
        let covered = window90.filter { availSet.contains($0) }
        guard !covered.isEmpty else {
            behaviorProfile = BehaviorProfile(coveredDays: 0, readiness: "数据积累中")
            return
        }
        // 主画像窗口：近 90 天有数据的日期（含逐小时，供时间偏好）
        let longStats = await store.scopeStats(dates: covered, includeHourly: true)
        // 近期变化：近 30 天 vs 前 30 天（同口径重算维度分）
        let recent30 = Array(window90.prefix(30))
        let prev30 = Array(window90.dropFirst(30).prefix(30))
        let recentStats = await store.scopeStats(dates: recent30.filter { availSet.contains($0) }, includeHourly: false)
        let prevStats = await store.scopeStats(dates: prev30.filter { availSet.contains($0) }, includeHourly: false)
        behaviorProfile = buildBehaviorProfile(coveredDays: covered.count,
                                                long: longStats, recent: recentStats, prev: prevStats)
    }

    /// 由三窗口统计推导行为画像。所有维度均可追溯到真实数据，不调用 AI。
    private func buildBehaviorProfile(coveredDays: Int,
                                       long: Store.ScopeStats,
                                       recent: Store.ScopeStats,
                                       prev: Store.ScopeStats) -> BehaviorProfile {
        let interval = Double(cfg.intervalSec)
        func catSec(_ cats: [(String, Int)], _ name: String) -> Double {
            Double(cats.first { $0.0 == name }?.1 ?? 0) * interval
        }
        let longCats = long.categories
        let totalActive = max(1.0, Double(longCats.reduce(0) { $0 + $1.1 }))
        // 4 个「分类映射」维度，按占活跃记录比例相对归一（最高 = 100）
        let groups: [(String, [String])] = [
            ("内容生产", ["办公与文档", "设计与创作"]),
            ("探索研究", ["阅读与研究"]),
            ("技术实践", ["编程开发"]),
            ("沟通协作", ["沟通与协作"])
        ]
        let groupShares = groups.map { g -> (String, Double) in
            let sec = g.1.reduce(0.0) { $0 + catSec(longCats, $1) }
            return (g.0, sec / totalActive)
        }
        let maxShare = max(0.0001, groupShares.map { $0.1 }.max() ?? 0.0001)
        var dims: [BehaviorDimension] = groupShares.map { g in
            let score = Int((g.1 / maxShare * 100).rounded())
            return BehaviorDimension(key: g.0, score: score,
                fact: "占活跃记录 \(Int((g.1 * 100).rounded()))%")
        }
        // 深度工作：加权专注度（绝对，0–100）
        let focus = long.focusReport
        let focusScore = (focus.focusedSec + focus.scatteredSec) > 0 ? focus.score : long.focus.score
        dims.append(BehaviorDimension(key: "深度工作", score: focusScore,
            fact: "加权专注度 \(focusScore)%"))
        // 碎片切换：每活跃小时干扰 + 切换次数（绝对，0–100）
        let activeH = max(0.5, Double(focus.focusedSec + focus.scatteredSec) / 3600)
        let disruptions = Double(focus.interruptionCount + focus.switchCount)
        let fragPerH = disruptions / activeH
        let fragScore = min(100, Int((fragPerH / 12 * 100).rounded()))
        dims.append(BehaviorDimension(key: "碎片切换", score: fragScore,
            fact: "每活跃小时约 \(Int(fragPerH.rounded())) 次切换/干扰"))
        // AI 辅助：AI 类应用占活跃应用比例（绝对，0–100）
        let aiKw = BehaviorProfileKit.aiKeywords
        let aiTotal = max(1, long.allApps.reduce(0) { $0 + $1.count })
        let aiCount = long.allApps
            .filter { a in aiKw.contains { a.app.lowercased().contains($0.lowercased()) } }
            .reduce(0) { $0 + $1.count }
        let aiShare = Double(aiCount) / Double(aiTotal)
        let aiScore = min(100, Int((aiShare * 300).rounded()))
        dims.append(BehaviorDimension(key: "AI 辅助", score: aiScore,
            fact: "AI 应用占活跃应用 \(Int((aiShare * 100).rounded()))%"))

        // 时间偏好（24 小时活跃占比）
        let maxH = max(1, long.hourly.max() ?? 1)
        let hourBars = long.hourly.map { Int((Double($0) / Double(maxH) * 100).rounded()) }

        // 长期主题（Top 活跃分类，中文）
        let topics = longCats.prefix(5).map { $0.0 }

        // 近期变化：对比 recent / prev 窗口的维度分
        let recentDims = dimScores(stats: recent, totalActive: max(1.0, Double(recent.categories.reduce(0) { $0 + $1.1 })))
        let prevDims = dimScores(stats: prev, totalActive: max(1.0, Double(prev.categories.reduce(0) { $0 + $1.1 })))
        var changes: [BehaviorChange] = []
        for key in ["内容生产", "探索研究", "技术实践", "沟通协作", "深度工作", "碎片切换", "AI 辅助"] {
            let cur = recentDims[key] ?? 0
            let pv = prevDims[key] ?? 0
            guard pv > 0 || cur > 0 else { continue }
            let delta = pv > 0 ? Int(((Double(cur - pv) / Double(pv)) * 100).rounded()) : (cur > 0 ? 100 : 0)
            let dir = delta > 3 ? 1 : (delta < -3 ? -1 : 0)
            changes.append(BehaviorChange(key: key, deltaPct: delta, direction: dir))
        }

        // 留刻发现：本地规则生成客观结论（非 AI、非人格判断）
        var discoveries: [String] = []
        let parts: [(String, Range<Int>)] = [("上午", 6..<12), ("下午", 12..<18), ("晚上", 18..<24), ("凌晨", 0..<6)]
        let partSum = parts.map { (name: String, range: Range<Int>) in
            (name, range.reduce(0) { $0 + long.hourly[$1] })
        }
        if let peak = partSum.max(by: { $0.1 < $1.1 }), peak.1 > 0 {
            discoveries.append("过去 \(coveredDays) 天，你的活跃高峰集中在\(peak.0)。")
        }
        if let ai = changes.first(where: { $0.key == "AI 辅助" }), ai.deltaPct >= 15 {
            discoveries.append("最近一个月，AI 工具相关活动明显上升（约 +\(ai.deltaPct)%）。")
        } else if let ai = changes.first(where: { $0.key == "AI 辅助" }), ai.deltaPct <= -15 {
            discoveries.append("最近一个月，AI 工具使用较前一阶段有所回落。")
        }
        if fragScore >= 50 {
            discoveries.append("切换较频繁，深度工作占比偏低，可适当减少并行任务。")
        } else if fragScore > 0 {
            discoveries.append("整体专注节奏较稳。")
        }

        return BehaviorProfile(coveredDays: coveredDays, readiness: BehaviorProfileKit.readiness(coveredDays),
                                dimensions: dims, hourBars: hourBars, topics: topics,
                                recentChanges: changes, discoveries: discoveries,
                                generatedAt: DateUtil.isoUTC(Date()))
    }

    /// 与 buildBehaviorProfile 同口径的「维度分」计算，供近期变化对比（key → score）。
    private func dimScores(stats: Store.ScopeStats, totalActive: Double) -> [String: Int] {
        let cats = stats.categories
        let interval = Double(cfg.intervalSec)
        func catSec(_ name: String) -> Double {
            Double(cats.first { $0.0 == name }?.1 ?? 0) * interval
        }
        let groups: [(String, [String])] = [
            ("内容生产", ["办公与文档", "设计与创作"]),
            ("探索研究", ["阅读与研究"]),
            ("技术实践", ["编程开发"]),
            ("沟通协作", ["沟通与协作"])
        ]
        var out: [String: Int] = [:]
        let groupShares = groups.map { g -> (String, Double) in
            let sec = g.1.reduce(0.0) { $0 + catSec($1) }
            return (g.0, sec / totalActive)
        }
        let maxShare = max(0.0001, groupShares.map { $0.1 }.max() ?? 0.0001)
        for g in groupShares { out[g.0] = Int((g.1 / maxShare * 100).rounded()) }
        let focus = stats.focusReport
        out["深度工作"] = (focus.focusedSec + focus.scatteredSec) > 0 ? focus.score : stats.focus.score
        let activeH = max(0.5, Double(focus.focusedSec + focus.scatteredSec) / 3600)
        let fragPerH = Double(focus.interruptionCount + focus.switchCount) / activeH
        out["碎片切换"] = min(100, Int((fragPerH / 12 * 100).rounded()))
        let aiKw = BehaviorProfileKit.aiKeywords
        let aiTotal = max(1, stats.allApps.reduce(0) { $0 + $1.count })
        let aiCount = stats.allApps
            .filter { a in aiKw.contains { a.app.lowercased().contains($0.lowercased()) } }
            .reduce(0) { $0 + $1.count }
        out["AI 辅助"] = min(100, Int((Double(aiCount) / Double(aiTotal) * 300).rounded()))
        return out
    }

    /// 对应 summary:generate，但改用「时间分层摘要」架构：
    /// 日→周→月→年 逐级由低层 Digest 组合；低层缺失时回退原始记录（再不行回退 220 行采样）。
    /// 统计（分类占比/专注度/Top 应用）全部由代码计算，AI 只负责理解与表达（overview/sections）。
    func generateSummary() async {
        summaryGenerating = true
        summaryError = nil
        defer { summaryGenerating = false }

        let scope = summaryScope.rawValue
        let dates = scopeDates

        // 1. 构建本 scope 的 Digest（内部按需复用/构建低层 Digest；无则回退原始记录）
        var digest = await loadOrBuildDigest(scope: scope, dates: dates)
        let hasData = digest.recordCount > 0 || !digest.categoryPercent.isEmpty
        guard hasData else {
            summaryError = "该区间没有可供总结的活动记录"
            return
        }

        // 2. 关键事实（供 AI 叙事：高频应用/主题 + 区间内高价值的一念主动记忆）
        var facts = await summaryFacts(scope: scope, dates: dates, digest: digest)
        // 年总结以「月度脉络」为骨架：把各月聚合后的专注度/分类/回忆喂给 AI，
        // 让它写出真实年度变化，而不是逐月罗列或只复用单月。
        if scope == "year", let mc = await yearMonthlyContext(dates: dates) {
            facts += "\n\n【月度脉络】（已按月份聚合，请据此写出年度变化，不要逐月罗列）：\n" + mc
        }

        // 3. AI 解释（若可用）：基于代码统计 + 事实生成 overview/sections
        if let profile = ModelRouter.profile(for: .panorama, in: cfg) {
            if modelOffline(profile.id) {
                summaryError = "模型离线（\(profile.name)），已保存统计摘要，联网后可重新生成 AI 回忆。"
            } else {
                let res = await Analyzer.summarizeDigest(scope: scope, rangeLabel: rangeLabel,
                                                          statsBlock: digest.computedDataBlock(),
                                                          facts: facts, profile: profile, cfg: cfg)
                if res.ok {
                    digest.overview = res.overview
                    digest.sections = res.sections
                    digest.model = res.model
                    digest.modelLabel = "\(profile.kind.label) · \(profile.modelName)"
                    digest.latencyMs = res.latencyMs
                    // 统计优先用代码计算的占比；仅在代码无占比时兜底用 AI 返回
                    if digest.categoryPercent.isEmpty, !res.categoryPercent.isEmpty {
                        digest.categoryPercent = res.categoryPercent
                    }
                } else {
                    summaryError = res.error
                }
            }
        } else {
            summaryError = "未配置可用模型，请在「模型」设置中分配模型。"
        }
        digest.generatedAt = DateUtil.isoUTC(Date())

        // 4. 持久化 Digest（派生数据，随时可由原始 Activity 重新生成）
        await store.writeDigest(digest)

        // 5. 写入/刷新 SummaryDoc（向后兼容：面板与历史仍读 SummaryDoc）
        let doc = SummaryDoc(from: digest, scope: scope, rangeLabel: rangeLabel, dates: dates)
        await store.writeSummary(doc.key, doc)
        await store.appendSummaryHistory(doc.key, doc)

        summaryDoc = doc
        summaryViewing = nil
        summaryHistory = await store.listSummaryHistory(doc.key)

        // 代码算好的分类占比顺带刷新饼图
        if !doc.category_percent.isEmpty {
            breakdown = CategoryBreakdown(
                analyzed: doc.category_percent.values.reduce(0, +),
                categories: doc.category_percent.map { ($0.key, $0.value) }
            )
        }
    }

    /// 删除某条历史生成记录并刷新列表；若当前正在查看该记录，则切回最新主记录。
    func deleteSummaryHistory(_ doc: SummaryDoc) async {
        let key = doc.key.isEmpty ? currentSummaryKey : doc.key
        await store.deleteSummaryHistory(key, generatedAt: doc.generatedAt)
        summaryHistory = await store.listSummaryHistory(key)
        if summaryViewing?.generatedAt == doc.generatedAt {
            summaryViewing = nil
        }
        // 如果删的是主记录，刷新主记录显示
        if summaryDoc?.generatedAt == doc.generatedAt {
            summaryDoc = await store.readSummary(key)
        }
    }

    // MARK: 分层摘要构建

    private func digestRangeLabel(_ dates: [String]) -> String {
        "\(dates.first ?? "") ~ \(dates.last ?? "")"
    }

    /// 读取或构建某 scope 的 Digest：先读已存 Digest（派生数据，最快）；
    /// 但若其源数据（覆盖日期的原始记录文件）比构建时更新，则视为陈旧、重新构建——
    /// 既保留「年总结只读 12 个 month Digest」的快速路径，又修掉了"点了生成却还是旧数据"的陈旧缓存 bug。
    private func loadOrBuildDigest(scope: String, dates: [String]) async -> ActivityDigest {
        let label = digestRangeLabel(dates)
        let key = DigestBuilder.keyForScope(scope, rangeLabel: label, dateStrs: dates)

        // 新鲜度守卫：源数据 mtime 不比 digest 记录的新 → 直接用缓存；否则重建（仅 stat、不解码）
        if let existing = await store.readDigest(key: key),
           await store.maxLogMtime(forDates: dates, kind: .memento) <= existing.sourceMaxTs {
            return existing
        }

        var built: ActivityDigest
        switch scope {
        case "day":
            let date = dates.first ?? summaryDate
            let recs = await store.dayRecords(date, kind: .memento)
            built = DigestBuilder.buildDay(date: date, records: recs)
        case "week":
            var children: [ActivityDigest] = []
            for d in dates where DateUtil.parseDateStr(d) != nil {
                children.append(await loadOrBuildDigest(scope: "day", dates: [d]))
            }
            built = DigestBuilder.buildFromChildren(scope: "week", rangeLabel: label, dateStrs: dates, children: children)
        case "month":
            var children: [ActivityDigest] = []
            for wk in DigestBuilder.weekKeysInDates(dates) {
                let monday = String(wk.dropFirst(5))   // "week-YYYY-MM-DD" → "YYYY-MM-DD"
                guard let md = DateUtil.parseDateStr(monday) else { continue }
                children.append(await loadOrBuildDigest(scope: "week", dates: DateUtil.weekDates(of: md)))
            }
            built = DigestBuilder.buildFromChildren(scope: "month", rangeLabel: label, dateStrs: dates, children: children)
        case "year":
            var children: [ActivityDigest] = []
            for mk in DigestBuilder.monthKeysInDates(dates) {
                let ym = String(mk.dropFirst(6))        // "month-YYYY-MM" → "YYYY-MM"
                guard let d0 = DateUtil.parseDateStr(ym + "-01") else { continue }
                children.append(await loadOrBuildDigest(scope: "month", dates: DateUtil.monthDates(of: d0)))
            }
            built = DigestBuilder.buildFromChildren(scope: "year", rangeLabel: label, dateStrs: dates, children: children)
        default:
            built = DigestBuilder.buildDay(date: dates.first ?? "", records: [])
        }

        // 记录源数据新鲜度 + 生成时间，供下次读取做陈旧判定
        built.sourceMaxTs = await store.maxLogMtime(forDates: dates, kind: .memento)
        built.generatedAt = DateUtil.isoUTC(Date())
        await store.writeDigest(built)
        return built
    }

    /// 年总结专用：读取各月 Digest，汇总成「月度脉络」供 AI 写出真实年度变化。
    /// 各月的专注度/分类/回忆本身已是低层 Digest 的聚合结果，这里只做拼接，不重新计算统计。
    private func yearMonthlyContext(dates: [String]) async -> String? {
        let keys = DigestBuilder.monthKeysInDates(dates)
        guard !keys.isEmpty else { return nil }
        var lines: [String] = []
        for mk in keys {
            guard let d = await store.readDigest(key: mk) else { continue }
            let cats = d.categoryPercent
                .sorted { $0.value > $1.value }
                .prefix(3)
                .map { "\($0.key)\($0.value)%" }
                .joined(separator: "/")
            let ov = d.overview.isEmpty ? "（尚未生成回忆）" : d.overview
            lines.append("\(d.rangeLabel)：专注度 \(d.focus.score)% · 主要分类 \(cats) · 回忆：\(ov)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 给 AI 的关键事实：高频应用/主题 + 区间内高价值的一念主动记忆（带 intent）。
    private func summaryFacts(scope: String, dates: [String], digest: ActivityDigest) async -> String {
        var lines: [String] = []
        if !digest.topActivities.isEmpty {
            lines.append("高频应用：" + digest.topActivities.prefix(8).joined(separator: "、"))
        }
        if !digest.topProjects.isEmpty {
            lines.append("高频主题：" + digest.topProjects.prefix(10).joined(separator: "、"))
        }
        let dateSet = Set(dates)
        let yinian = await store.allYinian(limit: 600).filter { r in
            guard let d = r.date else { return false }
            return dateSet.contains(d)
        }
        let priority = ["项目里程碑", "高光时刻", "重要通知", "待办提醒",
                       "灵感", "设计参考", "知识收藏", "生活记录", "其他"]
        let key = yinian
            .filter { let i = $0.activity?.intentValue ?? "其他"; return i != "其他" }
            .sorted { (priority.firstIndex(of: $0.activity?.intentValue ?? "其他") ?? 99)
                < (priority.firstIndex(of: $1.activity?.intentValue ?? "其他") ?? 99) }
            .prefix(12)
        if !key.isEmpty {
            let items = key.map { "【\($0.activity?.intentValue ?? "其他")】\($0.activity?.title ?? "")" }
            lines.append("主动记忆（一念）：\n" + items.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    /// 按 [日期 小时] 分组均匀采样（1:1 复刻 main.js 的采样逻辑）
    /// 改进：强制保留「最近」tailReserve 条，避免最新做的事被采样漏掉导致总结陈旧。
    static func sampleLines(_ lines: [String], cap: Int) -> [String] {
        guard lines.count > cap else { return lines }
        let tailReserve = min(cap / 5, 60)          // 强制保留最近 N 条（最新活动必进总结）
        let bodyCap = max(1, cap - tailReserve)     // 其余按小时均匀采样
        var order: [String] = []
        var groups: [String: [String]] = [:]
        for l in lines {
            let k = String(l.prefix(13))   // "[YYYY-MM-DD HH"
            if groups[k] == nil { groups[k] = []; order.append(k) }
            groups[k]?.append(l)
        }
        let per = max(1, Int(ceil(Double(bodyCap) / Double(order.count))))
        var sampled: [String] = []
        for k in order {
            sampled.append(contentsOf: (groups[k] ?? []).prefix(per))
            if sampled.count >= bodyCap { break }
        }
        // 强制把最近 tailReserve 条加进来（当天最后的活动一定被总结到）
        var used = Set(sampled)
        for l in lines.suffix(tailReserve) where !used.contains(l) {
            sampled.append(l); used.insert(l)
            if sampled.count >= cap { break }
        }
        // 兜底：仍不足 cap 时从尾部补
        if sampled.count < cap {
            for l in lines.suffix(80) where !used.contains(l) {
                sampled.append(l); used.insert(l)
                if sampled.count >= cap { break }
            }
        }
        Log.shared.info("总结采样：\(lines.count) 条 → 按小时均匀采样 \(sampled.count) 条（含最近 \(min(tailReserve, lines.count)) 条最新活动，覆盖全天）")
        return sampled
    }

    /// 对应 renderer.js datesInScope()
    static func datesInScope(_ scope: SummaryScope, _ baseStr: String) -> [String] {
        guard let base = DateUtil.parseDateStr(baseStr) else { return [baseStr] }
        switch scope {
        case .day: return [baseStr]
        case .week: return DateUtil.weekDates(of: base)
        case .month: return DateUtil.monthDates(of: base)
        case .year: return DateUtil.yearDates(of: base)
        }
    }

    // MARK: - 全局搜索

    /// 聚焦顶部 toolbar 搜索框（⌘F / ⌘K）
    func openSearch() {
        searchFocusSignal += 1
    }

    func runSearch() {
        searchTask?.cancel()
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            searchResults = []
            searchHasRun = false
            searchBusy = false
            return
        }
        searchBusy = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self, !Task.isCancelled else { return }
            // 走统一搜索索引：瞬息/一念/随想 一次匹配，索引内部已缓存，不再每次重扫所有 JSON
            let res = await self.searchIndex.search(
                q,
                filter: self.searchFilter.isEmpty ? nil : self.searchFilter,
                store: self.store,
                museStore: self.museStore,
                groupStore: self.museGroupStore
            )
            guard !Task.isCancelled else { return }
            self.searchResults = res
            self.searchHasRun = true
            self.searchBusy = false
        }
    }

    /// 点击搜索结果 → 跳转到该日期对应页面并闪烁定位（一念 → 一念页，瞬息 → 瞬息页）
    /// 各自更新所属页面的日期：一念跳转改 yinianDate，瞬息跳转改 currentDate，互不串。
    func jumpTo(_ r: ActRecord) {
        searchQuery = ""
        searchResults = []
        searchHasRun = false
        tab = r.kind == .yinian ? .yinian : .instant
        if r.kind == .yinian {
            // 搜索跳转到某条一念 → 定位到它所在日期，并切到过滤视图精准展示
            yinianDate = r.date ?? yinianDate
            filterByDate = true
        } else {
            currentDate = r.date ?? currentDate
        }
        Task {
            await reload()
            try? await Task.sleep(nanoseconds: 120_000_000)
            breatheId = r.id
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if breatheId == r.id { breatheId = nil }
        }
    }

    /// 点击统一搜索结果 → 按类型跳转
    /// 瞬息/一念：沿用 jumpTo 的定位逻辑；随想：打开随想页并选中该笔记。
    func jumpToHit(_ hit: SearchHit) {
        searchQuery = ""
        searchResults = []
        searchHasRun = false
        if hit.kind == .muse {
            tab = .muse
            let kw = hit.terms.first ?? ""
            museJumpKeyword = kw.isEmpty ? nil : kw
            museJumpToken += 1
            if let mid = hit.museId { selectMuse(mid) }
            return
        }
        guard let r = hit.record else { return }
        tab = r.kind == .yinian ? .yinian : .instant
        if r.kind == .yinian {
            yinianDate = r.date ?? yinianDate
            filterByDate = true
        } else {
            currentDate = r.date ?? currentDate
        }
        Task {
            await reload()
            try? await Task.sleep(nanoseconds: 120_000_000)
            breatheId = r.id
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if breatheId == r.id { breatheId = nil }
        }
    }

    /// 彻底取消搜索：清空关键词、结果、运行标记，让 DetailRoot 切回正常页面。
    /// 搜索框本身的展开态（isExpanded）由 CollapsibleSearchBar 的本地 @State 管理。
    func cancelSearch() {
        searchQuery = ""
        searchResults = []
        searchHasRun = false
        searchBusy = false
    }

    // MARK: - 记录操作

    func deleteRecord(_ r: ActRecord) async {
        let title = r.activity?.displayTitle ?? "这条"
        guard Dialogs.confirmDelete(
            message: "确定要删除「\(title)」这条记录吗？",
            detail: "截图也会一并删除，此操作不可撤销。"
        ) else { return }

        let ok = await store.deleteRecord(id: r.id)
        if ok {
            await reload()
            await refreshStorage()
            Task { await searchIndex.invalidateRecords() }
            onDataChanged?()
        } else {
            Dialogs.info("未找到这条记录（可能已被删除）")
        }
    }

    func toggleExpand(_ id: String) {
        if expandedIds.contains(id) { expandedIds.remove(id) } else { expandedIds.insert(id) }
    }

    // MARK: - 清理 / 备份

    func cleanupNow() async {
        cleaning = true
        cleanHint = "清理中…"
        defer { cleaning = false }
        var rules = cfg.cleanup
        rules.keepJson = true      // 图文分离：永远保留文本日志
        let r = await store.cleanup(rules)
        cleanHint = "已删 \(r.deletedShots) 张，释放 \(formatBytes(r.freedBytes))，保留 \(r.keptJson) 份日志 ✓"
        await refreshStorage()
        Log.shared.info("cleanup done | deletedShots=\(r.deletedShots) freed=\(String(format: "%.1f", Double(r.freedBytes) / 1048576))MB keptJson=\(r.keptJson)")
    }

    func exportBackup() async {
        backupBusy = true
        backupHint = "正在打包…"
        defer { backupBusy = false }

        guard FileManager.default.fileExists(atPath: cfg.outputDir) else {
            backupHint = "导出失败：保存目录不存在"
            return
        }
        let stamp = DateUtil.ymd(Date()).replacingOccurrences(of: "-", with: "")
        guard let dest = Dialogs.saveBackup(defaultName: "留刻备份-\(stamp).bak") else {
            backupHint = ""
            return
        }
        do {
            try await Migration.tarCreate(archive: dest.path, sourceDir: cfg.outputDir)
            backupHint = "已导出：\(dest.path) ✓"
            Log.shared.info("已导出备份：\(dest.path)")
        } catch {
            backupHint = "导出失败：\(error.localizedDescription)"
        }
    }

    func importBackup() async {
        backupBusy = true
        backupHint = "正在导入…"
        defer { backupBusy = false }

        guard let src = Dialogs.openBackup() else {
            backupHint = ""
            return
        }
        do {
            let restored = try await Migration.importBackup(archive: src.path, outputDir: cfg.outputDir)
            backupHint = "已导入 \(restored) 项 ✓"
            Log.shared.info("已导入备份：\(src.path)（\(restored) 项）")
            await reload()
            await refreshStorage()
        } catch {
            backupHint = "导入失败：\(error.localizedDescription)"
            Log.shared.warn("导入备份失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 权限横幅

    var showPermBanner: Bool {
        if permBannerDismissed { return false }
        return permission != .granted && permission != .unknown
    }

    func dismissPermBanner() {
        permBannerDismissed = true
        UserDefaults.standard.set(true, forKey: "lens.permBannerDismissed")
    }
}

import Combine

extension Notification.Name {
    static let lensTrayToggled = Notification.Name("lens.tray.toggled")
    static let lensTrayRefresh = Notification.Name("lens.tray.refresh")
    static let lensShowWindow = Notification.Name("lens.window.show")
}
