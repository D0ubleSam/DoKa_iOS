import SwiftUI
import CoreImage
import PhotosUI

final class CameraModel: ObservableObject {
    let camera = CameraController()
    let composition = CompositionModel()
    @Published var preview: UIImage?
    @Published var editedPreview: UIImage?
    @Published var latestPhoto: UIImage?
    @Published var isEditing = false
    @Published var isProcessing = false
    @Published var isSaving = false
    @Published var errorMessage: String?
    @Published var notice: String?
    @Published var gridEnabled = true
    @Published var levelEnabled = true
    @Published var settings = RenderSettings() {
        didSet {
            if settings.ratio != oldValue.ratio { composition.reset() }
            stateLock.lock()
            renderSettings = settings
            revision += 1
            stateLock.unlock()
            if isEditing { refreshEditor() }
        }
    }

    private let renderQueue = DispatchQueue(label: "com.doka.image-processing", qos: .userInitiated)
    private let engine = FilterEngine()
    private let stateLock = NSLock()
    private var renderSettings = RenderSettings()
    private var frameInFlight = false
    private var lastFrameTime = CFAbsoluteTimeGetCurrent()
    private var revision = 0
    private var cameraFrameGeneration = 0
    private var editorSource: CIImage?
    private var capturedSettings: RenderSettings?
    private var lastJPEG: Data?
    private var frameSize = CGSize(width: 3, height: 4)
    private var lastAnalysisFrameTime = CFAbsoluteTimeGetCurrent()

    init() {
        camera.onFrame = { [weak self] buffer in self?.receiveFrame(buffer) }
        camera.onPhoto = { [weak self] result in self?.receivePhoto(result) }
    }

    func capture() {
        guard !isProcessing, !isSaving, camera.isRunning, !camera.isCapturing else { return }
        capturedSettings = settings
        notice = nil
        isProcessing = true
        camera.capturePhoto()
    }

    func beginImport() { composition.reset(); isProcessing = true }

    func invalidateCameraFrame() {
        stateLock.lock()
        // Camera lifecycle changes must not cancel an imported-photo render.
        cameraFrameGeneration += 1
        stateLock.unlock()
        preview = nil
        composition.reset()
    }

    func focus(at croppedPoint: CGPoint) {
        stateLock.lock(); let size = frameSize; stateLock.unlock()
        let width = min(size.width, size.height * settings.ratio.value)
        let height = min(size.height, size.width / settings.ratio.value)
        let point = CGPoint(
            x: ((size.width - width) / 2 + croppedPoint.x * width) / size.width,
            y: ((size.height - height) / 2 + croppedPoint.y * height) / size.height
        )
        camera.focus(at: point)
    }

