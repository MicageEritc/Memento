import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 富文本编辑器（SwiftUI + NSTextView + NSAttributedString）
//
// 能力：普通文本 / 加粗 / 斜体 / 下划线 / 标题 / 列表 / 引用；插入图片与文件附件。
// 存储配合：正文序列化为 RTF（content.rtfd 内是 RTF 数据，无任何 Base64 内嵌），
//           附件（图片/文件）存到 notes/{id}/attachments/ 独立文件，
//           正文里用「附件占位符 U+FFFC」标记位置，读取时按顺序重建 NSTextAttachment。

/// 附件占位符：正文 RTF 中附件出现的位置统一替换为该字符，
/// 与 note.attachments 数组按下标一一对应（不内嵌任何二进制）。
///
/// ⚠️ 必须用「私有区字符」(Private Use Area) 而非 U+FFFC：
/// U+FFFC 是 Unicode 的「对象替换字符」，AppKit 的 RTF 写入器会把它当成附件占位、
/// 在纯 RTF 序列化时直接丢弃 —— 导致重载时 marker 消失、图片无法重建
/// （即"编辑中显示、离开再返回图片消失"的根因）。私有区字符 (如 U+E001) 作为普通
/// 文本被 RTF 完整保留，重载后可正常扫描还原。U+FFFC 仍专用于编辑态清单圈字符。
let museAttachmentMarker = "\u{FFFC}"

/// 图片 / 文件附件在落盘 RTF 中的占位字符（私有区，RTF 往返不丢）。
/// 与 U+E000（分割线）、U+FFFC（清单圈）互不冲突。
let museImgMarker = "\u{E001}"

// MARK: - 核对清单标记（正文内可点击的圆圈）
//
// 未勾 = 空心圆；已勾 = 圆圈内包蓝色对勾。
// 点击正文里的圈切换勾/未勾（Coordinator.textView(clickedOn:)）。
// 工具栏「制作核对清单」按钮只负责创建/取消清单，不负责打勾。
// 落盘时序列化为纯文本 ☐/☑（兼容搜索与旧版），加载后自动转回可点击附件。

final class MuseCheckAttachment: NSTextAttachment {
    var checked: Bool
    /// 创建圈时使用的字号（供行盒同步比对）
    let size: CGFloat

    init(checked: Bool, font: NSFont? = nil) {
        self.checked = checked
        self.size = (font ?? NSFont.systemFont(ofSize: 14.5)).pointSize
        super.init(data: nil, ofType: nil)
        let f = font ?? NSFont.systemFont(ofSize: 14.5)
        self.image = Self.image(checked: checked, font: f)
        // —— 彻底对齐方案 ——
        // bounds 完全等于正文字体的行盒：height = ascender - descender、y = descender。
        // 这样「圈单独成行」与「圈+文字同行」两种情况的基线几何完全一致，
        // 不会再出现"输入文字圈上移、删除又恢复"的跳动。
        // 圆圈本身画在图片内垂直居中，视觉中线 = 行盒中线 ≈ 文字视觉中线。
        self.bounds = NSRect(x: 0, y: f.descender,
                             width: 20, height: f.ascender - f.descender)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    /// 手绘（对齐 Mac 备忘录观感）：
    /// 未勾 = 空心圆；已勾 = 蓝色实心圆 + 白色（空心感）对勾。
    /// 图片尺寸 = 正文字体行盒（宽 19 = 圈 15 + 右侧 4pt 间距），
    /// 圆在图片内垂直居中。flipped=false（AppKit 默认，原点左下、y 向上）。
    static func image(checked: Bool, font: NSFont) -> NSImage {
        let d: CGFloat = 15                       // 圆直径
        let w: CGFloat = 20                       // 圈 15 + 左留白 1 + 右侧间距 4
        let h = font.ascender - font.descender    // 与正文行高一致
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            // 圆左侧留 1pt，描边不出界、不被裁；垂直居中于整张图（即整行行盒）
            let box = NSRect(x: 1, y: (h - d) / 2, width: d, height: d)
            if checked {
                let disc = NSBezierPath(ovalIn: box.insetBy(dx: 0.5, dy: 0.5))
                NSColor.systemBlue.setFill()
                disc.fill()
                let check = NSBezierPath()
                check.move(to: CGPoint(x: box.minX + d * 0.28, y: box.minY + d * 0.52))
                check.line(to: CGPoint(x: box.minX + d * 0.44, y: box.minY + d * 0.35))
                check.line(to: CGPoint(x: box.minX + d * 0.74, y: box.minY + d * 0.68))
                NSColor.white.setStroke()
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                check.stroke()
            } else {
                let circle = NSBezierPath(ovalIn: box.insetBy(dx: 1.0, dy: 1.0))
                NSColor.secondaryLabelColor.setStroke()
                circle.lineWidth = 1.5
                circle.stroke()
            }
            return true
        }
    }
}

// MARK: - 文件附件 chip（图标 + 文件名，纯绘制，不触发系统打开）
//
// PDF 等文件不再用 NSTextAttachment(fileWrapper) 显示（会被系统当文件打开/预览），
// 改为自绘圆角 chip：📎 图标 + 文件名。数据随附件落盘，加载时按 meta 重建。

final class MuseFileChipAttachment: NSTextAttachment {
    let fileName: String
    var fileData: Data

    init(fileName: String, data: Data) {
        self.fileName = fileName
        self.fileData = data
        super.init(data: nil, ofType: nil)
        let img = Self.chipImage(name: fileName)
        self.image = img
        // chip 高度 22pt，基线对齐正文
        self.bounds = NSRect(x: 0, y: -4, width: img.size.width, height: 22)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    /// 绘制：浅灰圆角底 + doc 图标 + 文件名（完整展示，含后缀，绝不省略号截断）
    static func chipImage(name: String) -> NSImage {
        let displayName = name
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let textW = (displayName as NSString).size(withAttributes: [.font: font]).width
        let w = ceil(8 + 14 + 5 + textW + 10)
        let h: CGFloat = 22
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            let bg = NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2)
            NSColor.gray.withAlphaComponent(0.16).setFill()
            bg.fill()
            // doc 图标（flipped=false，y 向上）
            let iconRect = NSRect(x: 8, y: (h - 13) / 2, width: 11, height: 13)
            let page = NSBezierPath(roundedRect: iconRect, xRadius: 2, yRadius: 2)
            NSColor.secondaryLabelColor.setStroke()
            page.lineWidth = 1.2
            page.stroke()
            // 文件名
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.labelColor,
            ]
            let str = displayName as NSString
            str.draw(at: NSPoint(x: 8 + 14 + 5, y: (h - str.size(withAttributes: attrs).height) / 2),
                     withAttributes: attrs)
            return true
        }
    }
}

// MARK: - 分割线（正文里的水平分隔）
//
// 编辑态是一段只占一行的附件：MuseDividerCell 把线画满整行宽度。
// 落盘：rtfData 把它序列化为私有区标记字符 museDividerMarker（非 U+FFFC），
// 因此不会污染 attachments/（图片/文件用 U+FFFC），加载时 rebuildAttachments 再还原回附件。

let museDividerMarker = "\u{E000}"

final class MuseDividerAttachment: NSTextAttachment {
    /// 用一张 2pt 高的深色横线图作为附件内容；布局时由 attachmentBounds 把它拉满整行宽度。
    override var image: NSImage? {
        get { Self.lineImage }
        set { }
    }
    override var bounds: NSRect {
        get { NSRect(x: 0, y: 0, width: 10, height: 14) }
        set { }
    }

    /// 让分割线占满当前行的内容宽度（而非固定 10pt）。
    override func attachmentBounds(for textContainer: NSTextContainer?,
                                    proposedLineFragment lineFrag: NSRect,
                                    glyphPosition: CGPoint,
                                    characterIndex charIndex: Int) -> NSRect {
        return NSRect(x: 0, y: 0, width: lineFrag.width, height: 14)
    }

    private static let lineImage: NSImage = {
        // 真正的分割线：2pt 实线 + 深色（比 1pt separatorColor 清晰得多），
        // 视觉等同「────────」。
        let img = NSImage(size: NSSize(width: 10, height: 14))
        img.lockFocus()
        NSColor.secondaryLabelColor.setFill()
        NSRect(x: 0, y: 6, width: 10, height: 2).fill()
        img.unlockFocus()
        return img
    }()
}

// MARK: 富文本 + 附件 序列化工具

enum MuseRichText {

