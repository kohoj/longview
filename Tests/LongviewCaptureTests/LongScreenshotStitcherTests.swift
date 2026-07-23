import CoreGraphics
import XCTest

@testable import LongviewCapture

final class LongScreenshotStitcherTests: XCTestCase {
    func testFindsExactVerticalOverlap() throws {
        let older = try makeViewport(documentRange: 0..<300)
        let newer = try makeViewport(documentRange: 150..<450)

        let overlap = try LongScreenshotStitcher().bestOverlap(
            older: older,
            newer: newer
        )

        XCTAssertEqual(overlap, 150)
    }

    func testCoarseToFineMatcherPreservesExactOverlapAcrossOffsets() throws {
        for expected in [80, 81, 97, 149, 151, 220, 274] {
            let older = try makeViewport(documentRange: 0..<300)
            let newer = try makeViewport(documentRange: (300 - expected)..<(600 - expected))

            let overlap = try LongScreenshotStitcher().bestOverlap(
                older: older,
                newer: newer
            )

            XCTAssertEqual(overlap, expected)
        }
    }

    func testMatcherDoesNotAliasMostlyRepetitiveContent() throws {
        let older = try makeRepetitiveViewport(documentRange: 0..<300)
        let newer = try makeRepetitiveViewport(documentRange: 77..<377)

        let overlap = try LongScreenshotStitcher().bestOverlap(
            older: older,
            newer: newer
        )

        XCTAssertEqual(overlap, 223)
    }

    func testWeChatProfileExcludesSidebarComposerAndScrollbar() throws {
        let layout = try LongScreenshotLayoutResolver.layout(
            bundleIdentifier: "com.tencent.xinWeChat",
            pixelWidth: 1920,
            pixelHeight: 1050,
            pointPixelScale: 1,
            region: .appProfile,
            comparisonFrames: []
        )

        XCTAssertEqual(layout.header, CGRect(x: 302, y: 0, width: 1598, height: 48))
        XCTAssertEqual(
            layout.transcript,
            CGRect(x: 302, y: 48, width: 1598, height: 804)
        )
        XCTAssertTrue(
            LongScreenshotProfileCatalog.prefersForegroundEventRoute(
                "com.tencent.xinWeChat"
            )
        )
        XCTAssertFalse(
            LongScreenshotProfileCatalog.prefersForegroundEventRoute(
                "com.example.Generic"
            )
        )
    }

    func testNormalizedRegionIsConvertedToPixels() throws {
        let layout = try LongScreenshotLayoutResolver.layout(
            bundleIdentifier: "com.apple.Safari",
            pixelWidth: 1_000,
            pixelHeight: 800,
            pointPixelScale: 1,
            region: .normalized(CGRect(x: 0.2, y: 0.1, width: 0.7, height: 0.8)),
            comparisonFrames: []
        )

        XCTAssertNil(layout.header)
        XCTAssertEqual(layout.transcript, CGRect(x: 200, y: 80, width: 700, height: 640))
    }

    func testSingleFrameGenericCaptureProducesAValidImage() throws {
        let frame = try makeViewport(documentRange: 0..<300)
        let result = try LongScreenshotStitcher().stitch(
            capturedFrames: [frame],
            direction: .up,
            region: .fullWindow,
            bundleIdentifier: "com.example.Generic"
        )

        XCTAssertEqual(result.image.width, frame.width)
        XCTAssertEqual(result.image.height, frame.height)
        XCTAssertEqual(result.overlaps, [])
    }

    func testWindowWithoutBundleIdentifierCanUseGenericRegions() throws {
        let frame = try makeViewport(documentRange: 0..<300)
        let result = try LongScreenshotStitcher().stitch(
            capturedFrames: [frame],
            direction: .down,
            region: .fullWindow,
            bundleIdentifier: nil
        )

        XCTAssertEqual(result.image.width, frame.width)
        XCTAssertEqual(result.image.height, frame.height)
    }

    func testAutomaticRegionNeverInfersHorizontalSidebar() throws {
        let first = try makeViewport(documentRange: 0..<300)
        let second = try makeViewport(documentRange: 50..<350)
        let layout = try LongScreenshotLayoutResolver.layout(
            bundleIdentifier: nil,
            pixelWidth: first.width,
            pixelHeight: first.height,
            pointPixelScale: 1,
            region: .automatic,
            comparisonFrames: [first, second]
        )

        XCTAssertEqual(layout.transcript.minX, 0)
        XCTAssertEqual(layout.transcript.width, CGFloat(first.width))
    }

    func testAutomaticMotionAnalysisExcludesFixedWindowChrome() throws {
        let older = try makeViewportWithFixedChrome(documentRange: 0..<300)
        let newer = try makeViewportWithFixedChrome(documentRange: 150..<450)

        let analysis = LongScreenshotStitcher().analyzeMotion(
            before: older,
            after: newer,
            direction: .down,
            region: .automatic,
            bundleIdentifier: "com.example.Generic"
        )

        XCTAssertNotNil(analysis)
        XCTAssertEqual(analysis?.overlap, 150)
        XCTAssertEqual(analysis?.viewportHeight, 300)
    }

    func testMotionAnalyzerRecognizesVerticalDocumentTranslation() throws {
        let newer = try makeViewport(documentRange: 150..<450)
        let older = try makeViewport(documentRange: 0..<300)

        XCTAssertTrue(
            LongScreenshotStitcher().hasPlausibleMotion(
                before: newer,
                after: older,
                direction: .up,
                region: .fullWindow,
                bundleIdentifier: "com.example.Generic"
            ))
        XCTAssertFalse(
            LongScreenshotStitcher().hasPlausibleMotion(
                before: newer,
                after: newer,
                direction: .up,
                region: .fullWindow,
                bundleIdentifier: "com.example.Generic"
            ))

        let analysis = LongScreenshotStitcher().analyzeMotion(
            before: newer,
            after: older,
            direction: .up,
            region: .fullWindow,
            bundleIdentifier: "com.example.Generic"
        )
        XCTAssertEqual(analysis?.overlap, 150)
        XCTAssertEqual(analysis?.viewportHeight, 300)
    }

