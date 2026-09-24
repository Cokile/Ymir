import AppKit

@MainActor
final class GatewayStatusIcon {
    private weak var button: NSButton?
    private let progress = ClickThroughProgressIndicator()
    private let runningImage = GatewayStatusIcon.menuBarIcon(opacity: 1)
    private let stoppedImage = GatewayStatusIcon.menuBarIcon(opacity: 0.35)

    init(button: NSButton) {
        self.button = button
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.isDisplayedWhenStopped = false
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.setAccessibilityElement(false)
        button.addSubview(progress)
        NSLayoutConstraint.activate([
            progress.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            progress.centerYAnchor.constraint(equalTo: button.centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 16),
            progress.heightAnchor.constraint(equalToConstant: 16)
        ])
        update(.stopped)
    }

    func update(_ state: GatewayState) {
        button?.toolTip = state.accessibilityDescription
        button?.setAccessibilityLabel(state.accessibilityDescription)
        // Only the image looks disabled; the menu must remain usable to start it.
        button?.image = state == .starting ? nil : (state == .running ? runningImage : stoppedImage)
        progress.isHidden = state != .starting
        if state == .starting {
            progress.startAnimation(nil)
        } else {
            progress.stopAnimation(nil)
        }
    }

    private static func menuBarIcon(opacity: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18))
        image.lockFocus()

        NSColor.black.withAlphaComponent(opacity).setStroke()
        let mark = NSBezierPath()
        mark.lineWidth = 2.8
        mark.lineCapStyle = .round
        mark.lineJoinStyle = .round
        mark.move(to: NSPoint(x: 4.5, y: 13.2))
        mark.line(to: NSPoint(x: 9, y: 8.4))
        mark.line(to: NSPoint(x: 13.5, y: 13.2))
        mark.move(to: NSPoint(x: 9, y: 8.4))
        mark.line(to: NSPoint(x: 9, y: 4.2))
        mark.stroke()

        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

private final class ClickThroughProgressIndicator: NSProgressIndicator {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
