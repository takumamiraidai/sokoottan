import Foundation
import MultipeerConnectivity

/// MultipeerConnectivity を使い、同じアプリで探索中のピアを相互発見するマネージャー
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

    init(displayName: String) {
        self.peerID = MCPeerID(displayName: displayName)
        self.session = MCSession(
            peer: MCPeerID(displayName: displayName),
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
        discoveredPeers.removeAll()
    }

    /// 指定ピアにテキストメッセージを送信する
    func sendMessage(_ text: String, to peerID: MCPeerID) {
        let payload: [String: String] = ["type": "chat", "text": text]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        do {
            try session.send(data, toPeers: [peerID], with: .reliable)
            let msg = ChatMessage(text: text, isFromSelf: true)
            DispatchQueue.main.async {
                self.messages[peerID, default: []].append(msg)
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
}

// MARK: - MCSessionDelegate

extension MultipeerManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        // 接続状態の変化は今回は使用しない
    }
    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: String],
            payload["type"] == "chat",
            let text = payload["text"]
        else { return }

        let msg = ChatMessage(text: text, isFromSelf: false)
        DispatchQueue.main.async {
            self.messages[peerID, default: []].append(msg)
            self.unreadPeers.insert(peerID)
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
            let peer = PeerInfo(id: peerID, angle: angle, distance: distance, discoveredAt: Date())

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