    func importPhoto(_ data: Data) {
        renderQueue.async { [weak self] in
            guard let self else { return }
            guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
                DispatchQueue.main.async { self.isProcessing = false; self.errorMessage = ImagingError.decodeFailed.localizedDescription }
                return
            }
            DispatchQueue.main.async {
                self.editorSource = source
                self.notice = nil
                self.editedPreview = nil
                self.isEditing = true
                self.isProcessing = false
                self.camera.stop()
                self.refreshEditor()
            }
        }
    }

    func importFailed(_ error: Error) {
        isProcessing = false
        errorMessage = error.localizedDescription
    }

    func closeEditor() {
        isEditing = false
        editorSource = nil
        editedPreview = nil
        camera.start()
    }

    func saveEditedPhoto() {
        guard let source = editorSource, !isSaving else { return }
        isSaving = true
        notice = nil
        let snapshot = settings
        renderQueue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try self.engine.jpeg(source, settings: snapshot)
                let thumb = try self.engine.render(source, settings: snapshot, maxDimension: 500)
                DispatchQueue.main.async {
                    self.lastJPEG = data
                    self.latestPhoto = thumb
                    self.persist(data)
                }
            } catch { DispatchQueue.main.async { self.isSaving = false; self.errorMessage = error.localizedDescription } }
        }
    }

    func retrySaveLastPhoto() {
        guard let data = lastJPEG, !isSaving else { return }
        isSaving = true
        persist(data)
    }

    private func persist(_ data: Data) {
        PhotoLibrary.save(data) { [weak self] result in
            guard let self else { return }
            self.isSaving = false
            switch result {
            case .success: self.notice = "已保存到照片"
            case .failure(let error): self.errorMessage = error.localizedDescription
            }
        }
    }

    private func receivePhoto(_ result: Result<Data, Error>) {
        let snapshot = capturedSettings ?? settings
        capturedSettings = nil
        switch result {
        case .failure(let error): isProcessing = false; errorMessage = error.localizedDescription
        case .success(let data):
            renderQueue.async { [weak self] in
                guard let self else { return }
                do {
                    guard let source = CIImage(data: data, options: [.applyOrientationProperty: true]) else { throw ImagingError.decodeFailed }
                    let jpeg = try self.engine.jpeg(source, settings: snapshot)
                    let thumb = try self.engine.render(source, settings: snapshot, maxDimension: 500)
                    DispatchQueue.main.async {
                        self.latestPhoto = thumb
                        self.lastJPEG = jpeg
                        self.isProcessing = false
                        self.isSaving = true
                        self.persist(jpeg)
                    }
                } catch { DispatchQueue.main.async { self.isProcessing = false; self.errorMessage = error.localizedDescription } }
            }
        }
    }

    private func receiveFrame(_ buffer: CVPixelBuffer) {
        stateLock.lock()
        frameSize = CGSize(width: CGFloat(CVPixelBufferGetWidth(buffer)), height: CGFloat(CVPixelBufferGetHeight(buffer)))
        let now = CFAbsoluteTimeGetCurrent()
        guard !frameInFlight, now - lastFrameTime >= 1 / 15 else { stateLock.unlock(); return }
        frameInFlight = true
        lastFrameTime = now
        let snapshot = renderSettings
        let version = revision
        let frameGeneration = cameraFrameGeneration
        stateLock.unlock()
        let input = CIImage(cvPixelBuffer: buffer)
        renderQueue.async { [weak self] in
            guard let self else { return }
            defer { self.stateLock.lock(); self.frameInFlight = false; self.stateLock.unlock() }
            do {
                let image = try self.engine.render(input, settings: snapshot, maxDimension: 1080)
                var analysisFrame: CGImage?
                let currentTime = CFAbsoluteTimeGetCurrent()
                if currentTime - self.lastAnalysisFrameTime >= 0.16 {
                    self.lastAnalysisFrameTime = currentTime
                    var neutral = RenderSettings()
                    neutral.ratio = snapshot.ratio
                    analysisFrame = try self.engine.render(input, settings: neutral, maxDimension: 768).cgImage
                }
                let originalFrame = analysisFrame
                DispatchQueue.main.async {
                    self.stateLock.lock()
                    let valid = version == self.revision && frameGeneration == self.cameraFrameGeneration
                    self.stateLock.unlock()
                    if valid && !self.isEditing && self.camera.isRunning {
                        self.preview = image
                        if let originalFrame { self.composition.consume(originalFrame) }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    if self.errorMessage == nil { self.errorMessage = error.localizedDescription }
                }
            }
        }
    }

    private func refreshEditor() {
        guard let source = editorSource else { return }
        let snapshot = settings
        stateLock.lock(); let version = revision; stateLock.unlock()
        renderQueue.async { [weak self] in
            guard let self else { return }
            // Slider updates coalesce: don't render superseded settings.
            self.stateLock.lock(); let valid = version == self.revision; self.stateLock.unlock()
            guard valid else { return }
            do {
                let image = try self.engine.render(source, settings: snapshot, maxDimension: 1500)
                DispatchQueue.main.async {
                    self.stateLock.lock(); let stillValid = version == self.revision; self.stateLock.unlock()
                    if stillValid && self.isEditing { self.editedPreview = image }
                }
            } catch { DispatchQueue.main.async { self.errorMessage = error.localizedDescription } }
        }
    }
}
