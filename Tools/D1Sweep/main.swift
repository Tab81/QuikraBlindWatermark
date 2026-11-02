import AppKit
import BWM
import CoreGraphics
import D1SweepSupport
import Darwin
import Foundation
import ImageIO

private let imageSize = 512
private let d1Values: [Float] = [36]
private let password = "d1-sweep-password"
private let payload = (0..<32).map { UInt8(($0 * 37 + 11) & 0xFF) }

private enum ImageCategory: String, CaseIterable {
    case flat
    case texture
    case dark
    case bright
}

private struct RGBAImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]
}

private enum Requirement {
    case mustPass
    case expected
    case bestEffort
}

private enum Attack: String, CaseIterable {
    case jpeg95 = "JPEG95"
    case jpeg90 = "JPEG90"
    case jpeg80 = "JPEG80"
    case jpeg70 = "JPEG70"
    case resizeHalf = "Scale0.5x"
    case resizeOneAndHalf = "Scale1.5x"
    case noise2 = "NoiseSigma2"
    case noise5 = "NoiseSigma5"
    case brightnessUp = "Brightness+10%"
    case brightnessDown = "Brightness-10%"
    case contrastUp = "Contrast+10%"
    case contrastDown = "Contrast-10%"

    var requirement: Requirement {
        switch self {
        case .jpeg90, .jpeg80, .resizeHalf:
            return .mustPass
        case .brightnessUp, .brightnessDown, .contrastUp, .contrastDown, .noise2:
            return .expected
        case .jpeg95, .jpeg70, .resizeOneAndHalf, .noise5:
            return .bestEffort
        }
    }
}

private struct AttackStats {
    var count = 0
    var magicCount = 0
    var crcCount = 0
    var berSum = 0.0

    var magicRate: Double { count > 0 ? Double(magicCount) / Double(count) : 0 }
    var crcRate: Double { count > 0 ? Double(crcCount) / Double(count) : 0 }
    var averageBER: Double { count > 0 ? berSum / Double(count) : 1 }
}

private struct SweepResult {
    let d1: Float
    let averagePSNR: Double
    let stats: [Attack: AttackStats]
    let mustPass: Bool
    let expectedPass: Bool

    var eligible: Bool { mustPass && expectedPass }
}

private struct DiagnosticResult {
    let headerMagicOK: Bool
    let crcOK: Bool
    let isText: Bool
    let payload: [UInt8]
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1.0e-12)
        let u2 = uniform()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * Double.pi * u2)
    }
}

private func clampToByte(_ value: Double) -> UInt8 {
    if value <= 0 { return 0 }
    if value >= 255 { return 255 }
    return UInt8(value.rounded())
}

private func makeImage(category: ImageCategory, variant: Int) -> RGBAImage {
    let width = imageSize
    let height = imageSize
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    let phase = Double(variant) * 0.37

    for y in 0..<height {
        for x in 0..<width {
            let xf = Double(x) / Double(width)
            let yf = Double(y) / Double(height)
            let sx = sin(2.0 * Double.pi * (xf * 7.0 + yf * 3.0) + phase)
            let sy = cos(2.0 * Double.pi * (xf * 11.0 - yf * 5.0) + phase * 0.7)
            let checker = ((x / 32 + y / 32) & 1) == 0 ? 1.0 : -1.0
            let hash = Double(((x &* 1_103_515_245) ^ (y &* 12_345) ^ (variant &* 99_991)) & 0xFF) / 255.0

            let red: Double
            let green: Double
            let blue: Double
            switch category {
            case .flat:
                red = 90.0 + 30.0 * xf + 8.0 * sx
                green = 125.0 + 20.0 * yf + 7.0 * sy
                blue = 155.0 + 18.0 * (1.0 - xf) + 6.0 * sx
            case .texture:
                red = 135.0 + 55.0 * sx + 18.0 * checker + 6.0 * hash
                green = 125.0 + 50.0 * sy - 15.0 * checker + 5.0 * hash
                blue = 115.0 + 40.0 * (sx - sy) + 20.0 * checker
            case .dark:
                red = 18.0 + 22.0 * xf + 9.0 * sx + 4.0 * hash
                green = 22.0 + 18.0 * yf + 8.0 * sy + 4.0 * hash
                blue = 30.0 + 20.0 * (1.0 - xf) + 7.0 * checker
            case .bright:
                red = 205.0 + 25.0 * xf + 8.0 * sx - 5.0 * checker
                green = 215.0 + 20.0 * yf + 7.0 * sy + 4.0 * checker
                blue = 198.0 + 22.0 * (1.0 - yf) + 6.0 * hash
            }

            let index = (y * width + x) * 4
            pixels[index] = clampToByte(red)
            pixels[index + 1] = clampToByte(green)
            pixels[index + 2] = clampToByte(blue)
            pixels[index + 3] = 255
        }
    }

    return RGBAImage(width: width, height: height, pixels: pixels)
}

