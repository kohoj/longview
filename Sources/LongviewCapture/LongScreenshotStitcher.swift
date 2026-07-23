import CoreGraphics
import Foundation

public struct LongScreenshotStitchOutput {
    public let image: CGImage
    public let overlaps: [Int]
    public let regionInPixels: CGRect
}

public struct LongScreenshotStitcher {
    public init() {}

    public func stitch(
        capturedFrames frames: [CGImage],
        direction: LongScreenshotDirection,
        region: LongScreenshotRegion,
        bundleIdentifier: String?,
        pointPixelScale: CGFloat = 1
    ) throws -> LongScreenshotStitchOutput {
        guard let first = frames.first else {
            throw LongScreenshotError.invalidConfiguration
        }
        guard
            frames.allSatisfy({
                $0.width == first.width && $0.height == first.height
            })
        else { throw LongScreenshotError.captureDimensionsChanged }

        let layout = try LongScreenshotLayoutResolver.layout(
            bundleIdentifier: bundleIdentifier,
            pixelWidth: first.width,
            pixelHeight: first.height,
            pointPixelScale: pointPixelScale,
            region: region,
            comparisonFrames: frames
        )
        let documentOrder = direction == .up ? Array(frames.reversed()) : frames
        let header = try layout.header.map { try crop(documentOrder[0], to: $0) }
        let contentFrames = try documentOrder.map {
            try crop($0, to: layout.transcript)
        }

        var overlaps: [Int] = []
        if contentFrames.count > 1 {
            for index in 1..<contentFrames.count {
                overlaps.append(
                    try bestOverlap(
                        older: contentFrames[index - 1],
                        newer: contentFrames[index]
                    ))
            }
        }

        let result = try compose(
            header: header,
            documentOrderFrames: contentFrames,
            overlaps: overlaps
        )
        return LongScreenshotStitchOutput(
            image: result,
            overlaps: overlaps,
            regionInPixels: layout.transcript
        )
    }

    func bestOverlap(older: CGImage, newer: CGImage) throws -> Int {
        try bestOverlapMatch(older: older, newer: newer).overlap
    }

    func hasPlausibleMotion(
        before: CGImage,
        after: CGImage,
        direction: LongScreenshotDirection,
        region: LongScreenshotRegion,
        bundleIdentifier: String?,
        pointPixelScale: CGFloat = 1
    ) -> Bool {
        guard before.width == after.width, before.height == after.height else { return false }
        let motionRegion: LongScreenshotRegion =
            if region == .automatic,
                LongScreenshotProfileCatalog.contains(bundleIdentifier)
            {
                .appProfile
            } else if region == .automatic {
                .fullWindow
            } else {
                region
            }
        guard
            let layout = try? LongScreenshotLayoutResolver.layout(
                bundleIdentifier: bundleIdentifier,
                pixelWidth: before.width,
                pixelHeight: before.height,
                pointPixelScale: pointPixelScale,
                region: motionRegion,
                comparisonFrames: [before, after]
            ),
            let beforeCrop = try? crop(before, to: layout.transcript),
            let afterCrop = try? crop(after, to: layout.transcript),
            meanSameCoordinateDifference(beforeCrop, afterCrop) >= 1.2
        else { return false }

        let older = direction == .up ? afterCrop : beforeCrop
        let newer = direction == .up ? beforeCrop : afterCrop
        guard let match = try? bestOverlapMatch(older: older, newer: newer) else {
            return false
        }
        return match.score <= 24
            && match.overlap >= max(80, older.height / 6)
            && match.overlap < older.height - 24
    }

    func hasMatchingViewport(before: CGImage, after: CGImage) -> Bool {
        guard before.width == after.width,
            before.height == after.height
        else { return false }
        return meanSameCoordinateDifference(before, after) <= 2.5
    }

    private struct OverlapMatch {
        let score: Double
        let overlap: Int
    }

    private func bestOverlapMatch(older: CGImage, newer: CGImage) throws -> OverlapMatch {
        guard older.width == newer.width,
            older.height == newer.height,
            older.height > 120
        else { throw LongScreenshotError.captureDimensionsChanged }
        let oldFeatures = try FeatureImage(image: older)
        let newFeatures = try FeatureImage(image: newer)
        let background = medianBackground(oldFeatures, newFeatures)
        let minimum = max(80, older.height / 6)
        let maximum = min(older.height - 24, 1_200)
        guard minimum < maximum else { throw LongScreenshotError.overlapUnavailable }

        var best: OverlapMatch?
        for overlap in minimum..<maximum {
            var difference = 0.0
            var informativeCount = 0
            var row = 0
            while row < overlap {
                let oldRow = older.height - overlap + row
                let newRow = row
                var column = 0
                while column < oldFeatures.width {
                    let oldPixel = oldFeatures.pixel(row: oldRow, column: column)
                    let newPixel = newFeatures.pixel(row: newRow, column: column)
                    if isInformative(oldPixel, background)
                        || isInformative(newPixel, background)
                    {
                        let delta =
                            (abs(Int(oldPixel.0) - Int(newPixel.0))
                                + abs(Int(oldPixel.1) - Int(newPixel.1))
                                + abs(Int(oldPixel.2) - Int(newPixel.2))) / 3
                        difference += Double(min(delta, 80))
                        informativeCount += 1
                    }
                    column += 1
                }
                row += 2
            }
            guard informativeCount >= 80 else { continue }
            let candidate = OverlapMatch(
                score: difference / Double(informativeCount),
                overlap: overlap
            )
            if best == nil || candidate.score < best!.score {
                best = candidate
            }
        }
        guard let best else { throw LongScreenshotError.overlapUnavailable }
        return best
    }

