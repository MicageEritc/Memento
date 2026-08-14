import SwiftUI
import AppKit

/// 截图缩略图加载器 —— 对应 renderer.js 的 shotUrl + shotUrlCache（lens://shot 协议）
///
/// Swift 版不需要自定义协议：直接读磁盘文件，用 ImageIO 生成缩略图后进内存缓存。
/// 缓存上限 240 张（约 20~40MB），LRU 淘汰。
@MainActor
final class ThumbCache: ObservableObject {

    static let shared = ThumbCache()

    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private var loading: Set<String> = []
    private let limit = 240

    /// 已加载的缩略图（同步取，取不到返回 nil 并触发后台加载）
    func image(_ path: String?, maxPixel: Int) -> NSImage? {
        guard let path, !path.isEmpty else { return nil }
        let key = "\(maxPixel)|\(path)"
        if let img = cache[key] {
            touch(key)
            return img
        }
        load(path: path, key: key, maxPixel: maxPixel)
        return nil
    }

    /// 原图（灯箱用，不进缩略图缓存）
    nonisolated func fullImage(_ path: String) -> NSImage? {
        ThumbCache.loadFull(path)
    }

    /// 后台线程安全的原图加载（灯箱用）—— static，不触碰 @MainActor 的 shared 单例
    nonisolated static func loadFull(_ path: String) -> NSImage? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return NSImage(contentsOfFile: path)
    }

    func exists(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func load(path: String, key: String, maxPixel: Int) {
        guard !loading.contains(key) else { return }
        loading.insert(key)
        Task.detached(priority: .utility) {
            let img = ImageUtil.loadThumbnail(path: path, maxPixel: maxPixel)
            await MainActor.run {
                self.loading.remove(key)
                guard let img else { return }
                self.cache[key] = img
                self.order.append(key)
                self.trim()
                self.objectWillChange.send()
            }
        }
    }

    private func touch(_ key: String) {
        if let i = order.firstIndex(of: key) {
            order.remove(at: i)
            order.append(key)
        }
    }

    private func trim() {
        while order.count > limit {
            let k = order.removeFirst()
            cache.removeValue(forKey: k)
        }
    }

    /// 数据目录变更 / 记录删除后清缓存
    func clear() {
        cache.removeAll()
        order.removeAll()
        objectWillChange.send()
    }
}

/// 异步缩略图（对应 <img class="thumb" loading="lazy">）
struct Thumb: View {
    let path: String?
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat = 10
    var maskText: String = ""
    var onTap: (() -> Void)?

    @ObservedObject private var cache = ThumbCache.shared
    @State private var hovering = false

    var body: some View {
        let img = cache.image(path, maxPixel: Int(width * 2.4))
        ZStack {
            if let img {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: width, height: height)
                    .clipped()
                    .scaleEffect(hovering ? 1.03 : 1)
                    .animation(.easeOut(duration: 0.16), value: hovering)
            } else {
                Rectangle().fill(T.surface2)
                    .frame(width: width, height: height)
            }
            if hovering, !maskText.isEmpty {
                ZStack {
                    Color.black.opacity(0.45)
                    Text(maskText)
                        .font(T.f(12, .medium))
                        .foregroundStyle(.white)
                }
                .frame(width: width, height: height)
                .transition(.opacity)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { onTap?() }
    }
}

/// 缺图占位（对应 .thumb.ph）
struct ThumbPlaceholder: View {
    let symbol: String
    var width: CGFloat = 168
    var height: CGFloat = 100
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(T.surface2)
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(T.border, lineWidth: 1)
            Text(symbol).font(.system(size: 22)).foregroundStyle(T.muted)
        }
        .frame(width: width, height: height)
    }
}