private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ??
    CGColorSpaceCreateDeviceRGB()
private let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
)

private func makeCGImage(from image: RGBAImage) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(image.pixels) as CFData) else {
        return nil
    }
    return CGImage(
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: image.width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    )
}

private func rgbaImage(from cgImage: CGImage) -> RGBAImage? {
    var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
    let created = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
        guard let context = CGContext(
            data: rawBuffer.baseAddress,
            width: cgImage.width,
            height: cgImage.height,
            bitsPerComponent: 8,
            bytesPerRow: cgImage.width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return false
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return true
    }
    return created ? RGBAImage(width: cgImage.width, height: cgImage.height, pixels: pixels) : nil
}

private func resizeRoundTrip(_ image: RGBAImage, factor: Double) -> RGBAImage? {
    guard let cgImage = makeCGImage(from: image) else { return nil }
    let scaledWidth = max(1, Int((Double(image.width) * factor).rounded()))
    let scaledHeight = max(1, Int((Double(image.height) * factor).rounded()))
    guard let scaledCG = render(cgImage, width: scaledWidth, height: scaledHeight),
          let restoredCG = render(scaledCG, width: image.width, height: image.height) else {
        return nil
    }
    return rgbaImage(from: restoredCG)
}

private func render(_ cgImage: CGImage, width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    ) else {
        return nil
    }
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

private func jpegRoundTrip(_ image: RGBAImage, quality: Double) -> RGBAImage? {
    guard let cgImage = makeCGImage(from: image) else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, "public.jpeg" as CFString, 1, nil
    ) else {
        return nil
    }
    let options = [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
    CGImageDestinationAddImage(destination, cgImage, options)
    guard CGImageDestinationFinalize(destination),
          let source = CGImageSourceCreateWithData(data as CFData, nil),
          let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return nil
    }
    return rgbaImage(from: decoded)
}

private func addNoise(_ image: RGBAImage, sigma: Double, seed: UInt64) -> RGBAImage {
    var rng = SplitMix64(state: seed)
    var pixels = image.pixels
    for index in stride(from: 0, to: pixels.count, by: 4) {
        for channel in 0..<3 {
            pixels[index + channel] = clampToByte(
                Double(pixels[index + channel]) + rng.gaussian() * sigma
            )
        }
    }
    return RGBAImage(width: image.width, height: image.height, pixels: pixels)
}

private func adjustBrightness(_ image: RGBAImage, factor: Double) -> RGBAImage {
    var pixels = image.pixels
    for index in stride(from: 0, to: pixels.count, by: 4) {
        for channel in 0..<3 {
            pixels[index + channel] = clampToByte(Double(pixels[index + channel]) * factor)
        }
    }
    return RGBAImage(width: image.width, height: image.height, pixels: pixels)
}

private func adjustContrast(_ image: RGBAImage, factor: Double) -> RGBAImage {
    var pixels = image.pixels
    for index in stride(from: 0, to: pixels.count, by: 4) {
        for channel in 0..<3 {
            pixels[index + channel] = clampToByte(
                (Double(pixels[index + channel]) - 128.0) * factor + 128.0
            )
        }
    }
    return RGBAImage(width: image.width, height: image.height, pixels: pixels)
}

private func applyAttack(_ attack: Attack, to image: RGBAImage, seed: UInt64) -> RGBAImage? {
    switch attack {
    case .jpeg95:
        return jpegRoundTrip(image, quality: 0.95)
    case .jpeg90:
        return jpegRoundTrip(image, quality: 0.90)
    case .jpeg80:
        return jpegRoundTrip(image, quality: 0.80)
    case .jpeg70:
        return jpegRoundTrip(image, quality: 0.70)
    case .resizeHalf:
        return resizeRoundTrip(image, factor: 0.5)
    case .resizeOneAndHalf:
        return resizeRoundTrip(image, factor: 1.5)
    case .noise2:
        return addNoise(image, sigma: 2.0, seed: seed)
    case .noise5:
        return addNoise(image, sigma: 5.0, seed: seed)
    case .brightnessUp:
        return adjustBrightness(image, factor: 1.10)
    case .brightnessDown:
        return adjustBrightness(image, factor: 0.90)
    case .contrastUp:
        return adjustContrast(image, factor: 1.10)
    case .contrastDown:
        return adjustContrast(image, factor: 0.90)
    }
}

