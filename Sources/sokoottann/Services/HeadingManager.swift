import Foundation
import CoreMotion

/// CoreMotion の磁力計でコンパス方位を取得するマネージャー。
/// GPS・位置情報の許可は不要。
final class HeadingManager: ObservableObject {

    /// 磁北基準の方位角（度, 0=北, 時計回り）。未確定の間は 0 のまま。
    @Published var heading: Double = 0

    private let motion = CMMotionManager()

    func start() {
        guard motion.isDeviceMotionAvailable else {
            print("⚠️ DeviceMotion not available")
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 20.0  // 20Hz
        motion.startDeviceMotionUpdates(
            using: .xMagneticNorthZVertical,
            to: .main
        ) { [weak self] data, _ in
            guard let data, data.heading >= 0 else { return }
            self?.heading = data.heading
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }
}
