import AppKit
import CoreText

/// Custom view for rendering suggestion text with pixel-perfect positioning
private final class SuggestionTextView: NSView {
    var text: String = ""
    var textFont: NSFont = NSFont.systemFont(ofSize: 14)
    var textColor: NSColor = .systemGray

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: textColor
        ]

        // In a non-flipped NSView, Y=0 is at the bottom
        // draw(at:) places the string's bounding box origin at the point
        // The descender extends below the baseline, so the bounding box bottom
        // is at baseline + descender (where descender is negative)
        //
        // To align our text baseline with the window bottom, we draw at Y=0
        // The text's bounding box bottom will be at Y=0, and baseline will be
        // at Y = -descender (positive value, e.g., 3pt above bottom)
        (text as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: attributes)
    }
}

final class SuggestionOverlayWindow: NSPanel {
    private let textView: SuggestionTextView

    init() {
        textView = SuggestionTextView()
        textView.wantsLayer = true

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
        contentView.addSubview(textView)
        self.contentView = contentView
    }

    /// Update the overlay with suggestion text
    /// - Parameters:
    ///   - text: The suggestion text to display
    ///   - font: The font to match the target text
    ///   - color: The text color
    ///   - origin: The position where text should start (bottom-right of caret in AppKit coords)
    func update(text: String, font: NSFont, color: NSColor, origin: CGPoint) {
        guard !text.isEmpty else {
            orderOut(nil)
            return
        }

        textView.text = text
        textView.textFont = font
        textView.textColor = color.withAlphaComponent(1.0)

        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let textSize = (text as NSString).size(withAttributes: attributes)

        // Calculate window size - exact fit, no padding
        let width = ceil(textSize.width)
        let height = ceil(textSize.height)

        // origin is the bottom-right of the caret rect in AppKit coordinates
        // We position the window bottom at the caret bottom to align text baselines
        //
        // In AppKit coordinates (origin at bottom-left of screen):
        // - origin.y is the bottom of the caret/text line
        // - Higher Y = further up on screen
        //
        // By aligning window bottom with caret bottom, and using the same font,
        // the baselines should align naturally since both texts have the same
        // distance from their bounding box bottom to baseline.

        let windowFrame = CGRect(x: origin.x, y: origin.y, width: width, height: height)

        // Clamp to visible screen area
        let screen = NSScreen.screens.first { $0.frame.contains(origin) } ?? NSScreen.main
        var finalFrame = windowFrame
        if let visibleFrame = screen?.visibleFrame {
            if finalFrame.maxX > visibleFrame.maxX {
                finalFrame.origin.x = visibleFrame.maxX - finalFrame.width
            }
            if finalFrame.minX < visibleFrame.minX {
                finalFrame.origin.x = visibleFrame.minX
            }
            if finalFrame.maxY > visibleFrame.maxY {
                finalFrame.origin.y = visibleFrame.maxY - finalFrame.height
            }
            if finalFrame.minY < visibleFrame.minY {
                finalFrame.origin.y = visibleFrame.minY
            }
        }

        setFrame(finalFrame, display: true)
        contentView?.frame = CGRect(origin: .zero, size: finalFrame.size)
        textView.frame = CGRect(origin: .zero, size: finalFrame.size)
        textView.needsDisplay = true

        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}