    /// 从纯文本生成 RTF Data
    static func makePlainRTF(_ text: String) -> Data {
        let att = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14.5),
            .foregroundColor: NSColor.textColor,
        ])
        return rtfData(att)
    }

    /// RTF Data → NSAttributedString
    static func attributed(fromRTF data: Data) -> NSAttributedString? {
        try? NSAttributedString(data: data,
                                options: [.documentType: NSAttributedString.DocumentType.rtf],
                                documentAttributes: nil)
    }

    /// 正文统一行距（对齐 Mac 备忘录的疏朗观感）
    static let bodyLineSpacing: CGFloat = 5

    /// 正文默认属性：14.5pt 系统字体 + 统一行距。
    /// 用户不主动调大小时，全文强制同一字号（标题/小标题除外）。
    static func defaultBodyAttrs() -> [NSAttributedString.Key: Any] {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing = bodyLineSpacing
        return [.font: NSFont.systemFont(ofSize: 14.5),
                .foregroundColor: NSColor.textColor,
                .paragraphStyle: ps]
    }

    /// 加载内容进编辑器前的归一化：
    /// - 行距全部统一为 bodyLineSpacing；
    /// - 非标题字号（<17pt）全部归一到 14.5pt（保留粗/斜 trait），
    ///   解决历史数据"一会大一会小、清单文字偏小"的问题。
    /// - 剥离旧版「AI 总结灰框」：AI 总结已改为独立 Tip，正文不应含背景色文本
    ///   （正文其它内容从不带背景色，带背景色的 run 视为旧灰框残留，直接删除）。
    static func normalize(_ att: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: att)
        let full = NSRange(location: 0, length: m.length)
        guard full.length > 0 else { return m }
        // 剥离旧灰框（AI 总结遗留正文）：删除所有带背景色的 run
        var staleRanges: [NSRange] = []
        m.enumerateAttribute(.backgroundColor, in: full, options: []) { v, r, _ in
            if v != nil { staleRanges.append(r) }
        }
        for r in staleRanges.reversed() {
            m.deleteCharacters(in: r)
        }
        // 删除后重新取范围（长度可能变化）
        let full2 = NSRange(location: 0, length: m.length)
        guard full2.length > 0 else { return m }
        m.enumerateAttribute(.paragraphStyle, in: full2) { v, r, _ in
            let src = (v as? NSParagraphStyle) ?? .default
            guard src.lineSpacing != bodyLineSpacing else { return }
            let ps = src.mutableCopy() as! NSMutableParagraphStyle
            ps.lineSpacing = bodyLineSpacing
            m.addAttribute(.paragraphStyle, value: ps, range: r)
        }
        m.enumerateAttribute(.font, in: full2) { v, r, _ in
            guard let f = v as? NSFont, f.pointSize < 17, f.pointSize != 14.5 else { return }
            let nf = NSFont(descriptor: f.fontDescriptor, size: 14.5)
                ?? NSFont.systemFont(ofSize: 14.5)
            m.addAttribute(.font, value: nf, range: r)
        }
        return m
    }

    /// 编辑器内全文强制统一（编辑中实时调用）：
    /// 非标题字号（<17pt）→ 14.5pt 且保留粗/斜 trait；行距全部 → 5pt。
    /// ⚠️ 必须禁用 undo 注册：这些属性规范化是「维护性修改」，若进入撤销栈，
    /// cmd+z 会先撤销一次看不见的属性变化（表现=撤销失灵）。
    static func enforceBodyStyle(_ tv: NSTextView) {
        guard let s = tv.textStorage, s.length > 0 else { return }
        let full = NSRange(location: 0, length: s.length)
        // 先收集需要修改的范围（只读扫描），只有真正需要改时才触发布局重算。
        // 之前无条件 beginEditing/endEditing 会在每次输入时强制重算布局，
        // 导致基线微移、核对清单圈跟着偏移。
        var fontFixes: [(NSFont, NSRange)] = []
        var paraFixes: [(NSParagraphStyle, NSRange)] = []
        // 清单圈行盒同步：圈创建时字号 ≠ 当前位置实际字号 → 用当前字号重建圈，
        // 保证圈与文字永远同一行盒（消除"输入文字圈下移/删除恢复"的跳动）
        var circleFixes: [(NSRange, MuseCheckAttachment, NSFont)] = []
        s.enumerateAttribute(.font, in: full) { v, r, _ in
            guard let f = v as? NSFont, f.pointSize < 17, f.pointSize != 14.5 else { return }
            let nf = NSFont(descriptor: f.fontDescriptor, size: 14.5)
                ?? NSFont.systemFont(ofSize: 14.5)
            fontFixes.append((nf, r))
        }
        s.enumerateAttribute(.attachment, in: full) { v, r, _ in
            guard let att = v as? MuseCheckAttachment, r.length == 1 else { return }
            let f = s.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
            var effSize = f?.pointSize ?? 14.5
            if effSize < 17, effSize != 14.5 { effSize = 14.5 }
            guard abs(att.size - effSize) > 0.01 else { return }
            let nf = f.flatMap { NSFont(descriptor: $0.fontDescriptor, size: effSize) }
                ?? NSFont.systemFont(ofSize: effSize)
            circleFixes.append((r, att, nf))
        }
        s.enumerateAttribute(.paragraphStyle, in: full) { v, r, _ in
            let src = (v as? NSParagraphStyle) ?? .default
            guard src.lineSpacing != bodyLineSpacing else { return }
            let ps = src.mutableCopy() as! NSMutableParagraphStyle
            ps.lineSpacing = bodyLineSpacing
            paraFixes.append((ps, r))
        }
        // 有修改才进入编辑会话（触发布局重算）；无修改则静默跳过
        if !fontFixes.isEmpty || !paraFixes.isEmpty || !circleFixes.isEmpty {
            let um = tv.undoManager
            let undoWasEnabled = um?.isUndoRegistrationEnabled ?? false
            if undoWasEnabled { um?.disableUndoRegistration() }
            s.beginEditing()
            for (f, r) in fontFixes { s.addAttribute(.font, value: f, range: r) }
            for (ps, r) in paraFixes { s.addAttribute(.paragraphStyle, value: ps, range: r) }
            for (r, att, nf) in circleFixes {
                var a: [NSAttributedString.Key: Any] = [
                    .font: nf,
                    .attachment: MuseCheckAttachment(checked: att.checked, font: nf)
                ]
                if let ps = s.attribute(.paragraphStyle, at: r.location,
                                        effectiveRange: nil) as? NSParagraphStyle {
                    a[.paragraphStyle] = ps
                }
                s.replaceCharacters(in: r, with: NSAttributedString(string: "\u{FFFC}", attributes: a))
            }
            s.endEditing()
            if undoWasEnabled { um?.enableUndoRegistration() }
        }
        // typingAttributes 也同步，防止下一输入回到小字号
        var t = tv.typingAttributes
        let tf = (t[.font] as? NSFont)?.pointSize ?? 0
        if tf != 0, tf < 17, tf != 14.5 {
            t[.font] = NSFont.systemFont(ofSize: 14.5)
            tv.typingAttributes = t
        }
    }

    /// NSAttributedString → RTF Data（附件会被替换为占位符，不内嵌）
    static func rtfData(_ att: NSAttributedString) -> Data {
        // 先清掉附件（NSTextAttachment 的 RTF 序列化会尝试内嵌 base64）
        let stripped = NSMutableAttributedString(attributedString: att)
        let full = NSRange(location: 0, length: stripped.length)
        var replacements: [(NSRange, NSAttributedString)] = []
        stripped.enumerateAttribute(.attachment, in: full, options: []) { value, range, _ in
            if let chk = value as? MuseCheckAttachment {
                // 核对清单圆圈 → 落盘为纯文本 ☐/☑（可搜索、兼容旧版）
                replacements.append((range, NSAttributedString(string: chk.checked ? "☑" : "☐")))
            } else if value is MuseDividerAttachment {
                // 分割线 → 私有区标记（与图片/文件区分，不污染 attachments/）
                replacements.append((range, NSAttributedString(string: museDividerMarker)))
            } else if value is NSTextAttachment {
                replacements.append((range, NSAttributedString(string: museImgMarker)))
            }
        }
        for (r, rep) in replacements.reversed() {
            stripped.replaceCharacters(in: r, with: rep)
        }
        return (try? stripped.data(from: NSRange(location: 0, length: stripped.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])) ?? Data()
    }

    /// 从富文本提取附件（图片 → PNG data；文件 → 原数据），返回 (附件元数据, 数据) 列表
    /// 顺序与正文占位符一一对应。
    static func extractAttachments(from att: NSAttributedString) -> [(MuseAttachment, Data)] {
        var out: [(MuseAttachment, Data)] = []
        let full = NSRange(location: 0, length: att.length)
        att.enumerateAttribute(.attachment, in: full, options: []) { value, _, _ in
            guard let attachment = value as? NSTextAttachment else { return }
            // 核对清单圆圈是纯绘制标记，不当普通附件落盘
            if attachment is MuseCheckAttachment { return }
            // 分割线是纯绘制标记，也不当附件落盘
            if attachment is MuseDividerAttachment { return }

            // 0) 文件 chip：数据直接取自 chip
            if let chip = attachment as? MuseFileChipAttachment {
                let meta = MuseAttachment(
                    id: UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8).description,
                    name: chip.fileName,
                    type: UTType(filenameExtension: (chip.fileName as NSString).pathExtension)?.identifier ?? "",
                    size: chip.fileData.count,
                    createdAt: DateUtil.isoLocal(Date()))
                out.append((meta, chip.fileData))
                return
            }

            // 1) 图片
            if let image = attachment.image {
                var data: Data? = nil
                var ext = "png"
                if let tiff = image.tiffRepresentation,
                   let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    data = png
                } else {
                    data = image.tiffRepresentation
                    ext = "tiff"
                }
                if let d = data {
                    let meta = MuseAttachment(
                        id: UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8).description,
                        name: "image-\(DateUtil.epochMs()).\(ext)",
                        type: UTType.image.identifier,
                        size: d.count,
                        createdAt: DateUtil.isoLocal(Date()))
                    out.append((meta, d))
                }
                return
            }

            // 2) 文件附件
            if let wrapper = attachment.fileWrapper,
               let data = wrapper.regularFileContents {
                let name = wrapper.preferredFilename ?? "attachment.bin"
                let meta = MuseAttachment(
                    id: UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(8).description,
                    name: name,
                    type: UTType(filenameExtension: (name as NSString).pathExtension)?.identifier ?? "",
                    size: data.count,
                    createdAt: DateUtil.isoLocal(Date()))
                out.append((meta, data))
                return
            }
        }
        return out
    }

    /// 用附件数据重建富文本：正文占位符按下标替换回 NSTextAttachment
    static func rebuildAttachments(rtfData data: Data,
                                   attachments: [(MuseAttachment, Data)]) -> NSAttributedString {
        guard let att = attributed(fromRTF: data) else {
            return NSAttributedString(string: "")
        }
        let mutable = NSMutableAttributedString(attributedString: att)

        // 找占位符位置（顺序）。同时兼容旧版遗留的 U+FFFC 占位（修复前个别笔记曾用它），
        // 两类 marker 都扫描后按位置排序合并，保证旧数据也能重建。
        var markers: [NSRange] = []
        for m in [museImgMarker, museAttachmentMarker] {
            var scan = 0
            while scan < mutable.length {
                let r = (mutable.string as NSString).range(of: m,
                                                           options: [],
                                                           range: NSRange(location: scan, length: mutable.length - scan))
                if r.location == NSNotFound { break }
                markers.append(r)
                scan = r.location + r.length
            }
        }
        markers.sort { $0.location < $1.location }

        // 从后往前替换
        for (i, r) in markers.reversed().enumerated() {
            let idx = markers.count - 1 - i
            guard idx < attachments.count else { continue }
            let (meta, data) = attachments[idx]
            let replacement: NSAttributedString
            // 依据 meta.type 判定图片 / 文件，而不是「NSImage(data:) 能否解码」：
            // PDF 也能被 NSImage 解码成封面图，若只看解码结果 PDF 会被误当图片内联成大图。
            if UTType(meta.type)?.conforms(to: .image) == true,
               let img = NSImage(data: data), img.size.width > 0 {
                // 图片：内联显示，宽度约束 420pt（与编辑态 insertAttachmentImage 一致），等比缩放避免撑爆
                let attachment = NSTextAttachment()
                attachment.image = img
                let maxW: CGFloat = 420
                if img.size.width > maxW {
                    let scale = maxW / img.size.width
                    attachment.bounds = NSRect(x: 0, y: 0,
                                               width: maxW,
                                               height: img.size.height * scale)
                }
                replacement = NSAttributedString(attachment: attachment)
            } else {
                // 非图片（PDF / 文档 / 图片文件等）→ 文件名 chip：点击才打开，绝不内联预览
                replacement = NSAttributedString(
                    attachment: MuseFileChipAttachment(fileName: meta.name, data: data))
            }
            mutable.replaceCharacters(in: r, with: replacement)
        }
        // 落盘的行首 ☐/☑ 字符 → 可点击清单圈
        return reviveDividerMarkers(reviveCheckMarkers(mutable))
    }

    /// 把落盘的分割线标记（私有区字符）还原回可绘制的分割线附件。
    static func reviveDividerMarkers(_ att: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: att)
        let str = m.string as NSString
        var idx = 0
        while idx < str.length {
            let r = str.range(of: museDividerMarker,
                              options: [],
                              range: NSRange(location: idx, length: str.length - idx))
            if r.location == NSNotFound { break }
            m.replaceCharacters(in: r, with: NSAttributedString(attachment: MuseDividerAttachment()))
            idx = r.location + 1   // 附件占 1 个字符，避免重复扫描
        }
        return m
    }

    /// 从富文本提取纯文本（搜索索引预留：标题/正文/分组）
    static func plainText(_ att: NSAttributedString) -> String {
        att.string
    }

    /// 把落盘的行首 ☐/☑ 字符转回可点击清单圈（编辑态）。
    /// 兼容旧版「符号+空格」与新版「符号（间距在圈图内）」两种格式；
    /// 旧版带空格的，恢复圈时一并吃掉空格（圈图自带间距）。
    /// 字符与附件同为 1 个 UTF-16 单元，替换不改变长度、不会乱偏移。
    static func reviveCheckMarkers(_ att: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: att)
        let str = m.string as NSString
        var idx = 0
        while idx < str.length {
            let pr = str.paragraphRange(for: NSRange(location: idx, length: 0))
            let line = str.substring(with: pr)
            for sym in ["☑", "☐"] where line.hasPrefix(sym) {
                let after = String(line.dropFirst(1))
                let eatSpace = after.hasPrefix(" ") ? 1 : 0
                // 圈的行盒跟随该行正文字体（读符号后第一个字符的字体）
                let bodyIdx = pr.location + 1 + eatSpace
                let bodyFont = bodyIdx < m.length
                    ? (m.attribute(.font, at: bodyIdx, effectiveRange: nil) as? NSFont)
                    : nil
                m.replaceCharacters(
                    in: NSRange(location: pr.location, length: 1 + eatSpace),
                    with: NSAttributedString(
                        attachment: MuseCheckAttachment(checked: sym == "☑", font: bodyFont)))
                break
            }
            idx = pr.location + max(1, pr.length)
        }
        return m
    }
}

