import CoreGraphics
import Foundation

public enum LongScreenshotProfileCatalog {
    public static let knownBundleIdentifiers = [
        "com.tencent.xinWeChat"
    ]

    static func contains(_ bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return knownBundleIdentifiers.contains(bundleIdentifier)
    }

    static func prefersForegroundEventRoute(_ bundleIdentifier: String?) -> Bool {
        bundleIdentifier == "com.tencent.xinWeChat"
    }
}

struct LongScreenshotCropLayout: Equatable {
    let header: CGRect?
    let transcript: CGRect
}

enum LongScreenshotLayoutResolver {
    static func layout(
        bundleIdentifier: String?,
        pixelWidth: Int,
        pixelHeight: Int,
        pointPixelScale: CGFloat,
        region: LongScreenshotRegion,
        comparisonFrames: [CGImage]
    ) throws -> LongScreenshotCropLayout {
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: pixelWidth,
            height: pixelHeight
        )
        switch region {
        case .fullWindow:
            return LongScreenshotCropLayout(header: nil, transcript: bounds)
        case .normalized(let normalized):
            guard normalized.minX >= 0,
                normalized.minY >= 0,
                normalized.maxX <= 1,
                normalized.maxY <= 1,
                normalized.width > 0.05,
                normalized.height > 0.05
            else { throw LongScreenshotError.cropUnavailable }
            let rect = CGRect(
                x: normalized.minX * bounds.width,
                y: normalized.minY * bounds.height,
                width: normalized.width * bounds.width,
                height: normalized.height * bounds.height
            ).integral.intersection(bounds)
            guard rect.width >= 80, rect.height >= 120 else {
                throw LongScreenshotError.cropUnavailable
            }
            return LongScreenshotCropLayout(header: nil, transcript: rect)
        case .appProfile:
            return try appProfile(
                bundleIdentifier: bundleIdentifier,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                pointPixelScale: pointPixelScale
            )
        case .automatic:
            if LongScreenshotProfileCatalog.contains(bundleIdentifier) {
                return try appProfile(
                    bundleIdentifier: bundleIdentifier,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    pointPixelScale: pointPixelScale
                )
            }
            let detected =
                AutomaticContentRegionDetector.detect(
                    frames: comparisonFrames,
                    bounds: bounds
                ) ?? bounds
            return LongScreenshotCropLayout(header: nil, transcript: detected)
        }
    }

    private static func appProfile(
        bundleIdentifier: String?,
        pixelWidth: Int,
        pixelHeight: Int,
        pointPixelScale: CGFloat
    ) throws -> LongScreenshotCropLayout {
        guard LongScreenshotProfileCatalog.contains(bundleIdentifier) else {
            throw LongScreenshotError.unsupportedApplication
        }
        let width = CGFloat(pixelWidth)
        let height = CGFloat(pixelHeight)
        let scale = max(1, pointPixelScale)
        let left = min(round(302 * scale), round(width * 0.35))
        let right = width - round(20 * scale)
        let headerHeight = min(round(48 * scale), round(height * 0.08))
        let transcriptBottom =
            height
            - min(
                round(198 * scale),
                round(height * 0.25)
            )
        guard right > left,
            headerHeight > 0,
            transcriptBottom > headerHeight
        else { throw LongScreenshotError.cropUnavailable }
        return LongScreenshotCropLayout(
            header: CGRect(
                x: left,
                y: 0,
                width: right - left,
                height: headerHeight
            ),
            transcript: CGRect(
                x: left,
                y: headerHeight,
                width: right - left,
                height: transcriptBottom - headerHeight
            )
        )
    }
}

private enum AutomaticContentRegionDetector {
    static func detect(frames: [CGImage], bounds: CGRect) -> CGRect? {
        guard frames.count >= 2,
            let first = frames.first,
            let last = frames.last,
            first.width == last.width,
            first.height == last.height,
            let lhs = try? DifferenceImage(image: first),
            let rhs = try? DifferenceImage(image: last)
        else { return nil }

        let rowDifferences = (0..<lhs.height).map { row in
            meanDifference(lhs, rhs, fixedRow: row, fixedColumn: nil)
        }
        let rowMedian = median(rowDifferences)
        guard rowMedian >= 2 else { return nil }

        let top = fixedPrefix(
            rowDifferences,
            threshold: max(1.5, rowMedian * 0.22),
            maximumFraction: 0.35
        )
        let bottom = fixedSuffix(
            rowDifferences,
            threshold: max(1.5, rowMedian * 0.22),
            maximumFraction: 0.35
        )
        // Generic horizontal inference is unsafe: document margins, line
        // numbers, avatars, and repeated text can all look "fixed" between
        // frames. Sidebars require an app profile or an explicit region.
        let left = 0
        let right = 0

        let scaleX = bounds.width / CGFloat(lhs.width)
        let scaleY = bounds.height / CGFloat(lhs.height)
        let rect = CGRect(
            x: CGFloat(left) * scaleX,
            y: CGFloat(top) * scaleY,
            width: bounds.width - CGFloat(left + right) * scaleX,
            height: bounds.height - CGFloat(top + bottom) * scaleY
        ).integral.intersection(bounds)
        guard rect.width >= bounds.width * 0.30,
            rect.height >= bounds.height * 0.30
        else { return nil }
        return rect
    }

    private static func fixedPrefix(
        _ values: [Double],
        threshold: Double,
        maximumFraction: Double
    ) -> Int {
        let maximum = Int(Double(values.count) * maximumFraction)
        var end = 0
        var misses = 0
        for index in 0..<maximum {
            if values[index] <= threshold {
                end = index + 1
                misses = 0
            } else {
                misses += 1
                if misses >= 3 { break }
            }
        }
        return end >= max(3, values.count / 40) ? end : 0
    }

    private static func fixedSuffix(
        _ values: [Double],
        threshold: Double,
        maximumFraction: Double
    ) -> Int {
        fixedPrefix(
            Array(values.reversed()),
            threshold: threshold,
            maximumFraction: maximumFraction
        )
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    private static func meanDifference(
        _ lhs: DifferenceImage,
        _ rhs: DifferenceImage,
        fixedRow: Int?,
        fixedColumn: Int?
    ) -> Double {
        let rows = fixedRow.map { [$0] } ?? Array(0..<lhs.height)
        let columns = fixedColumn.map { [$0] } ?? Array(0..<lhs.width)
        var total = 0
        var count = 0
        for row in rows {
            for column in columns {
                let a = lhs.pixel(row: row, column: column)
                let b = rhs.pixel(row: row, column: column)
                total +=
                    abs(Int(a.0) - Int(b.0))
                    + abs(Int(a.1) - Int(b.1))
                    + abs(Int(a.2) - Int(b.2))
                count += 3
            }
        }
        return count == 0 ? 0 : Double(total) / Double(count)
    }
}

private struct DifferenceImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(image: CGImage) throws {
        let targetWidth = 96
        let targetHeight = max(
            48,
            Int((Double(image.height) / Double(image.width) * 96).rounded())
        )
        width = targetWidth
        height = targetHeight
        var storage = [UInt8](repeating: 0, count: targetWidth * targetHeight * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw LongScreenshotError.imageCompositionFailed
        }
        let rendered = storage.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                let context = CGContext(
                    data: address,
                    width: targetWidth,
                    height: targetHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: targetWidth * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.interpolationQuality = .low
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
            )
            return true
        }
        guard rendered else { throw LongScreenshotError.imageCompositionFailed }
        bytes = storage
    }

    func pixel(row: Int, column: Int) -> (UInt8, UInt8, UInt8) {
        let offset = (row * width + column) * 4
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2])
    }

}
