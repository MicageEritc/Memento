import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AppKit

/// 图像处理 —— 对应 capture.js 里的 fitWidth / joinScreens / dHash / hamming / toJPEG
enum ImageUtil {

    /// 等比缩放到指定宽度（不放大）
    static func fitWidth(_ image: CGImage, _ width: Int) -> CGImage {
        let w = image.width
        guard w > 0, w > width, width > 0 else { return image }
        let h = max(1, Int((Double(image.height) * Double(width) / Double(w)).rounded()))
        return resize(image, width: width, height: h) ?? image
    }

    /// 等比 fit 进给定框内（不放大）
    static func fitBox(_ image: CGImage, maxW: Int, maxH: Int) -> CGImage {
        let w = Double(image.width), h = Double(image.height)
        guard w > 0, h > 0, maxW > 0, maxH > 0 else { return image }
        let s = min(Double(maxW) / w, Double(maxH) / h, 1.0)
        if s >= 1.0 { return image }
        let nw = max(1, Int((w * s).rounded()))
        let nh = max(1, Int((h * s).rounded()))
        return resize(image, width: nw, height: nh) ?? image
    }

    static func resize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: 8,
                                  bytesPerRow: 0,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    /// JPEG 编码
    static func jpeg(_ image: CGImage, quality: Int) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        let q = Double(clampVal(quality, 1, 100)) / 100.0
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationLossyCompressionQuality: q
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// 把多块屏横向拼成一张全景图（统一高度 512，最多 3 块），供模型一次分析
    static func joinScreens(_ images: [CGImage], maxWidth: Int) -> CGImage? {
        let list = Array(images.prefix(3))
        guard !list.isEmpty else { return nil }
        if list.count == 1 { return fitWidth(list[0], maxWidth) }

        let H = 512
        var pieces: [CGImage] = []
        for img in list {
            let w = img.width, h = img.height
            let nw = (w > 0 && h > 0) ? max(1, Int((Double(H) * Double(w) / Double(h)).rounded())) : H
            pieces.append(resize(img, width: nw, height: H) ?? img)
        }
        let totalW = pieces.reduce(0) { $0 + $1.width }
        guard totalW > 0 else { return list[0] }
        let scale = min(1.0, Double(maxWidth) / Double(totalW))
        let targetW = max(1, Int((Double(totalW) * scale).rounded()))
        let targetH = max(1, Int((Double(H) * scale).rounded()))

        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: targetW, height: targetH,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return list[0]
        }
        ctx.interpolationQuality = .high
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: targetW, height: targetH))
        var x = 0.0
        for p in pieces {
            let w = Double(p.width) * scale
            ctx.draw(p, in: CGRect(x: x, y: 0, width: w, height: Double(targetH)))
            x += w
        }
        return ctx.makeImage() ?? list[0]
    }

    /// 差异哈希：缩到 9x8 灰度，逐行比较相邻像素，得到 64bit 指纹（16 位 hex）
    static func dHash(_ image: CGImage) -> String {
        let W = 9, H = 8
        let cs = CGColorSpaceCreateDeviceRGB()
        let bytesPerRow = W * 4
        var buf = [UInt8](repeating: 0, count: bytesPerRow * H)
        let ok: Bool = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base, width: W, height: H,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: W, height: H))
            return true
        }
        guard ok else { return "" }

        var gray = [[Double]](repeating: [Double](repeating: 0, count: W), count: H)
        for y in 0..<H {
            for x in 0..<W {
                let i = y * bytesPerRow + x * 4
                let r = Double(buf[i]), g = Double(buf[i + 1]), b = Double(buf[i + 2])
                gray[y][x] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }
        var bits = ""
        bits.reserveCapacity(64)
        for y in 0..<H {
            for x in 0..<(W - 1) {
                bits.append(gray[y][x] > gray[y][x + 1] ? "1" : "0")
            }
        }
        var hex = ""
        hex.reserveCapacity(16)
        var idx = bits.startIndex
        while idx < bits.endIndex {
            let end = bits.index(idx, offsetBy: 4, limitedBy: bits.endIndex) ?? bits.endIndex
            var nibble = String(bits[idx..<end])
            while nibble.count < 4 { nibble.append("0") }
            let v = Int(nibble, radix: 2) ?? 0
            hex.append(String(v, radix: 16))
            idx = end
        }
        return hex
    }

    /// 裁剪中心区域（保留 keepW × keepH 比例，居中）。用于"内容是否变化"的语义检测，
    /// 排除菜单栏 / 程序坞 / 窗口边框等稳定装饰，让正文区的小幅改动更易被感知。
    static func cropCenter(_ image: CGImage, keepW: Double = 0.82, keepH: Double = 0.72) -> CGImage {
        guard image.width > 0, image.height > 0 else { return image }
        let cw = max(1, Int((Double(image.width) * keepW).rounded()))
        let ch = max(1, Int((Double(image.height) * keepH).rounded()))
        let x = max(0, (image.width - cw) / 2)
        let y = max(0, (image.height - ch) / 2)
        return image.cropping(to: CGRect(x: x, y: y, width: cw, height: ch)) ?? image
    }

    /// 汉明距离（两个 16 位 hex 串）
    static func hamming(_ a: String, _ b: String) -> Int {
        guard !a.isEmpty, !b.isEmpty, a.count == b.count else { return 64 }
        var d = 0
        for (ca, cb) in zip(a, b) {
            let x = (ca.hexDigitValue ?? 0) ^ (cb.hexDigitValue ?? 0)
            d += x.nonzeroBitCount
        }
        return d
    }

    /// 读文件为 CGImage
    static func load(path: String) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// 读文件为 NSImage（UI 展示用，带尺寸限制以省内存）
    static func loadThumbnail(path: String, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
