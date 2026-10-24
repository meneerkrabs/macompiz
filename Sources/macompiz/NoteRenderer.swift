import AppKit

// Renders a note (faux titlebar + markdown body) into an NSImage. We keep our
// own tiny line-based markdown parser so headings render big like the video,
// while inline **bold** / *italic* / `code` come from Foundation's parser.
enum NoteRenderer {

    static func image(title: String, body: String, size: CGSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            img.unlockFocus(); return img
        }

        // card background
        let rect = CGRect(origin: .zero, size: size)
        let radius: CGFloat = 12
        let card = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1),
                                xRadius: radius, yRadius: radius)
        NSColor.white.setFill()
        card.fill()

        // titlebar
        let barH: CGFloat = 30
        let barRect = CGRect(x: 0, y: size.height - barH, width: size.width, height: barH)
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSBezierPath(rect: barRect).fill()

        let dotY = size.height - barH / 2 - 6
        let colors: [NSColor] = [NSColor(srgbRed: 1.0, green: 0.37, blue: 0.35, alpha: 1),
                                 NSColor(srgbRed: 1.0, green: 0.74, blue: 0.18, alpha: 1),
                                 NSColor(srgbRed: 0.24, green: 0.79, blue: 0.25, alpha: 1)]
        for (i, c) in colors.enumerated() {
            c.setFill()
            NSBezierPath(ovalIn: CGRect(x: 14 + CGFloat(i) * 20, y: dotY, width: 12, height: 12)).fill()
        }
        let tAttr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 0.4, alpha: 1)]
        let tStr = NSAttributedString(string: title, attributes: tAttr)
        tStr.draw(at: CGPoint(x: size.width / 2 - tStr.size().width / 2, y: dotY - 1))

        // body
        drawBody(body, in: CGRect(x: 22, y: 16, width: size.width - 44,
                                  height: size.height - barH - 28), ctx: ctx)

        _ = ctx
        img.unlockFocus()
        return img
    }

    private static func drawBody(_ body: String, in rect: CGRect, ctx: CGContext) {
        let full = NSMutableAttributedString()
        let mono = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine
            let attr: NSMutableAttributedString

            if line.hasPrefix("# ") {
                attr = NSMutableAttributedString(string: String(line.dropFirst(2)), attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 22, weight: .bold),
                    .foregroundColor: NSColor.black])
            } else if line.hasPrefix("## ") {
                attr = NSMutableAttributedString(string: String(line.dropFirst(3)), attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 17, weight: .bold),
                    .foregroundColor: NSColor.black])
            } else {
                attr = inlineMarkdown(line, base: mono)
            }
            attr.append(NSAttributedString(string: "\n"))
            full.append(attr)
        }

        let para = NSMutableParagraphStyle()
        para.lineSpacing = 4
        para.paragraphSpacing = 6
        full.addAttribute(.paragraphStyle, value: para,
                          range: NSRange(location: 0, length: full.length))

        let flipped = CGRect(x: rect.minX,
                             y: ctx.height.cg - rect.maxY,
                             width: rect.width, height: rect.height)
        NSGraphicsContext.saveGraphicsState()
        full.draw(with: CGRect(origin: CGPoint(x: flipped.minX, y: 0),
                               size: CGSize(width: rect.width, height: rect.maxY - 8)),
                  options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
    }

    // **bold**, *italic*, `code` via Foundation's inline markdown parser,
    // re-styled onto our monospace base font.
    private static func inlineMarkdown(_ line: String, base: NSFont) -> NSMutableAttributedString {
        guard let parsed = try? AttributedString(
            markdown: line,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return NSMutableAttributedString(string: line, attributes: [.font: base,
                                             .foregroundColor: NSColor.black])
        }
        let out = NSMutableAttributedString()
        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            var font = base
            var color = NSColor.black
            let intent = run.inlinePresentationIntent ?? []
            if intent.contains(.stronglyEmphasized) {
                font = NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .bold)
            }
            if intent.contains(.emphasized) {
                let fm = NSFontManager.shared
                font = fm.convert(font, toHaveTrait: .italicFontMask)
            }
            if intent.contains(.code) {
                color = NSColor(srgbRed: 0.0, green: 0.3, blue: 0.75, alpha: 1)
            }
            out.append(NSAttributedString(string: text,
                        attributes: [.font: font, .foregroundColor: color]))
        }
        return out
    }
}

private extension Int {
    var cg: CGFloat { CGFloat(self) }
}
