import Foundation
import MultipeerConnectivity
import NearbyInteraction
import CoreBluetooth
import UserNotifications

/// ピア発見・通信・UWB 計測を統合したマネージャー。
///
/// 発見レイヤーを二重化して確実性を高める:
///   ① MultipeerConnectivity — WiFi Direct + BLE を OS が自動選択
///   ② CoreBluetooth BLE     — MPC が失敗・遅延したときの補完
///
/// invite 競合は起動時に生成した sessionID (UUID) の辞書順で一方だけが送る。
/// 同名ユーザーでも安全に動作する。
final class UWBManager: NSObject, ObservableObject {

    // MARK: - Service identifiers
    private static let mpcServiceType = "sokoita"
    /// CB 発見専用の UUID（BLE 広告に乗せるだけ。GATT サービスは持たない）
    private static let cbServiceUUID  = CBUUID(string: "A9C2E1D8-4F3B-41A7-8E0C-5B2D7F9E3C1A")

    // MARK: - Published
    @Published var discoveredPeers:  [PeerInfo]              = []
    @Published var isSearching:      Bool                    = false
    @Published var connectedPeerIDs: Set<String>             = []
    @Published var messages:         [String: [ChatMessage]] = [:]
    @Published var unreadPeers:      Set<String>             = []
    /// デバッグ用 NI ログ（画面表示用、直近 8 件）
    @Published var niLog:            [String]                = []

    /// このデバイスが UWB 精密距離測定をサポートしているか
    let uwbSupported: Bool = NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    /// このデバイスが UWB 方向測定をサポートしているか（U2 チップ = iPhone 14 以上）
    let uwbDirectionSupported: Bool = NISession.deviceCapabilities.supportsDirectionMeasurement

    // MARK: - MPC
    private let myPeerID:  MCPeerID
    /// 起動ごとに生成する UUID。invite の tie-break に使う。
    private let sessionID = UUID().uuidString
    private var session:   MCSession!
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser:    MCNearbyServiceBrowser?
    /// browser が発見したが未接続のピア。定期再 invite に使う。
    private var pendingPeers: [MCPeerID: String] = [:]  // MCPeerID → 相手の sessionID

    // MARK: - CB（補完 BLE 発見）
    private var cbCentral:    CBCentralManager?
    private var cbPeripheral: CBPeripheralManager?
    /// CB スキャンで発見した displayName のセット
    private var cbFoundNames: Set<String> = []

    // MARK: - NI (UWB)
    private var niSessions:      [String: NISession] = [:]
    private var niSessionToPeer: [NISession: String] = [:]

    // MARK: - Heading
    private var myCurrentHeading:   Double? = nil
    private var myLastSentHeading:  Double  = -999
    private static let headingThresholdDeg: Double = 5.0

    // MARK: - Timers
    private var headingTimer: Timer?
    private var retryTimer:   Timer?

    // MARK: - Init

    init(displayName: String) {
        self.myPeerID = MCPeerID(displayName: displayName)
        super.init()
        buildSession()
    }

