import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Publishes only named store captures, after validating the complete new set.
struct ScreenshotExport {
    struct TestAttachments: Decodable {
        let attachments: [Attachment]
    }

    struct Attachment: Decodable {
        let exportedFileName: String
        let suggestedHumanReadableName: String
        let isAssociatedWithFailure: Bool
    }

    struct InvalidExport: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static func run() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, ["ios", "tvos"].contains(arguments[1]) else {
            throw InvalidExport("usage: export-screenshots.swift ios|tvos attachments-directory output-directory")
        }
        let manager = FileManager.default
        let source = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        let output = URL(fileURLWithPath: arguments[3], isDirectory: true).standardizedFileURL
        let manifest = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        let tests = try JSONDecoder().decode([TestAttachments].self, from: manifest)
        let captures = tests.flatMap(\.attachments).filter { $0.suggestedHumanReadableName.hasPrefix("store-") }
        guard (1...10).contains(captures.count) else {
            throw InvalidExport("expected 1...10 store screenshots, found \(captures.count)")
        }
        try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = output.deletingLastPathComponent().appendingPathComponent(".screenshots-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        var names = Set<String>()
        for capture in captures {
            let name = try captureName(capture.suggestedHumanReadableName)
            guard names.insert(name).inserted, !capture.isAssociatedWithFailure else {
                throw InvalidExport("duplicate or failed screenshot: \(name)")
            }
            guard capture.exportedFileName == URL(fileURLWithPath: capture.exportedFileName).lastPathComponent,
                !capture.exportedFileName.isEmpty
            else { throw InvalidExport("attachment path must be a filename") }
            let input = source.appendingPathComponent(capture.exportedFileName)
            guard input.resolvingSymlinksInPath().deletingLastPathComponent() == source.resolvingSymlinksInPath() else {
                throw InvalidExport("attachment must stay inside its export directory")
            }
            try convert(input, to: staging.appendingPathComponent(name), platform: arguments[1])
        }
        // Both directories share a filesystem. Readers see the old set or the complete new set.
        if manager.fileExists(atPath: output.path) {
            guard renamex_np(staging.path, output.path, UInt32(RENAME_SWAP)) == 0 else {
                throw InvalidExport("cannot exchange screenshot directories: \(String(cString: strerror(errno)))")
            }
        } else {
            try manager.moveItem(at: staging, to: output)
        }
        print("Exported \(captures.count) screenshots to \(output.path)")
    }

    /// xcresulttool may append a timestamp to the attachment's supplied name.
    static func captureName(_ suggested: String) throws -> String {
        let expression = try NSRegularExpression(pattern: "^store-((?:0[1-9]|10)-[a-z0-9-]+)(?:_[^/]*)?(?:\\.png)?$")
        let range = NSRange(suggested.startIndex..., in: suggested)
        guard let match = expression.firstMatch(in: suggested, range: range),
            let nameRange = Range(match.range(at: 1), in: suggested)
        else { throw InvalidExport("invalid store attachment name: \(suggested)") }
        return String(suggested[nameRange]) + ".png"
    }

    /// Screenshot alpha channels are flattened without rescaling or changing the capture's composition.
    static func convert(_ source: URL, to destination: URL, platform: String) throws {
        guard let decoded = CGImageSourceCreateWithURL(source as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(decoded, 0, nil)
        else { throw InvalidExport("cannot decode \(source.lastPathComponent)") }
        let dimensions = platform == "ios" ? (1206, 2622) : (3840, 2160)
        guard image.width == dimensions.0, image.height == dimensions.1 else {
            throw InvalidExport(
                "\(source.lastPathComponent): expected \(dimensions.0)x\(dimensions.1), got \(image.width)x\(image.height)"
            )
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
            let writer = CGImageDestinationCreateWithURL(
                destination as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw InvalidExport("cannot create RGB screenshot") }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let flattened = context.makeImage() else { throw InvalidExport("cannot flatten screenshot") }
        CGImageDestinationAddImage(writer, flattened, nil)
        guard CGImageDestinationFinalize(writer) else { throw InvalidExport("cannot encode screenshot") }
    }
}

do {
    try ScreenshotExport.run()
} catch {
    fputs("screenshot export: \(error)\n", stderr)
    exit(1)
}
