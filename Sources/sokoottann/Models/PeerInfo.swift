import Foundation

/// ピア情報。id は displayName（String）で管理する。MCPeerID は使用しない。
struct PeerInfo: Identifiable, Equatable {
    let id: String
    let discoveredAt: Date

    /// NI確立前の仮配置（ランダム）
    let fallbackAngle: Double
    let fallbackDistance: CGFloat

    /// NINearbyObject から更新される実測距離（メートル）— UWB (U1チップ必須)
    var niDistance: Float?
    /// NINearbyObject から更新される方向ベクトル（デバイス座標系）
    /// FOV 内のときのみ非 nil。nil 時は niDirectionCached を使う。
    var niDirection: SIMD3<Float>?
    /// 最後に受信した方向ベクトルとその時刻。FOV から外れても 3 秒間有効。
    var niDirectionCached:     SIMD3<Float>? = nil
    var niDirectionCachedAt:   Date?         = nil
    private static let directionCacheSec: Double = 3.0

    /// 有効な方向ベクトル（現在値 → キャッシュ → nil の優先順）
    var effectiveDirection: SIMD3<Float>? {
        if let d = niDirection { return d }
        guard let cached = niDirectionCached,
              let at = niDirectionCachedAt,
              Date().timeIntervalSince(at) < Self.directionCacheSec
        else { return nil }
        return cached
    }

    /// BLE RSSI ログ距離モデルによる推定距離（メートル）— 全機種で動作するフォールバック
    var rssiDistance: Float?

    /// BLE 経由で受け取った相手のコンパス方位（度, 0=北, 時計回り）
    /// UWB 非対応機での方向推定に使用
    var peerHeading: Double?

    /// 相手デバイスが UWB 方向測定で算出し送ってきた「自分の絶対方位」（コンパス度）
    /// 相手が U2 チップ持ちで、自分が U1 チップ (iPhone 14 非Pro 等) の場合に使用
    var remoteBearing: Double?
    var remoteBearingReceivedAt: Date?

    var displayName: String { id }

    // MARK: - Radar positioning

    /// レーダー上の角度（SwiftUI座標系: x=右, y=下）
    ///
    /// - Parameter myHeadingDeg: 自分のコンパス方位（度, 0=北, 時計回り）
    ///
    /// 優先度: UWB (niDirection) → BLE 方位交換 (peerHeading) → ランダムフォールバック
    ///
    /// 正しい変換式:
    ///   ① NI 方向 φ（デバイス相対, rad）+ 自分のheading H（rad）→ 絶対方位 β = H + φ
    ///   ② レーダーZStack は -H 回転しているため、pre-rotation 角度 α = β - π/2 + H = 2H + φ - π/2
    ///   ③ コンパス方位 peerHeading の場合: β = peerHeading_rad → α = β - π/2 + H
    func radarAngle(myHeadingDeg: Double) -> Double {
        let myH = myHeadingDeg * .pi / 180
        if let dir = niDirection {
            let phi = Double(atan2(dir.x, -dir.z))
            return 2 * myH + phi - .pi / 2
        }
        if let ph = peerHeading {
            let beta = ph * .pi / 180
            return beta - .pi / 2 + myH
        }
        return fallbackAngle
    }

    /// レーダー半径に対する距離割合（0.08〜0.92）。最大 20m をレーダー端とする
    /// 優先度: UWB (niDistance) > BLE RSSI (rssiDistance) > ランダムフォールバック
    var radarDistanceFraction: CGFloat {
        let bestDistance: Float? = niDistance ?? rssiDistance
        if let d = bestDistance {
            let maxMeters: Float = 20.0
            let clamped = min(max(d, 0.3), maxMeters)
            return CGFloat(clamped / maxMeters) * 0.84 + 0.08
        }
        return fallbackDistance
    }

    // MARK: - Display labels

    /// 距離ラベル: UWB → BLE RSSI → 測定中 の優先順で表示
    var distanceLabel: String {
        if let d = niDistance {
            if d < 1.0 { return "1m未満" }
            return "約\(Int(d.rounded()))m"
        }
        if let d = rssiDistance {
            if d < 1.0 { return "約1m以内" }
            return "約\(Int(d.rounded()))m"
        }
        return "測定中…"
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

