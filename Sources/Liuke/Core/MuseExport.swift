import Foundation
import AppKit

// MARK: - 随想导出（Markdown / PDF / 原始文件）
//
// 设计原则：
// - 不修改任何原始数据；导出只读取当前笔记（磁盘 + 编辑器实时内容）。
// - Markdown：正文转标准 MD，图片/文件附件作为独立文件复制到 assets/，用相对路径引用，绝不用 Base64。
// - PDF：用 TextKit 分页渲染，图片内嵌；文件附件在正文里以 chip（图标+文件名）形式呈现，不嵌入原始二进制。
// - 原始文件：完整复制 notes/{id}/ 目录为 ZIP（note.json + content.rtfd + attachments/）。

enum MuseExport {

    /// Markdown 导出时随图片/附件一起携带的资源（磁盘原始文件，用于复制）
    struct ExportAsset {
        let name: String      // 写入 assets/ 的文件名（已清洗、保证唯一）
        let url: URL          // 原始文件磁盘路径（从随想 attachments/ 读取）
        let isImage: Bool     // true=图片（![..]）；false=文件附件（[..]）
    }

    // MARK: - 富文本 → Markdown

    /// 把富文本转换为 Markdown，并返回需要写入 assets/ 的资源列表。
    /// `diskAttachments` 为当前笔记磁盘附件（顺序 = 正文中非清单附件的出现顺序），
    /// 用于把正文里的图片/文件 chip 映射到原始文件（保留原文件名与格式）。
    static func buildMarkdown(title: String,
                              attributed att: NSAttributedString,
                              diskAttachments: [(MuseAttachment, URL)]) -> (md: String, assets: [ExportAsset]) {
        var assets: [ExportAsset] = []
        var assetCounter = 0
        var usedNames = Set<String>()

        var md = "# \(title)\n\n"
        let str = att.string as NSString
        var idx = 0
        let total = att.length

        while idx < total {
            let paraRange = str.paragraphRange(for: NSRange(location: idx, length: 0))
            let paraAtt = att.attributedSubstring(from: paraRange)
            let paraLen = paraAtt.length

            // 段落级样式（取自首字符属性）
            var fontSize: CGFloat = 14.5
            var headIndent: CGFloat = 0
            if paraLen > 0 {
                let a = paraAtt.attributes(at: 0, effectiveRange: nil)
                fontSize = (a[.font] as? NSFont)?.pointSize ?? 14.5
                headIndent = (a[.paragraphStyle] as? NSParagraphStyle)?.headIndent ?? 0
            }
            let isQuote = headIndent >= 20
            let headingPrefix = fontSize >= 22 ? "# " : (fontSize >= 17 ? "## " : "")

            // 行首清单圈（可点击附件）→ 核对清单标记，不当普通附件
            var checklistPrefix = ""
            var firstRunIsAttachment = false
            if paraLen > 0,
               let att0 = paraAtt.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment {
                firstRunIsAttachment = true
                if let chk = att0 as? MuseCheckAttachment {
                    checklistPrefix = chk.checked ? "- [x] " : "- [ ] "
                }
            }

            // 行首文本列表标记（• / – / 编号）→ 映射为 MD 前缀
            var listPrefix = ""
            var skipChars = 0
            if !firstRunIsAttachment {
                let pstr = paraAtt.string
                if pstr.hasPrefix("• ") || pstr.hasPrefix("○ ") {
                    listPrefix = "- "; skipChars = 2
                } else if pstr.hasPrefix("– ") {
                    listPrefix = "- "; skipChars = 2
                } else if let r = pstr.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                    listPrefix = String(pstr[r]); skipChars = r.upperBound.utf16Offset(in: pstr)
                }
            }

            // 逐 run 拼装正文（处理内联样式 + 附件）
            var content = ""
            var consumed = 0
            paraAtt.enumerateAttributes(in: NSRange(location: 0, length: paraLen), options: []) { attrs, range, _ in
                // 附件（图片 / 文件 chip）
                if let attachment = attrs[.attachment] as? NSTextAttachment {
                    if attachment is MuseCheckAttachment { return }   // 清单圈已在段落级处理
                    if attachment is MuseDividerAttachment {         // 分割线 → Markdown 主题分隔符
                        content += "\n---\n"
                        return
                    }
                    guard assetCounter < diskAttachments.count else { return }
                    let (meta, url) = diskAttachments[assetCounter]
                    assetCounter += 1
                    let isImage = !(attachment is MuseFileChipAttachment) && attachment.image != nil
                    let base = sanitizeFileName(meta.name)
                    let finalName = uniqueName(base, used: &usedNames)
                    assets.append(ExportAsset(name: finalName, url: url, isImage: isImage))
                    content += isImage
                        ? "![\(meta.name)](assets/\(finalName))"
                        : "[\(meta.name)](assets/\(finalName))"
                    return
                }

                // 文本 run
                var text = paraAtt.attributedSubstring(from: range).string
                if consumed == 0, skipChars > 0 {
                    let drop = min(skipChars, text.count)
                    text = String(text.dropFirst(drop))
                    skipChars -= drop
                }
                consumed += range.length
                guard !text.isEmpty else { return }

                let font = attrs[.font] as? NSFont
                let bold = font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
                let italic = (attrs[.obliqueness] as? Double ?? 0) != 0
                let strike = (attrs[.strikethroughStyle] as? Int ?? 0) != 0

                var pre = "", post = ""
                pre += strike ? "~~" : ""
                if bold, italic { pre += "***"; post = "***" + post }
                else if bold { pre += "**"; post = "**" + post }
                else if italic { pre += "*"; post = "*" + post }

                content += pre + text + post
            }

            let linePrefix = headingPrefix + (isQuote ? "> " : "") + checklistPrefix + listPrefix
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty, checklistPrefix.isEmpty, listPrefix.isEmpty {
                // 完全空段落：跳过，不堆空白行
            } else {
                md += linePrefix + content + "\n\n"
            }

            idx = NSMaxRange(paraRange)
        }

