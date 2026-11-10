import AppKit

/// Export styling uses source pixels, independent of the editor's zoom level.
struct ScreenshotAppearance {
    var watermark = ""
    var tiled = false
    var opacity: CGFloat = 0.35
    var background = 1
    var padding: CGFloat = 30
    var radius: CGFloat = 40
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
    private let padding = NSSlider(value: 30, minValue: 16, maxValue: 120, target: nil, action: nil)
    private let radius = NSSlider(value: 40, minValue: 0, maxValue: 48, target: nil, action: nil)
    private let shadow = NSButton(checkboxWithTitle: "阴影", target: nil, action: nil)
    private let opacityValue = NSTextField(labelWithString: "")
    private let paddingValue = NSTextField(labelWithString: "")
    private let radiusValue = NSTextField(labelWithString: "")
    var onApply: ((ScreenshotAppearance) -> Void)?

    init(image: NSImage, value: ScreenshotAppearance) {
        source = image
        self.value = value
        let previewHeight = min(200, max(100, 528 * image.size.height / max(1, image.size.width)))
        let size = NSSize(width: 560, height: previewHeight + 216)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "水印与美化"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        let root = NSView()
        panel.contentView = root
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        preview.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        preview.widthAnchor.constraint(equalToConstant: 528).isActive = true
        preview.heightAnchor.constraint(equalToConstant: previewHeight).isActive = true
        stack.addArrangedSubview(preview)
        watermark.placeholderString = "输入水印，留空关闭"
        watermark.stringValue = value.watermark
        watermark.delegate = self
        watermark.widthAnchor.constraint(equalToConstant: 330).isActive = true
        watermark.setAccessibilityLabel("水印文字")
        placement.addItems(withTitles: ["右下角", "平铺"])
        placement.selectItem(at: value.tiled ? 1 : 0)
        background.addItems(withTitles: ["原图", "紫色渐变", "蓝色渐变", "浅色", "深色"])
        background.selectItem(at: value.background)
        opacity.doubleValue = Double(value.opacity)
        padding.doubleValue = Double(value.padding)
        radius.doubleValue = Double(value.radius)
        shadow.state = value.shadow ? .on : .off
        func row(_ views: [NSView], height: CGFloat) -> NSStackView {
            let row = NSStackView(views: views)
            row.spacing = 8
            row.widthAnchor.constraint(equalToConstant: 528).isActive = true
            row.heightAnchor.constraint(equalToConstant: height).isActive = true
            stack.addArrangedSubview(row)
            return row
        }
        func label(_ title: String) -> NSTextField {
            let field = NSTextField(labelWithString: title)
            field.textColor = .secondaryLabelColor
            field.widthAnchor.constraint(equalToConstant: 44).isActive = true
            return field
        }
        _ = row([label("水印"), watermark, placement], height: 28)
        opacity.widthAnchor.constraint(equalToConstant: 330).isActive = true
        opacity.setAccessibilityLabel("水印透明度")
        _ = row([label("透明度"), opacity, opacityValue, NSView()], height: 22)
        background.widthAnchor.constraint(equalToConstant: 180).isActive = true
        _ = row([label("背景"), background, shadow, NSView()], height: 28)
        for (slider, text, name) in [(padding, paddingValue, "边距"), (radius, radiusValue, "圆角")] {
            slider.widthAnchor.constraint(equalToConstant: 150).isActive = true
            slider.setAccessibilityLabel(name)
            text.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            text.widthAnchor.constraint(equalToConstant: 30).isActive = true
        }
        _ = row([label("边距"), padding, paddingValue, label("圆角"), radius, radiusValue], height: 24)
        for control in [placement, background, opacity, padding, radius, shadow] as [NSControl] {
            control.target = self
            control.action = #selector(updatePreview)
        }
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "应用", target: self, action: #selector(apply))
        apply.keyEquivalent = "\r"
        _ = row([NSView(), cancel, apply], height: 32)
        panel.setContentSize(size)
        updatePreview()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    func controlTextDidChange(_ notification: Notification) { updatePreview() }
    @objc private func updatePreview() {
        value.watermark = String(watermark.stringValue.prefix(100))
        value.tiled = placement.indexOfSelectedItem == 1
        value.background = background.indexOfSelectedItem
        value.opacity = CGFloat(opacity.doubleValue)
        value.padding = CGFloat(padding.doubleValue)
        value.radius = CGFloat(radius.doubleValue)
        value.shadow = shadow.state == .on
        opacityValue.stringValue = "\(Int(value.opacity * 100))%"
        paddingValue.stringValue = "\(Int(value.padding))"
        radiusValue.stringValue = "\(Int(value.radius))"
        opacity.isEnabled = !value.watermark.isEmpty
        placement.isEnabled = !value.watermark.isEmpty
        padding.isEnabled = value.background != 0
        radius.isEnabled = value.background != 0
        shadow.isEnabled = value.background != 0
        let scale = min(1, 1000 / max(source.size.width + value.padding * 2, source.size.height + value.padding * 2))
        preview.image = value.render(source, scale: scale)
    }
    @objc private func cancel() { if let window { window.sheetParent?.endSheet(window) } }
    @objc private func apply() { onApply?(value); cancel() }
}
