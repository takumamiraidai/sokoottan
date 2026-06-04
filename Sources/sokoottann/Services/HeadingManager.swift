import Foundation
import CoreMotion

/// CoreMotion の磁力計でコンパス方位を取得するマネージャー。
/// GPS・位置情報の許可は不要。
final class HeadingManager: ObservableObject {

    /// 磁北基準の方位角（度, 0=北, 時計回り）。未確定の間は 0 のまま。
    @Published var heading: Double = 0

    private let motion = CMMotionManager()

    // 円周平均用の sin/cos 成分（EMA）
    // 0/360 境界を跨いでも正しく追従する
    private var emaS: Double = 0
    private var emaC: Double = 1
    private static let alpha: Double = 0.12  // 小さいほど滑らか（遅延 ↑）, 大きいほど遷正（ノイズ ↑）

    func start() {
        guard motion.isDeviceMotionAvailable else {
            print("⚠️ DeviceMotion not available")
            return
        }
        motion.deviceMotionUpdateInterval = 1.0 / 10.0  // 10Hz — 20Hzより安定
        motion.startDeviceMotionUpdates(
            using: .xMagneticNorthZVertical,
            to: .main
        ) { [weak self] data, _ in
            guard let self, let data, data.heading >= 0 else { return }
            let rad = data.heading * .pi / 180
            self.emaS = Self.alpha * sin(rad) + (1 - Self.alpha) * self.emaS
            self.emaC = Self.alpha * cos(rad) + (1 - Self.alpha) * self.emaC
            var smooth = atan2(self.emaS, self.emaC) * 180 / .pi
            if smooth < 0 { smooth += 360 }
            self.heading = smooth
        }
    }

    func stop() {
        motion.stopDeviceMotionUpdates()
    }
}