    func testValidatedCaptureOverlapsAvoidRedetection() throws {
        let newest = try makeViewport(documentRange: 300..<600)
        let middle = try makeViewport(documentRange: 150..<450)
        let oldest = try makeViewport(documentRange: 0..<300)

        let result = try LongScreenshotStitcher().stitch(
            capturedFrames: [newest, middle, oldest],
            direction: .up,
            region: .fullWindow,
            bundleIdentifier: "com.example.Generic",
            validatedCaptureOverlaps: [150, 150]
        )

        XCTAssertEqual(result.overlaps, [150, 150])
        XCTAssertEqual(result.image.height, 600)
    }

    func testRestoredViewportRequiresTranslationAgreement() throws {
        let original = try makeViewport(documentRange: 0..<300)
        let changed = try makeViewport(documentRange: 50..<350)
        let dynamicallyUpdated = try overlayDynamicPatch(on: original)
        let stitcher = LongScreenshotStitcher()

        XCTAssertTrue(stitcher.hasMatchingViewport(before: original, after: original))
        let dynamicMatch = stitcher.viewportTranslation(
            before: original,
            after: dynamicallyUpdated
        )
        XCTAssertEqual(dynamicMatch?.displacement, 0)
        XCTAssertLessThanOrEqual(dynamicMatch?.score ?? .infinity, 24)
        XCTAssertTrue(
            stitcher.hasMatchingViewport(
                before: original,
                after: dynamicallyUpdated
            )
        )
        XCTAssertFalse(stitcher.hasMatchingViewport(before: original, after: changed))
    }

    func testPNGWriterCreatesPrivateFileAndNeverOverwrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "longview-png-writer-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("capture.png")

        try LongScreenshotPNGWriter.write(
            try makeViewport(documentRange: 0..<20),
            to: output
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(
            try LongScreenshotPNGWriter.write(
                try makeViewport(documentRange: 0..<20),
                to: output
            ))
    }

    private func makeViewport(documentRange: Range<Int>) throws -> CGImage {
        let width = 96
        let height = documentRange.count
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for localY in 0..<height {
            let documentY = documentRange.lowerBound + localY
            for x in 0..<width {
                let offset = (localY * width + x) * 4
                let stripe = ((documentY / 11) + (x / 9)) % 5 == 0
                bytes[offset] = stripe ? UInt8((documentY * 3 + x) % 220 + 25) : 25
                bytes[offset + 1] = stripe ? UInt8((documentY + x * 2) % 200 + 35) : 25
                bytes[offset + 2] = stripe ? UInt8((documentY * 2 + x * 3) % 210 + 30) : 25
                bytes[offset + 3] = 255
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else { throw TestError.imageCreationFailed }
        return image
    }

    private func makeViewportWithFixedChrome(
        documentRange: Range<Int>
    ) throws -> CGImage {
        let content = try makeViewport(documentRange: documentRange)
        let chromeHeight = 40
        let height = chromeHeight + content.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: content.width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: content.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw TestError.imageCreationFailed }
        context.setFillColor(red: 0.18, green: 0.2, blue: 0.22, alpha: 1)
        context.fill(
            CGRect(
                x: 0,
                y: 0,
                width: content.width,
                height: chromeHeight
            )
        )
        context.draw(
            content,
            in: CGRect(
                x: 0,
                y: chromeHeight,
                width: content.width,
                height: content.height
            )
        )
        guard let image = context.makeImage() else {
            throw TestError.imageCreationFailed
        }
        return image
    }

    private func makeRepetitiveViewport(
        documentRange: Range<Int>
    ) throws -> CGImage {
        let width = 96
        let height = documentRange.count
        var bytes = [UInt8](repeating: 25, count: width * height * 4)
        for localY in 0..<height {
            let documentY = documentRange.lowerBound + localY
            for x in 0..<width {
                let offset = (localY * width + x) * 4
                if x < 12 {
                    bytes[offset] = UInt8((documentY * 17 + x * 3) % 220 + 25)
                    bytes[offset + 1] = UInt8((documentY * 7 + x * 5) % 210 + 30)
                    bytes[offset + 2] = UInt8((documentY * 11 + x) % 200 + 35)
                } else {
                    let repeatedRow = documentY % 18
                    let ink = ((repeatedRow / 3) + (x / 7)) % 4 == 0
                    let value = ink ? UInt8(220) : UInt8(25)
                    bytes[offset] = value
                    bytes[offset + 1] = value
                    bytes[offset + 2] = value
                }
                bytes[offset + 3] = 255
            }
        }
        let data = Data(bytes)
        guard let provider = CGDataProvider(data: data as CFData),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            )
        else { throw TestError.imageCreationFailed }
        return image
    }

    private func overlayDynamicPatch(on image: CGImage) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw TestError.imageCreationFailed }
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        context.setFillColor(red: 0.8, green: 0.2, blue: 0.5, alpha: 1)
        context.fill(
            CGRect(
                x: 8,
                y: 110,
                width: image.width - 16,
                height: 36
            )
        )
        guard let result = context.makeImage() else {
            throw TestError.imageCreationFailed
        }
        return result
    }

    private enum TestError: Error {
        case imageCreationFailed
    }
}
