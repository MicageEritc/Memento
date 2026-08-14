import SwiftUI
import AppKit

// MARK: - 日期切换（macOS Toolbar 风格：今天 + ◀ ▶ + 自定义日历 Popover）

struct DateSwitcher: View {
    @ObservedObject var app: AppState
    @Binding var date: String

    var body: some View {
        HStack(spacing: 4) {
            Button {
                shift(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(MuseCircleButtonStyle())
            .help("前一天")

            DatePickerButton(date: $date)

            Button {
                shift(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(MuseCircleButtonStyle())
            .help("后一天")
        }
    }

    private func shift(_ n: Int) {
        if let d = DateUtil.parseDateStr(date) {
            date = DateUtil.ymd(DateUtil.addDays(d, n))
        }
    }
}

// MARK: - 日期按钮（点击弹自定义日历 Popover，无大 stepper 箭头、无紫框）

struct DatePickerButton: View {
    @Binding var date: String
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Text(prettyDate(date))
                .font(T.f(12.5))
                .monospacedDigit()
        }
        .buttonStyle(ToolbarCapsuleStyle())
        .help("选择日期")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            CalendarPopover(date: $date) { showing = false }
        }
    }

    private func prettyDate(_ ds: String) -> String {
        guard let d = DateUtil.parseDateStr(ds) else { return ds }
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy年M月d日"
        fmt.locale = Locale(identifier: "zh_CN")
        return fmt.string(from: d)
    }
}

// MARK: - 自定义日历 Popover
// 不依赖 SwiftUI DatePicker，避免系统 accent 紫色高亮框；
// 年/月 用 Menu 快速切换，日 用 7×6 Grid，选中态用蓝色（不是 accent 紫）。

struct CalendarPopover: View {
    @Binding var date: String
    var onClose: () -> Void

    @State private var displayMonth: Date

    init(date: Binding<String>, onClose: @escaping () -> Void) {
        self._date = date
        self.onClose = onClose
        let first = DateUtil.parseDateStr(date.wrappedValue) ?? Date()
        self._displayMonth = State(initialValue: first)
    }

    private var cal: Calendar { DateUtil.calendar }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            weekdayHeader
            grid
        }
        .padding(14)
        .frame(width: 280)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Menu {
                ForEach(yearRange, id: \.self) { y in
                    Button {
                        if let d = cal.date(from: DateComponents(year: y, month: cal.component(.month, from: displayMonth), day: 1)) {
                            displayMonth = d
                        }
                    } label: {
                        Text(String(y) + " 年")
                    }
                }
            } label: {
                Text(String(yearNum) + " 年")
                    .font(T.f(13, .semibold))
                    .foregroundStyle(T.text)
                    .frame(minWidth: 64, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                ForEach(1...12, id: \.self) { m in
                    Button {
                        if let d = cal.date(from: DateComponents(year: yearNum, month: m, day: 1)) {
                            displayMonth = d
                        }
                    } label: {
                        Text(String(m) + " 月")
                    }
                }
            } label: {
                Text(String(monthNum) + " 月")
                    .font(T.f(13, .semibold))
                    .foregroundStyle(T.text)
                    .frame(minWidth: 44, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer(minLength: 4)

            Button("今天") {
                let t = cal.startOfDay(for: Date())
                displayMonth = t
                date = DateUtil.ymd(t)
            }
            .font(T.f(11))
            .buttonStyle(.bordered)
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            ForEach(["日","一","二","三","四","五","六"], id: \.self) { d in
                Text(d)
                    .font(T.f(10))
                    .foregroundStyle(T.muted)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var grid: some View {
        let days = buildDays()
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
            spacing: 2
        ) {
            ForEach(days) { item in
                dayCell(item)
            }
        }
    }

    private func dayCell(_ item: DayItem) -> some View {
        Button {
            if item.inMonth {
                date = DateUtil.ymd(item.date)
                onClose()
            }
        } label: {
            ZStack {
                if item.isSelected {
                    Circle().fill(T.accent)
                } else if item.isToday {
                    Circle().strokeBorder(T.accent, lineWidth: 1)
                }
                Text("\(item.day)")
                    .font(T.f(item.isToday ? 12.5 : 12,
                              item.isSelected ? .semibold : .regular))
                    .foregroundStyle(item.isSelected ? .white
                                     : (item.inMonth ? T.text : T.muted.opacity(0.35)))
            }
            .frame(width: 30, height: 26)
        }
        .buttonStyle(.plain)
        .disabled(!item.inMonth)
    }

    private struct DayItem: Identifiable {
        var id: Date { date }
        var date: Date
        var day: Int
        var inMonth: Bool
        var isToday: Bool
        var isSelected: Bool
    }

    private func buildDays() -> [DayItem] {
        let selected = cal.startOfDay(for: DateUtil.parseDateStr(date) ?? Date())
        let today = cal.startOfDay(for: Date())
        guard let firstOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: displayMonth)),
              let range = cal.range(of: .day, in: .month, for: displayMonth) else { return [] }
        let firstWeekday = cal.component(.weekday, from: firstOfMonth) // 1=Sun
        let leading = firstWeekday - 1
        let total = range.count

        var items: [DayItem] = []

        // 上月补
        if leading > 0,
           let prev = cal.date(byAdding: .month, value: -1, to: firstOfMonth),
           let prevRange = cal.range(of: .day, in: .month, for: prev) {
            for i in (prevRange.count - leading)..<prevRange.count {
                let d = cal.date(byAdding: .day, value: i, to: prev)!
                items.append(DayItem(date: d, day: i + 1, inMonth: false,
                                     isToday: cal.startOfDay(for: d) == today,
                                     isSelected: false))
            }
        }

        // 当月
        for i in 0..<total {
            let d = cal.date(byAdding: .day, value: i, to: firstOfMonth)!
            let dStart = cal.startOfDay(for: d)
            items.append(DayItem(date: d, day: i + 1, inMonth: true,
                                 isToday: dStart == today,
                                 isSelected: dStart == selected))
        }

        // 下月补到 42 格（6×7）
        let trailing = (42 - items.count) % 42
        if trailing > 0,
           let next = cal.date(byAdding: .month, value: 1, to: firstOfMonth) {
            for i in 0..<trailing {
                let d = cal.date(byAdding: .day, value: i, to: next)!
                items.append(DayItem(date: d, day: i + 1, inMonth: false,
                                     isToday: cal.startOfDay(for: d) == today,
                                     isSelected: false))
            }
        }

        return items
    }

    private var yearNum: Int { cal.component(.year, from: displayMonth) }
    private var monthNum: Int { cal.component(.month, from: displayMonth) }
    private var yearStr: String { String(yearNum) }
    private var monthStr: String { String(monthNum) }

    private var yearRange: [Int] {
        // 顶部日历可选年份：2000 起一直滚到 2099（用户可任意回溯和未来）
        return Array((2000...2099).reversed())
    }
}

// MARK: - 记录开关（开启/暂停瞬息）—— toolbar 主操作

struct RecordToggle: View {
    @ObservedObject var app: AppState

