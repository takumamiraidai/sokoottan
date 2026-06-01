import Foundation
import MultipeerConnectivity
import NearbyInteraction

/// MultipeerConnectivity + NearbyInteraction を使い近くのピアを発見・計測するマネージャー
final class MultipeerManager: NSObject, ObservableObject {

    // サービスタイプ: 小文字英数字とハイフンのみ、最大15文字
    private static let serviceType = "sokoita"

    @Published var discoveredPeers: [PeerInfo] = []
    @Published var isSearching: Bool = false
    /// ピアIDをキーにしたチャット履歴
    @Published var messages: [MCPeerID: [ChatMessage]] = [:]
    /// 未読メッセージのあるピアIDセット
    @Published var unreadPeers: Set<MCPeerID> = []

    private let peerID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    /// ピアごとの NISession（1対1 UWB計測セッション）
    private var niSessions: [MCPeerID: NISession] = [:]

    init(displayName: String) {
        self.peerID = MCPeerID(displayName: displayName)
        self.session = MCSession(
            peer: self.peerID,          // ← 同じ peerID インスタンスを使う
            securityIdentity: nil,
            encryptionPreference: .required
        )
        super.init()
        session.delegate = self
    }

    // MARK: - Public

    func startSearching() {
        guard !isSearching else { return }

        let adv = MCNearbyServiceAdvertiser(
            peer: peerID,
            discoveryInfo: nil,
            serviceType: Self.serviceType
        )
        adv.delegate = self
        adv.startAdvertisingPeer()
        advertiser = adv

        let brw = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        brw.delegate = self
        brw.startBrowsingForPeers()
        browser = brw

        isSearching = true
    }

    func stopSearching() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
        advertiser = nil
        browser = nil
        isSearching = false
        niSessions.values.forEach { $0.invalidate() }
        niSessions.removeAll()
        discoveredPeers.removeAll()
    }

    /// 指定ピアにテキストメッセージを送信する
    func sendMessage(_ text: String, to peerID: MCPeerID) {
        let packet = DataPacket(type: .chat, text: text, niTokenData: nil)
        guard let data = try? JSONEncoder().encode(packet) else { return }
        do {
            try session.send(data, toPeers: [peerID], with: .reliable)
            DispatchQueue.main.async {
                self.messages[peerID, default: []].append(ChatMessage(text: text, isFromSelf: true))
            }
        } catch {
            print("⚠️ Send error: \(error.localizedDescription)")
        }
    }

    /// 指定ピアとの未読をクリアする
    func markAsRead(peerID: MCPeerID) {
        DispatchQueue.main.async {
            self.unreadPeers.remove(peerID)
        }
    }

    // MARK: - NearbyInteraction (private)

    private func startNearbyInteraction(with peerID: MCPeerID) {
        // U1チップ非搭載デバイス・シミュレーター はスキップ
        guard NISession.isSupported else {
            print("⚠️ NearbyInteraction (UWB) not supported on this device")
            return
        }
        let ni = NISession()
        ni.delegate = self
        niSessions[peerID] = ni
        print("🔵 NISession created for \(peerID.displayName), token: \(ni.discoveryToken != nil)")
        sendNIToken(to: peerID, niSession: ni)
    }

    private func sendNIToken(to peerID: MCPeerID, niSession: NISession) {
        guard let token = niSession.discoveryToken else {
            print("⚠️ discoveryToken is nil (simulator?)")
            return
        }
        guard let tokenData = try? NSKeyedArchiver.archivedData(
            withRootObject: token, requiringSecureCoding: true
        ) else { return }
        let packet = DataPacket(type: .niToken, text: nil, niTokenData: tokenData)
        guard let data = try? JSONEncoder().encode(packet) else { return }
        do {
            try session.send(data, toPeers: [peerID], with: .reliable)
            print("📤 Sent NI token to \(peerID.displayName)")
        } catch {
            print("⚠️ Failed to send NI token: \(error.localizedDescription)")
        }
    }
}

// MARK: - DataPacket (パケット種別の統一)

