import CoreGraphics
import CoreText
import Foundation

/// The static chart, as a PNG and a PDF: every screen at once, for a document, a
/// message or a printout. Drawn with Core Graphics, so it needs nothing installed.
public struct Chart {
    private let graph: AtlasGraph
    private let run: CaptureRun?
    private let layout: AtlasLayout
    private let paths: Paths
    private let headerHeight: CGFloat = 112

    public init(graph: AtlasGraph, run: CaptureRun?, layout: AtlasLayout, paths: Paths) {
        self.graph = graph
        self.run = run
        self.layout = layout
        self.paths = paths
    }

    public func write() throws {
        let size = CGSize(
            width: max(layout.size.width, 900),
            height: layout.size.height + headerHeight
        )
        // Sharp in a card at 2×, and no sharper: this is what keeps the PDF small.
        var images: [String: CGImage] = [:]
        for node in graph.nodes {
            guard let file = run?.results[node.id]?.file else { continue }
            let url = paths.screens.appendingPathComponent(file)
            images[node.id] = Images.load(url, maxPixels: 1000)
        }

        try writePNG(size: size, images: images)
        try writePDF(size: size, images: images)
    }

    private func writePNG(size: CGSize, images: [String: CGImage]) throws {
        // A big map must still come out, so the scale gives way before the size limit.
        let scale = min(2, 16000 / max(size.width, size.height))
        let width = Int(size.width * scale), height = Int(size.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw AtlasError("Couldn't create a \(width)×\(height) image.") }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        draw(in: context, size: size, images: images)
        guard let image = context.makeImage(), let data = Images.png(image) else {
            throw AtlasError("Couldn't encode the chart as a PNG.")
        }
        try data.write(to: paths.chartPNG)
    }

    private func writePDF(size: CGSize, images: [String: CGImage]) throws {
        var box = CGRect(origin: .zero, size: size)
        guard let context = CGContext(paths.chartPDF as CFURL, mediaBox: &box, nil) else {
            throw AtlasError("Couldn't create \(paths.chartPDF.path).")
        }
        context.beginPDFPage(nil)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        draw(in: context, size: size, images: images)
        context.endPDFPage()
        context.closePDF()
    }

    // MARK: - Drawing

    private func draw(in context: CGContext, size: CGSize, images: [String: CGImage]) {
        context.setFillColor(Palette.background)
        context.fill(CGRect(origin: .zero, size: size))
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)

        drawHeader(in: context, size: size)

