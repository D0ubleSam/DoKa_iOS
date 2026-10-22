import Foundation
import UIKit

/// Only this origin receives login information, device metadata, or image data.
private final class AIOriginRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let target = request.url, target.scheme == "https",
              target.host?.lowercased() == "www.yindoka.com",
              target.port == nil || target.port == 443 else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

@MainActor
final class AIService {
    static let shared = AIService()
    private let baseURL = URL(string: "https://www.yindoka.com/")!
    private let tokenStore = AITokenStore()
    private let redirectDelegate = AIOriginRedirectDelegate()
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 40
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }()
    private let installationID: String

    private init() {
        let key = "doka-ios-installation-id"
        if let saved = UserDefaults.standard.string(forKey: key) {
            installationID = saved
        } else {
            installationID = UUID().uuidString
            UserDefaults.standard.set(installationID, forKey: key)
        }
    }

    var hasToken: Bool { ((try? tokenStore.read()) ?? nil)?.isEmpty == false }

    func logout() throws { try tokenStore.delete() }

    /// The UI calls this only in response to the user's explicit Send Code action.
    func sendCode(phone: String) async throws {
        let phone = try normalizedPhone(phone)
        let body = try JSONSerialization.data(withJSONObject: ["phone_num": phone])
        let _: EmptyAIPayload? = try await perform(path: "ai_camera/auth/get_code", body: body,
                                                   contentType: "application/json", authenticated: false)
    }

    func login(phone: String, code: String) async throws {
        let phone = try normalizedPhone(phone)
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...8).contains(code.count), code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw AIServiceError.invalidVerificationCode
        }
        let body = try JSONSerialization.data(withJSONObject: ["phone_num": phone, "msg_code": code, "username": ""])
        let payload: AIAuthPayload? = try await perform(path: "ai_camera/auth/login", body: body,
                                                       contentType: "application/json", authenticated: false)
        guard let token = payload?.token, !token.isEmpty,
              !token.contains("\r"), !token.contains("\n"), token.utf8.count <= 16_384 else {
            throw AIServiceError.malformedResponse
        }
        try tokenStore.save(token)
    }

    func analyze(jpeg: Data, width: Int, height: Int, zoomFactor: Double,
                 composeTimes: Int = 1) async throws -> AICompositionResult {
        guard jpeg.count > 3, jpeg.count <= 12 * 1024 * 1024,
              jpeg.starts(with: [0xff, 0xd8, 0xff]), width > 0, height > 0,
              zoomFactor.isFinite, zoomFactor > 0, composeTimes >= 1 else {
            throw AIServiceError.invalidImage
        }
        guard hasToken else { throw AIServiceError.authenticationRequired }
        let milliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        let fields: [String: String] = [
            "shoot_type": "scenery", "direction": "shu",
            "compose_times": String(composeTimes), "scan_focal_length": String(zoomFactor),
            "ai_filter": "on", "timestamp": String(milliseconds),
            "language": requestLanguage, "region": "china", "distribution": "store"
        ]
        let boundary = "DokaIOS-\(UUID().uuidString)"
        let body = Self.multipart(fields: fields, jpeg: jpeg, filename: "frame_\(milliseconds).jpg", boundary: boundary)
        let payload: AICameraPayload? = try await perform(path: "ai_camera/v2", body: body,
            contentType: "multipart/form-data; boundary=\(boundary)", authenticated: true)
        guard let payload else { throw AIServiceError.missingComposition }
        return try payload.result(imageWidth: width, imageHeight: height)
    }

    private var requestLanguage: String {
        Locale.preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "ZH" : "EN"
    }

    private func normalizedPhone(_ input: String) throws -> String {
        let phone = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard phone.count == 11, phone.first == "1", phone.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            throw AIServiceError.invalidPhone
        }
        return phone
    }

    private func perform<Payload: Decodable>(path: String, body: Data, contentType: String,
                                             authenticated: Bool) async throws -> Payload? {
        let token = authenticated ? try tokenStore.read() : nil
        if authenticated && (token?.isEmpty != false) { throw AIServiceError.authenticationRequired }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Doka-iOS-Port/0.1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        request.setValue("0.1.0", forHTTPHeaderField: "App-Version")
        request.setValue("0.1.0", forHTTPHeaderField: "X-App-Version")
        request.setValue("china", forHTTPHeaderField: "X-Region")
        request.setValue("store", forHTTPHeaderField: "X-Distribution")
        request.setValue(requestLanguage, forHTTPHeaderField: "X-Language")
        let model = UIDevice.current.model
        let metadata: [String: String] = [
            "os_type": "iOS", "os_version": UIDevice.current.systemVersion,
            "Device-ID": "Apple \(model)", "device_id": "Apple \(model)",
            "deviceUUID": installationID, "device_uuid": installationID,
            "device_model": model, "device_marketname": model,
            "env": "product", "doka_version": "0.1.0", "doka_version_ios": "0.1.0",
            "flavor": "store", "build_flavor": "china", "region": "china",
            "distribution": "store", "language": requestLanguage
        ]
        let metadataJSON = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        request.setValue(String(data: metadataJSON, encoding: .utf8), forHTTPHeaderField: "User-Agent-Follow")
        request.setValue("", forHTTPHeaderField: "Jwt-Token")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw AIServiceError.malformedResponse }
        if http.statusCode == 401 {
            try invalidateIfCurrent(token)
            throw AIServiceError.authenticationRequired
        }
        guard data.count <= 2 * 1024 * 1024 else { throw AIServiceError.malformedResponse }
        let decoder = JSONDecoder()
        if let status = try? decoder.decode(APIStatus.self, from: data), status.code != 0 {
            if [-20001, -20002, -20004].contains(status.code) {
                try invalidateIfCurrent(token)
                throw AIServiceError.authenticationRequired
            }
            throw AIServiceError.server(code: status.code, message: String((status.message ?? "").prefix(500)))
        }
        guard (200..<300).contains(http.statusCode) else { throw AIServiceError.httpStatus(http.statusCode) }
        guard let envelope = try? decoder.decode(APIEnvelope<Payload>.self, from: data), envelope.code == 0 else {
            throw AIServiceError.malformedResponse
        }
        return envelope.data
    }

    private func invalidateIfCurrent(_ sentToken: String?) throws {
        guard let sentToken, try tokenStore.read() == sentToken else { return }
        try tokenStore.delete()
    }

    static func multipart(fields: [String: String], jpeg: Data, filename: String, boundary: String) -> Data {
        var body = Data()
        func append(_ text: String) { body.append(Data(text.utf8)) }
        for key in fields.keys.sorted() {
            append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n")
        }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: image/jpeg\r\n\r\n")
        body.append(jpeg)
        append("\r\n--\(boundary)--\r\n")
        return body
    }
}