// MARK: - 编辑器子类：点击正文里的清单圈切换勾/未勾

final class MuseTextView: NSTextView {

    /// ⚠️ 结构性根治「点击标题时正文区闪一下灰色矩形框」。
    /// 照片证据（15:28 手机拍摄）：整个右编辑区出现一个有边框的灰色矩形块，闪一下消失。
    /// 根因：NSTextView 默认 focusRingType = .default（画焦点环矩形）+ drawsBackground = true
    ///   （画灰色背景），叠加后就是用户看到的"框"。SwiftUI 在异步加载 / 视图重建时
    ///   会重置这两个属性，仅在 makeNSView / updateNSView 设 .none 不够稳。
    /// override 这两个属性的 getter 永久返回 .none / false，无论 SwiftUI 怎么重置都无效。
    override var focusRingType: NSFocusRingType {
        get { .none }
        set { }  // 忽略外部 set，彻底不可改
    }
    override var drawsBackground: Bool {
        get { false }
        set { }  // 忽略外部 set
    }

    /// first responder 行为：完全恢复 NSTextView 默认（acceptsFirstResponder = true）。
    /// 🚨 关键结论（黑匣子 15:14-15:15 实锤 + 15:48 反复验证）：
    ///   1. 「正文自动抢标题焦点」从未发生——窗口不会自动任命 NSTextView（它不在 key view
    ///      loop 初始路径上），早期 13:37/14:27 日志里的 textview become 是用户点击正文的
    ///      正常编辑行为，被误判为抢焦点。
    ///   2. 标题「闪一下的框」真凶是 NSScrollView/NSTextView 的 drawsBackground + focusRingType
    ///      （已用 MuseScrollView/MuseTextView 子类 override 修好，用户确认不闪）。
    ///   3. 之前加的 wantsFR 闸门（acceptsFirstResponder 默认 false）是错误防御：窗口在路由
    ///      鼠标事件前先查 acceptsFirstResponder，false 导致正文连 mouseDown 都收不到 →
    ///      「正文编辑不了」。删除后正文恢复正常编辑。
    /// 因此这里不再 override acceptsFirstResponder / becomeFirstResponder / resignFirstResponder，
    /// 正文与普通 NSTextView 完全一致。

