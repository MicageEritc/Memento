import SwiftUI
import AppKit

// MARK: - 「随想」页 —— 类 macOS 备忘录的主动书写空间
//
// 结构：detail 区内的「左列表 + 右编辑器」两栏（不嵌套 NavigationSplitView，
//       避免与原生侧栏的 columnVisibility 语义打架）。
// 定位：用户**主动**写想法/灵感，与瞬息/一念（自动截屏）完全独立。
//
// 工具栏独立：
//   左 = + 新建随想
//   中 = 当前笔记标题（随输入实时更新）
//   右 = 预留 AI 按钮位置（暂禁用，后续迭代再接）
//
// 自动保存：编辑器内部 @State 草稿（打字不回写 @Published，中文输入法不中断），
//           每次变更经 scheduleMuseSave → 700ms 防抖落盘（逻辑在 AppStateMuse.swift）。

struct MusePanel: View {
    @ObservedObject var app: AppState

    // 编辑区草稿：由选中笔记载入；打字只改本地 @State，不直接驱动全局刷新。
    @State private var titleDraft = ""
    @State private var bodyRich = NSAttributedString()
    @State private var loadedId: String? = nil
    /// 外部同步令牌：切换笔记时 +1，驱动 RichTextEditor 把外部内容写入编辑器
    @State private var syncToken = 0
    /// 当前光标处格式状态：编辑器实时刷新，驱动窗口 toolbar 圆形按钮的激活高亮
    @StateObject private var formatState = MuseFormatState()
    /// 当前选中笔记的正文是否已加载完成。加载窗口内禁止触发保存——
    /// 否则切换笔记时标题赋值触发的 onChange 会拿空正文落盘，覆盖磁盘上已有内容
    @State private var bodyLoaded = false
    /// 列表顶部分组按钮：鼠标 hover 时显示下拉箭头，离开自动消失
    @State private var headerHovering = false
    /// 分组下拉 popover 是否展开
    @State private var groupPopover = false

    private var selected: MuseNote? { app.currentMuseNote }

