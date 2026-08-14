import SwiftUI
import AppKit

// MARK: - 灯箱（对应 renderer.js lightbox() + .lightbox）

struct Lightbox: View {
    let path: String
    var onClose: () -> Void

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black.opacity(0.82)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onClose() }

            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .shadow(color: .black.opacity(0.5), radius: 30, y: 20)
                } else {
                    ProgressView().controlSize(.large).tint(.white)
                }
            }
            .padding(40)
            .allowsHitTesting(false)

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Text("✕")
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 24)
                    .padding(.trailing, 28)
                }
                Spacer()
            }
        }
        .task(id: path) {
            image = nil
            let p = path
            let img = await Task.detached(priority: .userInitiated) {
                ThumbCache.loadFull(p)
            }.value
            image = img
        }
    }
}

// MARK: - Finder 式次级 Scope 筛选栏
/// 搜索激活（searchQuery 非空）时，在内容区顶部紧贴 toolbar 下方平滑展开。
/// 形如「搜索： [全部] [瞬息] [一念]  12 条结果」。

struct SearchScopeBar: View {
    @ObservedObject var app: AppState

    var body: some View {
        HStack(spacing: 12) {
            Text("搜索：")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                ScopeChip(title: "全部", isSelected: app.searchFilter == "") {
                    app.searchFilter = ""
                    app.runSearch()
                }
                ScopeChip(title: "瞬息", isSelected: app.searchFilter == "memento") {
                    app.searchFilter = "memento"
                    app.runSearch()
                }
                ScopeChip(title: "一念", isSelected: app.searchFilter == "yinian") {
                    app.searchFilter = "yinian"
                    app.runSearch()
                }
                ScopeChip(title: "随想", isSelected: app.searchFilter == "muse") {
                    app.searchFilter = "muse"
                    app.runSearch()
                }
            }

            Spacer(minLength: 0)

            if app.searchHasRun {
                Text("\(app.searchResults.count) 条结果")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 单个 Scope 切块按钮（Finder 同款圆角胶囊）
private struct ScopeChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.75))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.accentColor : Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 搜索结果列表（嵌入 detail 区，紧贴 ScopeBar 下方）
/// 仅保留结果列表主体；Scope 切换与「搜索：」标签已由 SearchScopeBar 承担，
/// 因此这里不再画头部、不再用模糊背景，直接铺满剩余空间。

struct SearchResultsView: View {
    @ObservedObject var app: AppState

    var body: some View {
        results
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .onExitCommand {
                app.searchQuery = ""
                app.runSearch()
            }
    }