private struct DataPacket: Codable {
    enum PacketType: String, Codable {
        case niToken = "ni_token"
        case chat
    }
    let type: PacketType
    let text: String?
    let niTokenData: Data?
}

// MARK: - MCSessionDelegate

extension MultipeerManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        switch state {
        case .connected:
            print("✅ MC connected: \(peerID.displayName)")
            // NISession はメインスレッドで生成・起動する
            DispatchQueue.main.async {
                self.startNearbyInteraction(with: peerID)
            }
        case .notConnected:
            print("❌ MC disconnected: \(peerID.displayName)")
            DispatchQueue.main.async {
                self.niSessions[peerID]?.invalidate()
                self.niSessions.removeValue(forKey: peerID)
            }
        default:
            break
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let packet = try? JSONDecoder().decode(DataPacket.self, from: data) else {
            print("⚠️ Failed to decode packet from \(peerID.displayName)")
            return
        }
        switch packet.type {
        case .niToken:
            print("📡 Received NI token from \(peerID.displayName)")
            guard
                let tokenData = packet.niTokenData,
                let token = try? NSKeyedUnarchiver.unarchivedObject(
                    ofClass: NIDiscoveryToken.self, from: tokenData
                )
            else {
                print("⚠️ Failed to unarchive NI token")
                return
            }
            DispatchQueue.main.async {
                // NISession がまだなければ作成してから run する
                if self.niSessions[peerID] == nil {
                    self.startNearbyInteraction(with: peerID)
                }
                guard let niSession = self.niSessions[peerID] else { return }
                niSession.run(NINearbyPeerConfiguration(peerToken: token))
            }

        case .chat:
            guard let text = packet.text else { return }
            DispatchQueue.main.async {
                self.messages[peerID, default: []].append(ChatMessage(text: text, isFromSelf: false))
                self.unreadPeers.insert(peerID)
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("⚠️ Advertiser error: \(error.localizedDescription)")
    }

    func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        // 招待を自動承諾（接続確立のため）
        invitationHandler(true, session)
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.discoveredPeers.contains(where: { $0.id == peerID }) else { return }

            let angle = Double.random(in: 0 ..< (2 * .pi))
            let distance = CGFloat.random(in: 0.28 ... 0.74)
            let peer = PeerInfo(
                id: peerID,
                discoveredAt: Date(),
                fallbackAngle: angle,
                fallbackDistance: distance
            )

            self.discoveredPeers.append(peer)
        }
        // 接続確立のために招待を送る
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { [weak self] in
            self?.discoveredPeers.removeAll { $0.id == peerID }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("⚠️ Browser error: \(error.localizedDescription)")
    }
}

// MARK: - NISessionDelegate

extension MultipeerManager: NISessionDelegate {

    /// 距離・方向が更新された
    func session(_ niSession: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard
            let obj = nearbyObjects.first,
            let peerID = niSessions.first(where: { $0.value === niSession })?.key
        else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let idx = self.discoveredPeers.firstIndex(where: { $0.id == peerID }) else { return }
            self.discoveredPeers[idx].niDistance  = obj.distance
            self.discoveredPeers[idx].niDirection = obj.direction
        }
    }

    /// ピアが範囲外に出た
    func session(_ niSession: NISession, didRemove nearbyObjects: [NINearbyObject], reason: NINearbyObject.RemovalReason) {
        guard let peerID = niSessions.first(where: { $0.value === niSession })?.key else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let idx = self.discoveredPeers.firstIndex(where: { $0.id == peerID }) else { return }
            self.discoveredPeers[idx].niDistance  = nil
            self.discoveredPeers[idx].niDirection = nil
        }
    }

    /// バックグラウンド復帰後にセッションを再起動
    func sessionSuspensionEnded(_ niSession: NISession) {
        guard let peerID = niSessions.first(where: { $0.value === niSession })?.key else { return }
        sendNIToken(to: peerID, niSession: niSession)
    }

    func session(_ niSession: NISession, didInvalidateWith error: Error) {
        print("⚠️ NISession invalidated: \(error.localizedDescription)")
    }
}