    /// 回车行为对齐备忘录：
    /// - 清单行且行内已有文字 → 新行自动加未勾圈；
    /// - 清单行但行内只有圈（空内容）→ 回车移除圈（退出清单模式）；
    /// - 圆点/短横/编号行 → 新行续同种标记（编号 +1）。
    override func insertNewline(_ sender: Any?) {
        guard let s = textStorage, s.length > 0 else { super.insertNewline(sender); return }
        let str = s.string as NSString
        // ⚠️ 段落定位必须用真实光标位置（文末空行时 location == length），
        //    若回退到 length-1 会把空行的操作作用到上一行（"跳到上面那行"的根因）
        let paraRange = str.paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = str.substring(with: paraRange)
        let core = line.hasSuffix("\n") ? String(line.dropLast()) : line
        // 带属性行：区分行首 U+FFFC 是清单圈还是文件 chip
        let attLine = s.attributedSubstring(from: paraRange)
        let (m, rest) = MuseFormatOps.existingMarker(core, attLine: attLine)

        guard let marker = m else { super.insertNewline(sender); return }
        let isCheck = MuseFormatOps.belongs(marker, to: .check)
        let bodyEmpty = rest.isEmpty

        if isCheck && bodyEmpty {
            // 空清单行回车 = 退出清单：删掉行首标记（新格式圈=1 单元，旧格式圈+空格=2）
            let removeLen = core.count - rest.count
            let removeRange = NSRange(location: paraRange.location,
                                      length: min(removeLen, paraRange.length))
            s.replaceCharacters(in: removeRange, with: "")
            setSelectedRange(NSRange(location: paraRange.location, length: 0))
            didChangeText()
            needsDisplay = true
            return
        }

        if isCheck {
            // 新行自动续未勾圈
            let nl = NSMutableAttributedString(string: "\n")
            nl.append(MuseFormatOps.checkUncheckedMarker(font: font))
            insertText(nl, replacementRange: selectedRange())
            return
        }
        var head = "\n"
        if marker == "1." {
            // 编号续号：当前行序号 +1
            let num = Int(core.prefix(while: { $0.isNumber })) ?? 1
            head += "\(num + 1). "
        } else {
            head += marker + " "
        }
        insertText(head, replacementRange: selectedRange())
    }

    /// 文本变化后修复输入字体：删除清单圈等结构后，typingAttributes 可能
    /// 残留附件的小字号 → 新打的字比正文小。这里让它跟随光标前一个字符的字号。
    override func didChangeText() {
        super.didChangeText()
        guard let s = textStorage, s.length > 0 else { return }
        let sel = selectedRange()
        guard sel.length == 0, sel.location > 0 else { return }
        let prev = s.attributes(at: sel.location - 1, effectiveRange: nil)
        guard let pf = prev[.font] as? NSFont,
              let tf = typingAttributes[.font] as? NSFont,
              pf.pointSize != tf.pointSize else { return }
        var t = typingAttributes
        t[.font] = pf
        typingAttributes = t
    }

    override func mouseDown(with event: NSEvent) {
        // 附件点击：只做打勾/打开，不进入编辑、不抢焦点
        if let idx = characterIndex(at: event), let s = textStorage,
           let att = s.attribute(.attachment, at: idx, effectiveRange: nil) as? NSTextAttachment {
            var r = NSRange()
            _ = s.attribute(.attachment, at: idx, effectiveRange: &r)
            if att is MuseCheckAttachment {
                // 只有点中圈本身才打勾（点旁边正文不误触）
                if clickPointIsInsideAttachment(characterRange: r, event: event) {
                    MuseFormatOps.toggleCheck(at: r, in: self)
                    return   // 点击圈 = 打勾操作，不移动光标
                }
            }
            if let chip = att as? MuseFileChipAttachment {
                // ⚠️ 必须用「点击点落在 chip 绘制矩形内」做命中判定：
                // glyphIndex(for:) 是就近匹配，点到 chip 旁的正文也会被算成 chip 索引、
                // 误触发打开文件。只有真正点中 chip 才打开。
                if clickPointIsInsideAttachment(characterRange: r, event: event) {
                    Self.openFileChip(chip)
                    return   // 点击 chip = 用系统默认应用打开，不移动光标
                }
            }
        }
        // 普通正文点击（含点中 chip 旁的正文）：正常编辑（NSTextView 默认行为）
        super.mouseDown(with: event)
    }

    /// 点击点是否真正落在附件（圈/文件 chip）的绘制矩形内。
    /// 用字形包围盒做命中测试，避免「就近匹配」把旁边正文也判成点中附件。
    private func clickPointIsInsideAttachment(characterRange r: NSRange, event: NSEvent) -> Bool {
        guard let lm = layoutManager, let tc = textContainer else { return false }
        let glyph = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        let rect = lm.boundingRect(forGlyphRange: glyph, in: tc)
        let p = convert(event.locationInWindow, from: nil)
        let cp = NSPoint(x: p.x - textContainerInset.width,
                         y: p.y - textContainerInset.height)
        return rect.contains(cp)
    }

    /// 文件 chip 点击打开：内容写到缓存临时文件，交给系统默认应用
    static func openFileChip(_ chip: MuseFileChipAttachment) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("liuke-open", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(chip.fileName)
        do {
            try chip.fileData.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            Log.shared.warn("open attachment failed: \(error.localizedDescription)")
        }
    }

    /// 鼠标悬停到清单圈/文件 chip 上时显示手型指针
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let s = textStorage, let lm = layoutManager, let tc = textContainer else { return }
        var idx = 0
        while idx < s.length {
            var r = NSRange()
            let att = s.attribute(.attachment, at: idx, effectiveRange: &r)
            if att is MuseCheckAttachment || att is MuseFileChipAttachment {
                let glyph = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
                let rect = lm.boundingRect(forGlyphRange: glyph, in: tc)
                    .offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
                addCursorRect(rect, cursor: .pointingHand)
                idx = r.location + r.length
            } else {
                idx += 1
            }
        }
    }

    private func characterIndex(at event: NSEvent) -> Int? {
        guard let lm = layoutManager, let tc = textContainer, let s = textStorage else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let cp = NSPoint(x: p.x - textContainerInset.width,
                         y: p.y - textContainerInset.height)
        let glyph = lm.glyphIndex(for: cp, in: tc)
        let idx = lm.characterIndexForGlyph(at: glyph)
        return idx < s.length ? idx : nil
    }
}

// MARK: - 滚动视图子类：结构性根治「闪一下灰色矩形」（drawsBackground + focusRingType 永久锁定）
/// 照片证据（用户 15:28 手机拍摄）：点击标题时整个正文区出现一个有边框的灰色矩形闪一下消失。
/// 根因：NSScrollView 默认 drawsBackground = true（灰色背景） + focusRingType = .default。
/// 仅在 makeNSView/updateNSView 设 .none 不够稳——SwiftUI 在异步加载 / 视图重建时可能重置。
/// 子类化直接 override getter 永久返回 false / .none，无论 SwiftUI 怎么重置都无效。
final class MuseScrollView: NSScrollView {
    override var drawsBackground: Bool {
        get { false }
        set { }
    }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set { }
    }
}

// MARK: - RichTextEditor（NSViewRepresentable）