    /// 正文字数统计：
    /// - 中文/日文等表意文字：每个字符算 1 字；
    /// - 连续英文字母/数字（无空格分隔的单词）：整体算 1 字（a 与 aaaaaaa 都算 1）；
    /// - 空格、标点、符号、附件占位符：不计入，但空格/符号作为单词分隔边界。
    private var bodyWordCount: Int {
        let plain = bodyRich.string
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: museDividerMarker, with: "")
        var count = 0
        var inLatinRun = false   // 是否正处于连续字母/数字串中
        for ch in plain {
            if ch.isLetter {
                // 非 ASCII 字母（中文/日文等）→ 每字 1
                if !ch.isASCII {
                    count += 1
                    inLatinRun = false
                } else {
                    // 英文字母 → 并入当前单词
                    if !inLatinRun { count += 1; inLatinRun = true }
                }
            } else if ch.isNumber {
                // 数字 → 并入当前单词（aaaaaaa / 12345 都算 1 字）
                if !inLatinRun { count += 1; inLatinRun = true }
            } else {
                // 空格 / 标点 / 符号 → 单词分隔边界，不计入
                inLatinRun = false
            }
        }
        return count
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 248)
            Divider()
            editorColumn
                .frame(maxWidth: .infinity)
        }
        // ideal 全压 0：绝不让本页内容向窗口声明「理想尺寸」，
        // 从根上杜绝内容把 NSWindow 撑大（其余页面 ScrollView 天然无此问题）。
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity,
               minHeight: 0, idealHeight: 0, maxHeight: .infinity,
               alignment: .leading)
        .onAppear { syncDraft(force: true) }
        .onChange(of: app.museSelectedId) { _, _ in
            // 无选中（如删除最后一篇）→ 工具栏高亮全部熄灭
            if selected == nil { formatState.reset() }
            syncDraft(force: true)
        }
        .toolbar {
            // 全局搜索为独立内容状态：搜索时清空整个 toolbar（不继承当前页面原有 items）
            if !app.isSearching {
            // 左：新建随想 + 新建分组。
            // ⚠️ 关键：SwiftUI 会把多个相邻 ToolbarItem 自动合并成「胶囊组控件」
            //    （截图里那条灰色长条的元凶），把画好的正圆裹进胶囊里。
            //    所以一侧只用**一个** ToolbarItem 承载自定义 HStack，
            //    组内每个按钮各自圆形背景、互不连体，与 Finder 的独立圆形 item 一致。
            ToolbarItem(placement: .navigation) {
                MuseLeadingToolbar(app: app)
            }
            // 中间留空
            ToolbarSpacer(.flexible)
            // 右：格式工具 + 预留 AI —— 同样单个自定义视图，全部 28×28 正圆；
            // 点击/悬停整圆盖灰，格式生效时整圆蓝底白图标（高亮正在使用的工具）。
            ToolbarItem(placement: .primaryAction) {
                MuseFormatToolbar(app: app,
                                  formatState: formatState,
                                  onInsertImage: { insertAttachmentImage() },
                                  onInsertFile: { insertAttachmentFile() })
            }
            }
        }
        // 分组编辑弹窗（新建 / 重命名）
        .sheet(isPresented: Binding(
            get: { app.museGroupDialog != nil },
            set: { if !$0 { app.museGroupDialog = nil } }
        )) {
            MuseGroupDialogSheet(app: app)
        }
        // 原生毛玻璃工具栏背景：滚动内容上滑时被模糊（macOS 26 原生观感）
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
        // AI 总结 / 润色 结果面板
        .sheet(item: $app.museAISheet) { mode in
            switch mode {
            case .summary: MuseAISummarySheet(app: app)
            case .polish: MuseAIPolishSheet(app: app)
            }
        }
    }

    // MARK: 左：随想列表
    //
    // 不用 `List(selection:)`：macOS 系统 selection tint 会在选中的行叠一层蓝底，
    // 即便加 `.tint(.clear)` 也压不住。改用 ScrollView + LazyVStack + Button 自管选中，
    // 样式 100% 自己控制：选中 = 黄色小矩形卡片，未选中 = 灰色小矩形卡片，
    // 整片背景 = 透明（透过去看到 sidebar 颜色）。

    private var listColumn: some View {
        let notes = app.filteredMuseNotes
        let groupEmpty = notes.isEmpty && app.museCurrentGroupId != nil
            && app.museGroups.contains(where: { $0.id == app.museCurrentGroupId })
        // ZStack：空态覆盖层相对「整列」垂直居中，与右侧编辑区空态水平对齐
        return ZStack {
            VStack(spacing: 0) {
                // 顶部：分组下拉 + 快速新建（参考 macOS 备忘录「📋 全部笔记 ▼」+ 右上 +）
                listHeaderBar
                // 总数统计（参考备忘录「共 N 项」）
                HStack {
                    Text("共 \(notes.count) 项")
                        .font(T.f(11))
                        .foregroundStyle(T.muted)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                if !notes.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(notes) { note in
                                Button {
                                    app.selectMuse(note.id)
                                } label: {
                                    MuseRow(note: note, app: app)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                    }
                    .scrollIndicators(.automatic)
                } else {
                    Spacer(minLength: 0)
                }
            }
            if groupEmpty {
                EmptyTip(icon: "folder",
                         text: "「\(app.currentMuseGroupName)」还没有随想。点右上角 + 写一篇。",
                         hiddenLines: 1)
                    .allowsHitTesting(false)
            } else if notes.isEmpty {
                EmptyTip(icon: "square.and.pencil",
                         text: "记录此刻的想法、灵感与片段",
                         hint: "点击右上角 + 开始记录")
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: 列表顶部栏：分组下拉（左）+ 快速新建（右）
    //
    // 用 SwiftUI Menu + .menuStyle(.borderlessButton)：
    //   - borderlessButton 让 label 没有系统按钮外观（无灰框）
    //   - 不加 .menuIndicator(.hidden) → 系统自带 ▼ chevron 自动显示
    //   - Menu 的下拉面板是 NSMenu —— 真正的 macOS 原生菜单（vibrancy 毛玻璃 + 系统圆角）
    //   - 这是最"原生"的下拉体验，也是用户真正想要的

    private var listHeaderBar: some View {
        HStack(spacing: 6) {
            // 分组下拉（SwiftUI Menu → NSMenu 下拉面板）
            Menu {
                Button {
                    app.setMuseCurrentGroup(nil)
                } label: {
                    Label("全部随想 (\(app.museGroupCount(nil)))", systemImage: "tray.full")
                }
                if !app.museGroups.isEmpty { Divider() }
                ForEach(app.museGroups) { g in
                    Button {
                        app.setMuseCurrentGroup(g.id)
                    } label: {
                        if app.museCurrentGroupId == g.id {
                            Label("\(g.name) (\(app.museGroupCount(g.id)))", systemImage: "folder.fill")
                        } else {
                            Label("\(g.name) (\(app.museGroupCount(g.id)))", systemImage: "folder")
                        }
                    }
                }
                // 当前分组：重命名 / 删除
                if let gid = app.museCurrentGroupId,
                   let g = app.museGroups.first(where: { $0.id == gid }) {
                    Divider()
                    Button {
                        app.museGroupDialog = .rename(id: g.id, name: g.name)
                    } label: {
                        Label("重命名分组", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        app.deleteMuseGroup(g.id)
                    } label: {
                        Label("删除分组", systemImage: "trash")
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: app.museCurrentGroupId == nil ? "tray.full" : "folder")
                        .font(.system(size: 13, weight: .medium))
                    Text(app.currentMuseGroupName)
                        .font(T.f(13, .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(T.text)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)   // label 无灰框 + 系统自带指示器
            .help("切换分组")

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)        // 与 sidebar 搜索框同一水平线对齐
        .padding(.bottom, 6)
    }

    // MARK: 右：编辑区

    @ViewBuilder
    private var editorColumn: some View {
        // GeometryReader 锁定编辑区尺寸为父级（detail）分配的实际大小，
        // 阻止富文本编辑器按内容向 window 声明「理想高度」，否则长文会把窗口撑高。
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // ⚠️ 编辑区常驻挂载：不随 selected 在 nil↔非nil 之间切换而销毁重建。
                // 否则首次打开时笔记列表是异步加载的，loadMuse 跑完才把 museSelectedId
                // 设为第一篇，selected 经历 nil→第一篇，整棵子树被销毁重建，
                // 刚点上去的标题 TextField 焦点框会闪一下即消失。
                VStack(alignment: .leading, spacing: 0) {
                    // 标题（单行 + plain 样式）
                    TextField("标题", text: $titleDraft)
                        .font(T.f(22, .semibold))
                        .foregroundStyle(T.text)
                        .textFieldStyle(.plain)
                        // ⚠️ 黑匣子实锤（15:14-15:15 日志）：标题焦点稳定（无 focused=false），
                        // 正文从未抢焦点（无 body become）——「闪一下的框」不是焦点竞争，
                        // 而是 macOS 每次启动后首次点击标题时画的焦点环（focus ring）。
                        // focusEffectDisabled() 关掉它，一劳永逸。
                        .focusEffectDisabled()
                        .lineLimit(1)
                        .padding(.horizontal, 28)
                        .padding(.top, 24)
                        .padding(.bottom, 4)
                        .onChange(of: titleDraft) { _, _ in schedule() }

                    // 轻量 metadata：标题下小字日期
                    if let date = selected?.updatedDate {
                        Text(formatMeta(date))
                            .font(T.f(11))
                            .foregroundStyle(T.muted)
                            .padding(.horizontal, 28)
                            .padding(.bottom, 10)
                    }

                    // AI 总结 Tip（独立于正文的附属信息；小眼睛=折叠，AI 面板「隐藏」=彻底删除）
                    if let tip = selected?.aiSummary, !tip.isEmpty {
                        MuseSummaryTipView(text: tip,
                                           hidden: selected?.aiSummaryHidden ?? false,
                                           onToggle: { app.toggleMuseSummaryTipHidden() })
                            .padding(.horizontal, 24)
                            .padding(.bottom, 8)
                    }

                    // 正文（NSTextView 富文本）；syncToken 切换笔记时递增 → 编辑器同步内容。
                    // formatState 注入编辑器：文本/选区变化时实时刷新，
                    // 窗口 toolbar 的正圆按钮据此高亮当前生效的格式。
                    RichTextEditor(text: $bodyRich, onEditing: schedule,
                                   syncToken: syncToken, formatState: formatState,
                                   jumpToken: app.museJumpToken, jumpKeyword: $app.museJumpKeyword)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.top, 6)
                        .padding(.bottom, 10)

                    // 底部字数统计（替代原自动保存时间）
                    HStack(spacing: 6) {
                        Spacer(minLength: 0)
                        // 显式字符串拼接，确保无千位分隔号
                        Text("共 " + String(bodyWordCount) + " 字")
                            .font(T.f(11))
                            .foregroundStyle(T.muted)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 6)
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                // 未选中时整块不可见、不接收点击（空态由下面的 EmptyTip 承接），
                // 但视图实例保持不变，标题 TextField 的焦点框不会再被重建吞掉。
                .opacity(selected != nil ? 1 : 0)
                .allowsHitTesting(selected != nil)

                if selected == nil {
                    // hiddenLines 1：左侧空态有 text+hint 两行，右侧补一行占位等高，图标对齐
                    EmptyTip(icon: "square.and.pencil",
                             text: app.museNotes.isEmpty
                                ? "留下一些未必重要，但值得记住的想法。"
                                : "选择左侧一篇随想开始阅读，或点 + 新建一篇。",
                             hiddenLines: 1)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }

    // MARK: 辅助

    /// 选中切换 / 进入页面时，把当前笔记载入草稿；同一篇不重复覆盖（避免打断输入）
    /// 富文本正文异步从 RTF + 附件重建。
    /// ⚠️ 内容丢失修复：进入加载窗口先把 bodyLoaded 置 false ——
    /// 标题赋值会触发 onChange → schedule()，此时正文尚未从磁盘读回（bodyRich 是旧值/空），
    /// 若放行保存，700ms 后空内容会覆盖磁盘上已有正文（"切走再回来内容全没了"的根因）。
    private func syncDraft(force: Bool) {
        guard let note = selected else { return }
        if force || note.id != loadedId {
            let targetId = note.id
            bodyLoaded = false            // 进入加载窗口：禁止任何落盘，直到正文加载完成
            titleDraft = note.title
            loadedId = note.id
            app.museSavedAt = ""
            Task {
                let rich = await app.loadMuseRichText(id: targetId)
                guard targetId == app.museSelectedId else { return }  // 期间已切换，丢弃
                bodyRich = rich
                syncToken += 1   // 通知编辑器：外部内容已更新，请同步
                bodyLoaded = true         // 加载完成：恢复保存
            }
        }
    }

    /// 防抖保存打点。两道闸门防止误覆盖：
    /// ① bodyLoaded：正文未加载完成时绝不落盘（见 syncDraft 注释）；
    /// ② loadedId 与当前选中一致：防止异步加载期间选中已切走，把内容写到错误笔记。
    private func schedule() {
        guard bodyLoaded else { return }
        guard let id = selected?.id, id == loadedId else { return }
        app.scheduleMuseSave(id: id, title: titleDraft, content: bodyRich)
    }

    private func formatMeta(_ d: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt.string(from: d)
    }

    // MARK: 附件插入

    /// 插入图片：NSOpenPanel 多选图片 → 构建 NSTextAttachment → 插入当前光标处
    private func insertAttachmentImage() {
        guard let tv = RichTextEditor.Coordinator.shared?.textView, let win = tv.window else { return }
        let panel = NSOpenPanel()
        panel.title = "插入图片"
        panel.prompt = "插入"
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: win) { resp in
            guard resp == .OK else { return }
            for url in panel.urls {
                guard let img = NSImage(contentsOf: url) else { continue }
                let attachment = NSTextAttachment()
                attachment.image = img
                // 固定显示宽度，避免超大图撑爆编辑区
                let maxW: CGFloat = 420
                if img.size.width > maxW {
                    let scale = maxW / img.size.width
                    attachment.bounds = NSRect(x: 0, y: 0,
                                               width: maxW,
                                               height: img.size.height * scale)
                }
                tv.insertText(NSAttributedString(attachment: attachment),
                              replacementRange: tv.selectedRange())
            }
        }
    }

    /// 插入文件：NSOpenPanel 多选任意文件 → 文件名 chip（图标+名称，不自动打开）
    private func insertAttachmentFile() {
        guard let tv = RichTextEditor.Coordinator.shared?.textView, let win = tv.window else { return }
        let panel = NSOpenPanel()
        panel.title = "插入文件"
        panel.prompt = "插入"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: win) { resp in
            guard resp == .OK else { return }
            for url in panel.urls {
                guard let data = try? Data(contentsOf: url) else { continue }
                let chip = MuseFileChipAttachment(fileName: url.lastPathComponent, data: data)
                tv.insertText(NSAttributedString(attachment: chip),
                              replacementRange: tv.selectedRange())
            }
        }
    }
}

// MARK: - 窗口 toolbar 自定义视图
//
// 每侧用**一个** ToolbarItem 承载自定义 HStack：
// SwiftUI 会把多个相邻 ToolbarItem 自动合并成系统「胶囊组控件」，
// 把自定义的正圆背景裹进一条灰色长胶囊里（之前"不是正圆"的根因）。
// 合并成单个 item 后，组内每个按钮的圆形背景完全由自己控制，互不连体。

/// 左：新建随想 + 新建分组（均为 28×28 正圆按钮）
struct MuseLeadingToolbar: View {
    @ObservedObject var app: AppState

    var body: some View {
        // spacing 2 + 每个按钮 3pt 外边距 → 所有 item 视觉间距统一
        HStack(spacing: 2) {
            Button {
                app.newMuseNote()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(MuseCircleButtonStyle())
            .help("新建随想 (⌘N)")

            Button {
                app.museGroupDialog = .create
            } label: {
                Image(systemName: "folder.badge.plus")
            }
            .buttonStyle(MuseCircleButtonStyle())
            .help("新建分组")
        }
        .fixedSize()
    }
}

/// 右：格式工具 + AI + 更多（全部 28×28 正圆；生效的工具整圆蓝底白图标高亮）
struct MuseFormatToolbar: View {
    @ObservedObject var app: AppState
    @ObservedObject var formatState: MuseFormatState
    var onInsertImage: () -> Void
    var onInsertFile: () -> Void

    @State private var showFormatPanel = false

    var body: some View {
        // spacing 2 + 每个按钮 3pt 外边距 → 所有 item 视觉间距统一
        HStack(spacing: 2) {
            // 「格式」：点击弹出 Popover 面板（B/I/U/S 横排 + 大小/列表选项，✓ 靠右对齐）。
            // 不用 Menu：菜单项不支持横排自定义布局，HStack+Button 会被转成失效项。
            Button {
                showFormatPanel.toggle()
                // 面板弹出时让正文失焦：此时打字不应进入正文（面板是模态操作区）
                if showFormatPanel {
                    RichTextEditor.Coordinator.shared?.textView?.window?
                        .makeFirstResponder(nil)
                }
            } label: {
                MuseCircleIcon(icon: "textformat", active: showFormatPanel)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showFormatPanel, arrowEdge: .bottom) {
                MuseFormatPanel(formatState: formatState) { fn in
                    op(fn)
                }
            }
            .help("格式：样式 / 大小 / 列表")

            // 制作核对清单：未勾 = 圆形、已勾 = 蓝色对勾；
            // 非清单行点它创建清单，清单行点它反复勾/取消
            circle("checklist", help: "制作核对清单",
                   active: formatState.listMarker == "☐") { op(MuseFormatOps.toggleChecklist) }

            circle("photo", help: "插入图片", active: false) { onInsertImage() }
            circle("paperclip", help: "插入文件", active: false) { onInsertFile() }

            // AI：点击弹出「总结 / 润色」菜单，不直接执行
            Menu {
                Button { app.requestMuseSummary() } label: {
                    Label("总结", systemImage: "text.alignleft")
                }
                Button { app.requestMusePolish() } label: {
                    Label("润色", systemImage: "wand.and.stars")
                }
            } label: {
                MuseCircleIcon(icon: "sparkles", active: app.museAILoading)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("AI 总结 / 润色")

            // 更多操作（必须是最右侧最后一个）：导出为 Markdown / PDF / 原始文件
            Menu {
                Button { app.requestMuseExportMarkdown() } label: {
                    Label("导出为 Markdown", systemImage: "doc")
                }
                Button { app.requestMuseExportPDF() } label: {
                    Label("导出为 PDF", systemImage: "doc.richtext")
                }
                Button { app.requestMuseExportRaw() } label: {
                    Label("导出为原始文件", systemImage: "folder")
                }
            } label: {
                MuseCircleIcon(icon: "ellipsis", active: false)
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help("更多操作与导出")
        }
        .fixedSize()
    }

    private func circle(_ icon: String, help: String, active: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
        }
        .buttonStyle(MuseCircleButtonStyle(isActive: active))
        .help(help)
    }

    /// 取当前编辑器执行格式操作；操作后 textDidChange 自动刷新高亮与落盘
    private func op(_ fn: (NSTextView) -> Void) {
        guard let tv = RichTextEditor.Coordinator.shared?.textView else {
            Log.shared.warn("muse format | textView is nil")
            return
        }
        fn(tv)
    }
}

// MARK: - 格式 Popover 面板（B/I/U/S 横排 + 大小/列表选项）

/// 格式面板：横排 B/I/U/S（选中蓝底白字）+ 清除格式画笔；
/// 下方竖列选项（标题/小标题/正文、三种列表），选中项右侧蓝色 ✓ 靠右对齐。
struct MuseFormatPanel: View {
    @ObservedObject var formatState: MuseFormatState
    /// 执行格式操作：接收 (NSTextView) -> Void 操作并作用于当前编辑器
    var perform: (@escaping (NSTextView) -> Void) -> Void

    private let rowMinWidth: CGFloat = 168

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ── 字符样式横排：B / I / U / S（SF Symbols 标准符号，天然居中）──
            // maxWidth 撑满 + 默认居中 → 四符号到面板左右边距相等
            HStack(spacing: 8) {
                styleChip("bold", on: formatState.bold) { perform(MuseFormatOps.toggleBold) }
                styleChip("italic", on: formatState.italic) { perform(MuseFormatOps.toggleItalic) }
                styleChip("underline", on: formatState.underline) { perform(MuseFormatOps.toggleUnderline) }
                styleChip("strikethrough", on: formatState.strike) { perform(MuseFormatOps.toggleStrikethrough) }
            }
            .frame(maxWidth: .infinity)

            Divider()

            // ── 文字大小 ──
            sizeRow("标题", font: .system(size: 15, weight: .bold),
                    on: formatState.fontSize >= 22) { perform { MuseFormatOps.applyHeading($0, .title) } }
            sizeRow("小标题", font: .system(size: 13.5, weight: .semibold),
                    on: formatState.fontSize >= 17 && formatState.fontSize < 22) { perform { MuseFormatOps.applyHeading($0, .heading) } }
            sizeRow("正文", font: .system(size: 13),
                    on: formatState.fontSize > 0 && formatState.fontSize < 17) { perform { MuseFormatOps.applyHeading($0, .body) } }

            Divider()

            // ── 列表 ──
            listRow("•", name: "项目符号列表",
                    on: formatState.listMarker == "•") { perform { MuseFormatOps.applyList($0, .bullet) } }
            listRow("–", name: "短横线列表",
                    on: formatState.listMarker == "–") { perform { MuseFormatOps.applyList($0, .dash) } }
            listRow("1.", name: "编号列表",
                    on: formatState.listMarker == "1.") { perform { MuseFormatOps.applyList($0, .ordered) } }

            Divider()

            // ── 清除格式：文字选项放在最后（不要符号）──
            clearRow
        }
        .padding(10)
        .frame(width: 196)
    }

    // MARK: 组件

    /// B/I/U/S 横排按钮：用 SF Symbols 标准文本格式符号（bold/italic/underline/strikethrough），
    /// 天然居中一致；选中 = 蓝底白字，未选中 = 浅灰底黑字。
    private func styleChip(_ symbol: String, on: Bool,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(on ? Color.white : Color.primary)
                .frame(width: 36, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(on ? Color.blue : Color.primary.opacity(0.07))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 清除格式：面板最后的文字选项。
    /// 前置 14pt ✓ 占位列（与 row() 相同）+ 画笔符号 → 画笔与上方「1.」「•」严格对齐。
    private var clearRow: some View {
        Button {
            perform(MuseFormatOps.clearFormatting)
        } label: {
            HStack(spacing: 6) {
                // 与 row() 相同的 14pt ✓ 占位列（透明）→ 画笔起点 = 列表符号列起点
                Color.clear.frame(width: 14)
                Image(systemName: "paintbrush")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 14)
                Text("清除格式")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    /// 竖列选项行：✓ 在文字前面（左侧），选中 ✓ 蓝色、文字也标蓝
    private func row(_ label: String, font: Font, on: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // ✓ 常驻占位（在文字前面）：未选中透明，保证所有行对齐
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.blue)
                    .opacity(on ? 1 : 0)
                    .frame(width: 14)
                Text(label)
                    .font(font)
                    .foregroundStyle(on ? Color.blue : Color.primary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func sizeRow(_ title: String, font: Font, on: Bool,
                         action: @escaping () -> Void) -> some View {
        row(title, font: font, on: on, action: action)
    }

    private func listRow(_ symbol: String, name: String,
                         on: Bool, action: @escaping () -> Void) -> some View {
        row("\(symbol)  \(name)", font: .system(size: 13), on: on, action: action)
    }
}

// MARK: - 列表行（标题 + 预览 + 时间；删除仅靠右键菜单触发）

struct MuseRow: View {
    let note: MuseNote
    @ObservedObject var app: AppState

    /// 选中/新建矩形卡片填充色：#F8F1D7（淡奶黄，参考 macOS 备忘录）
    private static let accentFill = Color(red: 0xEB / 255, green: 0xEB / 255, blue: 0xEB / 255)
    /// 未选中态卡片：#F8F8F9（极浅灰白，几乎纯白）
    private static let idleFill = Color(red: 0xF8 / 255, green: 0xF8 / 255, blue: 0xF9 / 255)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(note.displayTitle)
                    .font(T.f(13.5, .semibold))
                    .foregroundStyle(T.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(note.preview)
                .font(T.f(12))
                .foregroundStyle(T.muted)
                .lineLimit(1)
            HStack(spacing: 4) {
                Text(updatedText)
                    .font(T.f(11))
                    .foregroundStyle(T.muted.opacity(0.85))
                    .lineLimit(1)
                // 分组标签：仅在「全部随想」下显示，「小分组」类内嵌视图冗余不显示
                if app.museCurrentGroupId == nil, let gid = note.groupId,
                   let g = app.museGroups.first(where: { $0.id == gid }) {
                    Spacer(minLength: 0)
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 9))
                        Text(g.name)
                            .font(T.f(10.5))
                            .lineLimit(1)
                    }
                    .foregroundStyle(T.muted.opacity(0.85))
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // 圆角卡片：未选中 = 极浅灰，选中 = #EBEBEB（浅灰）
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Self.accentFill : Self.idleFill)
        )
        .contentShape(Rectangle())
        .focusEffectDisabled(true)
        .contextMenu {
            // 「移到分组」子菜单
            Menu("移到分组") {
                Button {
                    app.moveMuseToGroup(noteId: note.id, groupId: nil)
                } label: {
                    if note.groupId == nil {
                        Label("全部随想", systemImage: "checkmark")
                    } else {
                        Text("全部随想")
                    }
                }
                if !app.museGroups.isEmpty { Divider() }
                ForEach(app.museGroups) { g in
                    Button {
                        app.moveMuseToGroup(noteId: note.id, groupId: g.id)
                    } label: {
                        if note.groupId == g.id {
                            Label(g.name, systemImage: "checkmark")
                        } else {
                            Text(g.name)
                        }
                    }
                }
                if app.museGroups.isEmpty {
                    Text("还没有分组").font(.caption)
                }
            }
            Divider()
            Button(role: .destructive) { app.deleteMuse(note) } label: { Text("删除") }
        }
    }

    private var isSelected: Bool { app.museSelectedId == note.id }

    private var updatedText: String {
        guard let d = note.updatedDate else { return "" }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt.string(from: d)
    }
}

// MARK: - 分组下拉面板（Button(.plain) + popover 自绘，替代系统 Menu）
//
// 内容：全部随想 / 各分组（当前项打 ✓）/ 当前分组的重命名与删除。

struct MuseGroupPicker: View {
    @ObservedObject var app: AppState
    /// 选择完成后关闭 popover
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            pickerRow(name: "全部随想 (\(app.museGroupCount(nil)))",
                      icon: "tray.full",
                      selected: app.museCurrentGroupId == nil) {
                app.setMuseCurrentGroup(nil)
                onClose()
            }
            if !app.museGroups.isEmpty { Divider().padding(.vertical, 2) }
            ForEach(app.museGroups) { g in
                pickerRow(name: "\(g.name) (\(app.museGroupCount(g.id)))",
                          icon: app.museCurrentGroupId == g.id ? "folder.fill" : "folder",
                          selected: app.museCurrentGroupId == g.id) {
                    app.setMuseCurrentGroup(g.id)
                    onClose()
                }
            }
            // 当前分组：重命名 / 删除
            if let gid = app.museCurrentGroupId,
               let g = app.museGroups.first(where: { $0.id == gid }) {
                Divider().padding(.vertical, 2)
                actionRow(icon: "pencil", title: "重命名分组") {
                    app.museGroupDialog = .rename(id: g.id, name: g.name)
                    onClose()
                }
                actionRow(icon: "trash", title: "删除分组", destructive: true) {
                    app.deleteMuseGroup(gid)
                    onClose()
                }
            }
        }
        .padding(4)
        .background(
            // 系统毛玻璃材质（与 macOS 原生菜单 NSMenu 一致）+ 细边框 + 轻投影
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.gray.opacity(0.18), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 3)
        )
        .fixedSize()
    }

    private func pickerRow(name: String, icon: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 14)
                Text(name)
                    .font(T.f(13))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(T.muted)
                }
            }
            .foregroundStyle(T.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(selected ? Color.gray.opacity(0.14) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func actionRow(icon: String, title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(T.f(13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(destructive ? Color.red : T.text)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 分组编辑弹窗（新建 / 重命名）

struct MuseGroupDialogSheet: View {
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(dialogTitle)
                .font(.system(size: 15, weight: .semibold))
            Text(dialogSubtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("分组名字", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(action: commit) {
                    Text(isRename ? "保存" : "创建")
                        .frame(minWidth: 60)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            if case .rename(_, let n) = app.museGroupDialog {
                name = n
            }
        }
    }

    private var isRename: Bool {
        if case .rename = app.museGroupDialog { return true }
        return false
    }

    private var dialogTitle: String {
        isRename ? "重命名分组" : "新建分组"
    }

    private var dialogSubtitle: String {
        isRename ? "改一个更清楚的名字，方便在左侧辨认。" : "给你的随想建一个文件夹，比如「账号管理」「读书笔记」。"
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        switch app.museGroupDialog {
        case .create:
            app.createMuseGroup(name: trimmed)
        case .rename(let id, _):
            app.renameMuseGroup(id: id, newName: trimmed)
        case .none:
            break
        }
        dismiss()
    }
}

// MARK: - AI 总结结果面板
//
// 只展示 AI 生成的摘要，不写入正文；可复制到剪贴板。
// 关闭后面板消失，原文完全不受影响。

struct MuseAISummarySheet: View {
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    /// 当前笔记是否已插入 AI 总结（aiSummary 非空即算，与展开/隐藏状态无关）
    private var alreadyInserted: Bool {
        guard let note = app.currentMuseNote,
              let tip = note.aiSummary, !tip.isEmpty else { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI 总结")
                    .font(.system(size: 15, weight: .semibold))
                if !app.museAIModelLabel.isEmpty {
                    Text("由 \(app.museAIModelLabel) 生成")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                if app.museAILoading {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("正在生成总结…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(40)
                } else if let err = app.museAIError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 28))
                            .foregroundStyle(.orange)
                        Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .padding(40)
                } else {
                    Text(app.museAISummary.isEmpty ? "（无内容）" : app.museAISummary)
                        .font(.system(size: 13.5))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            HStack(spacing: 10) {
                Spacer()
                // 已有总结时提供「再次总结」：重新请求生成（不复用缓存）
                Button {
                    app.regenerateMuseSummary()
                } label: { Text("再次总结").frame(minWidth: 72) }
                    .disabled(app.museAILoading || app.museAISummary.isEmpty)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(app.museAISummary, forType: .string)
                } label: { Text("复制").frame(minWidth: 72) }
                    .disabled(app.museAISummary.isEmpty || app.museAILoading)
                // 插入 ↔ 隐藏 循环：已插入 → 隐藏（彻底移除）；未插入 → 插入
                Button {
                    if alreadyInserted {
                        app.removeMuseSummaryTip()   // 彻底移除 Tip
                    } else {
                        app.applyMuseSummaryInsert()  // 插入 Tip
                    }
                } label: { Text(alreadyInserted ? "隐藏" : "插入").frame(minWidth: 72) }
                    .disabled(app.museAISummary.isEmpty || app.museAILoading)
                    .help(alreadyInserted ? "隐藏（彻底移除）已插入的 AI 总结，之后可再次插入" : "插入到正文末尾")
                Button {
                    app.museAISheet = nil
                } label: { Text("完成").frame(minWidth: 72) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 520, height: 360)
    }
}

// MARK: - AI 润色预览面板
//
// 原则：原文 → AI 生成预览 → 用户确认 → 才替换原文。
// 「取消」关闭面板，原文不变；「使用润色结果」才回写编辑器。
// AI 调用失败或加载中均不修改原文。

struct MuseAIPolishSheet: View {
    @ObservedObject var app: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI 润色")
                    .font(.system(size: 15, weight: .semibold))
                if !app.museAIModelLabel.isEmpty {
                    Text("由 \(app.museAIModelLabel) 生成")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            if app.museAILoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在润色…").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if let err = app.museAIError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(err).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .padding(40)
            } else {
                HStack(spacing: 0) {
                    // 原文
                    VStack(alignment: .leading, spacing: 6) {
                        Text("原文").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                        ScrollView {
                            Text(app.musePolishOriginal)
                                .font(.system(size: 13))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.primary.opacity(0.03))

                    Divider()

                    // 润色结果
                    VStack(alignment: .leading, spacing: 6) {
                        Text("润色结果").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                        ScrollView {
                            Text(app.musePolishResult)
                                .font(.system(size: 13))
                                .lineSpacing(4)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Spacer()
                Button {
                    app.museAISheet = nil
                } label: { Text("取消") }
                    .keyboardShortcut(.cancelAction)
                Button {
                    app.applyMusePolish()
                } label: { Text("使用润色结果").frame(minWidth: 96) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(app.museAILoading || app.musePolishResult.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 640, height: 400)
    }
}