    @ViewBuilder
    private var results: some View {
        let q = app.searchQuery.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            srEmpty("输入关键词搜索全部记录", icon: "magnifyingglass")
        } else if app.searchBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("搜索中…").font(T.f(12)).foregroundStyle(T.muted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if app.searchResults.isEmpty && app.searchHasRun {
            srEmpty("没有找到相关内容", sub: "尝试搜索其他关键词", icon: "tray")
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 1) {
                    let grouped = Dictionary(grouping: app.searchResults, by: { $0.kind })
                    // 分段顺序：随想 → 瞬息 → 一念（与需求示例一致）
                    let order: [SearchHit.Kind] = [.muse, .memento, .yinian]
                    ForEach(order, id: \.self) { k in
                        if let items = grouped[k], !items.isEmpty {
                            SearchSectionHeader(title: k.title, count: items.count)
                            ForEach(items) { hit in
                                SearchHitRow(hit: hit) {
                                    app.jumpToHit(hit)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func srEmpty(_ text: String, sub: String? = nil, icon: String = "tray") -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(T.muted.opacity(0.6))
            Text(text)
                .font(T.f(12))
                .foregroundStyle(T.muted)
            if let sub {
                Text(sub)
                    .font(T.f(11))
                    .foregroundStyle(T.muted.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - 搜索结果分段标题（随想 / 瞬息 / 一念 分区）

private struct SearchSectionHeader: View {
    let title: String
    let count: Int
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(T.f(11, .semibold))
                .foregroundStyle(T.muted)
            Text("\(count)")
                .font(T.f(10, .semibold))
                .foregroundStyle(T.muted.opacity(0.7))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(T.surface2))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 3)
    }
}

// MARK: - 搜索结果行（瞬息 / 一念 / 随想 统一）
// 瞬息/一念：缩略图 + 标题(高亮) + 日期/时间/分类；随想：图标 + 标题(高亮) + 分组 + 命中片段(高亮)

struct SearchHitRow: View {
    let hit: SearchHit
    var onTap: () -> Void
    @State private var hovering = false

    private var isMuse: Bool { hit.kind == .muse }
    private var isYinian: Bool { hit.kind == .yinian }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // 左侧图标区
                if isMuse {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(T.surface2)
                        .frame(width: 52, height: 32)
                        .overlay(
                            Image(systemName: "note.text")
                                .font(.system(size: 13))
                                .foregroundStyle(T.muted)
                        )
                } else if let abs = hit.record?.screenshotAbs, ThumbCache.shared.exists(abs) {
                    Thumb(path: abs, width: 52, height: 32, radius: 5)
                } else {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(T.surface2)
                        .frame(width: 52, height: 32)
                        .overlay(
                            Image(systemName: hit.record?.statusEnum == .idle ? "moon.zzz" : "clock")
                                .font(.system(size: 11))
                                .foregroundStyle(T.muted)
                        )
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        highlighted(hit.title, terms: hit.terms)
                            .font(T.f(13, .semibold))
                            .foregroundStyle(T.text)
                            .lineLimit(1)
                        if isMuse {
                            if let g = hit.groupLabel, !g.isEmpty {
                                Text(g)
                                    .font(T.f(10, .semibold))
                                    .foregroundStyle(T.goldText)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(T.goldChipA))
                                    .overlay(Capsule().strokeBorder(T.gold, lineWidth: 1))
                            }
                        } else if isYinian {
                            Text("⭐ 一念")
                                .font(T.f(10, .semibold))
                                .foregroundStyle(T.goldText)
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(T.goldChipA))
                                .overlay(Capsule().strokeBorder(T.gold, lineWidth: 1))
                        }
                    }
                    HStack(spacing: 5) {
                        if !hit.dateLabel.isEmpty {
                            Text(hit.dateLabel).font(T.f(10.5)).monospacedDigit().foregroundStyle(T.muted)
                        }
                        if let t = hit.timeLabel, !t.isEmpty {
                            Text(t).font(T.f(10.5)).monospacedDigit().foregroundStyle(T.muted)
                        }
                        if let c = hit.categoryLabel, !c.isEmpty, c != "未知" {
                            let s = CatStyle.chip(c)
                            Text(c)
                                .font(T.f(10, .semibold))
                                .foregroundStyle(s.fg)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(s.bg))
                                .overlay(Capsule().strokeBorder(s.bd, lineWidth: 1))
                        }
                    }
                    // 正文片段（所有类型统一显示，关键词高亮）
                    if !hit.snippet.isEmpty {
                        highlighted(hit.snippet, terms: hit.terms)
                            .font(T.f(11))
                            .foregroundStyle(T.muted)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? T.surface2 : Color.clear)
                    .allowsHitTesting(false)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - 关键词高亮（不修改原始数据，仅在结果 UI 着色命中片段）

/// 把 source 中命中 terms（大小写不敏感）的部分用 accent 色加粗着色，其余原样。
func highlighted(_ source: String, terms: [String]) -> Text {
    guard !terms.isEmpty, !source.isEmpty else { return Text(source) }
    let lower = source.lowercased()
    var ranges: [Range<String.Index>] = []
    for t in terms where !t.isEmpty {
        var from = lower.startIndex
        while let r = lower.range(of: t, range: from..<lower.endIndex) {
            ranges.append(r)
            if r.upperBound == lower.endIndex { break }
            from = r.upperBound
        }
    }
    guard !ranges.isEmpty else { return Text(source) }
    // 排序并合并重叠区间
    let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
    var merged: [Range<String.Index>] = []
    for r in sorted {
        if let last = merged.last, last.upperBound >= r.lowerBound {
            merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
        } else {
            merged.append(r)
        }
    }
    var result = Text("")
    var cursor = source.startIndex
    for r in merged {
        if cursor < r.lowerBound {
            result = result + Text(String(source[cursor..<r.lowerBound]))
        }
        result = result + Text(String(source[r]))
            .foregroundStyle(Color.accentColor)
            .fontWeight(.semibold)
        cursor = r.upperBound
    }
    if cursor < source.endIndex {
        result = result + Text(String(source[cursor..<source.endIndex]))
    }
    return result
}

// MARK: - 弹窗容器（用于关于等仍需独立容器的内容）

struct ModalShell<Content: View>: View {
    var width: CGFloat = 480
    var padding: EdgeInsets = EdgeInsets(top: 30, leading: 32, bottom: 24, trailing: 32)
    var onClose: (() -> Void)?
    @ViewBuilder var content: Content

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) { content }
                    .padding(padding)
                    .frame(width: width, alignment: .leading)
            }
            .frame(width: width)
            .frame(maxHeight: 720)
            .fixedSize(horizontal: false, vertical: true)

            if let onClose {
                ModalCloseButton(action: onClose)
                    .padding(.top, 14)
                    .padding(.trailing, 14)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
                .background(
                    VisualEffectBackground(material: .popover, blending: .withinWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(T.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 32, y: 24)
    }
}

struct ModalCloseButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text("✕")
                .font(.system(size: 14))
                .foregroundStyle(T.text)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(hovering ? T.surfaceHover : T.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(T.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
