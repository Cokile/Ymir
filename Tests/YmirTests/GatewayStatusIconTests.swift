import AppKit
import XCTest
@testable import Ymir

final class GatewayStatusIconTests: XCTestCase {
    @MainActor
    func testIconDimsWhenStoppedSpinsWhenStartingAndRemainsClickable() async throws {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        let icon = GatewayStatusIcon(button: button)
        let progress = try XCTUnwrap(button.subviews.compactMap { $0 as? NSProgressIndicator }.first)
        let stoppedImage = try XCTUnwrap(button.image)
        XCTAssertTrue(stoppedImage.isTemplate)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(progress.isHidden)
        XCTAssertEqual(button.toolTip, "Ymir — gateway stopped")
        XCTAssertEqual(try maximumAlpha(stoppedImage), 0.35, accuracy: 0.02)

        icon.update(.starting)
        XCTAssertNil(button.image)
        XCTAssertFalse(progress.isHidden)
        XCTAssertTrue(progress.isIndeterminate)
        XCTAssertNil(progress.hitTest(.zero))
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.toolTip, "Ymir — gateway starting")

        icon.update(.running)
        let runningImage = try XCTUnwrap(button.image)
        XCTAssertTrue(runningImage.isTemplate)
        XCTAssertTrue(progress.isHidden)
        XCTAssertEqual(try maximumAlpha(runningImage), 1, accuracy: 0.01)
        XCTAssertEqual(button.toolTip, "Ymir — gateway running")

        icon.update(.stopped)
        XCTAssertTrue(button.image === stoppedImage)
        XCTAssertTrue(button.isEnabled)
        XCTAssertTrue(progress.isHidden)
    }

    private func maximumAlpha(_ image: NSImage) throws -> CGFloat {
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var alpha: CGFloat = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                alpha = max(alpha, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        return alpha
    }
}
