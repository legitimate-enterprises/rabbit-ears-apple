import AppKit
import Vision
import XCTest

/// Whether Vision can read text here. A virtual machine lacks the hardware
/// its recognizer compiles for, so the tests that read a drawn view skip there.
@MainActor
enum TextRecognition {
    private static var works: Bool?

    static func require() async throws {
        if works == nil {
            let image = NSImage(size: .init(width: 240, height: 80), flipped: false) { bounds in
                NSColor.white.setFill()
                bounds.fill()
                ("Probe" as NSString).draw(
                    at: .init(x: 20, y: 20),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.black])
                return true
            }
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            let drawn = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            if let drawn, (try? await request.perform(on: drawn)) != nil { works = true } else { works = false }
        }
        try XCTSkipUnless(works == true, "Vision cannot recognize text on this machine")
    }
}
