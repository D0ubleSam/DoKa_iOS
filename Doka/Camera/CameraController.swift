import AVFoundation
import Combine
import CoreVideo
import Foundation

enum CameraState: Equatable {
    case idle
    case requestingPermission
    case configuring
    case ready
    case denied
    case unavailable
    case interrupted
    case failed
}

enum CameraFlashMode: String, CaseIterable, Identifiable {
    case off, auto, on

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .off: return "bolt.slash"
        case .auto: return "bolt.badge.a"
        case .on: return "bolt.fill"
        }
    }

    var label: String {
        switch self {
        case .off: return "关闭闪光灯"
        case .auto: return "自动闪光灯"
        case .on: return "开启闪光灯"
        }
    }

    fileprivate var captureMode: AVCaptureDevice.FlashMode {
        switch self {
        case .off: return .off
        case .auto: return .auto
        case .on: return .on
        }
    }
}

enum CameraError: LocalizedError, Equatable {
    case unavailable
    case inputUnavailable
    case outputUnavailable
    case sessionNotRunning
    case captureInProgress
    case missingPhotoData
    case captureInterrupted

    var errorDescription: String? {
        switch self {
        case .unavailable: return "当前设备没有可用相机。模拟器可使用相册导入。"
        case .inputUnavailable: return "无法连接相机，请稍后重试。"
        case .outputUnavailable: return "无法建立相机输出。"
        case .sessionNotRunning: return "相机尚未就绪，请稍后拍摄。"
        case .captureInProgress: return "正在处理上一张照片。"
        case .missingPhotoData: return "未能取得照片数据，请重新拍摄。"
        case .captureInterrupted: return "拍摄被中断，请重新拍摄。"
        }
    }
}

/// AVFoundation ownership stays on `sessionQueue`; all published UI values change on main.
/// Frame consumers run synchronously on `frameQueue` and must return promptly.
/// Portrait pixel buffers are already rotated and front-camera frames are mirrored.
final class CameraController: NSObject, ObservableObject {
    @Published private(set) var state: CameraState = .idle
    @Published private(set) var isRunning = false
    @Published private(set) var isCapturing = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var position: AVCaptureDevice.Position = .back
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var zoomRange: ClosedRange<CGFloat> = 1...5
    @Published private(set) var exposureBias: Float = 0
    @Published private(set) var exposureRange: ClosedRange<Float> = -2...2
    @Published private(set) var flashMode: CameraFlashMode = .off
    @Published private(set) var isFlashAvailable = false

    /// Called on the frame queue. Retain the buffer if processing asynchronously.
    var onFrame: ((CVPixelBuffer) -> Void)? {
        get { callbackLock.withLock { frameHandler } }
        set { callbackLock.withLock { frameHandler = newValue } }
    }

    /// Called on main. Decode EXIF orientation when making a CIImage from this JPEG.
    var onPhoto: ((Result<Data, Error>) -> Void)? {
        get { callbackLock.withLock { photoHandler } }
        set { callbackLock.withLock { photoHandler = newValue } }
    }

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.doka.camera.session", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "com.doka.camera.frames", qos: .userInitiated)
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false
    private var wantsToRun = false
    private var requestingPermission = false
    private var interrupted = false
    private var requestedFlashMode: CameraFlashMode = .off
    private var activeCaptureID: Int64?
    private var deliveredCaptureData = false
    private var observers: [NSObjectProtocol] = []
    private let callbackLock = NSLock()
    private var frameHandler: ((CVPixelBuffer) -> Void)?
    private var photoHandler: ((Result<Data, Error>) -> Void)?

