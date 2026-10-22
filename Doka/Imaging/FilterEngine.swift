import CoreImage
import ImageIO
import UIKit

enum ImagingError: LocalizedError {
    case missingLUT(String), invalidLUT(String), decodeFailed, renderFailed
    var errorDescription: String? {
        switch self {
        case .missingLUT(let name): return "缺少滤镜资源：\(name)"
        case .invalidLUT(let name): return "滤镜数据损坏：\(name)"
        case .decodeFailed: return "无法读取这张照片。"
        case .renderFailed: return "照片处理失败，请重试。"
        }
    }
}

/// Access only on the model's serial rendering queue. Cube layout is R-fastest,
/// then G, then B, matching CIColorCube and the APK's 8x8 LUT tile indexing.
final class FilterEngine {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var context = CIContext(options: [
        .workingColorSpace: colorSpace, .outputColorSpace: colorSpace,
        .cacheIntermediates: false
    ])
    private var cubeCache: [String: Data] = [:]

    func filtered(_ image: CIImage, settings: RenderSettings) throws -> CIImage {
        var output = image
        let intensity = CGFloat(min(1, max(0, settings.intensity)))
        if settings.filterID != FilmFilter.original.id && intensity > 0.001 {
            let cube = try cubeData(settings.filterID)
            let lut = image.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": 64,
                "inputCubeData": cube,
                "inputColorSpace": colorSpace
            ])
            output = image.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputTargetImageKey: lut, kCIInputTimeKey: intensity
            ])
        }
        // Exact affine form of GLPreviewRenderer.applyPalette, before its clamp.
        let t = CGFloat(min(1, max(-1, settings.tone)))
        let c = CGFloat(min(1, max(-1, settings.chroma)))
        let amount = CGFloat(min(1, max(0, settings.paletteIntensity)))
        if amount > 0 && (t != 0 || c != 0) {
            let exposure = pow(2.0, t * 0.18)
            let contrast = max(0.68, 1 - t * 0.16)
            let saturation = 1 + c * 0.42
            let diagonal = 1 - amount + amount * exposure * contrast * saturation
            let luma = amount * exposure * (1 - saturation)
            let bias = amount * 0.5 * (1 - contrast) * saturation
            let r = luma * 0.299, g = luma * 0.587, b = luma * 0.114
            output = output.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: diagonal + r, y: g, z: b, w: 0),
                "inputGVector": CIVector(x: r, y: diagonal + g, z: b, w: 0),
                "inputBVector": CIVector(x: r, y: g, z: diagonal + b, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0)
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
                "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)
            ])
        }
        return output.cropped(to: image.extent)
    }

    func render(_ input: CIImage, settings: RenderSettings, maxDimension: CGFloat? = nil) throws -> UIImage {
        var image = Self.centerCrop(input, ratio: settings.ratio.value)
        if let limit = maxDimension {
            let scale = min(1, limit / max(image.extent.width, image.extent.height))
            image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }
        image = try filtered(image, settings: settings)
        guard let cg = context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw ImagingError.renderFailed
        }
        return UIImage(cgImage: cg)
    }

    func jpeg(_ input: CIImage, settings: RenderSettings) throws -> Data {
        let image = try filtered(Self.centerCrop(input, ratio: settings.ratio.value), settings: settings)
        guard let data = context.jpegRepresentation(of: image, colorSpace: colorSpace,
             options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95]) else {
            throw ImagingError.renderFailed
        }
        return data
    }

    static func centerCrop(_ input: CIImage, ratio: CGFloat) -> CIImage {
        let extent = input.extent
        let width = min(extent.width, extent.height * ratio)
        let height = min(extent.height, extent.width / ratio)
        let rect = CGRect(x: extent.midX - width / 2, y: extent.midY - height / 2, width: width, height: height)
        return input.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    private func cubeData(_ id: String) throws -> Data {
        if let cached = cubeCache[id] { return cached }
        guard let url = Bundle.main.url(forResource: id, withExtension: "rgb8", subdirectory: "LUTs")
                ?? Bundle.main.url(forResource: id, withExtension: "rgb8") else { throw ImagingError.missingLUT(id) }
        let bytes = try Data(contentsOf: url)
        let count = 64 * 64 * 64
        guard bytes.count == count * 3 else { throw ImagingError.invalidLUT(id) }
        var floats = [Float](repeating: 1, count: count * 4)
        bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for i in 0..<count {
                floats[i * 4] = Float(buffer[i * 3]) / 255
                floats[i * 4 + 1] = Float(buffer[i * 3 + 1]) / 255
                floats[i * 4 + 2] = Float(buffer[i * 3 + 2]) / 255
            }
        }
        let result = floats.withUnsafeBytes { Data($0) }
        if cubeCache.count >= 3 { cubeCache.removeAll() }
        cubeCache[id] = result
        return result
    }
}