    private func buildSession() {
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .optional)
        session.delegate = self
    }

    // MARK: - Public API

    func startSearching() {
        guard !isSearching else { return }
        isSearching = true

        // ── MPC ──────────────────────────────────────────
        // sessionID を discoveryInfo に載せて invite 競合を UUID 辞書順で解決する
        advertiser = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: ["sid": sessionID],
            serviceType: Self.mpcServiceType)
        advertiser?.delegate = self
        advertiser?.startAdvertisingPeer()

        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: Self.mpcServiceType)
        browser?.delegate = self
        browser?.startBrowsingForPeers()

        // ── CB（補完 BLE 発見）─────────────────────────────
        cbCentral    = CBCentralManager(delegate: self, queue: .main)
        cbPeripheral = CBPeripheralManager(delegate: self, queue: .main)

        // ── タイマー ──────────────────────────────────────
        // 5 秒ごとに未接続ピアへ再 invite（初回 invite が競合で失敗しても救済）
        retryTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.retryPendingInvites()
        }
        headingTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.broadcastHeading(force: true)
        }
    }

    func stopSearching() {
        isSearching = false
        retryTimer?.invalidate();   retryTimer   = nil
        headingTimer?.invalidate(); headingTimer = nil
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers();   browser   = nil
        cbCentral?.stopScan();    cbCentral    = nil
        cbPeripheral?.stopAdvertising(); cbPeripheral = nil
        session.disconnect()
        niSessions.values.forEach { $0.invalidate() }
        niSessions.removeAll(); niSessionToPeer.removeAll()
        connectedPeerIDs.removeAll(); discoveredPeers.removeAll()
        pendingPeers.removeAll(); cbFoundNames.removeAll()
        myCurrentHeading = nil; myLastSentHeading = -999
        buildSession()
    }

    func updateMyHeading(_ deg: Double) {
        myCurrentHeading = deg
        if myLastSentHeading == -999 {
            broadcastHeading(force: true)
        } else {
            var diff = abs(deg - myLastSentHeading)
            if diff > 180 { diff = 360 - diff }
            if diff >= Self.headingThresholdDeg { broadcastHeading(force: false) }
        }
    }

    @discardableResult
    func sendMessage(_ text: String, to peerName: String) -> Bool {
        let targets = session.connectedPeers.filter { $0.displayName == peerName }
        if targets.isEmpty {
            messages[peerName, default: []].append(
                ChatMessage(text: text, isFromSelf: true, isPending: true))
            return false
        }
        let ok = sendPacket(Packet(kind: .chat, sender: myPeerID.displayName, text: text),
                            to: targets)
        if ok { messages[peerName, default: []].append(ChatMessage(text: text, isFromSelf: true)) }
        return ok
    }

    func markAsRead(peerID: String) { unreadPeers.remove(peerID) }

    // MARK: - Private – invite logic

    /// MPC browser が発見したピアに invite を送るか判定する。
    /// sessionID (UUID) の辞書順が「小さい方」が invite を送る。
    /// → 同名ユーザー・同時起動でも必ず一方だけが invite する。
    private func shouldInvite(theirSID: String) -> Bool {
        // 相手の SID が不明（古いバージョン等）なら自分が invite する
        if theirSID.isEmpty { return true }
        return sessionID < theirSID
    }

    private func inviteIfNeeded(_ peerID: MCPeerID) {
        guard let browser else { return }
        guard !session.connectedPeers.contains(peerID) else { return }
        let theirSID = pendingPeers[peerID] ?? ""
        if shouldInvite(theirSID: theirSID) {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
        }
    }

    private func retryPendingInvites() {
        for peerID in pendingPeers.keys { inviteIfNeeded(peerID) }
    }

    // MARK: - Private – heading

    private func broadcastHeading(force: Bool) {
        guard let deg = myCurrentHeading else { return }
        myLastSentHeading = deg
        let peers = session.connectedPeers
        guard !peers.isEmpty else { return }
        sendPacket(Packet(kind: .heading, sender: myPeerID.displayName, headingDeg: deg), to: peers)
    }

    // MARK: - Private – data transfer

    @discardableResult
    private func sendPacket(_ packet: Packet, to peers: [MCPeerID]) -> Bool {
        guard !peers.isEmpty, let data = try? JSONEncoder().encode(packet) else { return false }
        do {
            try session.send(data, toPeers: peers, with: .reliable)
            return true
        } catch {
            print("⚠️ MCSession send error: \(error)")
            return false
        }
    }

    private func handle(_ data: Data, from peerID: MCPeerID) {
        guard let packet = try? JSONDecoder().decode(Packet.self, from: data) else { return }
        let name = peerID.displayName
        switch packet.kind {
        case .chat:
            guard let text = packet.text else { return }
            DispatchQueue.main.async { [weak self] in
                self?.messages[name, default: []].append(ChatMessage(text: text, isFromSelf: false))
                self?.unreadPeers.insert(name)
                self?.postNotification(from: name, text: text)
            }
        case .niToken:
            guard let tokenData = packet.niToken else { return }
            receiveNIToken(tokenData, from: peerID)
        case .heading:
            guard let deg = packet.headingDeg else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let i = self.discoveredPeers.firstIndex(where: { $0.id == name })
                else { return }
                self.discoveredPeers[i].peerHeading = deg
            }
        case .remoteBearing:
            guard let bearing = packet.headingDeg else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let i = self.discoveredPeers.firstIndex(where: { $0.id == name })
                else { return }
                self.discoveredPeers[i].remoteBearing = bearing
                self.discoveredPeers[i].remoteBearingReceivedAt = Date()
                self.niAppend("📨 remoteBearing from \(name): \(String(format: "%.1f°", bearing))")
            }
        }
    }

    // MARK: - Private – NI debug log

    private func niAppend(_ msg: String) {
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(ts)] \(msg)"
        print("🔵 NI \(line)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.niLog.append(line)
            if self.niLog.count > 10 { self.niLog.removeFirst() }
        }
    }

    // MARK: - Private – NI (UWB)

    private func startNISession(with peerID: MCPeerID) {
        niAppend("startNISession: \(peerID.displayName), dist=\(NISession.deviceCapabilities.supportsPreciseDistanceMeasurement) dir=\(NISession.deviceCapabilities.supportsDirectionMeasurement)")
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement else {
            niAppend("❌ UWB 非対応のため中断")
            return
        }
        let name = peerID.displayName
        if niSessions[name] != nil {
            niAppend("startNISession: \(name) は既存セッションあり（スキップ）")
            return
        }
        let ni = NISession()
        ni.delegate = self
        niSessions[name] = ni
        niSessionToPeer[ni] = name
        guard let token = ni.discoveryToken,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token,
                                                            requiringSecureCoding: true)
        else {
            niAppend("❌ トークン取得失敗")
            return
        }
        niAppend("✅ トークン送信 → \(name)")
        sendPacket(Packet(kind: .niToken, sender: myPeerID.displayName, niToken: data), to: [peerID])
    }

    private func receiveNIToken(_ tokenData: Data, from peerID: MCPeerID) {
        niAppend("receiveNIToken from \(peerID.displayName)")
        guard NISession.deviceCapabilities.supportsPreciseDistanceMeasurement,
              let token = try? NSKeyedUnarchiver.unarchivedObject(
                  ofClass: NIDiscoveryToken.self, from: tokenData)
        else {
            niAppend("❌ receiveNIToken: デコード失敗 or UWB非対応")
            return
        }

        // NISession はメインスレッドで作成・操作しないとデリゲートが呼ばれない
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let name = peerID.displayName

            if self.niSessions[name] == nil {
                let ni = NISession()
                ni.delegate = self
                self.niSessions[name] = ni
                self.niSessionToPeer[ni] = name
                // 自分のトークンを返送
                if let myToken = ni.discoveryToken,
                   let myData = try? NSKeyedArchiver.archivedData(withRootObject: myToken,
                                                                   requiringSecureCoding: true) {
                    self.niAppend("✅ トークン返送 → \(name)")
                    self.sendPacket(
                        Packet(kind: .niToken, sender: self.myPeerID.displayName, niToken: myData),
                        to: [peerID])
                } else {
                    self.niAppend("❌ 返送用トークン取得失敗")
                }
            }

            guard let ni = self.niSessions[name] else { return }
            self.niAppend("▶️ ni.run() 開始: \(name)")
            let config = NINearbyPeerConfiguration(peerToken: token)
            ni.run(config)
        }
    }

    private func tearDownNI(for name: String) {
        if let ni = niSessions[name] {
            ni.invalidate()
            niSessionToPeer.removeValue(forKey: ni)
        }
        niSessions.removeValue(forKey: name)
    }

    // MARK: - Private – notification

    private func postNotification(from sender: String, text: String) {
        let c = UNMutableNotificationContent()
        c.title = sender; c.body = text; c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { _ in }
    }

    // MARK: - Packet model

    private struct Packet: Codable {
        enum Kind: String, Codable { case chat, niToken = "ni_token", heading, remoteBearing = "remote_bearing" }
        let kind:       Kind
        let sender:     String
        var text:       String?
        var niToken:    Data?
        var headingDeg: Double?
    }
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension UWBManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // 既接続なら断る。未接続なら常に受け入れる。
        invitationHandler(!session.connectedPeers.contains(peerID), session)
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didNotStartAdvertisingPeer error: Error) {
        print("⚠️ MPC Advertiser error: \(error)")
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension UWBManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser,
                 foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        guard peerID != myPeerID else { return }
        let theirSID = info?["sid"] ?? ""
        pendingPeers[peerID] = theirSID
        inviteIfNeeded(peerID)
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        // セッションが切断されていなければ保留リストも維持する
        if !session.connectedPeers.contains(peerID) {
            pendingPeers.removeValue(forKey: peerID)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser,
                 didNotStartBrowsingForPeers error: Error) {
        print("⚠️ MPC Browser error: \(error)")
    }
}

