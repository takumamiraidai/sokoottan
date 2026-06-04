import Foundation
import CoreMotion

/// 短い歩行（2〜4歩）で相手の方位を推定するサービス。
///
/// アルゴリズム（ヒストグラム投票法）:
///   歩いた方向 θ・移動距離 L・UWB距離変化 Δd の関係から
///     cos(θ - bearing_to_target) ≈ -Δd / L
///   となるため、候補方位 = θ ± acos(-Δd/L) の 2 値が得られる。
///   複数セグメントの候補を 36-bin ガウシアン投票で集約し、
///   最多得票ビンを目標方位とする。
///
///   廊下など一方向しか歩けない場合でも:
///     - 前進で距離減少 → r≈1 → 両候補がほぼ同じ向き → 即収束
///     - 前進で距離増加 → r≈-1 → 逆方向を返す
final class WalkingBearingEstimator: ObservableObject {

    // MARK: - Published

    @Published var estimatedBearing: Double? = nil
    @Published var sampleCount: Int = 0
    @Published var isActive: Bool = false
    @Published var suggestedNextHeading: Double? = nil
    @Published var sampledHeadings: [Double] = []

    // MARK: - Constants

    static let requiredSamples: Int = 1         // 1 セグメントから推定開始
    static let recommendedSamples: Int = 4      // 4 セグメントで高精度
    private static let minDistBetweenSamples: Double = 0.5  // 0.5m ≈ 1歩
    private static let stepLength: Double = 0.72
    private static let maxSamples: Int = 8

    // MARK: - External inputs

    var getHeading: (() -> Double)?
    var getDistance: (() -> Double?)?

    // MARK: - Private state

    private let pedometer = CMPedometer()
    private var posX: Double = 0
    private var posY: Double = 0
    private var lastStepCount: Int = 0
    private var lastSamplePos: (Double, Double) = (0, 0)
    private var lastSampleDist: Double? = nil
    private var segments: [MoveSegment] = []

    // MARK: - Public API

    func start() {
        guard CMPedometer.isStepCountingAvailable() else { return }
        reset()
        isActive = true
        pedometer.startUpdates(from: Date()) { [weak self] data, error in
            guard let self, let data, error == nil else { return }
            let totalSteps = data.numberOfSteps.intValue
            let newSteps = totalSteps - self.lastStepCount
            guard newSteps > 0 else { return }
            self.lastStepCount = totalSteps

            DispatchQueue.main.async {
                let heading = self.getHeading?() ?? 0
                let rad = heading * .pi / 180
                let moved = Double(newSteps) * Self.stepLength
                self.posX += moved * sin(rad)
                self.posY += moved * cos(rad)

                let dx = self.posX - self.lastSamplePos.0
                let dy = self.posY - self.lastSamplePos.1
                let distFromLast = sqrt(dx * dx + dy * dy)

                if distFromLast >= Self.minDistBetweenSamples,
                   let distAfter = self.getDistance?() {
                    // distBefore がある場合のみセグメントを記録
                    if let distBefore = self.lastSampleDist {
                        self.addSegment(dx: dx, dy: dy,
                                        distBefore: distBefore, distAfter: distAfter,
                                        heading: heading)
                    }
                    self.lastSamplePos = (self.posX, self.posY)
                    self.lastSampleDist = distAfter
                } else if self.lastSampleDist == nil,
                          let d = self.getDistance?() {
                    // 最初の距離サンプルを記録
                    self.lastSampleDist = d
                }
            }
        }
    }

    func stop() {
        pedometer.stopUpdates()
        isActive = false
    }

    func reset() {
        pedometer.stopUpdates()
        posX = 0; posY = 0; lastStepCount = 0
        lastSamplePos = (0, 0); lastSampleDist = nil
        segments = []; sampleCount = 0
        estimatedBearing = nil; suggestedNextHeading = nil
        sampledHeadings = []
        isActive = false
    }

    // MARK: - Private

    private func addSegment(dx: Double, dy: Double,
                            distBefore: Double, distAfter: Double,
                            heading: Double) {
        let seg = MoveSegment(dx: dx, dy: dy,
                              distBefore: distBefore, distAfter: distAfter)
        guard seg.moveLen > 0.3 else { return }

        segments.append(seg)
        if segments.count > Self.maxSamples { segments.removeFirst() }
        sampleCount = segments.count
        sampledHeadings.append(heading)
        if sampledHeadings.count > Self.maxSamples { sampledHeadings.removeFirst() }

        suggestedNextHeading = norm360(heading + 90)
        estimatedBearing = vote()
    }

    /// ヒストグラム投票で方位を推定する。
    ///
    /// 各セグメントの r = -Δd/L に対して:
    ///   bearing_to_target = walkBearing ± acos(r) の2候補をガウシアン投票
    /// 真の方位に対応するビンが複数セグメントから累積投票を受けて支配的になる。
    private func vote() -> Double? {
        var bins = [Double](repeating: 0, count: 36)
        var totalW = 0.0

        for seg in segments {
            let r = seg.r
            // |r| が小さい = 直角移動 = ノイズ支配的 → スキップ
            guard abs(r) > 0.2 else { continue }

            let walkBear = atan2(seg.dx, seg.dy) * 180 / .pi
            let alphaDeg = acos(max(-1.0, min(1.0, r))) * 180 / .pi

            // 移動距離と |r| で重み付け（長く・まっすぐ歩いたほど信頼度高）
            let w = abs(r) * min(seg.moveLen / 0.8, 2.5)

            for candidate in [norm360(walkBear + alphaDeg), norm360(walkBear - alphaDeg)] {
                for b in 0..<36 {
                    var diff = abs(Double(b) * 10.0 + 5.0 - candidate)
                    if diff > 180 { diff = 360 - diff }
                    // σ ≈ 28°のガウシアン
                    bins[b] += w * exp(-diff * diff / 800.0)
                }
            }
            totalW += w * 2.0
        }

        guard totalW > 0 else { return nil }

        // ピーク探索
        guard let peak = bins.indices.max(by: { bins[$0] < bins[$1] }) else { return nil }

        // 1セグメントで両候補が近い（r≒1 or r≒-1）場合は鋭いピーク → すぐ確定
        // 複数セグメントなら均等投票が打ち消し合い真の方位が突出
        let total = bins.reduce(0, +)
        guard total > 0, bins[peak] / total > 0.07 else { return nil }

        // ピーク周辺の circular mean で精度向上
        var sinS = 0.0, cosS = 0.0
        for offset in -3...3 {
            let b = (peak + offset + 36) % 36
            let rad = (Double(b) * 10.0 + 5.0) * .pi / 180.0
            sinS += bins[b] * sin(rad)
            cosS += bins[b] * cos(rad)
        }
        var bearing = atan2(sinS, cosS) * 180.0 / .pi
        if bearing < 0 { bearing += 360 }
        return bearing
    }

    private func norm360(_ a: Double) -> Double {
        ((a.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: - MoveSegment

private struct MoveSegment {
    let dx: Double          // east displacement (m)
    let dy: Double          // north displacement (m)
    let distBefore: Double  // UWB distance before move (m)
    let distAfter: Double   // UWB distance after move (m)

    var moveLen: Double { sqrt(dx * dx + dy * dy) }

    /// -Δd/L : +1 = 完全に target 方向, -1 = 完全に逆方向, 0 = 直角
    var r: Double {
        let L = moveLen
        guard L > 0.1 else { return 0 }
        return max(-1.0, min(1.0, -(distAfter - distBefore) / L))
    }
}



