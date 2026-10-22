import Photos
import Foundation

enum PhotoLibraryError: LocalizedError {
    case denied, saveFailed
    var errorDescription: String? {
        switch self {
        case .denied: return "尚未允许保存照片。请在系统设置中允许 Doka 添加照片。"
        case .saveFailed: return "照片未能保存，请重试。"
        }
    }
}

enum PhotoLibrary {
    static func save(_ data: Data, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { completion(.failure(PhotoLibraryError.denied)) }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "Doka-\(UUID().uuidString).jpg"
                request.addResource(with: .photo, data: data, options: options)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        completion(.success(Void()))
                    } else {
                        completion(.failure(error ?? PhotoLibraryError.saveFailed))
                    }
                }
            }
        }
    }
}
