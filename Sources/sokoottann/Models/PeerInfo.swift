import Foundation
import MultipeerConnectivity

struct PeerInfo: Identifiable, Equatable {
    let id: MCPeerID
    let angle: Double    // radians 0〜2π (レーダー上の方向)
    let distance: CGFloat // 0.25〜0.80 (レーダー半径に対する割合)
    let discoveredAt: Date

    var displayName: String { id.displayName }

    static func == (lhs: PeerInfo, rhs: PeerInfo) -> Bool {
        lhs.id == rhs.id
    }
}
