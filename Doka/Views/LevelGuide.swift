import SwiftUI
import CoreMotion

final class LevelMonitor: ObservableObject {
    @Published var angle: Double = 0
    @Published var isAvailable = false
    private let motion = CMMotionManager()
    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 0.1
        motion.startDeviceMotionUpdates(to: .main) { [weak self] data, _ in
            guard let data, let self else { return }
            // A phone laid flat has no useful portrait horizon.
            self.isAvailable = abs(data.gravity.y) + abs(data.gravity.x) > 0.2
            self.angle = atan2(data.gravity.x, -data.gravity.y)
        }
    }
    func stop() { motion.stopDeviceMotionUpdates() }
    deinit { motion.stopDeviceMotionUpdates() }
}

struct LevelGuide: View {
    @StateObject private var monitor = LevelMonitor()
    var body: some View {
        ZStack {
            if monitor.isAvailable {
                Capsule().fill(.white.opacity(0.5)).frame(width: 72, height: 1)
                Capsule().fill(abs(monitor.angle) < 0.025 ? Color.green : .white)
                    .frame(width: 44, height: 2).rotationEffect(.radians(monitor.angle))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
            .onAppear { monitor.start() }.onDisappear { monitor.stop() }
    }
}
