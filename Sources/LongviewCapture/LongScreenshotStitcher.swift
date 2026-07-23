import CoreGraphics
import Foundation

public struct LongScreenshotStitchOutput {
    public let image: CGImage
    public let overlaps: [Int]
    public let regionInPixels: CGRect
}

struct LongScreenshotMotionAnalysis: Equatable {
    let overlap: Int
    let score: Double
    let viewportHeight: Int
}

public struct LongScreenshotStitcher {
    public init() {}

    public func stitch(
        capturedFrames frames: [CGImage],
        direction: LongScreenshotDirection,
        region: LongScreenshotRegion,
        bundleIdentifier: String?,
        pointPixelScale: CGFloat = 1,
        validatedCaptureOverlaps: [Int]? = nil
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

        let overlaps: [Int]
        if let validatedCaptureOverlaps {
            guard validatedCaptureOverlaps.count == contentFrames.count - 1 else {
                throw LongScreenshotError.overlapUnavailable
            }
            overlaps =
                direction == .up
                ? Array(validatedCaptureOverlaps.reversed())
                : validatedCaptureOverlaps
        } else if contentFrames.count > 1 {
            var detected: [Int] = []
            for index in 1..<contentFrames.count {
                detected.append(
                    try bestOverlap(
                        older: contentFrames[index - 1],
                        newer: contentFrames[index]
                    ))
            }
            overlaps = detected
        } else {
            overlaps = []
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
        analyzeMotion(
            before: before,
            after: after,
            direction: direction,
            region: region,
            bundleIdentifier: bundleIdentifier,
            pointPixelScale: pointPixelScale
        ) != nil
    }

    func analyzeMotion(
        before: CGImage,
        after: CGImage,
        direction: LongScreenshotDirection,
        region: LongScreenshotRegion,
        bundleIdentifier: String?,
        pointPixelScale: CGFloat = 1
    ) -> LongScreenshotMotionAnalysis? {
        guard before.width == after.width, before.height == after.height else { return nil }
        let motionRegion: LongScreenshotRegion =
            if region == .automatic,
                LongScreenshotProfileCatalog.contains(bundleIdentifier)
            {
                .appProfile
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
        else { return nil }

        let older = direction == .up ? afterCrop : beforeCrop
        let newer = direction == .up ? beforeCrop : afterCrop
        guard let match = try? bestOverlapMatch(older: older, newer: newer) else {
            return nil
        }
        guard
            match.score <= 24
                && match.overlap >= max(80, older.height / 6)
                && match.overlap < older.height - 24
        else { return nil }
        return LongScreenshotMotionAnalysis(
            overlap: match.overlap,
            score: match.score,
            viewportHeight: older.height
        )
    }

    func hasMatchingViewport(before: CGImage, after: CGImage) -> Bool {
        guard before.width == after.width,
            before.height == after.height
        else { return false }
        if meanSameCoordinateDifference(before, after) <= 2.5 {
            return true
        }
        guard let match = viewportTranslation(before: before, after: after) else {
            return false
        }
        return abs(match.displacement) <= 3 && match.score <= 24
    }

    func viewportTranslation(
        before: CGImage,
        after: CGImage
    ) -> (displacement: Int, score: Double)? {
        guard
            let match = try? bestVerticalTranslation(
                before: before,
                after: after
            )
        else { return nil }
        return (match.displacement, match.score)
    }

    private struct OverlapMatch {
        let score: Double
        let overlap: Int
    }

    private struct TranslationMatch {
        let score: Double
        let displacement: Int
    }

    private func bestVerticalTranslation(
        before: CGImage,
        after: CGImage
    ) throws -> TranslationMatch {
        let beforeFeatures = try FeatureImage(image: before)
        let afterFeatures = try FeatureImage(image: after)
        let background = medianBackground(beforeFeatures, afterFeatures)
        let maximumDisplacement = min(
            beforeFeatures.height - 24,
            max(24, min(beforeFeatures.height / 3, 240))
        )
        guard maximumDisplacement > 0 else {
            throw LongScreenshotError.captureDimensionsChanged
        }

        var coarse: [TranslationMatch] = []
        for displacement in -maximumDisplacement...maximumDisplacement {
            if let candidate = translationScore(
                displacement: displacement,
                before: beforeFeatures,
                after: afterFeatures,
                background: background,
                rowStride: 8,
                columnStride: 2,
                minimumInformativeCount: 20
            ) {
                coarse.append(candidate)
            }
        }
        coarse.sort { $0.score < $1.score }

        var seeds = [0]
        for candidate in coarse {
            guard seeds.allSatisfy({ abs($0 - candidate.displacement) > 4 }) else {
                continue
            }
            seeds.append(candidate.displacement)
            if seeds.count == 9 { break }
        }

        var best: TranslationMatch?
        for displacement in seeds {
            guard
                let candidate = translationScore(
                    displacement: displacement,
                    before: beforeFeatures,
                    after: afterFeatures,
                    background: background,
                    rowStride: 2,
                    columnStride: 1,
                    minimumInformativeCount: 80
                )
            else { continue }
            if best == nil || candidate.score < best!.score {
                best = candidate
            }
        }
        guard let best else { throw LongScreenshotError.overlapUnavailable }
        return best
    }

    private func translationScore(
        displacement: Int,
        before: FeatureImage,
        after: FeatureImage,
        background: (UInt8, UInt8, UInt8),
        rowStride: Int,
        columnStride: Int,
        minimumInformativeCount: Int
    ) -> TranslationMatch? {
        let beforeStart = max(0, -displacement)
        let afterStart = max(0, displacement)
        let rowCount = min(
            before.height - beforeStart,
            after.height - afterStart
        )
        guard rowCount > 0 else { return nil }

        var differenceHistogram = [Int](repeating: 0, count: 81)
        var informativeCount = 0
        var offset = 0
        while offset < rowCount {
            let beforeRow = beforeStart + offset
            let afterRow = afterStart + offset
            var column = 0
            while column < before.width {
                let beforePixel = before.pixel(row: beforeRow, column: column)
                let afterPixel = after.pixel(row: afterRow, column: column)
                if isInformative(beforePixel, background)
                    || isInformative(afterPixel, background)
                {
                    let delta =
                        (abs(Int(beforePixel.0) - Int(afterPixel.0))
                            + abs(Int(beforePixel.1) - Int(afterPixel.1))
                            + abs(Int(beforePixel.2) - Int(afterPixel.2))) / 3
                    differenceHistogram[min(delta, 80)] += 1
                    informativeCount += 1
                }
                column += columnStride
            }
            offset += rowStride
        }
        guard informativeCount >= minimumInformativeCount else { return nil }
        return TranslationMatch(
            score: lowerTrimmedMean(
                histogram: differenceHistogram,
                count: informativeCount,
                retainedFraction: 0.9
            ),
            displacement: displacement
        )
    }

    private func lowerTrimmedMean(
        histogram: [Int],
        count: Int,
        retainedFraction: Double
    ) -> Double {
        let retainedCount = max(1, Int((Double(count) * retainedFraction).rounded(.up)))
        var remaining = retainedCount
        var total = 0
        for (difference, frequency) in histogram.enumerated() where remaining > 0 {
            let accepted = min(remaining, frequency)
            total += difference * accepted
            remaining -= accepted
        }
        return Double(total) / Double(retainedCount)
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

        var coarseMatches: [OverlapMatch] = []
        for overlap in minimum..<maximum {
            if let candidate = overlapScore(
                overlap: overlap,
                older: oldFeatures,
                newer: newFeatures,
                background: background,
                rowStride: 8,
                columnStride: 2,
                minimumInformativeCount: 20
            ) {
                coarseMatches.append(candidate)
            }
        }
        coarseMatches.sort { $0.score < $1.score }

        var coarseSeeds: [Int] = []
        for candidate in coarseMatches {
            guard coarseSeeds.allSatisfy({ abs($0 - candidate.overlap) > 8 }) else {
                continue
            }
            coarseSeeds.append(candidate.overlap)
            if coarseSeeds.count == 8 { break }
        }

        var best: OverlapMatch?
        for overlap in coarseSeeds.sorted() {
            guard
                let candidate = overlapScore(
                    overlap: overlap,
                    older: oldFeatures,
                    newer: newFeatures,
                    background: background,
                    rowStride: 2,
                    columnStride: 1,
                    minimumInformativeCount: 80
                )
            else { continue }
            if best == nil || candidate.score < best!.score {
                best = candidate
            }
        }
        guard let best else { throw LongScreenshotError.overlapUnavailable }
        return best
    }

    private func overlapScore(
        overlap: Int,
        older: FeatureImage,
        newer: FeatureImage,
        background: (UInt8, UInt8, UInt8),
        rowStride: Int,
        columnStride: Int,
        minimumInformativeCount: Int
    ) -> OverlapMatch? {
        var difference = 0.0
        var informativeCount = 0
        var row = 0
        while row < overlap {
            let oldRow = older.height - overlap + row
            var column = 0
            while column < older.width {
                let oldPixel = older.pixel(row: oldRow, column: column)
                let newPixel = newer.pixel(row: row, column: column)
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
                column += columnStride
            }
            row += rowStride
        }
        guard informativeCount >= minimumInformativeCount else { return nil }
        return OverlapMatch(
            score: difference / Double(informativeCount),
            overlap: overlap
        )
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
