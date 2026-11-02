import Accelerate
import AppKit
import CoreGraphics
import Darwin
import Foundation
import ImageIO

private let imageSize = 512
private let password = "d1-sweep-password"
private let payload: [UInt8] = (0..<32).map { UInt8(($0 * 37 + 11) & 0xFF) }

private let headerBytes = 8
private let redundancy = 3
private let headerBits = headerBytes * 8
private let headerBlocks = headerBits * redundancy
private let headerMagic: UInt16 = 0xBA5E
private let headerVersion: UInt8 = 0x03

private let seedDomainBlock: UInt64 = 0x424C4F434B000001
private let seedDomainHeader: UInt64 = 0x4845414445520001
private let seedDomainPayload: UInt64 = 0x5041594C4F414401
private let dqValues: [Double] = [0.05, 0.03, 0.08]

private struct RGBAImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]
}

private enum ImageCategory: String, CaseIterable {
    case flat, texture, dark, bright
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

private struct QSample {
    let blockIndex: Int
    let qBefore: Double
    let qTarget: Double
}

private struct QDeviation {
    let meanTargetToExtract: Double
    let maxTargetToExtract: Double
    let meanBeforeToExtract: Double
    let maxBeforeToExtract: Double
}

private struct SweepResult {
    let dq: Double
    let averagePSNR: Double
    let stats: [Attack: AttackStats]
    let qDeviation: QDeviation
    let skippedBlocks: Int
    let baselineFailures: Int
}

private struct ExtractDiagnostic {
    let magicOK: Bool
    let version: UInt8
    let crcOK: Bool
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
    return UInt8(value + 0.5)
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

private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
private let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
    CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
)

private func makeCGImage(from image: RGBAImage) -> CGImage? {
    guard let provider = CGDataProvider(data: Data(image.pixels) as CFData) else { return nil }
    return CGImage(width: image.width, height: image.height,
                   bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: image.width * 4,
                   space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                   decode: nil, shouldInterpolate: true, intent: .defaultIntent)
}

private func rgbaImage(from cgImage: CGImage) -> RGBAImage? {
    var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
    let created = pixels.withUnsafeMutableBytes { rawBuffer -> Bool in
        guard let context = CGContext(data: rawBuffer.baseAddress,
                                      width: cgImage.width, height: cgImage.height,
                                      bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                                      space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
            return false
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        return true
    }
    return created ? RGBAImage(width: cgImage.width, height: cgImage.height, pixels: pixels) : nil
}

private func render(_ cgImage: CGImage, width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
        return nil
    }
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
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

private func jpegRoundTrip(_ image: RGBAImage, quality: Double) -> RGBAImage? {
    guard let cgImage = makeCGImage(from: image) else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data, "public.jpeg" as CFString, 1, nil
    ) else { return nil }
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
    case .jpeg95: return jpegRoundTrip(image, quality: 0.95)
    case .jpeg90: return jpegRoundTrip(image, quality: 0.90)
    case .jpeg80: return jpegRoundTrip(image, quality: 0.80)
    case .jpeg70: return jpegRoundTrip(image, quality: 0.70)
    case .resizeHalf: return resizeRoundTrip(image, factor: 0.5)
    case .resizeOneAndHalf: return resizeRoundTrip(image, factor: 1.5)
    case .noise2: return addNoise(image, sigma: 2.0, seed: seed)
    case .noise5: return addNoise(image, sigma: 5.0, seed: seed)
    case .brightnessUp: return adjustBrightness(image, factor: 1.10)
    case .brightnessDown: return adjustBrightness(image, factor: 0.90)
    case .contrastUp: return adjustContrast(image, factor: 1.10)
    case .contrastDown: return adjustContrast(image, factor: 0.90)
    }
}

private func pixelsToYUV(_ image: RGBAImage) -> (y: [Float], u: [Float], v: [Float]) {
    let count = image.width * image.height
    var y = [Float](repeating: 0, count: count)
    var u = [Float](repeating: 0, count: count)
    var v = [Float](repeating: 0, count: count)
    for i in 0..<count {
        let index = i * 4
        let r = Double(image.pixels[index])
        let g = Double(image.pixels[index + 1])
        let b = Double(image.pixels[index + 2])
        y[i] = Float(0.299 * r + 0.587 * g + 0.114 * b)
        u[i] = Float(-0.14713 * r - 0.28886 * g + 0.436 * b + 128.0)
        v[i] = Float(0.615 * r - 0.51499 * g - 0.10001 * b + 128.0)
    }
    return (y, u, v)
}

private func yuvToPixels(y: [Float], u: [Float], v: [Float], source: RGBAImage) -> RGBAImage {
    var pixels = source.pixels
    let count = source.width * source.height
    for i in 0..<count {
        let uValue = Double(u[i]) - 128.0
        let vValue = Double(v[i]) - 128.0
        let r = Double(y[i]) + 1.13983 * vValue
        let g = Double(y[i]) - 0.39465 * uValue - 0.58060 * vValue
        let b = Double(y[i]) + 2.03211 * uValue
        let index = i * 4
        pixels[index] = clampToByte(r)
        pixels[index + 1] = clampToByte(g)
        pixels[index + 2] = clampToByte(b)
    }
    return RGBAImage(width: source.width, height: source.height, pixels: pixels)
}

private let dctMatrix: [[Float]] = [
    [0.5, 0.5, 0.5, 0.5],
    [0.6532814824, 0.2705980501, -0.2705980501, -0.6532814824],
    [0.5, -0.5, -0.5, 0.5],
    [0.2705980501, -0.6532814824, 0.6532814824, -0.2705980501],
]

private func dct4x4(_ input: [Float]) -> [Float] {
    var rowTransformed = [Float](repeating: 0, count: 16)
    var output = [Float](repeating: 0, count: 16)
    for row in 0..<4 {
        for v in 0..<4 {
            var sum: Float = 0
            for c in 0..<4 { sum += input[row * 4 + c] * dctMatrix[v][c] }
            rowTransformed[row * 4 + v] = sum
        }
    }
    for v in 0..<4 {
        for u in 0..<4 {
            var sum: Float = 0
            for row in 0..<4 { sum += rowTransformed[row * 4 + v] * dctMatrix[u][row] }
            output[u * 4 + v] = sum
        }
    }
    return output
}

private func idct4x4(_ input: [Float]) -> [Float] {
    var columnRestored = [Float](repeating: 0, count: 16)
    var output = [Float](repeating: 0, count: 16)
    for v in 0..<4 {
        for row in 0..<4 {
            var sum: Float = 0
            for u in 0..<4 { sum += input[u * 4 + v] * dctMatrix[u][row] }
            columnRestored[row * 4 + v] = sum
        }
    }
    for row in 0..<4 {
        for col in 0..<4 {
            var sum: Float = 0
            for v in 0..<4 { sum += columnRestored[row * 4 + v] * dctMatrix[v][col] }
            output[row * 4 + col] = sum
        }
    }
    return output
}

private func svd4x4(_ input: [Float]) -> (u: [Float], s: [Float], vt: [Float]) {
    var a = [Float](repeating: 0, count: 16)
    for row in 0..<4 {
        for col in 0..<4 { a[col * 4 + row] = input[row * 4 + col] }
    }
    var singularValues = [Float](repeating: 0, count: 4)
    var uColumnMajor = [Float](repeating: 0, count: 16)
    var vtColumnMajor = [Float](repeating: 0, count: 16)
    var work = [Float](repeating: 0, count: 256)
    var jobu: Int8 = 65
    var jobvt: Int8 = 65
    var m: Int32 = 4
    var n: Int32 = 4
    var lda: Int32 = 4
    var ldu: Int32 = 4
    var ldvt: Int32 = 4
    var lwork: Int32 = 256
    var info: Int32 = 0
    _ = sgesvd_(&jobu, &jobvt, &m, &n, &a, &lda, &singularValues,
                &uColumnMajor, &ldu, &vtColumnMajor, &ldvt, &work, &lwork, &info)
    guard info == 0 else {
        return ([Float](repeating: 0, count: 16),
                [Float](repeating: 0, count: 4),
                [Float](repeating: 0, count: 16))
    }
    var u = [Float](repeating: 0, count: 16)
    var vt = [Float](repeating: 0, count: 16)
    for row in 0..<4 {
        for col in 0..<4 {
            u[row * 4 + col] = uColumnMajor[col * 4 + row]
            vt[row * 4 + col] = vtColumnMajor[col * 4 + row]
        }
    }
    return (u, singularValues, vt)
}

private func svdReconstruct(u: [Float], s: [Float], vt: [Float]) -> [Float] {
    var output = [Float](repeating: 0, count: 16)
    for row in 0..<4 {
        for col in 0..<4 {
            var sum: Float = 0
            for k in 0..<4 { sum += u[row * 4 + k] * s[k] * vt[k * 4 + col] }
            output[row * 4 + col] = sum
        }
    }
    return output
}

private func dwt2(_ input: [Float], width: Int, height: Int) -> (ll: [Float], h: [Float], llWidth: Int, llHeight: Int) {
    let llWidth = width / 2
    let llHeight = height / 2
    let count = llWidth * llHeight
    var ll = [Float](repeating: 0, count: count)
    var h = [Float](repeating: 0, count: 3 * count)
    for y in stride(from: 0, to: height, by: 2) {
        for x in stride(from: 0, to: width, by: 2) {
            let a = input[y * width + x]
            let b = input[y * width + x + 1]
            let c = input[(y + 1) * width + x]
            let d = input[(y + 1) * width + x + 1]
            let index = (y / 2) * llWidth + x / 2
            ll[index] = (a + b + c + d) * 0.5
            h[index] = (a + b - c - d) * 0.5
            h[count + index] = (a - b + c - d) * 0.5
            h[2 * count + index] = (a - b - c + d) * 0.5
        }
    }
    return (ll, h, llWidth, llHeight)
}

private func idwt2(ll: [Float], h: [Float], llWidth: Int, llHeight: Int,
                    width: Int, height: Int) -> [Float] {
    let count = llWidth * llHeight
    var output = [Float](repeating: 0, count: width * height)
    for y in stride(from: 0, to: height, by: 2) {
        for x in stride(from: 0, to: width, by: 2) {
            let index = (y / 2) * llWidth + x / 2
            let llValue = ll[index]
            let lh = h[index]
            let hl = h[count + index]
            let hh = h[2 * count + index]
            output[y * width + x] = (llValue + lh + hl + hh) * 0.5
            output[y * width + x + 1] = (llValue + lh - hl - hh) * 0.5
            output[(y + 1) * width + x] = (llValue - lh + hl - hh) * 0.5
            output[(y + 1) * width + x + 1] = (llValue - lh - hl + hh) * 0.5
        }
    }
    return output
}