        context.saveGState()
        context.translateBy(x: (size.width - layout.size.width) / 2, y: headerHeight)
        // Cards first: an arrow starting on a screen is drawn over its screenshot.
        for node in graph.nodes {
            if let frame = layout.frames[node.id] {
                drawCard(node, frame: frame, image: images[node.id], in: context)
            }
        }
        for routed in layout.edges { drawEdge(routed, in: context) }
        for routed in layout.edges { drawOrigin(routed, in: context) }
        for routed in layout.edges { drawLabel(routed, in: context) }
        context.restoreGState()
    }

    private func drawHeader(in context: CGContext, size: CGSize) {
        let left: CGFloat = AtlasLayout.margin
        drawText(graph.name, at: CGPoint(x: left, y: 54), font: Fonts.title, color: Palette.ink, in: context)
        var details = ["\(graph.nodes.count) screens", "\(graph.edges.count) connections"]
        if let device = run?.device { details.append(device) }
        if let runtime = run?.runtime { details.append(runtime) }
        if let commit = run?.commit { details.append(commit) }
        if let date = run?.capturedAt {
            details.append(date.formatted(date: .abbreviated, time: .shortened))
        }
        drawText(
            details.joined(separator: " · "), at: CGPoint(x: left, y: 78),
            font: Fonts.body, color: Palette.muted, in: context
        )

        // The legend, against the right edge, for only what this chart draws.
        var x = size.width - AtlasLayout.margin
        for (name, kind, isBack) in [
            ("Back", EdgeKind.push, true), ("Full screen", EdgeKind.cover, false),
            ("Sheet", EdgeKind.sheet, false), ("Push", EdgeKind.push, false),
        ] where layout.edges.contains(where: { $0.isBack == isBack && (isBack || $0.edge.kind == kind) }) {
            let width = textWidth(name, font: Fonts.small)
            x -= width
            drawText(name, at: CGPoint(x: x, y: 52), font: Fonts.small, color: Palette.muted, in: context)
            x -= 40
            context.saveGState()
            applyStroke(kind: kind, isBack: isBack, in: context)
            context.move(to: CGPoint(x: x, y: 48))
            context.addLine(to: CGPoint(x: x + 32, y: 48))
            context.strokePath()
            context.restoreGState()
            x -= 22
        }
    }

    private func applyStroke(kind: EdgeKind, isBack: Bool, in context: CGContext) {
        // One quiet colour, with the dash saying how a screen is presented.
        context.setStrokeColor(Palette.line)
        context.setFillColor(Palette.line)
        context.setLineWidth(1.25)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch kind {
        case _ where isBack: context.setLineDash(phase: 0, lengths: [1.5, 4])
        case .sheet: context.setLineDash(phase: 0, lengths: [5, 4])
        case .cover: context.setLineDash(phase: 0, lengths: [11, 4])
        case .push, .tab: context.setLineDash(phase: 0, lengths: [])
        }
    }

    private func drawEdge(_ routed: AtlasLayout.RoutedEdge, in context: CGContext) {
        guard let first = routed.curves.first, let last = routed.curves.last else { return }
        context.saveGState()
        applyStroke(kind: routed.edge.kind, isBack: routed.isBack, in: context)
        context.move(to: first.start)
        for curve in routed.curves {
            context.addCurve(to: curve.end, control1: curve.control1, control2: curve.control2)
        }
        context.strokePath()

        // The arrowhead, turned along the curve's last stretch.
        let angle = atan2(last.end.y - last.control2.y, last.end.x - last.control2.x)
        let length: CGFloat = 8, spread: CGFloat = 0.5
        context.setLineDash(phase: 0, lengths: [])
        context.setLineWidth(1.5)
        context.move(to: CGPoint(
            x: last.end.x - length * cos(angle - spread), y: last.end.y - length * sin(angle - spread)
        ))
        context.addLine(to: last.end)
        context.addLine(to: CGPoint(
            x: last.end.x - length * cos(angle + spread), y: last.end.y - length * sin(angle + spread)
        ))
        context.strokePath()
        context.restoreGState()
    }

    /// The dot on the element an arrow starts from.
    private func drawOrigin(_ routed: AtlasLayout.RoutedEdge, in context: CGContext) {
        guard let origin = routed.origin else { return }
        let dot = CGRect(x: origin.x - 3.5, y: origin.y - 3.5, width: 7, height: 7)
        context.setFillColor(Palette.line)
        context.fillEllipse(in: dot)
        context.setStrokeColor(Palette.card)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [])
        context.strokeEllipse(in: dot)
    }

    private func drawLabel(_ routed: AtlasLayout.RoutedEdge, in context: CGContext) {
        guard let label = routed.edge.label else { return }
        let width = min(textWidth(label, font: Fonts.small) + 10, 180)
        let rect = CGRect(
            x: routed.labelCenter.x - width / 2, y: routed.labelCenter.y - 8, width: width, height: 16
        )
        context.addPath(CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.setFillColor(Palette.background)
        context.fillPath()
        drawText(
            label, at: CGPoint(x: rect.minX + 5, y: rect.midY + 3.5), font: Fonts.small, color: Palette.muted,
            in: context, maxWidth: width - 10
        )
    }

    private func drawCard(_ node: AtlasGraph.Node, frame: CGRect, image: CGImage?, in context: CGContext) {
        let result = run?.results[node.id]
        let captured = result?.status == "ok"

        let phone = AtlasLayout.phone(in: frame)

        // The title sits under the phone, leaving its top clear for arriving arrows.
        let titleWidth = min(textWidth(node.title, font: Fonts.caption), frame.width)
        drawText(
            node.title, at: CGPoint(x: frame.midX - titleWidth / 2, y: phone.maxY + 21), font: Fonts.caption,
            color: captured ? Palette.ink : Palette.failure, in: context, maxWidth: frame.width
        )

        let path = CGPath(roundedRect: phone, cornerWidth: 30, cornerHeight: 30, transform: nil)

        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 8), blur: 22, color: Palette.shadow)
        context.addPath(path)
        context.setFillColor(Palette.card)
        context.fillPath()
        context.restoreGState()

        context.saveGState()
        context.addPath(path)
        context.clip()
        if let image, captured || result != nil {
            // Core Graphics draws images upright in its own coordinates, and this
            // context is flipped, so the image gets flipped back.
            context.saveGState()
            context.translateBy(x: phone.minX, y: phone.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: phone.size))
            context.restoreGState()
        }
        if !captured { drawUncaptured(node, result: result, in: phone, context: context, hasImage: image != nil) }
        context.restoreGState()

        context.addPath(path)
        context.setStrokeColor(Palette.frame)
        context.setLineWidth(0.5)
        context.strokePath()
    }

    /// A screen without a picture stays on the chart, saying why. A blank spot would
    /// read as a screen that is blank; a missing one, as a screen that doesn't exist.
    private func drawUncaptured(
        _ node: AtlasGraph.Node, result: CaptureResult?, in phone: CGRect, context: CGContext, hasImage: Bool
    ) {
        let heading: String
        let note: String
        if let skip = node.skip {
            heading = "Skipped"
            note = skip
        } else if let result {
            heading = result.status == "crashed" ? "Crashed" : "Didn't get there"
            note = result.note ?? ""
        } else {
            heading = "No route yet"
            note = node.routeNote ?? ""
        }
        // A veil over a failed capture's screenshot: it shows where the run stopped,
        // and must not be mistaken for this screen.
        context.setFillColor(hasImage ? Palette.veilStrong : Palette.empty)
        context.fill(phone)
        drawText(
            heading, at: CGPoint(x: phone.minX + 16, y: phone.minY + 66), font: Fonts.heading,
            color: Palette.ink, in: context, maxWidth: phone.width - 32
        )
        var y = phone.minY + 88
        for line in wrap(note, font: Fonts.small, width: phone.width - 32).prefix(14) {
            drawText(line, at: CGPoint(x: phone.minX + 16, y: y), font: Fonts.small, color: Palette.muted, in: context)
            y += 16
        }
    }

    // MARK: - Text

    private func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
        return CTLineCreateWithAttributedString(string)
    }

    private func textWidth(_ text: String, font: CTFont) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text, font: font, color: Palette.ink), nil, nil, nil))
    }

    private func drawText(
        _ text: String, at point: CGPoint, font: CTFont, color: CGColor, in context: CGContext, maxWidth: CGFloat? = nil
    ) {
        var drawn = line(text, font: font, color: color)
        if let maxWidth, textWidth(text, font: font) > maxWidth {
            let ellipsis = line("…", font: font, color: color)
            drawn = CTLineCreateTruncatedLine(drawn, Double(maxWidth), .end, ellipsis) ?? drawn
        }
        context.textPosition = point
        CTLineDraw(drawn, context)
    }

    private func wrap(_ text: String, font: CTFont, width: CGFloat) -> [String] {
        var lines: [String] = []
        var current = ""
        for word in text.split(separator: " ") {
            let candidate = current.isEmpty ? String(word) : "\(current) \(word)"
            if textWidth(candidate, font: font) > width, !current.isEmpty {
                lines.append(current)
                current = String(word)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}

private enum Fonts {
    // Computed, because `CTFont` isn't `Sendable` and so can't be held in a global.
    static var title: CTFont { font(size: 34, bold: true) }
    static var heading: CTFont { font(size: 15, bold: true) }
    static var caption: CTFont { font(size: 13, bold: true) }
    static var body: CTFont { font(size: 13, bold: false) }
    static var small: CTFont { font(size: 11, bold: false) }

    private static func font(size: CGFloat, bold: Bool) -> CTFont {
        let base = CTFontCreateUIFontForLanguage(.system, size, nil)!
        guard bold else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
    }
}

private enum Palette {
    // Apple's semantic colours in their light appearance, to match the map.
    static let background = rgb(0.949, 0.949, 0.969)
    static let card = rgb(1, 1, 1)
    static let empty = rgb(1, 1, 1)
    static let ink = rgb(0, 0, 0)
    static let muted = rgb(0.42, 0.42, 0.44)
    static let frame = rgb(0.78, 0.78, 0.80)
    static let failure = rgb(1, 0.231, 0.188)
    static let line = rgb(0.682, 0.682, 0.698)
    static let shadow = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.12)
    static let veilStrong = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.92)

    private static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