    private func crop(_ image: CGImage, to rect: CGRect) throws -> CGImage {
        let bounded = rect.integral.intersection(
            CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        guard !bounded.isEmpty, let cropped = image.cropping(to: bounded) else {
            throw LongScreenshotError.cropUnavailable
        }
        return cropped
    }

    private func compose(
        header: CGImage?,
        documentOrderFrames frames: [CGImage],
        overlaps: [Int]
    ) throws -> CGImage {
        guard let first = frames.first else {
            throw LongScreenshotError.invalidConfiguration
        }
        let width = first.width
        let contentHeight =
            first.height
            + zip(frames.dropFirst(), overlaps)
            .reduce(0) { $0 + $1.0.height - $1.1 }
        let headerHeight = header?.height ?? 0
        let outputHeight = headerHeight + contentHeight
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: outputHeight,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw LongScreenshotError.imageCompositionFailed }

        if let features = try? FeatureImage(image: first) {
            let background = medianBackground(features, features)
            context.setFillColor(
                red: CGFloat(background.0) / 255,
                green: CGFloat(background.1) / 255,
                blue: CGFloat(background.2) / 255,
                alpha: 1
            )
            context.fill(CGRect(x: 0, y: 0, width: width, height: outputHeight))
        }

        var y = outputHeight
        if let header {
            y -= header.height
            context.draw(header, in: CGRect(x: 0, y: y, width: width, height: header.height))
        }
        y -= first.height
        context.draw(first, in: CGRect(x: 0, y: y, width: width, height: first.height))

        for (frame, overlap) in zip(frames.dropFirst(), overlaps) {
            let tailRect = CGRect(
                x: 0,
                y: overlap,
                width: frame.width,
                height: frame.height - overlap
            )
            guard let tail = frame.cropping(to: tailRect) else {
                throw LongScreenshotError.cropUnavailable
            }
            y -= tail.height
            context.draw(tail, in: CGRect(x: 0, y: y, width: tail.width, height: tail.height))
        }
        guard let result = context.makeImage() else {
            throw LongScreenshotError.imageCompositionFailed
        }
        return result
    }

    private func meanSameCoordinateDifference(_ lhs: CGImage, _ rhs: CGImage) -> Double {
        guard let a = try? FeatureImage(image: lhs),
            let b = try? FeatureImage(image: rhs),
            a.width == b.width,
            a.height == b.height
        else { return 0 }
        var total = 0
        var count = 0
        var row = 0
        while row < a.height {
            for column in 0..<a.width {
                let x = a.pixel(row: row, column: column)
                let y = b.pixel(row: row, column: column)
                total +=
                    abs(Int(x.0) - Int(y.0))
                    + abs(Int(x.1) - Int(y.1))
                    + abs(Int(x.2) - Int(y.2))
                count += 3
            }
            row += 2
        }
        return count == 0 ? 0 : Double(total) / Double(count)
    }

    private func isInformative(
        _ pixel: (UInt8, UInt8, UInt8),
        _ background: (UInt8, UInt8, UInt8)
    ) -> Bool {
        max(
            abs(Int(pixel.0) - Int(background.0)),
            abs(Int(pixel.1) - Int(background.1)),
            abs(Int(pixel.2) - Int(background.2))
        ) > 8
    }

    private func medianBackground(
        _ lhs: FeatureImage,
        _ rhs: FeatureImage
    ) -> (UInt8, UInt8, UInt8) {
        var red: [UInt8] = []
        var green: [UInt8] = []
        var blue: [UInt8] = []
        for features in [lhs, rhs] {
            var index = 0
            while index < features.bytes.count {
                red.append(features.bytes[index])
                green.append(features.bytes[index + 1])
                blue.append(features.bytes[index + 2])
                index += 4 * 97
            }
        }
        red.sort()
        green.sort()
        blue.sort()
        return (red[red.count / 2], green[green.count / 2], blue[blue.count / 2])
    }
}

private struct FeatureImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(image: CGImage) throws {
        let targetWidth = 64
        let targetHeight = image.height
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
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
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