private func extractBlock(_ ll: [Float], llWidth: Int, blocksWidth: Int, blockIndex: Int) -> [Float] {
    let blockRow = blockIndex / blocksWidth
    let blockCol = blockIndex % blocksWidth
    let baseRow = blockRow * 4
    let baseCol = blockCol * 4
    var block = [Float](repeating: 0, count: 16)
    for row in 0..<4 {
        for col in 0..<4 { block[row * 4 + col] = ll[(baseRow + row) * llWidth + baseCol + col] }
    }
    return block
}

private func writeBlock(_ block: [Float], to ll: inout [Float], llWidth: Int,
                        blocksWidth: Int, blockIndex: Int) {
    let blockRow = blockIndex / blocksWidth
    let blockCol = blockIndex % blocksWidth
    let baseRow = blockRow * 4
    let baseCol = blockCol * 4
    for row in 0..<4 {
        for col in 0..<4 { ll[(baseRow + row) * llWidth + baseCol + col] = block[row * 4 + col] }
    }
}

private func blockQuantity(_ ll: [Float], llWidth: Int, blocksWidth: Int,
                           blockIndex: Int) -> (q: Double, energy: Double) {
    let block = extractBlock(ll, llWidth: llWidth, blocksWidth: blocksWidth, blockIndex: blockIndex)
    let coefficients = dct4x4(block)
    let (_, s, _) = svd4x4(coefficients)
    var energySquared: Double = 0
    for value in s { energySquared += Double(value) * Double(value) }
    let energy = sqrt(energySquared)
    guard energy > 1.0e-12 else { return (0, 0) }
    return (Double(s[0]) / energy, energy)
}

private func embedBitInLL(_ ll: inout [Float], llWidth: Int, blocksWidth: Int,
                          blockIndex: Int, bit: UInt8, dq: Double) -> (QSample?, Bool) {
    let block = extractBlock(ll, llWidth: llWidth, blocksWidth: blocksWidth, blockIndex: blockIndex)
    let coefficients = dct4x4(block)
    let (u, s, vt) = svd4x4(coefficients)
    var energySquared: Double = 0
    for value in s { energySquared += Double(value) * Double(value) }
    let energy = sqrt(energySquared)
    guard energy > 1.0e-12 else { return (nil, false) }
    let q = Double(s[0]) / energy
    let cell = floor(q / dq)
    let target = (cell + (bit == 1 ? 0.75 : 0.25)) * dq
    guard target > 0.0 && target < 1.0 else { return (nil, false) }
    var modifiedS = s
    modifiedS[0] = Float(target * energy)
    let frequency = svdReconstruct(u: u, s: modifiedS, vt: vt)
    let restored = idct4x4(frequency)
    writeBlock(restored, to: &ll, llWidth: llWidth, blocksWidth: blocksWidth, blockIndex: blockIndex)
    return (QSample(blockIndex: blockIndex, qBefore: q, qTarget: target), true)
}

private func readBitFromLL(_ ll: [Float], llWidth: Int, blocksWidth: Int,
                           blockIndex: Int, dq: Double) -> UInt8 {
    let quantity = blockQuantity(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                                 blockIndex: blockIndex)
    let scaled = quantity.q / dq
    let cell = floor(scaled)
    let fraction = scaled - cell
    return fraction >= 0.5 ? 1 : 0
}

private func crc16CCITT(_ data: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0xFFFF
    for byte in data {
        crc ^= UInt16(byte) << 8
        for _ in 0..<8 {
            crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
        }
    }
    return crc
}

private func buildHeader(payloadLength: Int, isText: Bool) -> [UInt8] {
    let crc = crc16CCITT(payload)
    return [UInt8(headerMagic >> 8), UInt8(headerMagic & 0xFF), headerVersion,
            isText ? 0x01 : 0x00, UInt8((payloadLength >> 8) & 0xFF),
            UInt8(payloadLength & 0xFF), UInt8(crc >> 8), UInt8(crc & 0xFF)]
}

private func bytesToRepeatedBits(_ bytes: [UInt8]) -> [UInt8] {
    var bits = [UInt8]()
    bits.reserveCapacity(bytes.count * 8 * redundancy)
    for byte in bytes {
        for bit in stride(from: 7, through: 0, by: -1) {
            let value = (byte >> UInt8(bit)) & 1
            bits.append(value); bits.append(value); bits.append(value)
        }
    }
    return bits
}

private func repeatedBitsToBytes(_ bits: [UInt8], byteCount: Int) -> [UInt8] {
    var output = [UInt8](repeating: 0, count: byteCount)
    var index = 0
    for byteIndex in 0..<byteCount {
        var value: UInt8 = 0
        for _ in 0..<8 {
            let votes = Int(bits[index]) + Int(bits[index + 1]) + Int(bits[index + 2])
            index += 3
            value = (value << 1) | (votes >= 2 ? 1 : 0)
        }
        output[byteIndex] = value
    }
    return output
}

private func passwordSeed(_ password: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in password.utf8 {
        hash ^= UInt64(byte)
        hash = hash &* 1_099_511_628_211
    }
    return hash
}

private func deriveSeed(password: String, domain: UInt64) -> UInt64 {
    var rng = SplitMix64(state: passwordSeed(password) ^ domain)
    return rng.next()
}

private func shuffledOrder(count: Int, seed: UInt64) -> [Int] {
    var order = Array(0..<count)
    var rng = SplitMix64(state: seed)
    var i = count
    while i > 1 {
        let j = Int(rng.next() % UInt64(i))
        order.swapAt(i - 1, j)
        i -= 1
    }
    return order
}

private func permuteForward(_ source: [UInt8], permutation: [Int]) -> [UInt8] {
    var destination = [UInt8](repeating: 0, count: source.count)
    for i in source.indices { destination[i] = source[permutation[i]] }
    return destination
}

private func permuteInverse(_ source: [UInt8], permutation: [Int]) -> [UInt8] {
    var destination = [UInt8](repeating: 0, count: source.count)
    for i in source.indices { destination[permutation[i]] = source[i] }
    return destination
}

private func embedB1(_ image: RGBAImage, dq: Double) -> (image: RGBAImage, samples: [QSample], skipped: Int)? {
    let (y, u, v) = pixelsToYUV(image)
    let (ll, h, llWidth, llHeight) = dwt2(y, width: image.width, height: image.height)
    let blocksWidth = llWidth / 4
    let blocksHeight = llHeight / 4
    let blockCount = blocksWidth * blocksHeight
    guard blockCount >= headerBlocks + redundancy * payload.count * 8 else { return nil }

    var modifiedLL = ll
    let blockOrder = shuffledOrder(count: blockCount,
                                   seed: deriveSeed(password: password, domain: seedDomainBlock))
    let headerSequence = bytesToRepeatedBits(buildHeader(payloadLength: payload.count, isText: false))
    let headerPermutation = shuffledOrder(count: headerSequence.count,
                                          seed: deriveSeed(password: password, domain: seedDomainHeader))
    let scrambledHeader = permuteForward(headerSequence, permutation: headerPermutation)
    let payloadSequence = bytesToRepeatedBits(payload)
    let payloadPermutation = shuffledOrder(count: payloadSequence.count,
                                           seed: deriveSeed(password: password, domain: seedDomainPayload))
    let scrambledPayload = permuteForward(payloadSequence, permutation: payloadPermutation)

    var samples = [QSample]()
    samples.reserveCapacity(headerBlocks + payloadSequence.count)
    var skipped = 0
    for i in 0..<headerBlocks {
        let (sample, ok) = embedBitInLL(&modifiedLL, llWidth: llWidth, blocksWidth: blocksWidth,
                                        blockIndex: blockOrder[i], bit: scrambledHeader[i], dq: dq)
        if ok, let sample { samples.append(sample) } else { skipped += 1 }
    }
    for i in 0..<payloadSequence.count {
        let (sample, ok) = embedBitInLL(&modifiedLL, llWidth: llWidth, blocksWidth: blocksWidth,
                                        blockIndex: blockOrder[headerBlocks + i],
                                        bit: scrambledPayload[i], dq: dq)
        if ok, let sample { samples.append(sample) } else { skipped += 1 }
    }
    let restoredY = idwt2(ll: modifiedLL, h: h, llWidth: llWidth, llHeight: llHeight,
                          width: image.width, height: image.height)
    let output = yuvToPixels(y: restoredY, u: u, v: v, source: image)
    return (output, samples, skipped)
}