// MARK: - MCSessionDelegate

extension UWBManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let name = peerID.displayName
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                self.pendingPeers.removeValue(forKey: peerID)
                self.connectedPeerIDs.insert(name)
                if !self.discoveredPeers.contains(where: { $0.id == name }) {
                    self.discoveredPeers.append(PeerInfo(
                        id: name,
                        discoveredAt: Date(),
                        fallbackAngle: Double.random(in: 0 ..< .pi * 2),
                        fallbackDistance: CGFloat.random(in: 0.2 ... 0.7)
                    ))
                }
                if let deg = self.myCurrentHeading {
                    self.sendPacket(
                        Packet(kind: .heading, sender: self.myPeerID.displayName, headingDeg: deg),
                        to: [peerID])
                }
                self.startNISession(with: peerID)

            case .notConnected:
                self.connectedPeerIDs.remove(name)
                self.discoveredPeers.removeAll { $0.id == name }
                self.tearDownNI(for: name)

            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        handle(data, from: peerID)
    }
    func session(_ session: MCSession, didReceive stream: InputStream,
                 withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - CBCentralManagerDelegate（補完 BLE 発見）

extension UWBManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        // ローカルに広告している同アプリ端末をスキャン
        central.scanForPeripherals(withServices: [Self.cbServiceUUID],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        // 広告の LocalName = 相手の displayName
        guard let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String,
              !name.isEmpty, name != myPeerID.displayName else { return }

        cbFoundNames.insert(name)

        // MPC で既に発見済みなら追加 invite 不要
        // pendingPeers に同名 MCPeerID があれば即 invite
        if let peerID = pendingPeers.keys.first(where: { $0.displayName == name }) {
            inviteIfNeeded(peerID)
        }
    }
}

