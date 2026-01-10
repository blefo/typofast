import AppKit

final class SuggestionOverlayWindow: NSPanel {
    private let label: NSTextField

    init() {
        label = NSTextField(labelWithString: "")
        label.alignment = .left
        label.lineBreakMode = .byClipping
        label.maximumNumberOfLines = 1
        label.backgroundColor = .clear
        label.textColor = .systemGray
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false
        label.isSelectable = false

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        hasShadow = false
        backgroundColor = .clear
        level = .popUpMenu
        ignoresMouseEvents = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let contentView = NSView(frame: .zero)
        contentView.addSubview(label)
        self.contentView = contentView
    }

    func update(text: String, font: NSFont, color: NSColor, origin: CGPoint) {
        guard !text.isEmpty else {
            orderOut(nil)
            return
        }

        label.stringValue = text
        label.font = font
        label.textColor = color.withAlphaComponent(1.0)

        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padX: CGFloat = 4
        let padY: CGFloat = 4
        let width = ceil(textSize.width) + padX * 2
        let height = ceil(textSize.height) + padY * 2

        // origin is the bottom-left corner where the suggestion should appear
        let windowFrame = CGRect(x: origin.x, y: origin.y, width: width, height: height)

        #if DEBUG
        print("[Typofast] SuggestionOverlay: setting frame=\(windowFrame) text=\"\(text.prefix(20))...\"")
        #endif

        let point = origin
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            var clamped = windowFrame
            if clamped.maxX > visibleFrame.maxX { clamped.origin.x = visibleFrame.maxX - clamped.width }
            if clamped.minX < visibleFrame.minX { clamped.origin.x = visibleFrame.minX }
            if clamped.maxY > visibleFrame.maxY { clamped.origin.y = visibleFrame.maxY - clamped.height }
            if clamped.minY < visibleFrame.minY { clamped.origin.y = visibleFrame.minY }
            setFrame(clamped, display: true)
        } else {
            setFrame(windowFrame, display: true)
        }
        contentView?.frame = CGRect(origin: .zero, size: CGSize(width: width, height: height))
        label.frame = CGRect(x: padX, y: padY, width: width - padX * 2, height: height - padY * 2)

        orderFrontRegardless()

        #if DEBUG
        let wf = frame
        let screens = NSScreen.screens.map { $0.frame }
        let onAnyScreen = NSScreen.screens.contains { $0.frame.intersects(wf) }
        print("[Typofast] Overlay state visible=\(isVisible) alpha=\(alphaValue) level=\(level.rawValue) frame=\(wf) onAnyScreen=\(onAnyScreen) screens=\(screens)")
        #endif
    }

    func hide() {
        orderOut(nil)
    }
}