    var body: some View {
        Button {
            app.toggleRecording()
        } label: {
            // 自绘同心圆（Canvas 一次性画内外两圆，几何严格共心）：
            // 运行中 = 外圈红 + 中心实心红点；暂停态 = 仅外圈。
            // 与左侧日期按钮共用同一圆形样式，水平基线一致。
            // ◉ 样式：外圈 + 常驻中心实心点（同色同圆心），不再只画单圈
            Canvas { ctx, size in
                let side = min(size.width, size.height)
                let c = app.running ? Color(nsColor: .systemRed) : Color.primary
                let outer = Path(ellipseIn: CGRect(
                    x: (size.width - side) / 2 + 0.9, y: (size.height - side) / 2 + 0.9,
                    width: side - 1.8, height: side - 1.8))
                ctx.stroke(outer, with: .color(c), lineWidth: 1.6)
                let inner = Path(ellipseIn: CGRect(
                    x: (size.width - 9) / 2, y: (size.height - 9) / 2,
                    width: 9, height: 9))
                ctx.fill(inner, with: .color(c))
            }
            // 图标加大到 20pt：白圈/灰圈占比变小，视觉不显空
            .frame(width: 20, height: 20)
        }
        .help(app.running ? "暂停自动记录" : "开始自动记录")
        .buttonStyle(MuseCircleButtonStyle(fill: true))
    }
}

// MARK: - Toolbar 锚点（完全不可见的占位）
// 保证窗口 NSToolbar 永不空：搜索弹层隐藏 items 后标题栏不塌陷（三键不动）。
// 用 0×0 Color.clear + opacity 0 + accessibilityHidden，**不会**渲染成 1px 线（27 轮 Color.clear 1×1 在 toolbar 里渲染成线）。

struct ToolbarAnchor: View {
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

// MARK: - 工具栏胶囊按钮样式
/// 不用系统 `.bordered`：AppKit 会把 bordered 按钮背景画成独立 NSView 层，
/// 导致 `.opacity(0)` 淡不掉背景 → 标题栏残留“幽灵胶囊框”。
/// 这里用 SwiftUI 自绘胶囊背景，常态无背景（仅 hover 极轻高亮），
/// 多个并排控件呈原生独立按钮，不再连成一片“灰色大外壳”。

struct ToolbarCapsuleStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    Color.primary.opacity(hovering ? 0.12 : 0)
                )
            )
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

// MARK: - 顶部嵌入式搜索已迁移至 CollapsibleSearchBar（瞬息/一念专用，Finder 折叠式）