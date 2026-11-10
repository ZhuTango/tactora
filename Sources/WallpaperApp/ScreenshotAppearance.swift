import AppKit

/// Export styling uses source pixels, independent of the editor's zoom level.
struct ScreenshotAppearance {
    var watermark = ""
    var tiled = false
    var opacity: CGFloat = 0.35
    var background = 0
    var padding: CGFloat = 48
    var radius: CGFloat = 16
    var shadow = true

    @MainActor func render(_ image: NSImage, scale: CGFloat = 1) -> NSImage? {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let inset = background == 0 ? 0 : padding
        let width = Int(CGFloat(source.width) + inset * 2)
        let height = Int(CGFloat(source.height) + inset * 2)
        guard width > 0, height > 0, width * height <= 100_000_000,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: max(1, Int(CGFloat(width) * scale)), pixelsHigh: max(1, Int(CGFloat(height) * scale)),
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: scale, y: scale)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let bounds = NSRect(x: 0, y: 0, width: width, height: height)
        if background != 0 {
            let pairs: [(NSColor, NSColor)] = [(.systemIndigo, .systemPurple), (.systemTeal, .systemBlue), (.white, NSColor(white: 0.88, alpha: 1)), (NSColor(white: 0.12, alpha: 1), .black)]
            let pair = pairs[min(max(0, background - 1), pairs.count - 1)]
            NSGradient(starting: pair.0, ending: pair.1)?.draw(in: bounds, angle: -35)
        }
        let imageRect = NSRect(x: inset, y: inset, width: CGFloat(source.width), height: CGFloat(source.height))
        NSGraphicsContext.saveGraphicsState()
        if background != 0 && shadow {
            let drop = NSShadow()
            drop.shadowColor = .black.withAlphaComponent(0.35)
            drop.shadowBlurRadius = min(24, inset / 2)
            drop.shadowOffset = NSSize(width: 0, height: -6)
            drop.set()
            NSColor.black.setFill()
            NSBezierPath(roundedRect: imageRect, xRadius: radius, yRadius: radius).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: imageRect, xRadius: background == 0 ? 0 : radius, yRadius: background == 0 ? 0 : radius).addClip()
        NSImage(cgImage: source, size: imageRect.size).draw(in: imageRect)
        if !watermark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let fontSize = max(12, min(42, CGFloat(source.width) / 28))
            let textShadow = NSShadow()
            textShadow.shadowColor = .black.withAlphaComponent(opacity)
            textShadow.shadowBlurRadius = 2
            textShadow.shadowOffset = NSSize(width: 0, height: -1)
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: NSColor.white.withAlphaComponent(opacity), .shadow: textShadow]
            let text = String(watermark.prefix(100)) as NSString
            let textSize = text.size(withAttributes: attributes)
            if tiled {
                let stepX = max(textSize.width + 60, 160)
                let stepY = max(textSize.height + 80, 120)
                var y = imageRect.minY + 24
                while y < imageRect.maxY {
                    var x = imageRect.minX + 24
                    while x < imageRect.maxX {
                        text.draw(at: NSPoint(x: x, y: y), withAttributes: attributes)
                        x += stepX
                    }
                    y += stepY
                }
            } else {
                text.draw(in: NSRect(x: max(imageRect.minX + 8, imageRect.maxX - textSize.width - 20), y: imageRect.minY + 16,
                                    width: max(0, min(textSize.width, imageRect.width - 16)), height: textSize.height), withAttributes: attributes)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = bitmap.cgImage else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

@MainActor
final class ScreenshotAppearanceSheet: NSWindowController, NSTextFieldDelegate {
    private let source: NSImage
    private var value: ScreenshotAppearance
    private let preview = NSImageView()
    private let watermark = NSTextField()
    private let placement = NSPopUpButton()
    private let background = NSPopUpButton()
    private let opacity = NSSlider(value: 0.35, minValue: 0.1, maxValue: 1, target: nil, action: nil)
    private let padding = NSSlider(value: 48, minValue: 16, maxValue: 120, target: nil, action: nil)
    private let radius = NSSlider(value: 16, minValue: 0, maxValue: 48, target: nil, action: nil)
    private let shadow = NSButton(checkboxWithTitle: "阴影", target: nil, action: nil)
    var onApply: ((ScreenshotAppearance) -> Void)?

    init(image: NSImage, value: ScreenshotAppearance) {
        source = image
        self.value = value
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "水印与美化"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        let root = NSStackView()
        root.orientation = .vertical
        root.spacing = 12
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        panel.contentView = root
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.widthAnchor.constraint(equalToConstant: 600).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 240).isActive = true
        root.addArrangedSubview(preview)
        watermark.placeholderString = "水印文字（留空关闭，最多 100 字）"
        watermark.stringValue = value.watermark
        watermark.delegate = self
        watermark.widthAnchor.constraint(equalToConstant: 360).isActive = true
        watermark.setAccessibilityLabel("水印文字")
        placement.addItems(withTitles: ["右下角", "平铺"])
        placement.selectItem(at: value.tiled ? 1 : 0)
        background.addItems(withTitles: ["原图", "紫色渐变", "蓝色渐变", "浅色", "深色"])
        background.selectItem(at: value.background)
        opacity.doubleValue = Double(value.opacity)
        padding.doubleValue = Double(value.padding)
        radius.doubleValue = Double(value.radius)
        shadow.state = value.shadow ? .on : .off
        root.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "水印"), watermark, placement]))
        root.addArrangedSubview(row("透明度", opacity))
        root.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: "背景"), background, shadow]))
        root.addArrangedSubview(row("边距", padding))
        root.addArrangedSubview(row("圆角", radius))
        for control in [placement, background, opacity, padding, radius, shadow] as [NSControl] {
            control.target = self
            control.action = #selector(updatePreview)
        }
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "应用", target: self, action: #selector(apply))
        apply.keyEquivalent = "\r"
        root.addArrangedSubview(NSStackView(views: [cancel, apply]))
        updatePreview()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    private func row(_ name: String, _ slider: NSSlider) -> NSStackView {
        slider.widthAnchor.constraint(equalToConstant: 360).isActive = true
        slider.setAccessibilityLabel(name)
        return NSStackView(views: [NSTextField(labelWithString: name), slider])
    }
    func controlTextDidChange(_ notification: Notification) { updatePreview() }
    @objc private func updatePreview() {
        value.watermark = String(watermark.stringValue.prefix(100))
        value.tiled = placement.indexOfSelectedItem == 1
        value.background = background.indexOfSelectedItem
        value.opacity = CGFloat(opacity.doubleValue)
        value.padding = CGFloat(padding.doubleValue)
        value.radius = CGFloat(radius.doubleValue)
        value.shadow = shadow.state == .on
        let scale = min(1, 1000 / max(source.size.width + value.padding * 2, source.size.height + value.padding * 2))
        preview.image = value.render(source, scale: scale)
    }
    @objc private func cancel() { if let window { window.sheetParent?.endSheet(window) } }
    @objc private func apply() { onApply?(value); cancel() }
}
