#if canImport(AppKit)
import AppKit
import BWM
import CoreGraphics
import Darwin
import Foundation

public enum BlindWatermarkResult: Equatable, Sendable {
    case detected(payload: Data, isText: Bool)
    case notDetected
}

public enum BlindWatermarkError: Error, LocalizedError, Equatable, Sendable {
    case invalidHandle(String)
    case fileNotFound(String)
    case invalidImage(String)
    case embedFailed(String)
    case extractFailed(String)
    case invalidParameters(String)
    case imageTooSmall(String)
    case passwordRequired(String)
    case outOfMemory(String)
    case unknown(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidHandle(let message),
             .fileNotFound(let message),
             .invalidImage(let message),
             .embedFailed(let message),
             .extractFailed(let message),
             .invalidParameters(let message),
             .imageTooSmall(let message),
             .passwordRequired(let message),
             .outOfMemory(let message),
             .unknown(_, let message):
            return message
        }
    }
}

@MainActor
public final class BlindWatermarkService {
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ??
        CGColorSpaceCreateDeviceRGB()
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )

    public init() {}

    public func embed(in image: NSImage, payload: Data, isText: Bool,
                      password: String) throws -> NSImage {
        guard !payload.isEmpty else {
            throw Self.error(for: Int32(BWM_ERROR_INVALID_PARAMS))
        }
        guard payload.count <= Int(Int32.max) else {
            throw Self.error(for: Int32(BWM_ERROR_INVALID_PARAMS))
        }

        let source = try makeBitmap(from: image)
        let displaySize = validDisplaySize(for: image, width: source.width, height: source.height)

        var embeddedPixels: UnsafeMutablePointer<UInt8>?
        var embeddedSize: Int32 = 0
        let status = payload.withUnsafeBytes { payloadBuffer -> Int32 in
            guard let payloadBase = payloadBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return Int32(BWM_ERROR_INVALID_PARAMS)
            }
            return password.withCString { passwordPointer in
                quikra_bwm_embed(
                    source.pointer,
                    Int32(source.width),
                    Int32(source.height),
                    4,
                    payloadBase,
                    Int32(payload.count),
                    isText ? 1 : 0,
                    BWM_ALGO_V1,
                    passwordPointer,
                    &embeddedPixels,
                    &embeddedSize
                )
            }
        }

        guard status == Int32(BWM_OK) else {
            if let embeddedPixels {
                Darwin.free(UnsafeMutableRawPointer(embeddedPixels))
            }
            throw Self.error(for: status)
        }
        guard let embeddedPixels else {
            throw Self.error(for: Int32(BWM_ERROR_EMBED_FAILED))
        }
        defer { Darwin.free(UnsafeMutableRawPointer(embeddedPixels)) }

        let expectedSize = source.width * source.height * 4
        guard Int(embeddedSize) == expectedSize else {
            throw Self.error(for: Int32(BWM_ERROR_EMBED_FAILED))
        }

        let pixelData = Data(bytes: embeddedPixels, count: expectedSize)
        return try makeImage(from: pixelData, width: source.width, height: source.height,
                             displaySize: displaySize)
    }

    public func extract(from image: NSImage, password: String) throws -> BlindWatermarkResult {
        let source = try makeBitmap(from: image)
        var payloadPointer: UnsafeMutablePointer<UInt8>?
        var payloadLength: Int32 = 0
        var isText: Int32 = 0

        let status = password.withCString { passwordPointer in
            quikra_bwm_extract(
                source.pointer,
                Int32(source.width),
                Int32(source.height),
                4,
                passwordPointer,
                &payloadPointer,
                &payloadLength,
                &isText
            )
        }

        guard status == Int32(BWM_OK) else {
            if let payloadPointer {
                Darwin.free(UnsafeMutableRawPointer(payloadPointer))
            }
            throw Self.error(for: status)
        }
        guard let payloadPointer else {
            return .notDetected
        }
        defer { Darwin.free(UnsafeMutableRawPointer(payloadPointer)) }
        guard payloadLength > 0 else {
            return .notDetected
        }

        return .detected(
            payload: Data(bytes: payloadPointer, count: Int(payloadLength)),
            isText: isText != 0
        )
    }

    private func makeBitmap(from image: NSImage) throws -> BitmapBuffer {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &proposedRect, context: nil,
                                          hints: nil) else {
            throw Self.error(for: Int32(BWM_ERROR_INVALID_IMAGE))
        }
        guard let buffer = BitmapBuffer(width: cgImage.width, height: cgImage.height) else {
            throw Self.error(for: Int32(BWM_ERROR_INVALID_IMAGE))
        }
        guard let context = CGContext(
            data: UnsafeMutableRawPointer(buffer.pointer),
            width: buffer.width,
            height: buffer.height,
            bitsPerComponent: 8,
            bytesPerRow: buffer.bytesPerRow,
            space: Self.colorSpace,
            bitmapInfo: Self.bitmapInfo.rawValue
        ) else {
            throw Self.error(for: Int32(BWM_ERROR_INVALID_IMAGE))
        }

        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height))
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height))
        return buffer
    }

    private func makeImage(from pixels: Data, width: Int, height: Int,
                           displaySize: NSSize) throws -> NSImage {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: Self.colorSpace,
                  bitmapInfo: Self.bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ) else {
            throw Self.error(for: Int32(BWM_ERROR_EMBED_FAILED))
        }
        return NSImage(cgImage: cgImage, size: displaySize)
    }

    private func validDisplaySize(for image: NSImage, width: Int, height: Int) -> NSSize {
        if image.size.width > 0, image.size.height > 0 {
            return image.size
        }
        return NSSize(width: CGFloat(width), height: CGFloat(height))
    }

    private static func error(for code: Int32) -> BlindWatermarkError {
        let message: String
        if let cString = bwm_get_error_message(code) {
            message = String(cString: cString)
        } else {
            message = "Unknown error"
        }

        if code == Int32(BWM_ERROR_INVALID_HANDLE) {
            return .invalidHandle(message)
        }
        if code == Int32(BWM_ERROR_FILE_NOT_FOUND) {
            return .fileNotFound(message)
        }
        if code == Int32(BWM_ERROR_INVALID_IMAGE) {
            return .invalidImage(message)
        }
        if code == Int32(BWM_ERROR_EMBED_FAILED) {
            return .embedFailed(message)
        }
        if code == Int32(BWM_ERROR_EXTRACT_FAILED) {
            return .extractFailed(message)
        }
        if code == Int32(BWM_ERROR_INVALID_PARAMS) {
            return .invalidParameters(message)
        }
        if code == Int32(BWM_ERROR_IMAGE_TOO_SMALL) {
            return .imageTooSmall(message)
        }
        if code == Int32(BWM_ERROR_PASSWORD_REQUIRED) {
            return .passwordRequired(message)
        }
        if code == Int32(BWM_ERROR_NOT_IMPLEMENTED) {
            return .unknown(code: code, message: message)
        }
        if code == Int32(BWM_ERROR_OUT_OF_MEMORY) {
            return .outOfMemory(message)
        }
        return .unknown(code: code, message: message)
    }
}

private final class BitmapBuffer {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let byteCount: Int
    let pointer: UnsafeMutablePointer<UInt8>

    init?(width: Int, height: Int) {
        guard width > 0, height > 0, width <= Int.max / 4 else {
            return nil
        }
        let rowBytes = width * 4
        guard height <= Int.max / rowBytes else {
            return nil
        }

        self.width = width
        self.height = height
        self.bytesPerRow = rowBytes
        self.byteCount = rowBytes * height
        self.pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
        pointer.initialize(repeating: 0, count: byteCount)
    }

    deinit {
        pointer.deinitialize(count: byteCount)
        pointer.deallocate()
    }
}
#endif