struct RichTextEditor: NSViewRepresentable {
    /// 外部绑定：当前笔记的富文本内容（编辑器实时回写）
    @Binding var text: NSAttributedString
    /// 编辑回调（用于自动保存防抖打点）
    var onEditing: () -> Void
    /// 外部同步令牌：切换笔记时 MusePanel 递增，updateNSView 据此把外部内容写入编辑器。
    /// 用户输入（textDidChange）不递增 token → 绝不覆盖用户正在打的内容。
    var syncToken: Int = 0
    /// 格式状态对象：文本/选区变化时刷新，toolbar 圆形按钮据此高亮（nil = 不需要）
    var formatState: MuseFormatState? = nil
    /// 搜索跳转令牌：每次点击搜索结果 +1，编辑器据此在内容同步后定位到关键词
    var jumpToken: Int = 0
    /// 搜索跳转关键词（进入笔记后定位到该词，定位后由编辑器清空）
    var jumpKeyword: Binding<String?>? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // 自定义子类（等价 scrollableTextView 配置 + 清单圈点击支持）
        // 关键：用 MuseScrollView 子类替代 NSScrollView，
        // drawsBackground / focusRingType 在 class 层永久 .none / false（见上面子类定义）
        let scroll = MuseScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = MuseTextView()
        // MuseTextView 同样在 class 层永久 focusRingType = .none / drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        scroll.documentView = textView
        textView.delegate = context.coordinator
        textView.allowsUndo = true
        textView.isRichText = true
        textView.importsGraphics = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 12, height: 14)
        textView.textContainer?.widthTracksTextView = true
        textView.font = NSFont.systemFont(ofSize: 14.5)
        textView.textColor = .textColor
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.typingAttributes = MuseRichText.defaultBodyAttrs()
        textView.textStorage?.setAttributedString(MuseRichText.normalize(text))

        context.coordinator.textView = textView
        context.coordinator.lastSyncToken = syncToken
        context.coordinator.formatState = formatState
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.parent = self
        context.coordinator.formatState = formatState
        // 防御性：子类已保证 .none / false，但保险起见再设一遍（双保险）
        scroll.drawsBackground = false
        scroll.focusRingType = .none
        textView.focusRingType = .none
        textView.drawsBackground = false
        // 仅当外部 syncToken 变化（= 切换笔记）才同步内容；用户输入绝不覆盖
        if context.coordinator.lastSyncToken != syncToken {
            textView.textStorage?.setAttributedString(MuseRichText.normalize(text))
            textView.typingAttributes = MuseRichText.defaultBodyAttrs()
            // 把光标放到文末，避免 selectedRange 非零时画整个 selection 高亮（= 另一个"框"来源）
            let len = textView.attributedString().length
            textView.selectedRange = NSRange(location: len, length: 0)
            context.coordinator.lastSyncToken = syncToken
            context.coordinator.lastAttributed = text
            textView.scrollToBeginningOfDocument(nil)
            // 切到新笔记后，让圆形按钮高亮立即反映新内容的格式
            context.coordinator.refreshFormatState()
        }
        // 搜索跳转：进入笔记后定位到关键词（独立于 syncToken，停留同一篇也触发）
        if context.coordinator.lastJumpToken != jumpToken {
            context.coordinator.lastJumpToken = jumpToken
            if let kw = jumpKeyword?.wrappedValue, !kw.isEmpty,
               let storage = textView.textStorage {
                let str = storage.string
                if let r = str.range(of: kw, options: [.caseInsensitive, .diacriticInsensitive]) {
                    let ns = NSRange(r, in: str)
                    textView.setSelectedRange(ns)
                    textView.scrollRangeToVisible(ns)
                }
            }
            jumpKeyword?.wrappedValue = nil
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        /// 共享的当前编辑器引用（工具栏/附件插入直接拿，绕开 @State 时序问题）
        static weak var shared: Coordinator?

        var parent: RichTextEditor
        weak var textView: NSTextView?
        /// 上次处理的跳转令牌（避免重复定位）
        var lastJumpToken: Int = -1
        /// 最近一次外部同步的 token（切换笔记时变化）
        var lastSyncToken = -1
        /// 最近一次同步给编辑器的内容（外部比对用）
        var lastAttributed: NSAttributedString = NSAttributedString()
        /// 外部注入的格式状态对象（toolbar 圆形按钮据此高亮）
        var formatState: MuseFormatState?

        /// 依据当前选区/光标处属性，刷新格式状态（加粗/斜体/下划线等是否生效）
        /// - 有选中：读选中首字符的属性
        /// - 仅光标：读 typingAttributes（下一个输入字符将应用的属性）——
        ///   这样点了「加粗」不用先选字也能立刻高亮，明确告诉用户"已点开"
        func refreshFormatState() {
            guard let fs = formatState, let tv = textView else { return }
            // 空文档：字符样式读 typingAttributes（点了加粗/斜体等立即高亮——
            // applyAttribute 无选中时写入的就是 typingAttributes，输入首字即生效）；
            // 段落/字号/列表无内容可谈，归零。
            guard (tv.textStorage?.length ?? 0) > 0 else {
                let t = tv.typingAttributes
                let f = (t[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 14.5)
                fs.update(bold: f.fontDescriptor.symbolicTraits.contains(.bold),
                          italic: ((t[.obliqueness] as? Double) ?? 0) != 0,
                          underline: ((t[.underlineStyle] as? Int) ?? 0) != 0,
                          strike: ((t[.strikethroughStyle] as? Int) ?? 0) != 0,
                          quote: false, fontSize: f.pointSize, listMarker: "", indent: false)
                return
            }
            let range = tv.selectedRange()
            let attrs: [NSAttributedString.Key: Any]
            if range.length > 0, let s = tv.textStorage, s.length > 0 {
                let idx = min(range.location, s.length - 1)
                attrs = s.attributes(at: idx, effectiveRange: nil)
            } else {
                attrs = tv.typingAttributes
            }

            let font = (attrs[.font] as? NSFont)
                ?? tv.font ?? NSFont.systemFont(ofSize: 14.5)
            let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
            let italic = ((attrs[.obliqueness] as? Double) ?? 0) != 0
            let underline = ((attrs[.underlineStyle] as? Int) ?? 0) != 0
            let strike = ((attrs[.strikethroughStyle] as? Int) ?? 0) != 0
            let para = (attrs[.paragraphStyle] as? NSParagraphStyle)
                ?? NSParagraphStyle.default
            let quote = para.headIndent >= 20
            let indent = para.firstLineHeadIndent > 0

            // 列表标记：看光标所在行的行首前缀（•/○/–/☑/☐ 或 N.）；
            // 行首附件需区分清单圈与文件 chip（带属性行识别）
            var listMarker = ""
            if let s = tv.textStorage, s.length > 0 {
                let str = s.string as NSString
                let loc = min(range.location, s.length - 1)
                let pr = str.paragraphRange(for: NSRange(location: loc, length: 0))
                let paraAtt = s.attributedSubstring(from: pr)
                let firstLine = String(paraAtt.string.split(separator: "\n",
                                                      omittingEmptySubsequences: false).first ?? "")
                listMarker = MuseFormatOps.markerOf(currentLine: firstLine, attLine: paraAtt)
            }

            fs.update(bold: bold, italic: italic, underline: underline, strike: strike,
                      quote: quote, fontSize: font.pointSize,
                      listMarker: listMarker, indent: indent)
        }

        init(_ parent: RichTextEditor) {
            self.parent = parent
            super.init()
            Self.shared = self
        }

        deinit {
            if Self.shared === self { Self.shared = nil }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            // 全文强制统一：非标题字号→14.5pt、行距→5pt。
            // 兜住"删掉清单/结构后残留小字号"的问题，正文与清单永远同字号同行距。
            MuseRichText.enforceBodyStyle(textView)
            let newValue = textView.attributedString()
            parent.text = newValue
            lastAttributed = newValue
            parent.onEditing()
            refreshFormatState()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // 选区/光标变化 → 刷新格式状态，让 toolbar 圆形按钮实时反映当前位置的格式
            refreshFormatState()
        }
    }
}

// MARK: - 内容工具栏（独立正圆 item + 激活高亮）

/// 编辑器当前光标位置的格式状态：由 RichTextEditor 的 Coordinator 在文本/选区
/// 变化时实时刷新；toolbar 的圆形按钮订阅它做高亮（点了加粗，加粗按钮就亮起，
/// 明确告诉用户"这个格式当前是开着的"）。
final class MuseFormatState: ObservableObject {
    @Published var bold = false
    @Published var italic = false
    @Published var underline = false
    @Published var strike = false
    @Published var quote = false
    /// 当前位置字号（0 = 无内容）；标题/小标题菜单据此打勾
    @Published var fontSize: CGFloat = 0
    /// 当前段落的项目符号（"" = 无列表）；列表菜单据此打勾与高亮
    @Published var listMarker = ""
    /// 当前段落是否首行缩进；缩进按钮据此高亮
    @Published var indent = false

    /// 无选中笔记时全部清零（删除笔记后高亮不再残留）
    func reset() {
        update(bold: false, italic: false, underline: false, strike: false,
               quote: false, fontSize: 0, listMarker: "", indent: false)
    }

