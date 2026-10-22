import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Tracks a region selected by the remote composition service; it does not
/// choose a composition or perform the server's AI inference.
///
/// All methods and state must be accessed on one serial queue. Inputs must be
/// upright, identically cropped frames. Coordinates exposed to the UI use a
/// top-left origin; Vision internally uses a bottom-left origin.
final class CompositionTracker {
    struct TrackingUpdate {
        let rectangle: CGRect
        let confidence: Float
    }

    enum TrackerError: LocalizedError {
        case invalidRectangle
        case invalidReference
        case initializationFailed

        var errorDescription: String? {
            switch self {
            case .invalidRectangle: return "构图区域无效，请重新分析。"
            case .invalidReference: return "参考画面无效，请重新分析。"
            case .initializationFailed: return "无法跟踪这个构图区域，请保持手机稳定后重新分析。"
            }
        }
    }

    private(set) var isLost = false
    private var sequence = VNSequenceRequestHandler()
    private var request: VNTrackObjectRequest?
    private var referenceAspect: CGFloat?
    private let confidenceThreshold: Float = 0.5

    func start(reference: CGImage, rectangle: CGRect) throws {
        reset()
        guard reference.width > 0, reference.height > 0 else {
            loseTracking()
            throw TrackerError.invalidReference
        }
        guard let region = Self.validatedRectangle(rectangle) else {
            loseTracking()
            throw TrackerError.invalidRectangle
        }

        let observation = VNDetectedObjectObservation(boundingBox: Self.flipOrigin(region))
        let newRequest = VNTrackObjectRequest(detectedObjectObservation: observation)
        newRequest.trackingLevel = .accurate
        referenceAspect = CGFloat(reference.width) / CGFloat(reference.height)

        do {
            // Prime the sequence with the exact image sent for AI analysis.
            // Starting from a later live frame would attach the target to the
            // wrong content when the phone moved while the request was in flight.
            try sequence.perform([newRequest], on: reference, orientation: .up)
            guard let result = newRequest.results?.first as? VNDetectedObjectObservation,
                  accepted(result) != nil else {
                loseTracking()
                throw TrackerError.initializationFailed
            }
            newRequest.inputObservation = result
            request = newRequest
        } catch {
            loseTracking()
            throw error
        }
    }

    /// Returns nil before start or immediately after tracking is lost. A nil
    /// return with isLost=true requires the caller to remove any old overlay.
    func track(frame: CGImage) -> TrackingUpdate? {
        guard let request, let referenceAspect else { return nil }
        guard frame.width > 0, frame.height > 0,
              abs(CGFloat(frame.width) / CGFloat(frame.height) - referenceAspect) < 0.001 else {
            loseTracking()
            return nil
        }
        do {
            try sequence.perform([request], on: frame, orientation: .up)
            guard let result = request.results?.first as? VNDetectedObjectObservation, let update = accepted(result) else {
                loseTracking()
                return nil
            }
            request.inputObservation = result
            return update
        } catch {
            loseTracking()
            return nil
        }
    }

    func reset() {
        request = nil
        referenceAspect = nil
        sequence = VNSequenceRequestHandler()
        isLost = false
    }

    private func loseTracking() {
        request = nil
        referenceAspect = nil
        sequence = VNSequenceRequestHandler()
        isLost = true
    }

    private func accepted(_ observation: VNDetectedObjectObservation) -> TrackingUpdate? {
        guard observation.confidence.isFinite,
              observation.confidence >= confidenceThreshold,
              let rectangle = Self.validatedRectangle(Self.flipOrigin(observation.boundingBox)) else {
            return nil
        }
        return TrackingUpdate(rectangle: rectangle, confidence: observation.confidence)
    }

    private static func flipOrigin(_ rectangle: CGRect) -> CGRect {
        CGRect(x: rectangle.minX, y: 1 - rectangle.maxY,
               width: rectangle.width, height: rectangle.height)
    }

    private static func validatedRectangle(_ rectangle: CGRect) -> CGRect? {
        let values = [rectangle.origin.x, rectangle.origin.y, rectangle.width, rectangle.height]
        guard values.allSatisfy({ $0.isFinite }), rectangle.width > 0.000001,
              rectangle.height > 0.000001 else { return nil }
        // Only absorb floating-point roundoff. A target that actually leaves
        // the image is lost rather than clamped into a misleading aligned box.
        let tolerance: CGFloat = 0.000001
        guard rectangle.minX >= -tolerance, rectangle.minY >= -tolerance,
              rectangle.maxX <= 1 + tolerance, rectangle.maxY <= 1 + tolerance else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let clipped = rectangle.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { return nil }
        return clipped
    }
}
