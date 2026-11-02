import AppKit
import BWM
import CoreGraphics
import Foundation
import XCTest
@testable import BlindWatermarkKit

@MainActor
final class BlindWatermarkServiceTests: XCTestCase {
    private let service = BlindWatermarkService()
    private let password = "round-trip-password"
    private let imageWidth = 320
    private let imageHeight = 224

    func testLegacyV1PNGStillExtracts() throws {
        guard let url = Bundle.module.url(forResource: "v1_legacy_0x02", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return XCTFail("legacy v1 fixture is unavailable")
        }

        let result = try service.extract(from: image, password: "legacy-v1-password")

        guard case .detected(let payload, let isText) = result else {
            return XCTFail("legacy 0x02 image should route to v1 and extract")
        }
        XCTAssertEqual(payload, Data("legacy-v1-0x02".utf8))
        XCTAssertTrue(isText)
    }

    func testV2EmbedReturnsNotImplemented() throws {
        let payload = Data("v2".utf8)
        let pixels = [UInt8](repeating: 0, count: 4)
        var output: UnsafeMutablePointer<UInt8>?
        var outputSize: Int32 = -1

        let status = pixels.withUnsafeBufferPointer { source in
            payload.withUnsafeBytes { payloadBuffer in
                "v2-password".withCString { passwordPointer in
                    quikra_bwm_embed(
                        source.baseAddress, 1, 1, 4,
                        payloadBuffer.bindMemory(to: UInt8.self).baseAddress,
                        Int32(payload.count), 0, BWM_ALGO_V2, passwordPointer,
                        &output, &outputSize
                    )
                }
            }
        }

        XCTAssertEqual(status, Int32(BWM_ERROR_NOT_IMPLEMENTED))
        XCTAssertNil(output)
        XCTAssertEqual(outputSize, 0)
        XCTAssertEqual(String(cString: bwm_get_error_message(status)),
                       "Algorithm not implemented")
    }

    func testTextPayloadSurvivesPNGRoundTrip() throws {
        let payload = Data("hello blind watermark".utf8)
        let original = try makeImage(width: imageWidth, height: imageHeight)

        let embedded = try service.embed(in: original, payload: payload, isText: true,
                                         password: password)
        let decoded = try pngRoundTrip(embedded)
        let result = try service.extract(from: decoded, password: password)

        guard case .detected(let extractedPayload, let isText) = result else {
            return XCTFail("expected a detected watermark")
        }
        XCTAssertEqual(extractedPayload, payload)
        XCTAssertTrue(isText)
    }

    func testTextPayloadSurvivesInMemoryRoundTrip() throws {
        let payload = Data("hello in-memory watermark".utf8)
        let original = try makeImage(width: imageWidth, height: imageHeight)

        let embedded = try service.embed(in: original, payload: payload, isText: true,
                                         password: password)
        let result = try service.extract(from: embedded, password: password)

        guard case .detected(let extractedPayload, let isText) = result else {
            return XCTFail("expected a detected watermark from the in-memory result")
        }
        XCTAssertEqual(extractedPayload, payload)
        XCTAssertTrue(isText)
    }

    func testTransparentImageSurvivesInMemoryRoundTrip() throws {
        let payload = Data("transparent image watermark".utf8)
        let original = try makeTransparentImage(width: imageWidth, height: imageHeight)

        let embedded = try service.embed(in: original, payload: payload, isText: true,
                                         password: password)
        let result = try service.extract(from: embedded, password: password)

        guard case .detected(let extractedPayload, let isText) = result else {
            return XCTFail("expected a detected watermark from a transparent image")
        }
        XCTAssertEqual(extractedPayload, payload)
        XCTAssertTrue(isText)
    }

    func testTransparentImageSurvivesUIStylePNGFileRoundTrip() throws {
        let payload = Data("UI save and reload watermark".utf8)
        let original = try makeTransparentImage(width: imageWidth, height: imageHeight)

        let embedded = try service.embed(in: original, payload: payload, isText: true,
                                         password: password)
        var rect = NSRect(origin: .zero, size: embedded.size)
        guard let cgImage = embedded.cgImage(forProposedRect: &rect, context: nil, hints: nil),
              let png = NSBitmapImageRep(cgImage: cgImage)
                  .representation(using: .png, properties: [:]) else {
            throw FixtureError.pngEncodingFailed
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }
        try png.write(to: url, options: .atomic)

        guard let decoded = NSImage(contentsOf: url) else {
            throw FixtureError.pngDecodingFailed
        }
        let result = try service.extract(from: decoded, password: password)

        guard case .detected(let extractedPayload, let isText) = result else {
            return XCTFail("expected a detected watermark after UI-style PNG reload")
        }
        XCTAssertEqual(extractedPayload, payload)
        XCTAssertTrue(isText)
    }