private func embed(_ image: RGBAImage, d1: Float) -> [UInt8]? {
    var output: UnsafeMutablePointer<UInt8>?
    var outputSize: Int32 = 0
    let expectedSize = image.width * image.height * 4

    let status = image.pixels.withUnsafeBufferPointer { source in
        payload.withUnsafeBufferPointer { payloadBuffer in
            password.withCString { passwordPointer in
                quikra_bwm_embed(
                    source.baseAddress,
                    Int32(image.width),
                    Int32(image.height),
                    4,
                    payloadBuffer.baseAddress,
                    Int32(payload.count),
                    0,
                    BWM_ALGO_V1,
                    passwordPointer,
                    &output,
                    &outputSize
                )
            }
        }
    }

    guard status == Int32(BWM_OK), let output, Int(outputSize) == expectedSize else {
        if let output {
            Darwin.free(UnsafeMutableRawPointer(output))
        }
        return nil
    }
    defer { Darwin.free(UnsafeMutableRawPointer(output)) }
    return Array(UnsafeBufferPointer(start: output, count: expectedSize))
}

private func publicExtract(_ pixels: [UInt8], width: Int, height: Int, d1: Float) -> [UInt8]? {
    var output: UnsafeMutablePointer<UInt8>?
    var outputLength: Int32 = 0
    var isText: Int32 = 0
    let status = pixels.withUnsafeBufferPointer { source in
        password.withCString { passwordPointer in
            quikra_bwm_extract(
                source.baseAddress,
                Int32(width),
                Int32(height),
                4,
                passwordPointer,
                &output,
                &outputLength,
                &isText
            )
        }
    }
    guard status == Int32(BWM_OK), let output, outputLength > 0 else {
        if let output {
            Darwin.free(UnsafeMutableRawPointer(output))
        }
        return nil
    }
    defer { Darwin.free(UnsafeMutableRawPointer(output)) }
    return Array(UnsafeBufferPointer(start: output, count: Int(outputLength)))
}

private func diagnose(_ pixels: [UInt8], width: Int, height: Int,
                      d1: Float) -> DiagnosticResult? {
    var info = bwm_diag_info()
    var rawPayload = [UInt8](repeating: 0, count: 4096)
    let status = pixels.withUnsafeBufferPointer { source in
        rawPayload.withUnsafeMutableBufferPointer { destination in
            password.withCString { passwordPointer in
                bwm_diag_extract(
                    source.baseAddress,
                    Int32(width),
                    Int32(height),
                    4,
                    passwordPointer,
                    d1,
                    Int32(payload.count),
                    &info,
                    destination.baseAddress,
                    Int32(destination.count)
                )
            }
        }
    }
    guard status == Int32(BWM_OK) else { return nil }
    let length = max(0, min(Int(info.payload_len), rawPayload.count))
    return DiagnosticResult(
        headerMagicOK: info.header_magic_ok != 0,
        crcOK: info.crc_ok != 0,
        isText: info.is_text != 0,
        payload: Array(rawPayload[0..<length])
    )
}

private func psnr(_ original: [UInt8], _ modified: [UInt8]) -> Double {
    var squaredError = 0.0
    var componentCount = 0
    for index in stride(from: 0, to: original.count, by: 4) {
        for channel in 0..<3 {
            let difference = Double(original[index + channel]) - Double(modified[index + channel])
            squaredError += difference * difference
            componentCount += 1
        }
    }
    let mse = squaredError / Double(componentCount)
    return mse == 0 ? .infinity : 10.0 * log10((255.0 * 255.0) / mse)
}

private func bitErrorRate(expected: [UInt8], actual: [UInt8]) -> Double {
    guard expected.count == actual.count else { return 1.0 }
    var bitErrors = 0
    for index in expected.indices {
        bitErrors += (expected[index] ^ actual[index]).nonzeroBitCount
    }
    return Double(bitErrors) / Double(expected.count * 8)
}

private func percent(_ value: Double) -> String {
    String(format: "%5.1f%%", value * 100.0)
}

private func printTable(title: String, results: [SweepResult],
                        value: (AttackStats) -> String) {
    print("\n\(title)")
    print("d1 | " + Attack.allCases.map(\.rawValue).joined(separator: " | "))
    print(String(repeating: "---|", count: Attack.allCases.count + 1))
    for result in results {
        let cells = Attack.allCases.map { attack in
            value(result.stats[attack] ?? AttackStats())
        }
        print(String(format: "%2.0f | ", result.d1) + cells.joined(separator: " | "))
    }
}

