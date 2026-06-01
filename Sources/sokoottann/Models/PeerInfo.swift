import Foundation
import MultipeerConnectivity

/// NearbyInteraction で取得したリアルタイム計測値を持つピア情報
struct PeerInfo: Identifiable, Equatable {
    let id: MCPeerID
    let discoveredAt: Date

    /// NI確立前の仮配置（ランダム）
    let fallbackAngle: Double
    let fallbackDistance: CGFloat

    /// NINearbyObject から更新される実測距離（メートル）
    var niDistance: Float?
    /// NINearbyObject から更新される方向ベクトル（デバイス座標系）
    /// x=右, y=上, z=手前（カメラ方向は -z）
    var niDirection: SIMD3<Float>?

    var displayName: String { id.displayName }

    // MARK: - Radar positioning

    /// レーダー上の角度（SwiftUI座標系: 0=右, -π/2=上）
    /// NI: デバイス前方 = レーダー上 になるよう変換
    var radarAngle: Double {
        if let dir = niDirection {
            // atan2(x, -z): x=右, -z=前方 → 前方=0rad → SwiftUI上=-π/2に補正
            return Double(atan2(dir.x, -dir.z)) - .pi / 2
        }
        return fallbackAngle
    }

    /// レーダー半径に対する距離割合（0.08〜0.92）。最大 20m をレーダー端とする
    var radarDistanceFraction: CGFloat {
        if let d = niDistance {
            let maxMeters: Float = 20.0
            let clamped = min(max(d, 0.3), maxMeters)
            return CGFloat(clamped / maxMeters) * 0.84 + 0.08
        }
        return fallbackDistance
    }

    // MARK: - Display labels

    var distanceLabel: String {
        guard let d = niDistance else { return "測定中…" }
        if d < 1.0 { return "1m未満" }
        return "約\(Int(d.rounded()))m"
    }

    /// デバイス向き基準の方向ラベル
    var directionLabel: String {
        guard let dir = niDirection else { return "測定中…" }
        var deg = atan2(Double(dir.x), Double(-dir.z)) * 180 / .pi
        if deg < 0 { deg += 360 }
        switch deg {
        case 337.5..<360, 0..<22.5: return "前方"
        case 22.5..<67.5:           return "前右"
        case 67.5..<112.5:          return "右"
        case 112.5..<157.5:         return "後右"
        case 157.5..<202.5:         return "後方"
        case 202.5..<247.5:         return "後左"
        case 247.5..<292.5:         return "左"
        default:                    return "前左"
        }
    }

    var directionArrow: String {
        guard niDirection != nil else { return "…" }
        switch directionLabel {
        case "前方": return "↑"
        case "前右": return "↗"
        case "右":   return "→"
        case "後右": return "↘"
        case "後方": return "↓"
        case "後左": return "↙"
        case "左":   return "←"
        default:     return "↖"
        }
    }

    static func == (lhs: PeerInfo, rhs: PeerInfo) -> Bool {
        lhs.id == rhs.id &&
        lhs.niDistance == rhs.niDistance &&
        lhs.niDirection == rhs.niDirection
    }
}