    func update(bold: Bool, italic: Bool, underline: Bool, strike: Bool, quote: Bool,
                fontSize: CGFloat, listMarker: String, indent: Bool) {
        if self.bold != bold { self.bold = bold }
        if self.italic != italic { self.italic = italic }
        if self.underline != underline { self.underline = underline }
        if self.strike != strike { self.strike = strike }
        if self.quote != quote { self.quote = quote }
        if self.fontSize != fontSize { self.fontSize = fontSize }
        if self.listMarker != listMarker { self.listMarker = listMarker }
        if self.indent != indent { self.indent = indent }
    }
}

/// toolbar 正圆按钮样式（对齐 Finder 工具栏观感）：
/// - 常态：无背景，只有图标；
/// - hover：整个正圆盖一层浅灰；
/// - 按下：整个正圆盖一层深灰（Finder 点击时"全部覆盖灰色"的效果）；
/// - 激活（工具正在生效，如加粗已开）：整个正圆蓝底白图标。
/// 形状保障：内容 frame 宽高相等 + 外层 fixedSize()，toolbar 无法把它拉成椭圆。
struct MuseCircleButtonStyle: ButtonStyle {
    var isActive: Bool = false
    /// fill = true：灰/蓝圆铺满整个 item（不留 4pt 边距），供录制按钮等"独占一格"的 item 用
    var fill: Bool = false
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        // 激活态不再使用主题蓝（用户要求：toolbar 选中项去掉蓝色，
        // 激活状态改由菜单内文字标蓝表示）。仅保留 hover / 按下的浅灰反馈。
        let fillColor: Color = configuration.isPressed ? Color.primary.opacity(0.25)
            : hovering ? Color.primary.opacity(0.12)
            : Color.clear
        // fill 模式内容 34pt：整体变大、保持正圆（负边距外扩会被系统白框
        // 追高成椭圆）；灰圆不越界，靠内容变大让白边在视觉上变细。
        let d: CGFloat = fill ? 34 : 28
        return configuration.label
            // 图标加大：接近 macOS 原生工具栏图标观感
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.primary)
            .frame(width: d, height: d)
            .background(Circle().fill(fillColor))
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
            // 非 fill：圆外留 3pt，系统白胶囊不贴灰圆边；fill：不留边距铺满。
            // 与组内 HStack spacing 2 叠加，所有 item 视觉间距统一 ≈8pt。
            .padding(fill ? 0 : 3)
            .fixedSize()
    }
}

/// 工具栏图标块（供 Menu 等非 Button 控件复用同样的外观与 hover 反馈）。
/// icon / text 二选一：SF 符号或纯文字（如「格式」按钮）。
/// 形状：图标 item = 正圆；文字 item = 胶囊（椭圆），避免正圆"包不住"两个字。
struct MuseCircleIcon: View {
    var icon: String? = nil
    var text: String? = nil
    /// 图标也用胶囊（椭圆）底，如「大小」；默认图标 = 正圆
    var capsule: Bool = false
    var active: Bool = false
    @State private var hovering = false

    private var fill: Color {
        // 激活态不再使用主题蓝（用户要求 toolbar 选中项去掉蓝色）；
        // 仅保留 hover 浅灰反馈。激活状态改由菜单内文字标蓝表示。
        hovering ? Color.primary.opacity(0.12)
            : Color.clear
    }

    var body: some View {
        if text != nil || capsule {
            capsuleChip
        } else {
            circleChip
        }
    }

    /// 正圆：28×28，与其他图标 item 一致；外边距 3pt 与文字胶囊统一
    private var circleChip: some View {
        Image(systemName: icon ?? "")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(Color.primary)
            .frame(width: 28, height: 28)
            .background(Circle().fill(fill))
            .contentShape(Circle())
            .onHover { hovering = $0 }
            .padding(3)
            .fixedSize()
    }

    /// 胶囊（椭圆）：文字/图标统一 44×28 固定胶囊，形状一致
    private var capsuleChip: some View {
        Group {
            if let text {
                Text(text).font(.system(size: 13.5, weight: .medium))
            } else if let icon {
                Image(systemName: icon).font(.system(size: 16, weight: .medium))
            }
        }
            .foregroundStyle(Color.primary)
            .frame(width: 44, height: 28)
            .background(Capsule().fill(fill))
            .contentShape(Capsule())
            .onHover { hovering = $0 }
            // 与圆形 item 相同的 3pt 内边距，toolbar 间距统一
            .padding(3)
            .fixedSize()
    }
}

// MARK: - 格式操作（供窗口 toolbar 的正圆按钮调用）
//
// 原 RichTextToolbar（编辑区内嵌工具面板）已迁移到窗口 toolbar：
// 每个工具一个独立 ToolbarItem，全部 28×28 正圆（见 MuseCircleButtonStyle）。

/// 富文本格式操作集合。全部为静态方法、接收 NSTextView；
/// MusePanel 的 toolbar 正圆按钮通过 RichTextEditor.Coordinator.shared?.textView
/// 取到当前编辑器后调用。操作会触发 textDidChange → 自动刷新格式状态高亮。
enum MuseFormatOps {

    enum HeadingLevel { case title, heading, body }

    /// 让 textView 成为 first responder（工具栏点击后确保选中区有效）
    private static func focusTextView(_ tv: NSTextView) {
        tv.window?.makeFirstResponder(tv)
    }

    /// 读取「当前生效属性」：有选中读选中首字符，仅光标读 typingAttributes。
    /// 空文档也不会越界（原实现直接 attribute(at:0) 在空文档上会崩）。
    private static func currentAttributes(_ tv: NSTextView) -> [NSAttributedString.Key: Any] {
        let range = tv.selectedRange()
        if range.length > 0, let s = tv.textStorage, s.length > 0 {
            return s.attributes(at: min(range.location, s.length - 1), effectiveRange: nil)
        }
        return tv.typingAttributes
    }

    /// 把某个 attribute 应用到「选中文字」；无选中（光标）时写入 typingAttributes（影响后续输入）
    /// 关键：必须 beginEditing()/endEditing() 包住 addAttribute，否则 layoutManager 不会触发重绘！
    private static func applyAttribute(_ key: NSAttributedString.Key, value: Any, tv: NSTextView) {
        let range = tv.selectedRange()
        if range.length > 0 {
            tv.textStorage?.beginEditing()
            tv.textStorage?.addAttribute(key, value: value, range: range)
            tv.textStorage?.endEditing()
        } else {
            var typing = tv.typingAttributes
            typing[key] = value
            tv.typingAttributes = typing
        }
        tv.didChangeText()
        // 强制重绘（layoutManager.endEditing 后通常已自动刷新，这里双保险）
        tv.needsDisplay = true
        tv.layoutManager?.invalidateDisplay(forCharacterRange: range.length == 0
            ? NSRange(location: 0, length: tv.textStorage?.length ?? 0)
            : range)
        Log.shared.info("muse format | key=\(key.rawValue) range=\(range) tv=\(tv.hashValue)")
    }

    /// 切换字体的粗体 trait（粗体走 fontDescriptor，中文/系统字体可靠）
    static func toggleBold(_ tv: NSTextView) {
        focusTextView(tv)
        let baseFont = (currentAttributes(tv)[.font] as? NSFont)
            ?? tv.font ?? NSFont.systemFont(ofSize: 14.5)
        let current = baseFont.fontDescriptor.symbolicTraits
        let newTraits: NSFontDescriptor.SymbolicTraits = current.contains(.bold)
            ? current.subtracting(.bold)
            : current.union(.bold)
        let newDesc = baseFont.fontDescriptor.withSymbolicTraits(newTraits)
        let newFont = NSFont(descriptor: newDesc, size: baseFont.pointSize) ?? baseFont
        applyAttribute(.font, value: newFont, tv: tv)
    }

    /// 斜体：中文字体（苹方等）没有真斜体字形，fontDescriptor 的 italic trait 无效。
    /// 用 obliqueness（倾斜变换）实现斜体效果，对中文/西文都可靠。
    static func toggleItalic(_ tv: NSTextView) {
        focusTextView(tv)
        let existing = (currentAttributes(tv)[.obliqueness] as? Double) ?? 0
        let newValue = existing == 0 ? 0.25 : 0.0   // 0.25 rad ≈ 14° 倾斜
        applyAttribute(.obliqueness, value: newValue, tv: tv)
    }

    static func toggleUnderline(_ tv: NSTextView) {
        focusTextView(tv)
        let existing = (currentAttributes(tv)[.underlineStyle] as? Int) ?? 0
        let newValue = existing == 0 ? NSUnderlineStyle.single.rawValue : 0
        applyAttribute(.underlineStyle, value: newValue, tv: tv)
    }