    func testBinaryPayloadSurvivesPNGRoundTrip() throws {
        let payload = Data([0x00, 0x01, 0x7F, 0x80, 0xFE, 0xFF, 0x42, 0x24])
        let original = try makeImage(width: imageWidth, height: imageHeight)

        let embedded = try service.embed(in: original, payload: payload, isText: false,
                                         password: password)
        let decoded = try pngRoundTrip(embedded)
        let result = try service.extract(from: decoded, password: password)

        guard case .detected(let extractedPayload, let isText) = result else {
            return XCTFail("expected a detected watermark")
        }
        XCTAssertEqual(extractedPayload, payload)
        XCTAssertFalse(isText)
    }

    func testWrongPasswordReturnsNotDetectedWithoutThrowing() throws {
        let payload = Data("wrong-password-check".utf8)
        let original = try makeImage(width: imageWidth, height: imageHeight)

        let embedded = try service.embed(in: original, payload: payload, isText: true,
                                         password: password)
        let decoded = try pngRoundTrip(embedded)
        let result = try service.extract(from: decoded, password: "not-the-password")

        XCTAssertEqual(result, .notDetected)
    }

    func testImageTooSmallMapsToTypedError() throws {
        let original = try makeImage(width: 64, height: 64)
        let payload = Data("too small".utf8)

        do {
            _ = try service.embed(in: original, payload: payload, isText: true,
                                  password: password)
            XCTFail("expected imageTooSmall")
        } catch let error as BlindWatermarkError {
            guard case .imageTooSmall(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(message, "Image too small for watermark payload")
        }
    }

    func testEmptyPasswordMapsToTypedError() throws {
        let original = try makeImage(width: imageWidth, height: imageHeight)
        let payload = Data("password check".utf8)

        do {
            _ = try service.embed(in: original, payload: payload, isText: false,
                                  password: "")
            XCTFail("expected passwordRequired")
        } catch let error as BlindWatermarkError {
            guard case .passwordRequired(let message) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(message, "Password is required")
        }
    }

    private func makeImage(width: Int, height: Int) throws -> NSImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ??
            CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw FixtureError.contextCreationFailed
        }

        let rowCount = max(height, 1)
        for row in 0..<height {
            let amount = CGFloat(row) / CGFloat(rowCount)
            context.setFillColor(red: 0.15 + 0.65 * amount, green: 0.30,
                                 blue: 0.75 - 0.45 * amount, alpha: 1)
            context.fill(CGRect(x: 0, y: row, width: width, height: 1))
        }

        for index in 0..<24 {
            let x = (index * 53) % width
            let y = (index * 97) % height
            let rect = CGRect(x: x, y: y, width: min(48, width - x),
                              height: min(32, height - y))
            context.setFillColor(red: CGFloat((index * 37) % 200) / 255.0,
                                 green: CGFloat((index * 71) % 200) / 255.0,
                                 blue: CGFloat((index * 113) % 200) / 255.0,
                                 alpha: 1)
            context.fill(rect)
        }

        guard let cgImage = context.makeImage() else {
            throw FixtureError.imageCreationFailed
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private func makeTransparentImage(width: Int, height: Int) throws -> NSImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ??
            CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        )
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw FixtureError.contextCreationFailed
        }

        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.15, 0.35, 0.75),
            (0.78, 0.28, 0.32),
            (0.22, 0.62, 0.45),
            (0.88, 0.62, 0.18),
        ]
        for (index, color) in colors.enumerated() {
            let size = CGFloat(40 + index * 18)
            let x = CGFloat((index * 47) % max(width - Int(size), 1))
            let y = CGFloat((index * 37) % max(height - Int(size), 1))
            context.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: size, height: size))
        }

        guard let cgImage = context.makeImage() else {
            throw FixtureError.imageCreationFailed
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    private func pngRoundTrip(_ image: NSImage) throws -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw FixtureError.pngEncodingFailed
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: url) }
        try png.write(to: url, options: .atomic)

        guard let decoded = NSImage(contentsOf: url) else {
            throw FixtureError.pngDecodingFailed
        }
        return decoded
    }
}

private enum FixtureError: Error {
    case contextCreationFailed
    case imageCreationFailed
    case pngEncodingFailed
    case pngDecodingFailed
}
