import Foundation
import CoreGraphics
import Security

struct AIFilterRecommendation: Identifiable, Equatable {
    let filterName: String
    let reason: String
    var id: String { filterName }
}

/// Coordinates refer to the exact JPEG submitted for analysis: top-left origin,
/// normalized to [0, 1]. The original protocol calls zoom `ExifFocalLength`.
struct AICompositionResult {
    let rect: CGRect
    let reason: String
    let recommendations: [AIFilterRecommendation]
    let suggestedZoomFactor: Double?
}

enum AIServiceError: LocalizedError {
    case authenticationRequired
    case compositionUnavailable
    case invalidPhone
    case invalidVerificationCode
    case invalidImage
    case malformedResponse
    case missingComposition
    case invalidComposition
    case httpStatus(Int)
    case server(code: Int, message: String)
    case tokenStorage(OSStatus)

    var isAuthenticationError: Bool {
        if case .authenticationRequired = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .authenticationRequired: return "请先登录 Doka 账号，或重新登录后再试。"
        case .compositionUnavailable: return "当前 Doka 账号没有可用构图次数或有效会员权益。请在原版 Doka 中检查账号权益。"
        case .invalidPhone: return "请输入有效的 11 位手机号码。"
        case .invalidVerificationCode: return "请输入收到的短信验证码。"
        case .invalidImage: return "当前画面无法用于构图，请重新取景。"
        case .malformedResponse: return "Doka 服务返回了无法识别的数据。"
        case .missingComposition: return "服务未返回可用的构图区域，请换个画面重试。"
        case .invalidComposition: return "服务返回的构图区域无效，请重新分析。"
        case .httpStatus(let status): return "Doka 服务暂不可用（HTTP \(status)）。"
        case .server(let code, let message):
            return message.isEmpty ? "Doka 服务未能完成请求（\(code)）。" : message
        case .tokenStorage: return "无法安全保存登录状态，请重试。"
        }
    }
}

struct APIStatus: Decodable {
    let code: Int
    let message: String?
}

struct APIEnvelope<Payload: Decodable>: Decodable {
    let code: Int
    let message: String?
    let data: Payload?
}

struct EmptyAIPayload: Decodable {}

struct AIAuthPayload: Decodable {
    let token: String?
}

struct AIEntitlementPayload: Decodable {
    let isVIP: Bool
    let remainingCount: Int

    private enum CodingKeys: String, CodingKey {
        case is_vip, remaining_compose_count, ai_compose_remaining_count, remaining_free_count
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isVIP = try values.decodeIfPresent(Bool.self, forKey: .is_vip) ?? false
        let compose = try values.decodeIfPresent(Int.self, forKey: .remaining_compose_count)
        let alternate = try values.decodeIfPresent(Int.self, forKey: .ai_compose_remaining_count)
        let legacy = try values.decodeIfPresent(Int.self, forKey: .remaining_free_count)
        remainingCount = max(0, compose ?? alternate ?? legacy ?? 0)
    }

    var canCompose: Bool { isVIP || remainingCount > 0 }
}

struct AICameraPayload: Decodable {
    let ExifFocalLength: String?
    let ComposeReason: String?
    let LeftTopCrd: [Double]?
    let RightDownCrd: [Double]?
    let SubAreaRectNorm: AINormalizedRect?
    let AiCameraFilter: AIFilterPayload?
    let AiCameraFilters: [AIFilterPayload]?

    enum CodingKeys: String, CodingKey {
        case ExifFocalLength, ComposeReason, LeftTopCrd, RightDownCrd
        case SubAreaRectNorm, AiCameraFilter, AiCameraFilters
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let number = try? values.decode(Double.self, forKey: .ExifFocalLength) {
            ExifFocalLength = String(number)
        } else {
            ExifFocalLength = try values.decodeIfPresent(String.self, forKey: .ExifFocalLength)
        }
        ComposeReason = try values.decodeIfPresent(String.self, forKey: .ComposeReason)
        LeftTopCrd = try values.decodeIfPresent([Double].self, forKey: .LeftTopCrd)
        RightDownCrd = try values.decodeIfPresent([Double].self, forKey: .RightDownCrd)
        // Older responses may include an empty/partial normalized object along
        // with the legacy pixel coordinates. Keep that independent fallback usable.
        SubAreaRectNorm = try? values.decode(AINormalizedRect.self, forKey: .SubAreaRectNorm)
        AiCameraFilter = try values.decodeIfPresent(AIFilterPayload.self, forKey: .AiCameraFilter)
        AiCameraFilters = try values.decodeIfPresent([AIFilterPayload].self, forKey: .AiCameraFilters)
    }

    func result(imageWidth: Int, imageHeight: Int) throws -> AICompositionResult {
        guard imageWidth > 0, imageHeight > 0 else { throw AIServiceError.invalidImage }
        let rect: CGRect
        if let normalized = SubAreaRectNorm, let valid = try? normalized.validatedRect() {
            rect = valid
        } else if let left = LeftTopCrd, let right = RightDownCrd,
                  left.count == 2, right.count == 2 {
            rect = try AINormalizedRect(
                x: left[0] / Double(imageWidth), y: left[1] / Double(imageHeight),
                width: (right[0] - left[0]) / Double(imageWidth),
                height: (right[1] - left[1]) / Double(imageHeight)
            ).validatedRect()
        } else {
            throw SubAreaRectNorm == nil ? AIServiceError.missingComposition : AIServiceError.invalidComposition
        }
        var seen = Set<String>()
        let filters = (AiCameraFilters ?? []) + (AiCameraFilter.map { [$0] } ?? [])
        let recommendations = filters.compactMap { filter -> AIFilterRecommendation? in
            let name = (filter.FilterName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
            return AIFilterRecommendation(filterName: name, reason: String((filter.Reason ?? "").prefix(500)))
        }
        let parsedZoom = ExifFocalLength.flatMap(Double.init)
        let zoom = parsedZoom.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return AICompositionResult(rect: rect, reason: String((ComposeReason ?? "").prefix(1000)),
                                   recommendations: recommendations, suggestedZoomFactor: zoom)
    }
}

struct AIFilterPayload: Decodable {
    let FilterName: String?
    let Reason: String?
}

struct AINormalizedRect: Decodable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }

    private enum CodingKeys: String, CodingKey { case X, Y, W, H, x, y, w, h }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        x = try values.decodeIfPresent(Double.self, forKey: .X) ?? values.decode(Double.self, forKey: .x)
        y = try values.decodeIfPresent(Double.self, forKey: .Y) ?? values.decode(Double.self, forKey: .y)
        width = try values.decodeIfPresent(Double.self, forKey: .W) ?? values.decode(Double.self, forKey: .w)
        height = try values.decodeIfPresent(Double.self, forKey: .H) ?? values.decode(Double.self, forKey: .h)
    }

    func validatedRect() throws -> CGRect {
        guard [x, y, width, height].allSatisfy({ $0.isFinite }),
              x >= 0, y >= 0, x < 1, y < 1, width > 0, height > 0,
              x + width <= 1.000001, y + height <= 1.000001 else {
            throw AIServiceError.invalidComposition
        }
        // Only remove sub-pixel floating-point overshoot at the far edge.
        return CGRect(x: x, y: y, width: min(width, 1 - x), height: min(height, 1 - y))
    }
}