    static func toggleStrikethrough(_ tv: NSTextView) {
        focusTextView(tv)
        let existing = (currentAttributes(tv)[.strikethroughStyle] as? Int) ?? 0
        let newValue = existing == 0 ? NSUnderlineStyle.single.rawValue : 0
        applyAttribute(.strikethroughStyle, value: newValue, tv: tv)
    }

    /// 撤销恢复：把编辑器正文整体恢复为 old（AI 润色/插入总结的 undo 目标）。
    static func restoreBody(_ tv: NSTextView, old: NSAttributedString) {
        guard let s = tv.textStorage else { return }
        let um = tv.undoManager
        let undoWasEnabled = um?.isUndoRegistrationEnabled ?? false
        if undoWasEnabled { um?.disableUndoRegistration() }
        s.beginEditing()
        s.setAttributedString(MuseRichText.normalize(old))
        s.endEditing()
        tv.didChangeText()
        if undoWasEnabled { um?.enableUndoRegistration() }
    }

    /// 清除格式：把选中范围（无选中则全文）还原为最原始的正文格式——
    /// 14.5pt 系统字体、去掉粗/斜/下划线/删除线/颜色/链接等一切外来格式，
    /// 段落重置为统一行距、清除首行缩进（引用）与多余段间距。
    /// 仅重置字符/段落属性，不替换 run，因此图片/文件/清单圈等附件原样保留。
    static func clearFormatting(_ tv: NSTextView) {
        focusTextView(tv)
        guard let s = tv.textStorage else { return }
        let sel = tv.selectedRange()
        let target = sel.length > 0 ? sel : NSRange(location: 0, length: s.length)
        guard target.length > 0 else {
            tv.typingAttributes = MuseRichText.defaultBodyAttrs()
            tv.didChangeText()
            return
        }
        s.beginEditing()
        // 段落属性：统一行距 + 清除缩进/段间距
        var paraIdx = target.location
        let end = NSMaxRange(target)
        while paraIdx < end {
            let pr = (s.string as NSString).paragraphRange(for: NSRange(location: paraIdx, length: 0))
            let clamped = NSIntersectionRange(pr, target)
            guard clamped.length > 0 else { break }
            let ps = NSMutableParagraphStyle()
            ps.lineSpacing = MuseRichText.bodyLineSpacing
            s.addAttribute(.paragraphStyle, value: ps, range: clamped)
            paraIdx = NSMaxRange(pr)
        }
        // 字符属性：还原为默认正文
        s.addAttribute(.font, value: NSFont.systemFont(ofSize: 14.5), range: target)
        s.removeAttribute(.obliqueness, range: target)
        s.removeAttribute(.underlineStyle, range: target)
        s.removeAttribute(.underlineColor, range: target)
        s.removeAttribute(.strikethroughStyle, range: target)
        s.removeAttribute(.strikethroughColor, range: target)
        s.removeAttribute(.link, range: target)
        s.removeAttribute(.foregroundColor, range: target)
        s.removeAttribute(.backgroundColor, range: target)
        s.removeAttribute(.strokeColor, range: target)
        s.removeAttribute(.strokeWidth, range: target)
        s.removeAttribute(.textEffect, range: target)
        s.removeAttribute(.writingDirection, range: target)
        s.endEditing()
        tv.didChangeText()
        tv.needsDisplay = true
        Log.shared.info("muse format | clearFormatting range=\(target)")
    }

    static func applyHeading(_ tv: NSTextView, _ level: HeadingLevel) {
        focusTextView(tv)
        let size: CGFloat
        switch level {
        case .title: size = 22
        case .heading: size = 17
        case .body: size = 14.5
        }
        // 保留当前位置已有的粗体/斜体 trait（原来切标题会吞掉加粗）
        let baseFont = (currentAttributes(tv)[.font] as? NSFont)
            ?? tv.font ?? NSFont.systemFont(ofSize: 14.5)
        var traits = baseFont.fontDescriptor.symbolicTraits
        if level == .body {
            traits.remove(.bold)
        } else {
            traits.insert(.bold)
        }
        let desc = baseFont.fontDescriptor.withSymbolicTraits(traits)
        let font = NSFont(descriptor: desc, size: size)
            ?? NSFont.systemFont(ofSize: size)
        applyAttribute(.font, value: font, tv: tv)
    }

    // MARK: 列表（项目符号 / 编号 / 核对清单）与首行缩进

    enum ListStyle { case bullet, hollow, dash, ordered, check, quote }

    /// 可能出现在行首的纯文本列表标记（供状态检测）。
    /// 「☑/☐/✓/◯」为旧版/落盘符号，兼容识别；编辑态的清单圈是可点击附件（行首为 U+FFFC）。
    static let plainMarkers = ["•", "○", "–", "☑", "☐", "✓", "◯"]

    /// 清单圈附件的占位字符（行首出现即清单行）
    private static let checkPlaceholder = museAttachmentMarker

    /// 识别行首标记：
    /// 行首 U+FFFC 且附件是「清单圈」→ 归一 "☐"；是文件 chip 等其他附件 → 不当列表标记
    /// （否则回车续行/待办高亮会误伤文件附件）；文本符号前缀匹配；编号正则 ^\d+\.
    static func existingMarker(_ line: String,
                               attLine: NSAttributedString? = nil) -> (marker: String?, rest: String) {
        if line.hasPrefix(checkPlaceholder) {
            if let a = attLine, a.length > 0,
               !(a.attribute(.attachment, at: 0, effectiveRange: nil) is MuseCheckAttachment) {
                return (nil, line)   // 行首是文件 chip 等，不是清单圈
            }
            let after = String(line.dropFirst(1))
            // 旧数据圈后带空格，一并吃掉
            return ("☐", after.hasPrefix(" ") ? String(after.dropFirst(1)) : after)
        }
        for m in plainMarkers where line.hasPrefix(m + " ") {
            return (m, String(line.dropFirst(m.count + 1)))
        }
        if let r = line.range(of: #"^\d+\.\s"#, options: .regularExpression) {
            return ("1.", String(line[r.upperBound...]))
        }
        return (nil, line)
    }

    /// 光标所在行首行标记（供状态显示/打勾）；已勾/旧圈符号归一为「☐」
    static func markerOf(currentLine line: String,
                         attLine: NSAttributedString? = nil) -> String {
        let m = existingMarker(line, attLine: attLine).marker ?? ""
        return (m == "☑" || m == "✓" || m == "◯") ? "☐" : m
    }

    static func belongs(_ marker: String?, to style: ListStyle) -> Bool {
        switch style {
        case .bullet: return marker == "•"
        case .hollow: return marker == "○"
        case .dash: return marker == "–"
        case .ordered: return marker == "1."
        case .check: return marker == "☐" || marker == "☑" || marker == "✓" || marker == "◯"
        case .quote: return false   // quote 走缩进判定，不参与前缀 toggle
        }
    }

    /// 未勾清单圈：可点击附件。圈与文字的间距由圈图右侧留白控制，正文不加空格。
    /// 圈字符自带正文默认字体+行距：插入即与正文行盒一致，不会等 enforce 兜底。
    static func checkUncheckedMarker(font: NSFont?) -> NSAttributedString {
        markerAttr(MuseCheckAttachment(checked: false, font: font), font: font)
    }

    /// 已勾清单圈：蓝色实心圆 + 白色对勾（可点击附件）
    static func checkCheckedMarker(font: NSFont?) -> NSAttributedString {
        markerAttr(MuseCheckAttachment(checked: true, font: font), font: font)
    }

    /// 圈附件字符的完整属性：正文字体 + 统一行距（行盒几何与正文一致）
    private static func markerAttr(_ att: MuseCheckAttachment, font: NSFont?) -> NSAttributedString {
        var a = MuseRichText.defaultBodyAttrs()
        if let f = font { a[.font] = f }
        a[.attachment] = att
        return NSAttributedString(string: "\u{FFFC}", attributes: a)
    }

    /// 行首标记的字符长度：清单圈 = 1（无尾随空格）；文本标记 = 符号 + 1 空格
    static func markerLength(_ marker: String) -> Int {
        marker == museAttachmentMarker ? 1 : marker.count + 1
    }