// MARK: - CBPeripheralManagerDelegate（補完 BLE 広告）

extension UWBManager: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        // サービス UUID + LocalName（= displayName）を BLE 広告に乗せる
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [Self.cbServiceUUID],
            CBAdvertisementDataLocalNameKey:    myPeerID.displayName
        ])
    }
}

// MARK: - NISessionDelegate

extension UWBManager: NISessionDelegate {
    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let name = niSessionToPeer[session] else { return }
        for obj in nearbyObjects {
            let distStr = obj.distance.map { String(format: "%.2fm", $0) } ?? "nil"
            let dirStr  = obj.direction.map { String(format: "(%.2f,%.2f,%.2f)", $0.x, $0.y, $0.z) } ?? "nil"
            niAppend("📡 didUpdate \(name): dist=\(distStr) dir=\(dirStr)")
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let i = self.discoveredPeers.firstIndex(where: { $0.id == name })
                else { return }
                self.discoveredPeers[i].niDistance = obj.distance
                if let dir = obj.direction {
                    self.discoveredPeers[i].niDirection        = dir
                    self.discoveredPeers[i].niDirectionCached  = dir
                    self.discoveredPeers[i].niDirectionCachedAt = Date()
                    // U2チップで方向が取れた場合、絶対方位を計算して相手に送信
                    // 相手が U1チップ (iPhone 14 非Pro等) でも矢印を表示できるようにする
                    if let myHeading = self.myCurrentHeading,
                       let peer = self.session.connectedPeers.first(where: { $0.displayName == name }) {
                        let relAngle = Double(atan2(dir.x, -dir.z)) * 180 / .pi
                        let absBearing = (myHeading + relAngle).truncatingRemainder(dividingBy: 360)
                        let normalized = absBearing < 0 ? absBearing + 360 : absBearing
                        self.sendPacket(
                            Packet(kind: .remoteBearing, sender: self.myPeerID.displayName, headingDeg: normalized),
                            to: [peer])
                    }
                } else {
                    // FOV 外: nil にするが、キャッシュは残す
                    self.discoveredPeers[i].niDirection = nil
                }
            }
        }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        niAppend("❌ didInvalidate: \(error.localizedDescription)")
    }

    func sessionWasSuspended(_ session: NISession) {}

    func sessionSuspensionEnded(_ session: NISession) {
        guard let name = niSessionToPeer[session] else { return }
        niSessionToPeer.removeValue(forKey: session)
        niSessions.removeValue(forKey: name)
        if let peerID = self.session.connectedPeers.first(where: { $0.displayName == name }) {
            startNISession(with: peerID)
        }
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject],
                 reason: NINearbyObject.RemovalReason) {
        guard let name = niSessionToPeer[session] else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let i = self.discoveredPeers.firstIndex(where: { $0.id == name })
            else { return }
            self.discoveredPeers[i].niDistance  = nil
            self.discoveredPeers[i].niDirection = nil
        }
    }
}
