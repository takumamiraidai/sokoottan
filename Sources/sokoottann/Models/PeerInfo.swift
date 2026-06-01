import Foundation
import MultipeerConnectivity

struct PeerInfo: Identifiable, Equatable {
    let id: MCPeerID
    let angle: Double    // radians 0〜2π (レーダー上の方向)
    let distance: CGFloat // 0.25〜0.80 (レーダー半径に対する割合)
    let discoveredAt: Date

    var displayName: String { id.displayName }

    /// 約何メートルか（レーダー最大50mとして換算）
    var distanceLabel: String {
        let meters = Int(distance * 50)
        return "約\(meters)m"
    }

    /// コンパス方角ラベル
    /// SwiftUIの座標系: angle=0 は右(東)、時計回りに増加
    var directionLabel: String {
        var degrees = (angle * 180 / .pi).truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        switch degrees {
        case 337.5..<360, 0..<22.5:  return "東"
        case 22.5..<67.5:            return "南東"
        case 67.5..<112.5:           return "南"
        case 112.5..<157.5:          return "南西"
        case 157.5..<202.5:          return "西"
        case 202.5..<247.5:          return "北西"
        case 247.5..<292.5:          return "北"
        default:                     return "北東"
        }
    }

    /// 方角に対応する矢印
    var directionArrow: String {
        switch directionLabel {
        case "東":   return "→"
        case "南東": return "↘"
        case "南":   return "↓"
        case "南西": return "↙"
        case "西":   return "←"
        case "北西": return "↖"
        case "北":   return "↑"
        default:     return "↗"
        }
    }

    static func == (lhs: PeerInfo, rhs: PeerInfo) -> Bool {
        lhs.id == rhs.id
    }
}