        md = md.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        return (md, assets)
    }

    /// 把 Markdown 与 assets 写入 `parent/{标题}/` 目录（{标题}.md + assets/）
    static func writeMarkdown(parent: URL, displayTitle: String, md: String, assets: [ExportAsset]) -> Bool {
        let fm = FileManager.default
        let dirName = sanitizeFolder(displayTitle)
        let dir = parent.appendingPathComponent(dirName)
        let assetsDir = dir.appendingPathComponent("assets")
        do {
            try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
            try md.write(to: dir.appendingPathComponent("\(dirName).md"), atomically: true, encoding: .utf8)
            for a in assets {
                let dest = assetsDir.appendingPathComponent(a.name)
                try? fm.removeItem(at: dest)
                try fm.copyItem(at: a.url, to: dest)
            }
            return true
        } catch {
            Log.shared.error("muse md export failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 富文本 → PDF

    /// 用 TextKit 分页渲染 PDF（A4，标题 + 正文）。
    /// 关键点：PDF 上下文默认 y 轴向上，而正文按 y 轴向下排版。
    /// 必须把原点移到内容区左上角并上下翻转（translate + scaleBy y:-1），
    /// 配合 flipped:true 的 NSGraphicsContext，文字与图片附件才会正向渲染，
    /// 否则会出现「文字反向 / 整页反向」。
    static func makePDF(title: String, attributed att: NSAttributedString) -> Data? {
        if Thread.isMainThread {
            return _renderPDF(title: title, att: att)
        }
        return DispatchQueue.main.sync { _renderPDF(title: title, att: att) }
    }

    private static func _renderPDF(title: String, att: NSAttributedString) -> Data? {
        let pageW: CGFloat = 595.28, pageH: CGFloat = 841.89   // A4 (pt)
        let margin: CGFloat = 56
        let contentW = pageW - margin * 2
        let contentH = pageH - margin * 2
        let scale: CGFloat = 2   // 位图 2x，保证清晰度

        let full = NSMutableAttributedString()
        full.append(NSAttributedString(string: title, attributes: [
            .font: NSFont.boldSystemFont(ofSize: 22),
            .foregroundColor: NSColor.textColor
        ]))
        full.append(NSAttributedString(string: "\n\n"))
        full.append(att)

        let ts = NSTextStorage(attributedString: full)
        let lm = NSLayoutManager()
        ts.addLayoutManager(lm)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return nil }
        var mediaBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        guard let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        let totalGlyphs = lm.numberOfGlyphs
        var glyphIndex = 0
        var drewAny = false
        while glyphIndex < totalGlyphs {
            let tc = NSTextContainer(size: CGSize(width: contentW, height: contentH))
            tc.lineFragmentPadding = 0
            lm.addTextContainer(tc)
            let glyphRange = lm.glyphRange(for: tc)
            if glyphRange.length == 0 { break }

            // ── 先把这一页渲染到位图（2x），再嵌入 PDF ──
            // PDF 上下文直接 drawGlyphs 会触发彩色字体渲染（RGB 色散）；
            // 位图上下文关闭字体平滑后以灰度抗锯齿渲染，彻底无彩虹纹。
            let pxW = Int(contentW * scale)
            let pxH = Int(contentH * scale)
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                       pixelsWide: pxW, pixelsHigh: pxH,
                                       bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            let repGraphics = NSGraphicsContext(bitmapImageRep: rep)!
            let bitmapCG = repGraphics.cgContext
            // 位图上下文原点左下；放大 2x 后把原点移到内容区左上、y 向下
            bitmapCG.scaleBy(x: scale, y: scale)
            bitmapCG.translateBy(x: 0, y: contentH)
            bitmapCG.scaleBy(x: 1, y: -1)
            bitmapCG.setShouldSmoothFonts(false)
            bitmapCG.setAllowsFontSmoothing(false)
            bitmapCG.setShouldSubpixelPositionFonts(false)
            bitmapCG.setShouldSubpixelQuantizeFonts(false)
            bitmapCG.setShouldAntialias(true)

            let nsCtx = NSGraphicsContext(cgContext: bitmapCG, flipped: true)
            nsCtx.shouldAntialias = true
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsCtx
            // 白底
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: contentW, height: contentH).fill()
            // flipped:true 让文字与图片附件都按正向绘制（不再反向）
            lm.drawGlyphs(forGlyphRange: glyphRange, at: CGPoint(x: 0, y: 0))
            NSGraphicsContext.restoreGraphicsState()

            // ── 位图 → PDF 页 ──
            ctx.beginPDFPage(nil)
            if let img = rep.cgImage {
                ctx.interpolationQuality = .high
                ctx.draw(img, in: CGRect(x: margin, y: margin,
                                         width: contentW, height: contentH))
            }
            ctx.endPDFPage()

            glyphIndex = NSMaxRange(glyphRange)
            drewAny = true
        }
        ctx.closePDF()
        return drewAny ? data as Data : nil
    }

    // MARK: - 原始文件 → ZIP

    /// 把整篇随想目录（note.json + content.rtfd + attachments/）打包为 ZIP。
    static func zipNoteDir(_ noteDir: URL, title: String, to destURL: URL) -> Bool {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("liuke-export-\(UUID().uuidString)")
        let srcFolder = tmp.appendingPathComponent(sanitizeFolder(title))
        do {
            try fm.createDirectory(at: srcFolder, withIntermediateDirectories: true)
            let contents = try fm.contentsOfDirectory(at: noteDir, includingPropertiesForKeys: nil)
            for c in contents {
                try fm.copyItem(at: c, to: srcFolder.appendingPathComponent(c.lastPathComponent))
            }
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            proc.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", srcFolder.path, destURL.path]
            try proc.run()
            proc.waitUntilExit()
            try? fm.removeItem(at: tmp)
            return proc.terminationStatus == 0
        } catch {
            Log.shared.error("muse raw export failed: \(error.localizedDescription)")
            try? fm.removeItem(at: tmp)
            return false
        }
    }

    // MARK: - 文件名清洗

    static func sanitizeFolder(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = t.replacingOccurrences(of: "/", with: "-")
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: "\\", with: "-")
        return cleaned.isEmpty ? "随想" : cleaned
    }

    static func sanitizeFileName(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:")
        let cleaned = s.components(separatedBy: invalid).joined(separator: "-")
        return cleaned.isEmpty ? "file" : cleaned
    }

    static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        var n = name
        var i = 2
        while used.contains(n) {
            let ext = (name as NSString).pathExtension
            let base = (name as NSString).deletingPathExtension
            n = ext.isEmpty ? "\(base)-\(i)" : "\(base)-\(i).\(ext)"
            i += 1
        }
        used.insert(n)
        return n
    }
}