private let images: [RGBAImage] = ImageCategory.allCases.flatMap { category in
    (0..<3).map { variant in makeImage(category: category, variant: variant) }
}
print("V1 regression: \(images.count) images (4 categories x 3), \(imageSize)x\(imageSize), d1=36")
print("Payload: \(payload.count) bytes, password: \(password)")
print("Brightness attack: RGB x 1.10/0.90; contrast attack: (RGB - 128) x 1.10/0.90 + 128")
print("BER: raw payload bit errors using the known payload length; header magic does not gate BER")

private var results: [SweepResult] = []
private var failures: [String] = []

for d1 in d1Values {
    var stats = Dictionary(uniqueKeysWithValues: Attack.allCases.map { ($0, AttackStats()) })
    var psnrSum = 0.0

    for (imageIndex, image) in images.enumerated() {
        guard let embedded = embed(image, d1: d1) else {
            failures.append("embed failed d1=\(d1) image=\(imageIndex)")
            continue
        }

        psnrSum += psnr(image.pixels, embedded)
        guard let baseline = diagnose(embedded, width: image.width, height: image.height, d1: d1),
              baseline.headerMagicOK, baseline.crcOK,
              baseline.payload == payload,
              publicExtract(embedded, width: image.width, height: image.height, d1: d1) == payload else {
            failures.append("baseline extraction failed d1=\(d1) image=\(imageIndex)")
            continue
        }

        for attack in Attack.allCases {
            let seed = UInt64(imageIndex + 1) &* 0x9E37_79B9_7F4A_7C15
            guard let attacked = applyAttack(attack, to: RGBAImage(width: image.width,
                                                                   height: image.height,
                                                                   pixels: embedded),
                                             seed: seed) else {
                failures.append("attack failed d1=\(d1) image=\(imageIndex) attack=\(attack.rawValue)")
                continue
            }
            guard let diagnostic = diagnose(attacked.pixels, width: attacked.width,
                                            height: attacked.height, d1: d1) else {
                failures.append("diagnose failed d1=\(d1) image=\(imageIndex) attack=\(attack.rawValue)")
                continue
            }

            var current = stats[attack] ?? AttackStats()
            current.count += 1
            if diagnostic.headerMagicOK { current.magicCount += 1 }
            if diagnostic.crcOK { current.crcCount += 1 }
            if diagnostic.payload.count == payload.count {
                current.berSum += bitErrorRate(expected: payload, actual: diagnostic.payload)
            } else {
                current.berSum += 1.0
            }
            stats[attack] = current
        }
    }

    let mustPass = [Attack.jpeg90, .jpeg80, .resizeHalf].allSatisfy {
        (stats[$0]?.crcRate ?? 0) >= 0.90
    }
    let expectedPass = [Attack.brightnessUp, .brightnessDown, .contrastUp,
                        .contrastDown, .noise2].allSatisfy {
        (stats[$0]?.crcRate ?? 0) >= 0.80
    }
    let averagePSNR = psnrSum / Double(images.count)
    results.append(SweepResult(d1: d1, averagePSNR: averagePSNR, stats: stats,
                               mustPass: mustPass, expectedPass: expectedPass))
    print(String(format: "d1=%2.0f avgPSNR=%.3f dB must=%d expected=%d eligible=%d",
                 d1, averagePSNR, mustPass ? 1 : 0, expectedPass ? 1 : 0,
                 (mustPass && expectedPass) ? 1 : 0))
}

if !failures.isEmpty {
    print("\nFailures:")
    failures.prefix(20).forEach { print("- \($0)") }
    print("total failures=\(failures.count)")
    exit(1)
}

printTable(title: "CRC success matrix", results: results) { percent($0.crcRate) }
printTable(title: "Header magic matrix", results: results) { percent($0.magicRate) }
printTable(title: "BER matrix (lower is better)", results: results) { percent($0.averageBER) }

print("\nAverage embedding PSNR")
print("d1 | avg PSNR | must | expected | eligible")
print("---|---|---|---|---")
for result in results {
    print(String(format: "%2.0f | %.3f dB | %@ | %@ | %@",
                 result.d1, result.averagePSNR,
                 result.mustPass ? "pass" : "fail",
                 result.expectedPass ? "pass" : "fail",
                 result.eligible ? "yes" : "no"))
}

private let eligible = results.filter(\.eligible)
if let recommended = eligible.max(by: { $0.averagePSNR < $1.averagePSNR }) {
    print(String(format: "\nRECOMMENDED_D1=%.0f (avg PSNR %.3f dB)",
                 recommended.d1, recommended.averagePSNR))
} else {
    print("\nRECOMMENDED_D1=none (no d1 met the must-pass and expected thresholds)")
}
