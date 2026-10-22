import SwiftUI
import CoreImage

/// UI state is owned by the main queue. Vision work is owned by trackingQueue.
final class CompositionModel: ObservableObject {
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isAuthenticated = AIService.shared.hasToken
    @Published private(set) var result: AICompositionResult?
    @Published private(set) var trackedRect: CGRect?
    @Published private(set) var isTrackingLost = false
    @Published private(set) var status = ""
    @Published var errorMessage: String?
    @Published var showLogin = false

    private let tracker = CompositionTracker()
    private let trackingQueue = DispatchQueue(label: "com.doka.composition-tracking", qos: .userInitiated)
    private var latestFrame: CGImage?
    private var latestFrameTime = Date.distantPast
    private var requestTask: Task<Void, Never>?
    private var generation = UUID()
    private var trackingBusy = false
    private var trackerReady = false
    private var composeTimes = 0

    var isAligned: Bool {
        guard let rect = trackedRect, !isTrackingLost else { return false }
        return abs(rect.midX - 0.5) < 0.04 && abs(rect.midY - 0.5) < 0.04
            && rect.width >= 0.9 && rect.height >= 0.9
    }

    var guidance: String {
        if isAnalyzing { return "正在分析，请保持手机稳定" }
        if isTrackingLost { return "目标已丢失，请重新构图" }
        guard let rect = trackedRect else { return status }
        let dx = rect.midX - 0.5, dy = rect.midY - 0.5
        if abs(dx) >= 0.04 || abs(dy) >= 0.04 {
            if abs(dx) >= abs(dy) { return dx < 0 ? "向左转动手机" : "向右转动手机" }
            return dy < 0 ? "向上转动手机" : "向下转动手机"
        }
        if isAligned { return "已对齐，可以拍摄" }
        return "保持居中，靠近或放大目标画面"
    }

    /// CGImage uses the exact unfiltered portrait crop sent to the service.
    func consume(_ image: CGImage) {
        latestFrame = image
        latestFrameTime = Date()
        guard trackerReady, !trackingBusy, !isTrackingLost else { return }
        trackingBusy = true
        let requestID = generation
        trackingQueue.async { [weak self] in
            guard let self else { return }
            let observation = self.tracker.track(frame: image)
            DispatchQueue.main.async {
                guard self.generation == requestID else { return }
                self.trackingBusy = false
                guard let observation else {
                    self.trackedRect = nil
                    self.isTrackingLost = true
                    self.trackerReady = false
                    return
                }
                self.trackedRect = observation.rectangle
            }
        }
    }

    func analyze(zoomFactor: Double) {
        guard !isAnalyzing else { return }
        isAuthenticated = AIService.shared.hasToken
        guard isAuthenticated else { showLogin = true; return }
        guard let frame = latestFrame, Date().timeIntervalSince(latestFrameTime) < 1.5 else {
            errorMessage = "取景画面尚未准备好，请稍后重试。"
            return
        }
        reset(clearFrame: false)
        isAnalyzing = true
        status = "正在分析，请保持手机稳定"
        let requestID = generation
        composeTimes += 1
        let currentComposeTimes = composeTimes
        requestTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                // Only the current 768px analysis frame is sent, without photo metadata.
                guard let jpeg = UIImage(cgImage: frame).jpegData(compressionQuality: 0.85) else { throw ImagingError.renderFailed }
                let result = try await AIService.shared.analyze(
                    jpeg: jpeg, width: frame.width, height: frame.height,
                    zoomFactor: zoomFactor, composeTimes: currentComposeTimes
                )
                try Task.checkCancellation()
                guard self.generation == requestID else { return }
                self.result = result
                self.isAnalyzing = false
                self.status = "正在定位推荐画面"
                self.trackingQueue.async { [weak self] in
                    guard let self else { return }
                    do {
                        try self.tracker.start(reference: frame, rectangle: result.rect)
                        DispatchQueue.main.async {
                            guard self.generation == requestID else { return }
                            self.trackerReady = true
                            // Do not draw the stale request-frame rectangle over a newer frame.
                            if let current = self.latestFrame { self.consume(current) }
                        }
                    } catch {
                        DispatchQueue.main.async {
                            guard self.generation == requestID else { return }
                            self.isTrackingLost = true
                            self.status = "目标跟踪失败，请重新构图"
                        }
                    }
                }
            } catch {
                guard self.generation == requestID, !Task.isCancelled else { return }
                self.isAnalyzing = false
                self.status = "构图未完成"
                self.errorMessage = error.localizedDescription
                self.isAuthenticated = AIService.shared.hasToken
                if !self.isAuthenticated { self.showLogin = true }
            }
        }
    }

    func reset(clearFrame: Bool = true) {
        requestTask?.cancel()
        requestTask = nil
        generation = UUID()
        isAnalyzing = false
        result = nil
        trackedRect = nil
        trackerReady = false
        trackingBusy = false
        isTrackingLost = false
        status = ""
        if clearFrame { latestFrame = nil; latestFrameTime = .distantPast }
        trackingQueue.async { [tracker] in tracker.reset() }
    }

    func refreshLogin() { isAuthenticated = AIService.shared.hasToken }

    func logout() {
        do {
            try AIService.shared.logout()
            isAuthenticated = false
            reset()
        } catch { errorMessage = error.localizedDescription }
    }
}