    override init() {
        super.init()
        installObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        // AVFoundation stopRunning is blocking; do not perform it on the UI thread.
        let captureSession = session
        sessionQueue.async {
            if captureSession.isRunning { captureSession.stopRunning() }
        }
    }

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsToRun = true
            self.startIfAuthorized()
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.wantsToRun = false
            if self.session.isRunning { self.session.stopRunning() }
            self.failPendingCapture(CameraError.captureInterrupted)
            self.updateUI {
                $0.isRunning = false
                if $0.state == .ready || $0.state == .configuring || $0.state == .interrupted {
                    $0.state = .idle
                }
            }
        }
    }

    func switchCamera() {
        sessionQueue.async { [weak self] in
            guard let self, self.configured, self.activeCaptureID == nil,
                  let oldInput = self.videoInput else { return }
            let newPosition: AVCaptureDevice.Position = oldInput.device.position == .back ? .front : .back
            guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition) else {
                self.publishError(CameraError.unavailable)
                return
            }
            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.removeInput(oldInput)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.videoInput = newInput
                    self.configurePhotoDimensions(for: device)
                    self.configureConnections(position: newPosition)
                    self.session.commitConfiguration()
                    self.publishDeviceState(device)
                    self.updateUI { $0.errorMessage = nil }
                } else {
                    // Restore the existing usable input when the replacement is rejected.
                    if self.session.canAddInput(oldInput) {
                        self.session.addInput(oldInput)
                        self.configurePhotoDimensions(for: oldInput.device)
                        self.configureConnections(position: oldInput.device.position)
                    } else {
                        self.videoInput = nil
                        self.configured = false
                    }
                    self.session.commitConfiguration()
                    self.publishError(CameraError.inputUnavailable)
                }
            } catch {
                self.publishError(error)
            }
        }
    }

    func setFlashMode(_ mode: CameraFlashMode) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestedFlashMode = mode
            self.updateUI { $0.flashMode = mode }
        }
    }

    func setZoom(_ value: CGFloat) {
        guard value.isFinite else { return }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let lower = max(1, device.minAvailableVideoZoomFactor)
            let upper = max(lower, min(5, device.maxAvailableVideoZoomFactor))
            let zoom = min(max(value, lower), upper)
            do {
                try device.lockForConfiguration()
                device.cancelVideoZoomRamp()
                device.videoZoomFactor = zoom
                device.unlockForConfiguration()
                self.updateUI { $0.zoomFactor = zoom }
            } catch {
                self.publishError(error)
            }
        }
    }

    func setExposureBias(_ value: Float) {
        guard value.isFinite else { return }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let bias = min(max(value, device.minExposureTargetBias), device.maxExposureTargetBias)
            do {
                try device.lockForConfiguration()
                device.setExposureTargetBias(bias, completionHandler: nil)
                device.unlockForConfiguration()
                self.updateUI { $0.exposureBias = bias }
            } catch {
                self.publishError(error)
            }
        }
    }

    /// Point is normalized in the full portrait preview (before any UI crop), origin top-left.
    func focus(at previewPoint: CGPoint) {
        guard previewPoint.x.isFinite, previewPoint.y.isFinite else { return }
        sessionQueue.async { [weak self] in
            guard let self, let device = self.videoInput?.device else { return }
            let x = min(max(previewPoint.x, 0), 1)
            let y = min(max(previewPoint.y, 0), 1)
            // AVCaptureDevice coordinates are landscape-native and never mirrored.
            let sensorPoint = CGPoint(x: y, y: device.position == .front ? x : 1 - x)
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = sensorPoint
                    if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = sensorPoint
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
                device.isSubjectAreaChangeMonitoringEnabled = true
                device.unlockForConfiguration()
            } catch {
                self.publishError(error)
            }
        }
    }

    func capturePhoto() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            guard self.wantsToRun, self.session.isRunning, !self.interrupted else {
                self.deliverPhoto(.failure(CameraError.sessionNotRunning))
                return
            }
            guard self.activeCaptureID == nil else {
                // Do not complete the in-flight UI request on a duplicate shutter press.
                self.publishError(CameraError.captureInProgress)
                return
            }
            guard self.photoOutput.availablePhotoCodecTypes.contains(.jpeg) else {
                self.deliverPhoto(.failure(CameraError.outputUnavailable))
                return
            }
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.photoQualityPrioritization = .balanced
            settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            let flash = self.requestedFlashMode.captureMode
            if self.photoOutput.supportedFlashModes.contains(flash) {
                settings.flashMode = flash
            }
            self.configureConnections(position: self.videoInput?.device.position ?? .back)
            self.activeCaptureID = settings.uniqueID
            self.deliveredCaptureData = false
            self.updateUI {
                $0.isCapturing = true
                $0.errorMessage = nil
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func startIfAuthorized() {
        guard wantsToRun else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            guard !requestingPermission else { return }
            requestingPermission = true
            updateUI { $0.state = .requestingPermission }
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                guard let self else { return }
                self.sessionQueue.async {
                    self.requestingPermission = false
                    if self.wantsToRun { self.startIfAuthorized() }
                }
            }
        case .denied, .restricted:
            updateUI {
                $0.state = .denied
                $0.isRunning = false
                $0.errorMessage = "请在系统设置中允许相机访问，或使用相册导入。"
            }
        @unknown default:
            updateUI {
                $0.state = .denied
                $0.isRunning = false
                $0.errorMessage = "系统暂未允许相机访问。"
            }
        }
    }

    private func configureAndStart() {
        guard wantsToRun, !interrupted else { return }
        do {
            if !configured {
                updateUI {
                    $0.state = .configuring
                    $0.errorMessage = nil
                }
                try configureSession()
                configured = true
            }
            if !session.isRunning { session.startRunning() }
            let running = session.isRunning
            updateUI {
                $0.isRunning = running
                $0.state = running ? .ready : .failed
                $0.errorMessage = running ? nil : "相机启动失败，请重试。"
            }
        } catch {
            updateUI {
                $0.isRunning = false
                $0.state = (error as? CameraError) == .unavailable ? .unavailable : .failed
                $0.errorMessage = error.localizedDescription
            }
        }
    }

    private func configureSession() throws {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw CameraError.unavailable
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        // A failed configuration is retriable, without leaving partially attached outputs.
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        videoInput = nil
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
        guard session.canAddInput(input) else { throw CameraError.inputUnavailable }
        session.addInput(input)
        guard session.canAddOutput(photoOutput) else {
            session.removeInput(input)
            throw CameraError.outputUnavailable
        }
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality
        configurePhotoDimensions(for: device)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(videoOutput) else {
            session.removeOutput(photoOutput)
            session.removeInput(input)
            throw CameraError.outputUnavailable
        }
        session.addOutput(videoOutput)
        videoInput = input
        configureConnections(position: device.position)
        publishDeviceState(device)
    }

    private func configurePhotoDimensions(for device: AVCaptureDevice) {
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions.sorted {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }
        // 12 MP bounds image-processing memory on older phones while preserving full-quality output.
        if let chosen = dimensions.last(where: { Int64($0.width) * Int64($0.height) <= 12_500_000 }) ?? dimensions.first {
            photoOutput.maxPhotoDimensions = chosen
        }
    }

    private func configureConnections(position: AVCaptureDevice.Position) {
        for connection in [videoOutput.connection(with: .video), photoOutput.connection(with: .video)].compactMap({ $0 }) {
            if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = position == .front
            }
        }
    }

    private func publishDeviceState(_ device: AVCaptureDevice) {
        let lowerZoom = max(1, device.minAvailableVideoZoomFactor)
        let upperZoom = max(lowerZoom, min(5, device.maxAvailableVideoZoomFactor))
        let devicePosition = device.position
        let currentZoom = device.videoZoomFactor
        let currentBias = device.exposureTargetBias
        let lowerBias = max(-2, device.minExposureTargetBias)
        let upperBias = max(lowerBias, min(2, device.maxExposureTargetBias))
        let flashAvailable = device.hasFlash && device.isFlashAvailable
        updateUI {
            $0.position = devicePosition
            $0.zoomFactor = currentZoom
            $0.zoomRange = lowerZoom...upperZoom
            $0.exposureBias = currentBias
            $0.exposureRange = lowerBias...upperBias
            $0.isFlashAvailable = flashAvailable
        }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                self.interrupted = true
                self.failPendingCapture(CameraError.captureInterrupted)
                self.updateUI {
                    $0.state = .interrupted
                    $0.isRunning = false
                    $0.errorMessage = "相机暂时被其他任务占用，恢复后会自动继续。"
                }
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.sessionQueue.async {
                self.interrupted = false
                if self.wantsToRun { self.configureAndStart() }
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            guard let self else { return }
            let captureError = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self.sessionQueue.async {
                self.failPendingCapture((captureError as Error?) ?? CameraError.captureInterrupted)
                if captureError?.code == .mediaServicesWereReset {
                    self.interrupted = false
                    if self.wantsToRun { self.configureAndStart() }
                } else {
                    self.updateUI {
                        $0.state = .failed
                        $0.isRunning = false
                        $0.errorMessage = captureError?.localizedDescription ?? "相机发生错误，请重试。"
                    }
                }
            }
        })
    }

    private func failPendingCapture(_ error: Error) {
        if activeCaptureID != nil && !deliveredCaptureData {
            deliverPhoto(.failure(error))
        }
        activeCaptureID = nil
        deliveredCaptureData = false
        updateUI { $0.isCapturing = false }
    }

    private func deliverPhoto(_ result: Result<Data, Error>) {
        let handler = onPhoto
        DispatchQueue.main.async { [weak self] in
            if case .failure(let error) = result { self?.errorMessage = error.localizedDescription }
            handler?(result)
        }
    }

    private func publishError(_ error: Error) {
        updateUI { $0.errorMessage = error.localizedDescription }
    }

    private func updateUI(_ update: @escaping (CameraController) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            update(self)
        }
    }
}

extension CameraController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer), let handler = onFrame else { return }
        autoreleasepool { handler(buffer) }
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let captureID = photo.resolvedSettings.uniqueID
        let data = error == nil ? photo.fileDataRepresentation() : nil
        sessionQueue.async { [weak self] in
            guard let self, self.activeCaptureID == captureID, !self.deliveredCaptureData else { return }
            self.deliveredCaptureData = true
            if let error {
                self.deliverPhoto(.failure(error))
            } else if let data {
                self.deliverPhoto(.success(data))
            } else {
                self.deliverPhoto(.failure(CameraError.missingPhotoData))
            }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        sessionQueue.async { [weak self] in
            guard let self, self.activeCaptureID == resolvedSettings.uniqueID else { return }
            if !self.deliveredCaptureData {
                self.deliverPhoto(.failure(error ?? CameraError.missingPhotoData))
            }
            self.activeCaptureID = nil
            self.deliveredCaptureData = false
            self.updateUI { $0.isCapturing = false }
        }
    }
}
