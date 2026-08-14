import SwiftUI
import AppKit

// MARK: - 「关于」页 —— 模块化布局：Hero 品牌卡 + 三个分组 Section 卡

struct AboutPanel: View {
    @ObservedObject var app: AppState

    var body: some View {
        // 统一规范：ScrollView Full-Bleed（自身零 padding），所有 padding 在内层 VStack 上，
        // 保证右侧滚动条轨道与全软件 6 页绝对一致（顶端/底端纹丝不动）。
        // 注：640 限宽下放到「每张卡片」上（而非外层 VStack），外层保持 maxWidth .infinity 铺满，
        // 这样滚动条贴窗口右边、卡片最大 640 靠左，两全其美。
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                heroCard
                aboutCard
                privacyCard
                authorCard
            }
            // 外层容器铺满 detail 列，滚动条贴窗口右边；卡片各自限宽 640。
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 40)
            .padding(.trailing, 40)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollIndicators(.automatic)
        .defaultScrollAnchor(.top)
        .navigationTitle("关于")
        // 锚点 toolbar：保证窗口 NSToolbar 始终存在，切到本页时标题栏/边栏不跳动
        .toolbar {
            // 全局搜索为独立内容状态：搜索时清空整个 toolbar（不继承当前页面原有 items）
            if !app.isSearching {
                ToolbarItem(placement: .primaryAction) { ToolbarAnchor() }
            }
        }
    }

    // MARK: Hero 品牌卡片

    private var heroCard: some View {
        HStack(spacing: 16) {
            appIcon
                .frame(width: 52, height: 52)
                .cornerRadius(10)

            VStack(alignment: .leading, spacing: 4) {
                Text("\(AppInfo.name) \(AppInfo.englishName)")
                    .font(.title2.bold())
                    .foregroundColor(.primary)

                Text(AppInfo.tagline)
                    .font(.body)
                    .foregroundColor(.secondary)

                Text("Version \(AppInfo.version) · Build 2026")
                    .font(.caption)
                    .foregroundColor(.secondary.opacity(0.8))
            }

            Spacer()
        }
        .padding(16)
        .frame(maxWidth: 640, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var appIcon: some View {
        let img = NSImage(named: NSImage.applicationIconName)
            ?? NSImage(named: "icon")
            ?? NSImage(size: NSSize(width: 64, height: 64))
        return Image(nsImage: img)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }

    // MARK: ABOUT（产品初衷）

    private var aboutCard: some View {
        sectionCard(title: "ABOUT") {
            Text("做这个小工具的初衷特别简单。每到年底写总结，总觉得这一年忙忙碌碌却记不清时间花在哪；平时还要硬憋日报周报。于是我想，要是有个工具默默在后台记录每天轨迹，既省去手动写日报，回顾时也有清楚的凭据，该多省心。")
                .font(.body)
                .foregroundColor(.primary)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)

            Text("它不只是打工辅助。我也希望它留住日常那些细小点滴——无意刷到的网页、折腾一晚的小爱好、看一半的纪录片。这些片段才是真实生活的底色，有了它，就像在数字世界给自己留了份随身日记。")
                .font(.body)
                .foregroundColor(.primary)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
                .padding(.top, 8)
        }
    }

    // MARK: PRIVACY（隐私承诺）

    private var privacyCard: some View {
        sectionCard(title: "PRIVACY") {
            Text("默认全程采用本地离线模型运行，所有图片与文本数据严格保存在本机，保障零隐私风险；同时支持按需接入在线 API 大模型，速度、性能与隐私皆可按需随心掌控。")
                .font(.body)
                .foregroundColor(.primary)
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .multilineTextAlignment(.leading)
        }
    }

    // MARK: AUTHOR（开发者信息）

    private var authorCard: some View {
        sectionCard(title: "AUTHOR") {
            HStack {
                Text("温水动物")
                    .font(.body)
                    .foregroundColor(.primary)

                Spacer()

                Button {
                    if let u = URL(string: "mailto:micage@foxmail.com") {
                        NSWorkspace.shared.open(u)
                    }
                } label: {
                    Text("micage@foxmail.com")
                        .font(.body)
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .onHover { NSCursor.pointingHand.set(); if !$0 { NSCursor.arrow.set() } }
            }
        }
    }

    // MARK: 分组卡片容器（与 Hero 一致的淡灰圆角底框 + 大写小标题）

    private func sectionCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.bold())
                .foregroundColor(.secondary)

            content()
        }
        .padding(16)
        .frame(maxWidth: 640, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}