    /// 对当前段落（含多行选区的每一行）应用列表样式；
    /// 首行已属于同一样式 → 移除标记（toggle 关闭）。
    /// 正文部分取原 attributed 子串重建，不丢失加粗等格式。
    static func applyList(_ tv: NSTextView, _ style: ListStyle) {
        focusTextView(tv)
        // 块引用 = 段落左缩进，不走行首前缀逻辑
        if style == .quote {
            toggleQuote(tv)
            return
        }
        guard let s = tv.textStorage, s.length > 0 else {
            // 空文档：直接插入一行带标记的开头（带正文默认属性，避免 12pt 残留）
            let attrs = MuseRichText.defaultBodyAttrs()
            let head: NSAttributedString = switch style {
            case .bullet: NSAttributedString(string: "• ", attributes: attrs)
            case .hollow: NSAttributedString(string: "○ ", attributes: attrs)
            case .dash: NSAttributedString(string: "– ", attributes: attrs)
            case .ordered: NSAttributedString(string: "1. ", attributes: attrs)
            case .check: checkUncheckedMarker(font: tv.font)
            case .quote: NSAttributedString(string: "")
            }
            tv.insertText(head, replacementRange: tv.selectedRange())
            return
        }
        let str = s.string as NSString
        let sel = tv.selectedRange()
        let loc = min(sel.location, s.length - 1)
        let len = sel.length == 0 ? 0 : min(sel.length, s.length - loc)
        let paraRange = str.paragraphRange(for: NSRange(location: loc, length: len))
        let paraAtt = s.attributedSubstring(from: paraRange)
        let paraText = paraAtt.string
        var lines = paraText.components(separatedBy: "\n")
        let hadTrailingNewline = lines.last?.isEmpty == true
        if hadTrailingNewline { lines.removeLast() }
        guard !lines.isEmpty else { return }

        // 首行已属于同一样式 → 整体移除标记（再点一次 = 取消列表）
        let turningOff = belongs(existingMarker(lines[0], attLine: paraAtt).marker, to: style)
        var orderedIndex = 0
        var offset = 0
        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            let lineLen = (line as NSString).length
            let lineAtt = paraAtt.attributedSubstring(
                from: NSRange(location: offset, length: lineLen))
            let (m, _) = existingMarker(line, attLine: lineAtt)
            let wasChecked: Bool
            if m == "☑" || m == "✓" {
                wasChecked = true
            } else if lineAtt.length > 0,
                      let chk = lineAtt.attribute(.attachment, at: 0,
                                                  effectiveRange: nil) as? MuseCheckAttachment {
                wasChecked = chk.checked
            } else {
                wasChecked = false
            }
            let mLen = m != nil ? markerLength(m!) : 0
            let body = lineAtt.attributedSubstring(
                from: NSRange(location: mLen, length: max(0, lineLen - mLen)))
            // 空行不加列表前缀（避免"光标行上方冒出空圈"的 bug）
            let isEmptyLine = m == nil && line.trimmingCharacters(in: .whitespaces).isEmpty

            if turningOff || isEmptyLine {
                out.append(body)
            } else {
                orderedIndex += 1
                let attrs = MuseRichText.defaultBodyAttrs()
                switch style {
                case .bullet: out.append(NSAttributedString(string: "• ", attributes: attrs))
                case .hollow: out.append(NSAttributedString(string: "○ ", attributes: attrs))
                case .dash: out.append(NSAttributedString(string: "– ", attributes: attrs))
                case .ordered: out.append(NSAttributedString(string: "\(orderedIndex). ", attributes: attrs))
                case .check:
                    // 已是清单行则保持原勾选状态，否则新建为未勾
                    out.append(wasChecked ? checkCheckedMarker(font: tv.font)
                                          : checkUncheckedMarker(font: tv.font))
                case .quote:
                    break   // quote 已在入口提前处理，不会走到这里
                }
                out.append(body)
            }
            if i < lines.count - 1 || hadTrailingNewline {
                out.append(NSAttributedString(string: "\n"))
            }
            offset += lineLen + 1
        }
        s.replaceCharacters(in: paraRange, with: out)
        tv.didChangeText()
        tv.needsDisplay = true
        Log.shared.info("muse format | list style=\(style) off=\(turningOff)")
    }

    /// 「制作核对清单」按钮：行级语义——只作用于光标所在行，
    /// 非清单行 → 行首插入未勾圈（不跑到别的行去）；已是清单行 → 移除圈。
    /// 创建后光标自动移到该行行尾（圈 + 空格之后），对齐备忘录体验。
    /// 打勾/取消打勾由点击正文里的圈完成（见 MuseTextView.mouseDown）。
    static func toggleChecklist(_ tv: NSTextView) {
        focusTextView(tv)
        guard let s = tv.textStorage, s.length > 0 else {
            // 空文档：插入圈，光标停在圈后
            tv.insertText(checkUncheckedMarker(font: tv.font),
                          replacementRange: tv.selectedRange())
            return
        }
        let str = s.string as NSString
        // 真实光标位置定位段落（文末空行不越到上一行）
        let paraRange = str.paragraphRange(for: NSRange(location: tv.selectedRange().location, length: 0))
        let paraAtt = s.attributedSubstring(from: paraRange)
        let line = paraAtt.string
        let hadNL = line.hasSuffix("\n")
        let coreLen = paraAtt.length - (hadNL ? 1 : 0)
        let core = paraAtt.attributedSubstring(from: NSRange(location: 0, length: coreLen))
        let (m, rest) = existingMarker(line, attLine: paraAtt)

        let out = NSMutableAttributedString()
        if belongs(m, to: .check) {
            // 已是清单行 → 移除行首标记（新格式圈=1 单元，旧格式圈+空格=2 单元）
            let removeLen = min(coreLen - (rest as NSString).length, coreLen)
            out.append(core.attributedSubstring(
                from: NSRange(location: removeLen, length: coreLen - removeLen)))
        } else {
            // 非清单行 → 行首插入未勾圈；若已有其他标记先移除
            let mLen = m != nil ? markerLength(m!) : 0
            out.append(checkUncheckedMarker(font: tv.font))
            out.append(core.attributedSubstring(
                from: NSRange(location: mLen, length: max(0, coreLen - mLen))))
        }
        if hadNL { out.append(NSAttributedString(string: "\n")) }
        s.replaceCharacters(in: paraRange, with: out)
        // 创建后光标移到行尾（圈右侧待输入）；取消后停在行首
        let caret = paraRange.location + (belongs(m, to: .check) ? 0 : out.length - (hadNL ? 1 : 0))
        tv.setSelectedRange(NSRange(location: min(caret, s.length), length: 0))
        tv.didChangeText()
        tv.needsDisplay = true
        Log.shared.info("muse format | checklist toggle line")
    }

    /// 点击正文里的清单圈：切换勾/未勾
    static func toggleCheck(at attachmentRange: NSRange, in tv: NSTextView) {
        guard let s = tv.textStorage,
              let att = s.attribute(.attachment, at: attachmentRange.location,
                                    effectiveRange: nil) as? MuseCheckAttachment else { return }
        // 用光标处正文字体重建圈，保证行盒与正文一致
        let after = min(attachmentRange.location + 1, s.length - 1)
        let bodyFont = (s.length > 0
            ? s.attribute(.font, at: max(0, after), effectiveRange: nil) as? NSFont : nil)
            ?? tv.font
        let replacement = NSAttributedString(
            attachment: MuseCheckAttachment(checked: !att.checked, font: bodyFont))
        s.replaceCharacters(in: attachmentRange, with: replacement)
        tv.didChangeText()
        tv.needsDisplay = true
    }

    /// 首行缩进切换：当前段落 firstLineHeadIndent 0 ↔ 24
    static func toggleIndent(_ tv: NSTextView) {
        focusTextView(tv)
        let current = (currentAttributes(tv)[.paragraphStyle] as? NSParagraphStyle)
            ?? NSParagraphStyle.default
        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(current)
        let turnOn = current.firstLineHeadIndent <= 0
        style.firstLineHeadIndent = turnOn ? 24 : 0
        applyAttribute(.paragraphStyle, value: style, tv: tv)
        Log.shared.info("muse format | indent \(turnOn ? "on" : "off")")
    }

    /// 块引用（左缩进）切换：只动 headIndent，保留 firstLineHeadIndent，
    /// 与「首行缩进」的高亮状态互不串扰
    static func toggleQuote(_ tv: NSTextView) {
        focusTextView(tv)
        // 判断当前段落是否已引用缩进
        let current = (currentAttributes(tv)[.paragraphStyle] as? NSParagraphStyle)
            ?? NSParagraphStyle.default
        let isIndented = current.headIndent >= 20

        let style = NSMutableParagraphStyle()
        style.setParagraphStyle(current)
        style.paragraphSpacing = 4
        style.headIndent = isIndented ? 0 : 24
        applyAttribute(.paragraphStyle, value: style, tv: tv)
        Log.shared.info("muse format | quote toggle indent=\(isIndented ? "off" : "on")")
    }
}