private func extractB1(_ image: RGBAImage, dq: Double, expectedPayloadLength: Int) -> ExtractDiagnostic {
    let (y, _, _) = pixelsToYUV(image)
    let (ll, _, llWidth, llHeight) = dwt2(y, width: image.width, height: image.height)
    let blocksWidth = llWidth / 4
    let blocksHeight = llHeight / 4
    let blockCount = blocksWidth * blocksHeight
    if blockCount < headerBlocks {
        return ExtractDiagnostic(magicOK: false, version: 0, crcOK: false, payload: [])
    }
    let blockOrder = shuffledOrder(count: blockCount,
                                   seed: deriveSeed(password: password, domain: seedDomainBlock))
    let headerPermutation = shuffledOrder(count: headerBlocks,
                                          seed: deriveSeed(password: password, domain: seedDomainHeader))
    var scrambledHeader = [UInt8](repeating: 0, count: headerBlocks)
    for i in 0..<headerBlocks {
        scrambledHeader[i] = readBitFromLL(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                                           blockIndex: blockOrder[i], dq: dq)
    }
    let header = repeatedBitsToBytes(permuteInverse(scrambledHeader, permutation: headerPermutation),
                                     byteCount: headerBytes)
    let magic = (UInt16(header[0]) << 8) | UInt16(header[1])
    let version = header[2]
    let magicOK = magic == headerMagic && version == headerVersion
    let headerPayloadLength = (Int(header[4]) << 8) | Int(header[5])
    let headerCRC = (UInt16(header[6]) << 8) | UInt16(header[7])

    let payloadSequenceCount = expectedPayloadLength * 8 * redundancy
    guard blockCount >= headerBlocks + payloadSequenceCount else {
        return ExtractDiagnostic(magicOK: magicOK, version: version, crcOK: false, payload: [])
    }
    let payloadPermutation = shuffledOrder(count: payloadSequenceCount,
                                           seed: deriveSeed(password: password, domain: seedDomainPayload))
    var scrambledPayload = [UInt8](repeating: 0, count: payloadSequenceCount)
    for i in 0..<payloadSequenceCount {
        scrambledPayload[i] = readBitFromLL(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                                            blockIndex: blockOrder[headerBlocks + i], dq: dq)
    }
    let decodedPayload = repeatedBitsToBytes(
        permuteInverse(scrambledPayload, permutation: payloadPermutation),
        byteCount: expectedPayloadLength
    )
    let crcOK = magicOK && headerPayloadLength == expectedPayloadLength &&
        crc16CCITT(decodedPayload) == headerCRC
    return ExtractDiagnostic(magicOK: magicOK, version: version, crcOK: crcOK,
                             payload: decodedPayload)
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

private func quantile(_ sorted: [Double], _ probability: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let position = probability * Double(sorted.count - 1)
    let lower = Int(floor(position))
    let upper = Int(ceil(position))
    if lower == upper { return sorted[lower] }
    let fraction = position - Double(lower)
    return sorted[lower] * (1.0 - fraction) + sorted[upper] * fraction
}

private func percent(_ value: Double) -> String {
    String(format: "%5.1f%%", value * 100.0)
}

private func printTable(title: String, results: [SweepResult],
                        value: (AttackStats) -> String) {
    print("\n\(title)")
    print("dq | " + Attack.allCases.map(\.rawValue).joined(separator: " | "))
    print(String(repeating: "---|", count: Attack.allCases.count + 1))
    for result in results {
        let cells = Attack.allCases.map { value(result.stats[$0] ?? AttackStats()) }
        print(String(format: "%.2f | ", result.dq) + cells.joined(separator: " | "))
    }
}

private let images: [RGBAImage] = ImageCategory.allCases.flatMap { category in
    (0..<3).map { variant in makeImage(category: category, variant: variant) }
}

private func runQDistribution() {
    var quantities = [Double]()
    quantities.reserveCapacity(images.count * (imageSize / 8) * (imageSize / 8))
    for image in images {
        let (y, _, _) = pixelsToYUV(image)
        let (ll, _, llWidth, llHeight) = dwt2(y, width: image.width, height: image.height)
        let blocksWidth = llWidth / 4
        let blocksHeight = llHeight / 4
        for blockIndex in 0..<(blocksWidth * blocksHeight) {
            quantities.append(blockQuantity(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                                            blockIndex: blockIndex).q)
        }
    }
    quantities.sort()
    let total = quantities.count
    let inBand = quantities.filter { $0 >= 0.6 && $0 <= 0.9 }.count
    let above95 = quantities.filter { $0 > 0.95 }.count
    let above99 = quantities.filter { $0 > 0.99 }.count
    let below60 = quantities.filter { $0 < 0.6 }.count
    let above90 = quantities.filter { $0 > 0.9 }.count

    print("B1 q distribution: \(images.count) images, \(total) LL blocks")
    print(String(format: "min=%.6f max=%.6f", quantities.first ?? 0, quantities.last ?? 0))
    print(String(format: "P5=%.6f", quantile(quantities, 0.05)))
    print(String(format: "P25=%.6f", quantile(quantities, 0.25)))
    print(String(format: "P50=%.6f", quantile(quantities, 0.50)))
    print(String(format: "P75=%.6f", quantile(quantities, 0.75)))
    print(String(format: "P95=%.6f", quantile(quantities, 0.95)))
    print(String(format: "in[0.60,0.90]=%d (%.2f%%)", inBand, 100.0 * Double(inBand) / Double(total)))
    print(String(format: "q<0.60=%d (%.2f%%)", below60, 100.0 * Double(below60) / Double(total)))
    print(String(format: "q>0.90=%d (%.2f%%)", above90, 100.0 * Double(above90) / Double(total)))
    print(String(format: "q>0.95=%d (%.2f%%)", above95, 100.0 * Double(above95) / Double(total)))
    print(String(format: "q>0.99=%d (%.2f%%)", above99, 100.0 * Double(above99) / Double(total)))

    let binCount = 20
    var bins = [Int](repeating: 0, count: binCount)
    for value in quantities {
        bins[max(0, min(binCount - 1, Int(value * Double(binCount))))] += 1
    }
    let maximum = bins.max() ?? 1
    print("\nHistogram (bin width 0.05)")
    for bin in 0..<binCount {
        let lower = Double(bin) / Double(binCount)
        let upper = Double(bin + 1) / Double(binCount)
        let barCount = maximum > 0 ? Int((Double(bins[bin]) / Double(maximum) * 60.0).rounded()) : 0
        print(String(format: "[%.2f,%.2f) %6d %@", lower, upper, bins[bin],
                     String(repeating: "#", count: barCount)))
    }

    let zoomLower = max(0.9990, quantities.first ?? 0)
    let zoomUpper = min(1.0000, (quantities.last ?? 1.0) + 0.0000001)
    var zoomBins = [Int](repeating: 0, count: binCount)
    var zoomUnderflow = 0
    for value in quantities {
        if value < zoomLower { zoomUnderflow += 1; continue }
        let normalized = (value - zoomLower) / (zoomUpper - zoomLower)
        zoomBins[max(0, min(binCount - 1, Int(normalized * Double(binCount))))] += 1
    }
    let zoomMaximum = zoomBins.max() ?? 1
    print("\nZoom histogram [\(String(format: "%.6f", zoomLower)), \(String(format: "%.6f", zoomUpper))]")
    print("values below lower bound: \(zoomUnderflow)")
    for bin in 0..<binCount {
        let lower = zoomLower + Double(bin) / Double(binCount) * (zoomUpper - zoomLower)
        let upper = zoomLower + Double(bin + 1) / Double(binCount) * (zoomUpper - zoomLower)
        let barCount = zoomMaximum > 0 ? Int((Double(zoomBins[bin]) / Double(zoomMaximum) * 60.0).rounded()) : 0
        print(String(format: "[%.6f,%.6f) %6d %@", lower, upper, zoomBins[bin],
                     String(repeating: "#", count: barCount)))
    }
}

private func runSweep() {
    var results = [SweepResult]()
    for dq in dqValues {
        var stats = Dictionary(uniqueKeysWithValues: Attack.allCases.map { ($0, AttackStats()) })
        var psnrSum = 0.0
        var squaredDifferenceSum = 0.0
        var perImagePSNR = [Double]()
        var absoluteDifferenceSum = 0.0
        var changedChannelCount = 0
        var comparedChannelCount = 0
        var skippedBlocks = 0
        var baselineFailures = 0
        var targetDeviationSum = 0.0
        var beforeDeviationSum = 0.0
        var targetDeviationMax = 0.0
        var beforeDeviationMax = 0.0
        var deviationCount = 0

        for (imageIndex, image) in images.enumerated() {
            guard let embedded = embedB1(image, dq: dq) else {
                print("embed failed dq=\(dq) image=\(imageIndex)")
                continue
            }
            skippedBlocks += embedded.skipped
            let imagePSNR = psnr(image.pixels, embedded.image.pixels)
            psnrSum += imagePSNR
            perImagePSNR.append(imagePSNR)
            for index in stride(from: 0, to: image.pixels.count, by: 4) {
                for channel in 0..<3 {
                    let difference = abs(Int(image.pixels[index + channel]) -
                                         Int(embedded.image.pixels[index + channel]))
                    absoluteDifferenceSum += Double(difference)
                    squaredDifferenceSum += Double(difference * difference)
                    if difference != 0 { changedChannelCount += 1 }
                    comparedChannelCount += 1
                }
            }
            let baseline = extractB1(embedded.image, dq: dq, expectedPayloadLength: payload.count)
            if !baseline.crcOK { baselineFailures += 1 }

            let (y, _, _) = pixelsToYUV(embedded.image)
            let (ll, _, llWidth, _) = dwt2(y, width: embedded.image.width,
                                           height: embedded.image.height)
            let blocksWidth = llWidth / 4
            for sample in embedded.samples {
                let quantity = blockQuantity(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                                             blockIndex: sample.blockIndex)
                let targetDifference = abs(quantity.q - sample.qTarget)
                let beforeDifference = abs(quantity.q - sample.qBefore)
                targetDeviationSum += targetDifference
                beforeDeviationSum += beforeDifference
                targetDeviationMax = max(targetDeviationMax, targetDifference)
                beforeDeviationMax = max(beforeDeviationMax, beforeDifference)
                deviationCount += 1
            }

            for attack in Attack.allCases {
                let seed = UInt64(imageIndex + 1) &* 0x9E37_79B9_7F4A_7C15
                guard let attacked = applyAttack(attack, to: embedded.image, seed: seed) else {
                    var current = stats[attack] ?? AttackStats()
                    current.count += 1
                    current.berSum += 1.0
                    stats[attack] = current
                    continue
                }
                let diagnostic = extractB1(attacked, dq: dq,
                                           expectedPayloadLength: payload.count)
                var current = stats[attack] ?? AttackStats()
                current.count += 1
                if diagnostic.magicOK { current.magicCount += 1 }
                if diagnostic.crcOK { current.crcCount += 1 }
                current.berSum += bitErrorRate(expected: payload, actual: diagnostic.payload)
                stats[attack] = current
            }
        }

        let count = max(deviationCount, 1)
        let deviation = QDeviation(
            meanTargetToExtract: targetDeviationSum / Double(count),
            maxTargetToExtract: targetDeviationMax,
            meanBeforeToExtract: beforeDeviationSum / Double(count),
            maxBeforeToExtract: beforeDeviationMax
        )
        results.append(SweepResult(dq: dq,
                                   averagePSNR: psnrSum / Double(images.count),
                                   stats: stats,
                                   qDeviation: deviation,
                                   skippedBlocks: skippedBlocks,
                                   baselineFailures: baselineFailures))
        print(String(format: "dq=%.2f avgPSNR=%.3f dB skipped=%d baselineFailures=%d",
                     dq, psnrSum / Double(images.count), skippedBlocks, baselineFailures))
        print(String(format: "dq=%.2f meanAbsRGBDiff=%.6f changedChannels=%d/%d",
                     dq, absoluteDifferenceSum / Double(max(comparedChannelCount, 1)),
                     changedChannelCount, comparedChannelCount))
        let finitePSNRs = perImagePSNR.filter { $0.isFinite }
        let finiteAveragePSNR = finitePSNRs.reduce(0, +) / Double(max(finitePSNRs.count, 1))
        let overallMSE = squaredDifferenceSum / Double(max(comparedChannelCount, 1))
        let overallPSNR = overallMSE > 0 ? 10.0 * log10((255.0 * 255.0) / overallMSE) : .infinity
        print(String(format: "dq=%.2f finiteAvgPSNR=%.3f dB overallPSNR=%.3f dB infiniteImages=%d",
                     dq, finiteAveragePSNR, overallPSNR,
                     perImagePSNR.count - finitePSNRs.count))
    }

    print("\nq target vs extracted")
    print("dq | mean|q'-q_target| | max|q'-q_target| | mean|q'-q_before| | max|q'-q_before| | dq/4 | mean>dq/4")
    print("---|---|---|---|---|---")
    for result in results {
        let deviation = result.qDeviation
        print(String(format: "%.2f | %.6f | %.6f | %.6f | %.6f | %.6f | %@",
                     result.dq, deviation.meanTargetToExtract,
                     deviation.maxTargetToExtract,
                     deviation.meanBeforeToExtract,
                     deviation.maxBeforeToExtract,
                     result.dq / 4.0,
                     deviation.meanTargetToExtract > result.dq / 4.0 ? "yes" : "no"))
    }

    printTable(title: "CRC success matrix", results: results) { percent($0.crcRate) }
    printTable(title: "Header magic/version matrix", results: results) { percent($0.magicRate) }
    printTable(title: "BER matrix (lower is better)", results: results) { percent($0.averageBER) }

    print("\nAverage embedding PSNR")
    print("dq | avg PSNR | skipped blocks | baseline failures")
    print("---|---|---|---")
    for result in results {
        print(String(format: "%.2f | %.3f dB | %d | %d",
                     result.dq, result.averagePSNR, result.skippedBlocks,
                     result.baselineFailures))
    }
}

private func meanAndStd(_ values: [Float]) -> (mean: Double, std: Double) {
    let count = Double(values.count)
    let mean = values.reduce(0.0) { $0 + Double($1) } / count
    var variance = 0.0
    for value in values {
        let difference = Double(value) - mean
        variance += difference * difference
    }
    return (mean, sqrt(variance / count))
}

private func blockS1Ratios(_ ll: [Float], llWidth: Int, blocksWidth: Int,
                           blockIndex: Int) -> (s1OverS0: Double, s1OverNorm: Double) {
    let block = extractBlock(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                             blockIndex: blockIndex)
    let coefficients = dct4x4(block)
    let (_, s, _) = svd4x4(coefficients)
    let s0 = Double(s[0])
    let s1 = Double(s[1])
    var energySquared = 0.0
    for value in s { energySquared += Double(value) * Double(value) }
    let norm = sqrt(energySquared)
    guard s0 > 1.0e-12, norm > 1.0e-12 else { return (0, 0) }
    return (s1 / s0, s1 / norm)
}

private func run7C() {
    print("方向一偏差基准：嵌入前原图 Y 的 mean/std；任一 ±10% 分支均值或标准差偏差 >5% 记为不可靠")
    var imageStats = [(mean: Double, std: Double)]()
    var yuvCache = [(y: [Float], u: [Float], v: [Float])]()
    for image in images {
        let yuv = pixelsToYUV(image)
        yuvCache.append(yuv)
        imageStats.append(meanAndStd(yuv.y))
    }
    let sortedStds = imageStats.map(\.std).sorted()
    let stdMedian = quantile(sortedStds, 0.5)
    var unreliable = 0
    var deviations = [Double]()

    for (imageIndex, image) in images.enumerated() {
        let source = yuvCache[imageIndex]
        let mean = imageStats[imageIndex].mean
        let std = imageStats[imageIndex].std
        let normalizedY = source.y.map {
            Float((Double($0) - mean) * (stdMedian / std) + 128.0)
        }
        let normalizedImage = yuvToPixels(y: normalizedY, u: source.u, v: source.v,
                                          source: image)
        guard let embedded = embedB1(normalizedImage, dq: 0.05) else {
            unreliable += 1
            continue
        }
        let (embeddedY, _, _) = pixelsToYUV(embedded.image)
        let inverseY = embeddedY.map {
            Float((Double($0) - 128.0) * (std / stdMedian) + mean)
        }
        let restored = yuvToPixels(y: inverseY, u: source.u, v: source.v, source: image)

        var imageUnreliable = false
        for factor in [1.10, 0.90] {
            let attacked = adjustBrightness(restored, factor: factor)
            let (attackedY, _, _) = pixelsToYUV(attacked)
            let attackedStats = meanAndStd(attackedY)
            let meanDeviation = abs(attackedStats.mean - mean) / max(abs(mean), 1.0e-9) * 100.0
            let stdDeviation = abs(attackedStats.std - std) / max(abs(std), 1.0e-9) * 100.0
            deviations.append(meanDeviation)
            deviations.append(stdDeviation)
            if meanDeviation > 5.0 || stdDeviation > 5.0 {
                imageUnreliable = true
            }
        }
        if imageUnreliable { unreliable += 1 }
    }

    if unreliable > 3 {
        print("方向一：不可靠图数/总数 = \(unreliable)/\(images.count)，已提前终止，不输出精度分位数")
        print("方向一判断：不可行，亮度 ±10% 使重算均值/标准差系统性偏移超过 5%")
    } else {
        deviations.sort()
        print(String(format: "方向一偏差%：P50=%.2f P95=%.2f max=%.2f 不可靠图数/总数=%d/%d",
                     quantile(deviations, 0.50), quantile(deviations, 0.95),
                     deviations.last ?? 0, unreliable, images.count))
        print("方向一判断：可行，重算归一化因子偏差可控")
    }

    var s1OverS0 = [Double]()
    var s1OverNorm = [Double]()
    s1OverS0.reserveCapacity(49152)
    s1OverNorm.reserveCapacity(49152)
    for image in images {
        let (y, _, _) = pixelsToYUV(image)
        let (ll, _, llWidth, llHeight) = dwt2(y, width: image.width, height: image.height)
        let blocksWidth = llWidth / 4
        let blockCount = blocksWidth * (llHeight / 4)
        for blockIndex in 0..<blockCount {
            let ratios = blockS1Ratios(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                                       blockIndex: blockIndex)
            s1OverS0.append(ratios.s1OverS0)
            s1OverNorm.append(ratios.s1OverNorm)
        }
    }
    s1OverS0.sort()
    s1OverNorm.sort()
    let total = Double(s1OverS0.count)
    let s1s0Count = s1OverS0.filter { $0 >= 0.05 && $0 <= 0.5 }.count
    let s1normCount = s1OverNorm.filter { $0 >= 0.05 && $0 <= 0.5 }.count
    let s1s0InBand = Double(s1s0Count) / total * 100.0
    let s1normInBand = Double(s1normCount) / total * 100.0

    print("方向二：总块数=\(s1OverS0.count)")
    print("指标 | P5 | P25 | P50 | P75 | P95 | [0.05,0.5]占比")
    print(String(format: "S1/S0 | %.6f | %.6f | %.6f | %.6f | %.6f | %d (%.2f%%)",
                 quantile(s1OverS0, 0.05), quantile(s1OverS0, 0.25),
                 quantile(s1OverS0, 0.50), quantile(s1OverS0, 0.75),
                 quantile(s1OverS0, 0.95), Int32(s1s0Count), s1s0InBand))
    print(String(format: "S1/||A||F | %.6f | %.6f | %.6f | %.6f | %.6f | %d (%.2f%%)",
                 quantile(s1OverNorm, 0.05), quantile(s1OverNorm, 0.25),
                 quantile(s1OverNorm, 0.50), quantile(s1OverNorm, 0.75),
                 quantile(s1OverNorm, 0.95), Int32(s1normCount), s1normInBand))

    if s1s0InBand < 10.0 && s1normInBand < 10.0 {
        print("方向二判断：不可行，S1 普遍过小，目标区间占比极低，B2 比值分母不稳定")
    } else {
        print("方向二判断：可行，S1 有足够块落入目标区间")
    }
}

private func dctMatrixN(_ size: Int) -> [[Float]] {
    var matrix = [[Float]](repeating: [Float](repeating: 0, count: size), count: size)
    for frequency in 0..<size {
        let scale = frequency == 0 ? sqrt(1.0 / Double(size)) : sqrt(2.0 / Double(size))
        for position in 0..<size {
            let angle = Double.pi * Double(2 * position + 1) * Double(frequency) /
                (2.0 * Double(size))
            matrix[frequency][position] = Float(scale * cos(angle))
        }
    }
    return matrix
}

private let dct8Matrix = dctMatrixN(8)

private func dct8x8(_ input: [Float]) -> [Float] {
    var rowTransformed = [Float](repeating: 0, count: 64)
    var output = [Float](repeating: 0, count: 64)
    for row in 0..<8 {
        for v in 0..<8 {
            var sum: Float = 0
            for c in 0..<8 { sum += input[row * 8 + c] * dct8Matrix[v][c] }
            rowTransformed[row * 8 + v] = sum
        }
    }
    for v in 0..<8 {
        for u in 0..<8 {
            var sum: Float = 0
            for row in 0..<8 { sum += rowTransformed[row * 8 + v] * dct8Matrix[u][row] }
            output[u * 8 + v] = sum
        }
    }
    return output
}

private func svd8x8(_ input: [Float]) -> (u: [Float], s: [Float], vt: [Float]) {
    var a = [Float](repeating: 0, count: 64)
    for row in 0..<8 {
        for col in 0..<8 { a[col * 8 + row] = input[row * 8 + col] }
    }
    var singularValues = [Float](repeating: 0, count: 8)
    var uColumnMajor = [Float](repeating: 0, count: 64)
    var vtColumnMajor = [Float](repeating: 0, count: 64)
    var work = [Float](repeating: 0, count: 512)
    var jobu: Int8 = 65
    var jobvt: Int8 = 65
    var m: Int32 = 8
    var n: Int32 = 8
    var lda: Int32 = 8
    var ldu: Int32 = 8
    var ldvt: Int32 = 8
    var lwork: Int32 = 512
    var info: Int32 = 0
    _ = sgesvd_(&jobu, &jobvt, &m, &n, &a, &lda, &singularValues,
                &uColumnMajor, &ldu, &vtColumnMajor, &ldvt, &work, &lwork, &info)
    guard info == 0 else {
        return ([Float](repeating: 0, count: 64),
                [Float](repeating: 0, count: 8),
                [Float](repeating: 0, count: 64))
    }
    var u = [Float](repeating: 0, count: 64)
    var vt = [Float](repeating: 0, count: 64)
    for row in 0..<8 {
        for col in 0..<8 {
            u[row * 8 + col] = uColumnMajor[col * 8 + row]
            vt[row * 8 + col] = vtColumnMajor[col * 8 + row]
        }
    }
    return (u, singularValues, vt)
}

private func extractBlock8(_ ll: [Float], llWidth: Int, blocksWidth: Int,
                           blockIndex: Int) -> [Float] {
    let blockRow = blockIndex / blocksWidth
    let blockCol = blockIndex % blocksWidth
    let baseRow = blockRow * 8
    let baseCol = blockCol * 8
    var block = [Float](repeating: 0, count: 64)
    for row in 0..<8 {
        for col in 0..<8 {
            block[row * 8 + col] = ll[(baseRow + row) * llWidth + baseCol + col]
        }
    }
    return block
}

private func singularRatios(_ s: [Float]) -> (s1OverS0: Double, s2OverS0: Double, s1Abs: Double) {
    let s0 = Double(s[0])
    guard s0 > 1.0e-12 else { return (0, 0, 0) }
    return (Double(s[1]) / s0, Double(s[2]) / s0, Double(s[1]))
}

private func blockRatios4(_ ll: [Float], llWidth: Int, blocksWidth: Int,
                          blockIndex: Int) -> (s1OverS0: Double, s2OverS0: Double) {
    let block = extractBlock(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                             blockIndex: blockIndex)
    let (_, s, _) = svd4x4(dct4x4(block))
    let ratios = singularRatios(s)
    return (ratios.s1OverS0, ratios.s2OverS0)
}

private func blockRatios8(_ ll: [Float], llWidth: Int, blocksWidth: Int,
                          blockIndex: Int) -> (s1OverS0: Double, s2OverS0: Double, s1Abs: Double) {
    let block = extractBlock8(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                              blockIndex: blockIndex)
    let (_, s, _) = svd8x8(dct8x8(block))
    return singularRatios(s)
}

private func bandCount(_ values: [Double]) -> Int {
    values.filter { $0 >= 0.05 && $0 <= 0.5 }.count
}

private func run7D() {
    var s1_4 = [Double](); var s2_4 = [Double]()
    var s1_8 = [Double](); var s2_8 = [Double](); var s1Abs8 = [Double]()
    for image in images {
        let (y, _, _) = pixelsToYUV(image)
        let (ll, _, llWidth, llHeight) = dwt2(y, width: image.width, height: image.height)
        let blocksWidth4 = llWidth / 4
        let blockCount4 = blocksWidth4 * (llHeight / 4)
        for blockIndex in 0..<blockCount4 {
            let ratios = blockRatios4(ll, llWidth: llWidth, blocksWidth: blocksWidth4,
                                      blockIndex: blockIndex)
            s1_4.append(ratios.s1OverS0)
            s2_4.append(ratios.s2OverS0)
        }
        let blocksWidth8 = llWidth / 8
        let blockCount8 = blocksWidth8 * (llHeight / 8)
        for blockIndex in 0..<blockCount8 {
            let ratios = blockRatios8(ll, llWidth: llWidth, blocksWidth: blocksWidth8,
                                      blockIndex: blockIndex)
            s1_8.append(ratios.s1OverS0)
            s2_8.append(ratios.s2OverS0)
            s1Abs8.append(ratios.s1Abs)
        }
    }
    s1_4.sort(); s2_4.sort(); s1_8.sort(); s2_8.sort(); s1Abs8.sort()
    let total4 = Double(s1_4.count)
    let total8 = Double(s1_8.count)
    let count4S1 = bandCount(s1_4)
    let count4S2 = bandCount(s2_4)
    let count8S1 = bandCount(s1_8)
    let count8S2 = bandCount(s2_8)

    print("7d 块尺寸分位数：4x4=\(s1_4.count) 块，8x8=\(s1_8.count) 块")
    print("块尺寸 | 指标 | P5 | P25 | P50 | P75 | P95 | [0.05,0.5]占比")
    print("---|---|---|---|---|---|---|---")
    print(String(format: "4x4 | S1/S0 | %.6f | %.6f | %.6f | %.6f | %.6f | %d (%.2f%%)",
                 quantile(s1_4, 0.05), quantile(s1_4, 0.25), quantile(s1_4, 0.50),
                 quantile(s1_4, 0.75), quantile(s1_4, 0.95), Int32(count4S1),
                 Double(count4S1) / total4 * 100.0))
    print(String(format: "4x4 | S2/S0 | %.6f | %.6f | %.6f | %.6f | %.6f | %d (%.2f%%)",
                 quantile(s2_4, 0.05), quantile(s2_4, 0.25), quantile(s2_4, 0.50),
                 quantile(s2_4, 0.75), quantile(s2_4, 0.95), Int32(count4S2),
                 Double(count4S2) / total4 * 100.0))
    print(String(format: "8x8 | S1/S0 | %.6f | %.6f | %.6f | %.6f | %.6f | %d (%.2f%%)",
                 quantile(s1_8, 0.05), quantile(s1_8, 0.25), quantile(s1_8, 0.50),
                 quantile(s1_8, 0.75), quantile(s1_8, 0.95), Int32(count8S1),
                 Double(count8S1) / total8 * 100.0))
    print(String(format: "8x8 | S2/S0 | %.6f | %.6f | %.6f | %.6f | %.6f | %d (%.2f%%)",
                 quantile(s2_8, 0.05), quantile(s2_8, 0.25), quantile(s2_8, 0.50),
                 quantile(s2_8, 0.75), quantile(s2_8, 0.95), Int32(count8S2),
                 Double(count8S2) / total8 * 100.0))
    print(String(format: "8x8 S1 绝对值：P5=%.6f P50=%.6f P95=%.6f",
                 quantile(s1Abs8, 0.05), quantile(s1Abs8, 0.50),
                 quantile(s1Abs8, 0.95)))

    let inBand8 = Double(count8S1) / total8 * 100.0
    let s1P5 = quantile(s1Abs8, 0.05)
    if inBand8 >= 10.0 && s1P5 > 2.0 {
        print(String(format: "8x8 S1/S0 判断：可行，目标区间占比 %.2f%%，S1 P5=%.3f 远离噪声量级", inBand8, s1P5))
    } else {
        print(String(format: "8x8 S1/S0 判断：不可行，目标区间占比 %.2f%%，S1 P5=%.3f 未远离噪声量级", inBand8, s1P5))
    }
}

// MARK: - 7e: v1 path + geometric synchronization frame prototype

private let v1D1 = 36.0
private let v1Version: UInt8 = 0x02
private let frameAmplitude: Float = 4.0
private let frameChipPattern: [Double] = [
    1, -1, -1, 1, 1, -1, 1, -1, -1, 1, -1, 1, 1, -1, -1, 1,
]

private func frameChipSign(_ normalized: Double) -> Double {
    let index = max(0, min(frameChipPattern.count - 1,
                           Int(floor((normalized + 1.0) * 0.5 *
                                     Double(frameChipPattern.count)))))
    return frameChipPattern[index]
}

private func buildHeaderV1(payloadLength: Int, isText: Bool) -> [UInt8] {
    let crc = crc16CCITT(payload)
    return [UInt8(headerMagic >> 8), UInt8(headerMagic & 0xFF), v1Version,
            isText ? 0x01 : 0x00, UInt8((payloadLength >> 8) & 0xFF),
            UInt8(payloadLength & 0xFF), UInt8(crc >> 8), UInt8(crc & 0xFF)]
}

private func embedBitV1InLL(_ ll: inout [Float], llWidth: Int, blocksWidth: Int,
                            blockIndex: Int, bit: UInt8) -> Bool {
    let block = extractBlock(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                             blockIndex: blockIndex)
    let (u, s, vt) = svd4x4(dct4x4(block))
    let s0 = Double(s[0])
    let cell = floor(s0 / v1D1)
    let target = (cell + (bit == 1 ? 0.75 : 0.25)) * v1D1
    guard target.isFinite else { return false }
    var modifiedS = s
    modifiedS[0] = Float(target)
    let restored = idct4x4(svdReconstruct(u: u, s: modifiedS, vt: vt))
    writeBlock(restored, to: &ll, llWidth: llWidth, blocksWidth: blocksWidth,
               blockIndex: blockIndex)
    return true
}

private func readBitV1FromLL(_ ll: [Float], llWidth: Int, blocksWidth: Int,
                             blockIndex: Int) -> UInt8 {
    let block = extractBlock(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                             blockIndex: blockIndex)
    let (_, s, _) = svd4x4(dct4x4(block))
    let scaled = Double(s[0]) / v1D1
    let fraction = scaled - floor(scaled)
    return fraction >= 0.5 ? 1 : 0
}

private func embedV1(_ image: RGBAImage) -> RGBAImage? {
    let (y, u, v) = pixelsToYUV(image)
    let (ll, h, llWidth, llHeight) = dwt2(y, width: image.width, height: image.height)
    let blocksWidth = llWidth / 4
    let blockCount = blocksWidth * (llHeight / 4)
    guard blockCount >= headerBlocks + redundancy * payload.count * 8 else { return nil }

    var modifiedLL = ll
    let blockOrder = shuffledOrder(count: blockCount,
                                   seed: deriveSeed(password: password, domain: seedDomainBlock))
    let headerSequence = bytesToRepeatedBits(buildHeaderV1(payloadLength: payload.count,
                                                            isText: false))
    let headerPermutation = shuffledOrder(count: headerSequence.count,
                                          seed: deriveSeed(password: password,
                                                           domain: seedDomainHeader))
    let scrambledHeader = permuteForward(headerSequence, permutation: headerPermutation)
    let payloadSequence = bytesToRepeatedBits(payload)
    let payloadPermutation = shuffledOrder(count: payloadSequence.count,
                                           seed: deriveSeed(password: password,
                                                            domain: seedDomainPayload))
    let scrambledPayload = permuteForward(payloadSequence, permutation: payloadPermutation)

    for i in 0..<headerBlocks {
        _ = embedBitV1InLL(&modifiedLL, llWidth: llWidth, blocksWidth: blocksWidth,
                           blockIndex: blockOrder[i], bit: scrambledHeader[i])
    }
    for i in 0..<payloadSequence.count {
        _ = embedBitV1InLL(&modifiedLL, llWidth: llWidth, blocksWidth: blocksWidth,
                           blockIndex: blockOrder[headerBlocks + i], bit: scrambledPayload[i])
    }
    let restoredY = idwt2(ll: modifiedLL, h: h, llWidth: llWidth, llHeight: llHeight,
                          width: image.width, height: image.height)
    return yuvToPixels(y: restoredY, u: u, v: v, source: image)
}

private struct V1HeaderRead {
    let magicOK: Bool
    let version: UInt8
    let payloadLength: Int
    let crc: UInt16
}

private func readHeaderV1(_ image: RGBAImage) -> V1HeaderRead {
    let (y, _, _) = pixelsToYUV(image)
    let (ll, _, llWidth, llHeight) = dwt2(y, width: image.width, height: image.height)
    let blocksWidth = llWidth / 4
    let blockCount = blocksWidth * (llHeight / 4)
    guard blockCount >= headerBlocks else {
        return V1HeaderRead(magicOK: false, version: 0, payloadLength: 0, crc: 0)
    }
    let blockOrder = shuffledOrder(count: blockCount,
                                   seed: deriveSeed(password: password, domain: seedDomainBlock))
    let headerPermutation = shuffledOrder(count: headerBlocks,
                                          seed: deriveSeed(password: password,
                                                           domain: seedDomainHeader))
    var scrambled = [UInt8](repeating: 0, count: headerBlocks)
    for i in 0..<headerBlocks {
        scrambled[i] = readBitV1FromLL(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                                       blockIndex: blockOrder[i])
    }
    let header = repeatedBitsToBytes(permuteInverse(scrambled, permutation: headerPermutation),
                                     byteCount: headerBytes)
    let magic = (UInt16(header[0]) << 8) | UInt16(header[1])
    let length = (Int(header[4]) << 8) | Int(header[5])
    let crc = (UInt16(header[6]) << 8) | UInt16(header[7])
    return V1HeaderRead(magicOK: magic == headerMagic && header[2] == v1Version,
                        version: header[2], payloadLength: length, crc: crc)
}

private func v1ScrambledHeaderBits() -> [UInt8] {
    let headerSequence = bytesToRepeatedBits(buildHeaderV1(payloadLength: payload.count,
                                                            isText: false))
    let permutation = shuffledOrder(count: headerSequence.count,
                                    seed: deriveSeed(password: password,
                                                     domain: seedDomainHeader))
    return permuteForward(headerSequence, permutation: permutation)
}

private func v1HeaderBitErrors(_ image: RGBAImage) -> Int {
    let (y, _, _) = pixelsToYUV(image)
    let (ll, _, llWidth, llHeight) = dwt2(y, width: image.width, height: image.height)
    let blocksWidth = llWidth / 4
    let blockCount = blocksWidth * (llHeight / 4)
    guard blockCount >= headerBlocks else { return headerBlocks }
    let blockOrder = shuffledOrder(count: blockCount,
                                   seed: deriveSeed(password: password, domain: seedDomainBlock))
    let expected = v1ScrambledHeaderBits()
    var errors = 0
    for i in 0..<headerBlocks {
        let bit = readBitV1FromLL(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                                  blockIndex: blockOrder[i])
        if bit != expected[i] { errors += 1 }
    }
    return errors
}

private func extractV1(_ image: RGBAImage) -> ExtractDiagnostic {
    let header = readHeaderV1(image)
    let (y, _, _) = pixelsToYUV(image)
    let (ll, _, llWidth, llHeight) = dwt2(y, width: image.width, height: image.height)
    let blocksWidth = llWidth / 4
    let blockCount = blocksWidth * (llHeight / 4)
    let payloadSequenceCount = header.payloadLength * 8 * redundancy
    guard header.magicOK, header.payloadLength > 0,
          blockCount >= headerBlocks + payloadSequenceCount else {
        return ExtractDiagnostic(magicOK: header.magicOK, version: header.version,
                                 crcOK: false, payload: [])
    }
    let blockOrder = shuffledOrder(count: blockCount,
                                   seed: deriveSeed(password: password, domain: seedDomainBlock))
    let payloadPermutation = shuffledOrder(count: payloadSequenceCount,
                                           seed: deriveSeed(password: password,
                                                            domain: seedDomainPayload))
    var scrambled = [UInt8](repeating: 0, count: payloadSequenceCount)
    for i in 0..<payloadSequenceCount {
        scrambled[i] = readBitV1FromLL(ll, llWidth: llWidth, blocksWidth: blocksWidth,
                                       blockIndex: blockOrder[headerBlocks + i])
    }
    let decoded = repeatedBitsToBytes(permuteInverse(scrambled, permutation: payloadPermutation),
                                      byteCount: header.payloadLength)
    let crcOK = crc16CCITT(decoded) == header.crc
    return ExtractDiagnostic(magicOK: true, version: header.version, crcOK: crcOK,
                             payload: decoded)
}

private func addSyncFrame(_ image: RGBAImage) -> RGBAImage {
    let (y, u, v) = pixelsToYUV(image)
    var framedY = y
    let centerX = Double(image.width - 1) * 0.5
    let centerY = Double(image.height - 1) * 0.5
    let halfWidth = Double(image.width) * 0.5
    let halfHeight = Double(image.height) * 0.5
    for row in 0..<image.height {
        for col in 0..<image.width {
            let left = col
            let right = image.width - 1 - col
            let top = row
            let bottom = image.height - 1 - row
            let distance = min(min(left, right), min(top, bottom))
            let inOuterFrame = distance < 16
            let inInnerFrame = distance >= 120 && distance < 136
            guard inOuterFrame || inInnerFrame else { continue }
            let radialSign: Float = (distance < 8 || (distance >= 120 && distance < 128))
                ? 1.0 : -1.0
            let normalized: Double
            if distance == left || distance == right {
                normalized = (Double(row) - centerY) / halfHeight
            } else {
                normalized = (Double(col) - centerX) / halfWidth
            }
            let delta = frameAmplitude * radialSign * Float(frameChipSign(normalized))
            framedY[row * image.width + col] += delta
        }
    }
    return yuvToPixels(y: framedY, u: u, v: v, source: image)
}

private func sampleBilinearRGBA(_ image: RGBAImage, x: Double, y: Double)
    -> (UInt8, UInt8, UInt8, UInt8) {
    guard x >= 0, y >= 0, x <= Double(image.width - 1), y <= Double(image.height - 1) else {
        return (0, 0, 0, 255)
    }
    let x0 = Int(floor(x)); let y0 = Int(floor(y))
    let x1 = min(x0 + 1, image.width - 1); let y1 = min(y0 + 1, image.height - 1)
    let fx = x - Double(x0); let fy = y - Double(y0)
    var channels = [UInt8](repeating: 0, count: 4)
    for channel in 0..<4 {
        let p00 = Double(image.pixels[(y0 * image.width + x0) * 4 + channel])
        let p10 = Double(image.pixels[(y0 * image.width + x1) * 4 + channel])
        let p01 = Double(image.pixels[((y1 * image.width + x0)) * 4 + channel])
        let p11 = Double(image.pixels[((y1 * image.width + x1)) * 4 + channel])
        let top = p00 * (1.0 - fx) + p10 * fx
        let bottom = p01 * (1.0 - fx) + p11 * fx
        channels[channel] = UInt8(max(0, min(255, top * (1.0 - fy) + bottom * fy + 0.5)))
    }
    return (channels[0], channels[1], channels[2], channels[3])
}

private func warpImage(_ image: RGBAImage, angleDegrees: Double, scale: Double,
                       offsetX: Double = 0, offsetY: Double = 0) -> RGBAImage {
    let radians = angleDegrees * Double.pi / 180.0
    let cosine = cos(radians); let sine = sin(radians)
    let centerX = Double(image.width - 1) * 0.5
    let centerY = Double(image.height - 1) * 0.5
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    for row in 0..<image.height {
        for col in 0..<image.width {
            let dx = Double(col) - centerX
            let dy = Double(row) - centerY
            let sourceX = centerX + scale * (cosine * dx - sine * dy) + offsetX
            let sourceY = centerY + scale * (sine * dx + cosine * dy) + offsetY
            let sample = sampleBilinearRGBA(image, x: sourceX, y: sourceY)
            let index = (row * image.width + col) * 4
            pixels[index] = sample.0; pixels[index + 1] = sample.1
            pixels[index + 2] = sample.2; pixels[index + 3] = sample.3
        }
    }
    return RGBAImage(width: image.width, height: image.height, pixels: pixels)
}

private func cropCenterAndRestore(_ image: RGBAImage, fraction: Double) -> RGBAImage? {
    // Sampling c + f*(p-c) is exactly center-crop followed by resize back
    // to the original dimensions, without CoreGraphics half-pixel ambiguity.
    return warpImage(image, angleDegrees: 0, scale: fraction)
}

private func sampleY(_ y: [Float], width: Int, height: Int, x: Double, yValue: Double) -> Double {
    guard x >= 0, yValue >= 0, x <= Double(width - 1), yValue <= Double(height - 1) else {
        return 0
    }
    let x0 = Int(floor(x)); let y0 = Int(floor(yValue))
    let x1 = min(x0 + 1, width - 1); let y1 = min(y0 + 1, height - 1)
    let fx = x - Double(x0); let fy = yValue - Double(y0)
    let top = Double(y[y0 * width + x0]) * (1.0 - fx) + Double(y[y0 * width + x1]) * fx
    let bottom = Double(y[y1 * width + x0]) * (1.0 - fx) + Double(y[y1 * width + x1]) * fx
    return top * (1.0 - fy) + bottom * fy
}

private func frameCorrelationScore(_ y: [Float], width: Int, height: Int,
                                   angleDegrees: Double, radius: Double) -> Double {
    guard radius > 20 else { return 0 }
    let radians = angleDegrees * Double.pi / 180.0
    let cosine = cos(radians); let sine = sin(radians)
    let centerX = Double(width - 1) * 0.5
    let centerY = Double(height - 1) * 0.5
    let halfSide = radius + 4.0
    let baseNormalsAndTangents = [
        ((0.0, -1.0), (1.0, 0.0)),
        ((0.0, 1.0), (1.0, 0.0)),
        ((-1.0, 0.0), (0.0, 1.0)),
        ((1.0, 0.0), (0.0, 1.0)),
    ]
    var samples = [Double]()
    var template = [Double]()
    samples.reserveCapacity(720)
    template.reserveCapacity(720)
    let normalizedStep = 0.025
    var normalized = -0.9
    while normalized <= 0.9 {
        let chip = frameChipSign(normalized)
        let tangentDistance = normalized * halfSide
        for entry in baseNormalsAndTangents {
            let baseNormal = entry.0
            let baseTangent = entry.1
            let normalX = cosine * baseNormal.0 - sine * baseNormal.1
            let normalY = sine * baseNormal.0 + cosine * baseNormal.1
            let tangentX = cosine * baseTangent.0 - sine * baseTangent.1
            let tangentY = sine * baseTangent.0 + cosine * baseTangent.1
            let baseX = centerX + normalX * radius + tangentX * tangentDistance
            let baseY = centerY + normalY * radius + tangentY * tangentDistance
            let outer = sampleY(y, width: width, height: height, x: baseX, yValue: baseY)
            let innerRadius = radius - 8.0
            let innerX = centerX + normalX * innerRadius + tangentX * tangentDistance
            let innerY = centerY + normalY * innerRadius + tangentY * tangentDistance
            let inner = sampleY(y, width: width, height: height, x: innerX, yValue: innerY)
            samples.append(outer)
            template.append(chip)
            samples.append(inner)
            template.append(-chip)
        }
        normalized += normalizedStep
    }
    let count = Double(samples.count)
    guard count > 100 else { return 0 }
    let sampleMean = samples.reduce(0, +) / count
    let templateMean = template.reduce(0, +) / count
    var covariance = 0.0
    var sampleVariance = 0.0
    var templateVariance = 0.0
    for index in samples.indices {
        let centeredSample = samples[index] - sampleMean
        let centeredTemplate = template[index] - templateMean
        covariance += centeredSample * centeredTemplate
        sampleVariance += centeredSample * centeredSample
        templateVariance += centeredTemplate * centeredTemplate
    }
    guard sampleVariance > 1.0e-9, templateVariance > 1.0e-9 else { return 0 }
    return abs(covariance / sqrt(sampleVariance * templateVariance)) * sqrt(count)
}

private struct FrameHit {
    let angle: Double
    let radius: Double
    let score: Double
}

private func detectFrameHits(_ image: RGBAImage) -> [FrameHit] {
    let (y, _, _) = pixelsToYUV(image)
    var coarse = [FrameHit]()
    var angle = -12.0
    while angle <= 12.0 {
        var radius = 72.0
        while radius <= 252.0 {
            let score = frameCorrelationScore(y, width: image.width, height: image.height,
                                              angleDegrees: angle, radius: radius)
            if score > 4.0 { coarse.append(FrameHit(angle: angle, radius: radius, score: score)) }
            radius += 4.0
        }
        angle += 1.5
    }
    coarse.sort { $0.score > $1.score }
    var refined = [FrameHit]()
    for hit in coarse.prefix(12) {
        var best = hit
        var refinedAngle = hit.angle - 1.5
        while refinedAngle <= hit.angle + 1.5 {
            var refinedRadius = max(48.0, hit.radius - 4.0)
            let radiusLimit = min(252.0, hit.radius + 4.0)
            while refinedRadius <= radiusLimit {
                let score = frameCorrelationScore(y, width: image.width, height: image.height,
                                                  angleDegrees: refinedAngle,
                                                  radius: min(252.0, refinedRadius))
                if score > best.score {
                    best = FrameHit(angle: refinedAngle, radius: refinedRadius, score: score)
                }
                refinedRadius += 1.0
            }
            refinedAngle += 0.1
        }
        refined.append(best)
    }
    refined.sort { $0.score > $1.score }
    return refined
}

private struct CorrectionCandidate {
    let angle: Double
    let scale: Double
    let score: Double
}

private let frameTransitionRadii = [252.0, 244.0, 132.0, 124.0]

private func snappedFrameAngle(_ angle: Double) -> Double {
    (angle * 2.0).rounded() / 2.0
}

private func correctionCandidates(from hits: [FrameHit]) -> [CorrectionCandidate] {
    var candidates = [CorrectionCandidate]()
    for hit in hits.prefix(12) {
        let rawAngles = [hit.angle * 2.0, hit.angle, hit.angle * 0.5, 0.0]
        var angleVariants = [Double]()
        for angle in rawAngles {
            let snapped = snappedFrameAngle(angle)
            if abs(snapped) <= 12.0 && !angleVariants.contains(where: {
                abs($0 - snapped) < 1.0e-9
            }) {
                angleVariants.append(snapped)
            }
        }
        for transition in [hit.radius, hit.radius - 8.0] {
            for baseRadius in frameTransitionRadii {
                let scale = (transition / baseRadius * 100.0).rounded() / 100.0
                guard scale >= 0.90, scale <= 2.20 else { continue }
                for angle in angleVariants where abs(angle) <= 12.0 {
                    candidates.append(CorrectionCandidate(angle: angle, scale: scale,
                                                          score: hit.score))
                }
            }
        }
    }
    candidates.sort { lhs, rhs in
        if abs(lhs.score - rhs.score) > 1.0e-9 { return lhs.score > rhs.score }
        return abs(lhs.scale - 1.0) < abs(rhs.scale - 1.0)
    }
    var unique = [CorrectionCandidate]()
    for candidate in candidates {
        let duplicate = unique.contains {
            abs($0.angle - candidate.angle) < 0.12 && abs($0.scale - candidate.scale) < 0.015
        }
        if !duplicate { unique.append(candidate) }
        if unique.count >= 20 { break }
    }
    return unique
}

private enum GeometryGroup: String {
    case rotation, crop, scale, combo
}

private enum GeometryAttack: String, CaseIterable {
    case rotateNeg10 = "Rot -10°"
    case rotateNeg5 = "Rot -5°"
    case rotateNeg2 = "Rot -2°"
    case rotateNeg1 = "Rot -1°"
    case rotatePos1 = "Rot +1°"
    case rotatePos2 = "Rot +2°"
    case rotatePos5 = "Rot +5°"
    case rotatePos10 = "Rot +10°"
    case crop90 = "Crop 90%"
    case crop75 = "Crop 75%"
    case crop50 = "Crop 50%"
    case scaleHalf = "Scale 0.5x"
    case scaleThreeQuarter = "Scale 0.75x"
    case rotate2Crop90 = "Rot2°+Crop90%"

    var group: GeometryGroup {
        switch self {
        case .rotateNeg10, .rotateNeg5, .rotateNeg2, .rotateNeg1,
             .rotatePos1, .rotatePos2, .rotatePos5, .rotatePos10:
            return .rotation
        case .crop90, .crop75, .crop50:
            return .crop
        case .scaleHalf, .scaleThreeQuarter:
            return .scale
        case .rotate2Crop90:
            return .combo
        }
    }

    var trueAngle: Double {
        switch self {
        case .rotateNeg10: return -10
        case .rotateNeg5: return -5
        case .rotateNeg2: return -2
        case .rotate2Crop90: return 2
        case .rotateNeg1: return -1
        case .rotatePos1: return 1
        case .rotatePos2: return 2
        case .rotatePos5: return 5
        case .rotatePos10: return 10
        default: return 0
        }
    }

    var trueScale: Double {
        switch self {
        case .crop90, .rotate2Crop90: return 1.0 / 0.90
        case .crop75: return 1.0 / 0.75
        case .crop50: return 1.0 / 0.50
        default: return 1.0
        }
    }

    func apply(to image: RGBAImage) -> RGBAImage? {
        switch self {
        case .rotateNeg10, .rotateNeg5, .rotateNeg2, .rotateNeg1,
             .rotatePos1, .rotatePos2, .rotatePos5, .rotatePos10:
            return warpImage(image, angleDegrees: -trueAngle, scale: 1.0)
        case .crop90:
            return cropCenterAndRestore(image, fraction: 0.90)
        case .crop75:
            return cropCenterAndRestore(image, fraction: 0.75)
        case .crop50:
            return cropCenterAndRestore(image, fraction: 0.50)
        case .scaleHalf:
            return resizeRoundTrip(image, factor: 0.5)
        case .scaleThreeQuarter:
            return resizeRoundTrip(image, factor: 0.75)
        case .rotate2Crop90:
            let rotated = warpImage(image, angleDegrees: 2.0, scale: 1.0)
            return cropCenterAndRestore(rotated, fraction: 0.90)
        }
    }
}

private struct GeometryRow {
    let attack: GeometryAttack
    var imageCount = 0
    var beforeCRC = 0
    var afterCRC = 0
    var estimatedCount = 0
    var angleErrorSum = 0.0
    var scaleErrorSum = 0.0
    var skipped = false
}

private struct CorrectedExtraction {
    let diagnostic: ExtractDiagnostic
    let angle: Double
    let scale: Double
}

private func correctAndExtract(_ attacked: RGBAImage) -> CorrectedExtraction? {
    let hits = detectFrameHits(attacked)
    guard let bestHit = hits.first, bestHit.score >= 6.0 else { return nil }
    let candidates = correctionCandidates(from: hits)
    var fallback: CorrectedExtraction?
    for candidate in candidates.prefix(24) {
        let corrected = warpImage(attacked, angleDegrees: candidate.angle,
                                  scale: candidate.scale)
        let header = readHeaderV1(corrected)
        if header.magicOK {
            return CorrectedExtraction(diagnostic: extractV1(corrected),
                                       angle: candidate.angle, scale: candidate.scale)
        }
        if fallback == nil {
            fallback = CorrectedExtraction(
                diagnostic: ExtractDiagnostic(magicOK: false, version: header.version,
                                              crcOK: false, payload: []),
                angle: candidate.angle, scale: candidate.scale
            )
        }
    }
    for candidate in candidates.prefix(8) {
        for deltaAngle in [-0.25, 0.25] {
            for scaleFactor in [0.99, 1.01] {
                let corrected = warpImage(attacked,
                                          angleDegrees: candidate.angle + deltaAngle,
                                          scale: candidate.scale * scaleFactor)
                if readHeaderV1(corrected).magicOK {
                    return CorrectedExtraction(diagnostic: extractV1(corrected),
                                               angle: candidate.angle + deltaAngle,
                                               scale: candidate.scale * scaleFactor)
                }
            }
        }
    }
    let translations: [(Double, Double)] = [
        (-0.5, 0), (0.5, 0), (0, -0.5), (0, 0.5),
        (-0.5, -0.5), (0.5, -0.5), (-0.5, 0.5), (0.5, 0.5),
    ]
    for candidate in candidates.prefix(4) {
        for translation in translations {
            let corrected = warpImage(attacked, angleDegrees: candidate.angle,
                                      scale: candidate.scale,
                                      offsetX: translation.0, offsetY: translation.1)
            if readHeaderV1(corrected).magicOK {
                return CorrectedExtraction(diagnostic: extractV1(corrected),
                                           angle: candidate.angle, scale: candidate.scale)
            }
        }
    }
    return fallback
}

private func run7EProbe() {
    guard let first = images.first else { return }
    let framedInput = addSyncFrame(first)
    guard let embedded = embedV1(framedInput) else {
        print("7e probe: v1 embed failed")
        return
    }
    print(String(format: "probe frame+wm PSNR %.2f dB, baseline CRC=%d",
                 psnr(first.pixels, embedded.pixels),
                 extractV1(embedded).crcOK ? 1 : 0))
    let frameOnly = addSyncFrame(first)
    let frameOnlyRotated = warpImage(frameOnly, angleDegrees: 10.0, scale: 1.0)
    let frameOnlyHits = detectFrameHits(frameOnlyRotated)
    print(String(format: "frame-only rot+10 top=(%.1f°, r%.0f, %.1f)",
                 frameOnlyHits.first?.angle ?? 0, frameOnlyHits.first?.radius ?? 0,
                 frameOnlyHits.first?.score ?? 0))
    var blankPixels = [UInt8](repeating: 128, count: imageSize * imageSize * 4)
    for index in stride(from: 3, to: blankPixels.count, by: 4) { blankPixels[index] = 255 }
    let blank = RGBAImage(width: imageSize, height: imageSize, pixels: blankPixels)
    let blankFrame = addSyncFrame(blank)
    let blankRotated = warpImage(blankFrame, angleDegrees: 10.0, scale: 1.0)
    let blankHits = detectFrameHits(blankRotated)
    print(String(format: "blank-frame rot+10 top=(%.1f°, r%.0f, %.1f)",
                 blankHits.first?.angle ?? 0, blankHits.first?.radius ?? 0,
                 blankHits.first?.score ?? 0))
    for attack in GeometryAttack.allCases {
        guard let attacked = attack.apply(to: embedded) else { continue }
        let hits = detectFrameHits(attacked)
        let probeYUV = pixelsToYUV(attacked)
        var trueAngleBest = -Double.infinity
        var trueAngleRadius = 0.0
        var probeRadius = 72.0
        while probeRadius <= 252.0 {
            let score = frameCorrelationScore(probeYUV.y, width: attacked.width,
                                              height: attacked.height,
                                              angleDegrees: attack.trueAngle,
                                              radius: probeRadius)
            if score > trueAngleBest {
                trueAngleBest = score
                trueAngleRadius = probeRadius
            }
            probeRadius += 2.0
        }
        let before = extractV1(attacked)
        let corrected = correctAndExtract(attacked)
        let exact = warpImage(attacked, angleDegrees: attack.trueAngle,
                              scale: attack.trueScale)
        let exactHeader = readHeaderV1(exact)
        let exactCRC = exactHeader.magicOK ? extractV1(exact).crcOK : false
        let exactBitErrors = v1HeaderBitErrors(exact)
        var translatedSuccess = 0
        var minimumBitErrors = exactBitErrors
        for dx in [-1.0, -0.5, 0.0, 0.5, 1.0] {
            for dy in [-1.0, -0.5, 0.0, 0.5, 1.0] {
                let trial = warpImage(attacked, angleDegrees: attack.trueAngle,
                                      scale: attack.trueScale, offsetX: dx, offsetY: dy)
                minimumBitErrors = min(minimumBitErrors, v1HeaderBitErrors(trial))
                if extractV1(trial).crcOK { translatedSuccess += 1 }
            }
        }
        var localSuccess = 0
        for da in [-0.8, -0.4, 0.0, 0.4, 0.8] {
            for ds in [-0.03, 0.0, 0.03] {
                let trial = warpImage(attacked, angleDegrees: attack.trueAngle + da,
                                      scale: attack.trueScale * (1.0 + ds))
                if extractV1(trial).crcOK { localSuccess += 1 }
            }
        }
        print(String(format: "%@ hits=%d top=(%.1f°, r%.0f, %.1f) trueScore=(%.1f, r%.0f) before=%d after=%d exact=%d bitErr=%d minErr=%d shift=%d/25 local=%d/15 est=(%.1f°, %.3f) true=(%.1f°, %.3f)",
                     attack.rawValue, hits.count, hits.first?.angle ?? 0,
                     hits.first?.radius ?? 0, hits.first?.score ?? 0,
                     trueAngleBest, trueAngleRadius,
                     before.crcOK ? 1 : 0, corrected?.diagnostic.crcOK == true ? 1 : 0,
                     exactCRC ? 1 : 0, exactBitErrors, minimumBitErrors,
                     translatedSuccess, localSuccess,
                     corrected?.angle ?? 0, corrected?.scale ?? 0,
                     attack.trueAngle, attack.trueScale))
    }
}

private func run7E() {
    var rows = Dictionary(uniqueKeysWithValues: GeometryAttack.allCases.map {
        ($0, GeometryRow(attack: $0))
    })
    var framedPSNRSum = 0.0
    var baselinePSNRSum = 0.0
    var preparedCount = 0

    var prepared = [(original: RGBAImage, embedded: RGBAImage)]()
    for image in images {
        guard let baseline = embedV1(image),
              let embedded = embedV1(addSyncFrame(image)) else { continue }
        prepared.append((image, embedded))
        preparedCount += 1
        framedPSNRSum += psnr(image.pixels, embedded.pixels)
        baselinePSNRSum += psnr(image.pixels, baseline.pixels)
    }

    for attack in GeometryAttack.allCases {
        for item in prepared {
            guard let attacked = attack.apply(to: item.embedded) else { continue }
            var row = rows[attack]!
            row.imageCount += 1
            let before = extractV1(attacked)
            if before.crcOK { row.beforeCRC += 1 }
            if let corrected = correctAndExtract(attacked) {
                if corrected.diagnostic.crcOK { row.afterCRC += 1 }
                row.estimatedCount += 1
                row.angleErrorSum += abs(corrected.angle - attack.trueAngle)
                row.scaleErrorSum += abs(corrected.scale - attack.trueScale)
            }
            rows[attack] = row
        }
    }

    let displayed = GeometryAttack.allCases.map { attack in (attack, rows[attack]!) }

    print("| 攻击 | 校正前CRC | 校正后CRC | 角度误差 | 缩放误差 |")
    print("|---|---|---|---|---|")
    for (attack, row) in displayed {
        if row.skipped {
            print("| \(attack.rawValue) | — | 提前终止 | — | — |")
            continue
        }
        let count = max(1, row.imageCount)
        let beforeRate = Double(row.beforeCRC) / Double(count)
        let afterRate = Double(row.afterCRC) / Double(count)
        let angleError = row.estimatedCount > 0
            ? String(format: "%.2f°", row.angleErrorSum / Double(row.estimatedCount)) : "—"
        let scaleError = row.estimatedCount > 0
            ? String(format: "%.3f", row.scaleErrorSum / Double(row.estimatedCount)) : "—"
        print(String(format: "| %@ | %.1f%% | %.1f%% | %@ | %@ |",
                     attack.rawValue, beforeRate * 100.0, afterRate * 100.0,
                     angleError, scaleError))
    }
    if preparedCount > 0 {
        print(String(format: "加框+水印平均 PSNR：%.2f dB（无框 v1：%.2f dB）",
                     framedPSNRSum / Double(preparedCount),
                     baselinePSNRSum / Double(preparedCount)))
    }

    let rotationRows = displayed.filter { $0.0.group == .rotation && !$0.1.skipped }
    let cropRows = displayed.filter { $0.0.group == .crop && !$0.1.skipped }
    func successRate(_ selected: [(GeometryAttack, GeometryRow)]) -> Double {
        let count = selected.reduce(0) { $0 + $1.1.imageCount }
        guard count > 0 else { return 0 }
        let success = selected.reduce(0) { $0 + $1.1.afterCRC }
        return Double(success) / Double(count)
    }
    let rotationRate = successRate(rotationRows)
    let cropRate = successRate(cropRows)
    let meanPSNR = preparedCount > 0 ? framedPSNRSum / Double(preparedCount) : 0
    let verdict: String
    if rotationRate >= 0.80 && cropRate >= 0.80 && meanPSNR >= 42.0 {
        verdict = "值得移植：旋转/裁剪≥80%，PSNR≥42 dB。"
    } else if rotationRate >= 0.80 && meanPSNR >= 42.0 {
        verdict = "暂不移植：旋转可用，但裁剪成功率不足。"
    } else if meanPSNR < 42.0 {
        verdict = "暂不移植：框架 PSNR 不达标。"
    } else {
        verdict = "不移植：校正后几何成功率不足 80%。"
    }
    print("判断：\(verdict)")
}

private func run7EOracle() {
    var embeddedImages = [RGBAImage]()
    for image in images {
        if let embedded = embedV1(addSyncFrame(image)) { embeddedImages.append(embedded) }
    }
    print("oracle exact-transform CRC")
    for attack in GeometryAttack.allCases {
        var success = 0
        var count = 0
        for embedded in embeddedImages {
            guard let attacked = attack.apply(to: embedded) else { continue }
            count += 1
            let corrected = warpImage(attacked, angleDegrees: attack.trueAngle,
                                      scale: attack.trueScale)
            if extractV1(corrected).crcOK { success += 1 }
        }
        print(String(format: "%@ %.1f%%", attack.rawValue,
                     100.0 * Double(success) / Double(max(1, count))))
    }
}

let arguments = CommandLine.arguments
let mode = arguments.count > 1 ? arguments[1] : "q"
if mode == "q" {
    runQDistribution()
} else if mode == "full" {
    runSweep()
} else if mode == "7c" {
    run7C()
} else if mode == "7d" {
    run7D()
} else if mode == "7e" {
    run7E()
} else if mode == "7eprobe" {
    run7EProbe()
} else if mode == "7eoracle" {
    run7EOracle()
} else {
    print("usage: swift b1_prototype.swift [q|full|7c|7d|7e|7eprobe|7eoracle]")
}
