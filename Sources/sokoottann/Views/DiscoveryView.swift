import SwiftUI
import MultipeerConnectivity

struct DiscoveryView: View {
    let userName: String

    @StateObject private var manager: MultipeerManager
    @State private var showPeerList = false
    @State private var newPeerBurst = false
    @State private var chatPeer: PeerInfo? = nil

    init(userName: String) {
        self.userName = userName
        _manager = StateObject(wrappedValue: MultipeerManager(displayName: userName))
    }

    var body: some View {
        ZStack {
            // ── 背景 ──────────────────────────────────────────
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.04, blue: 0.15),
                    Color(red: 0.06, green: 0.02, blue: 0.20)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            StarFieldView()

            // ── メインコンテンツ ──────────────────────────────
            VStack(spacing: 0) {
                headerView
                    .padding(.top, 8)

                Spacer()

                RadarView(
                    peers: manager.discoveredPeers,
                    isSearching: manager.isSearching,
                    userName: userName
                )

                Spacer()

                VStack(spacing: 16) {
                    peerCountBadge
                    searchToggleButton
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 44)
            }

            // ── ピアリストオーバーレイ ─────────────────────────
            if showPeerList && !manager.discoveredPeers.isEmpty {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation(.spring(duration: 0.4)) { showPeerList = false }
                    }

                VStack {
                    Spacer()
                    PeerListView(
                        peers: manager.discoveredPeers,
                        unreadPeers: manager.unreadPeers,
                        isShowing: $showPeerList
                    ) { peer in
                        withAnimation(.spring(duration: 0.4)) { showPeerList = false }
                        chatPeer = peer
                    }
                }
                .ignoresSafeArea(edges: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $chatPeer) { peer in
            ChatView(peer: peer, manager: manager)
        }
        .onChange(of: manager.discoveredPeers.count) { oldCount, newCount in
            guard newCount > oldCount else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.spring(duration: 0.3, bounce: 0.5)) { newPeerBurst = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation { newPeerBurst = false }
            }
        }
        .animation(.spring(duration: 0.4), value: showPeerList)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("そこいた！")
                    .font(.system(size: 26, weight: .black, design: .rounded))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.cyan, .white],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                Text("@\(userName)")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer()

            statusBadge
        }
        .padding(.horizontal, 24)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(manager.isSearching ? Color.green : .gray)
                .frame(width: 7, height: 7)
                .shadow(color: manager.isSearching ? .green : .clear, radius: 5)

            Text(manager.isSearching ? "探索中" : "待機中")
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Capsule()
                .fill(.white.opacity(0.07))
                .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
        )
    }

    // MARK: - Peer Count Badge

    private var peerCountBadge: some View {
        Button {
            guard !manager.discoveredPeers.isEmpty else { return }
            withAnimation(.spring(duration: 0.4)) { showPeerList.toggle() }
        } label: {
            HStack(spacing: 16) {
                // カウント
                VStack(spacing: 2) {
                    Text("\(manager.discoveredPeers.count)")
                        .font(.system(size: 40, weight: .black, design: .rounded))
                        .foregroundStyle(
                            manager.discoveredPeers.isEmpty
                                ? LinearGradient(colors: [.gray], startPoint: .leading, endPoint: .trailing)
                                : LinearGradient(
                                    colors: [.cyan, Color(red: 0.3, green: 1.0, blue: 0.6)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                        )
                        .shadow(color: manager.discoveredPeers.isEmpty ? .clear : .cyan.opacity(0.5), radius: 10)
                        .scaleEffect(newPeerBurst ? 1.35 : 1.0)
                        .animation(.spring(duration: 0.3, bounce: 0.5), value: newPeerBurst)

                    Text("人を発見")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()

                // アイコン
                if !manager.discoveredPeers.isEmpty {
                    HStack(spacing: -8) {
                        ForEach(manager.discoveredPeers.prefix(3)) { peer in
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [.cyan.opacity(0.6), .purple.opacity(0.6)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Text(String(peer.displayName.prefix(1)).uppercased())
                                        .font(.system(size: 13, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                )
                                .overlay(Circle().stroke(.black.opacity(0.3), lineWidth: 1.5))
                        }
                    }

                    Image(systemName: "chevron.up")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.cyan.opacity(0.7))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(
                                manager.discoveredPeers.isEmpty
                                    ? Color.white.opacity(0.1)
                                    : Color.cyan.opacity(0.35),
                                lineWidth: 1.5
                            )
                    )
            )
        }
        .disabled(manager.discoveredPeers.isEmpty)
        .buttonStyle(.plain)
    }

    // MARK: - Search Toggle Button

    private var searchToggleButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            if manager.isSearching {
                manager.stopSearching()
                withAnimation(.spring(duration: 0.4)) { showPeerList = false }
            } else {
                manager.startSearching()
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: manager.isSearching
                      ? "stop.circle.fill"
                      : "antenna.radiowaves.left.and.right")
                    .font(.system(size: 22, weight: .semibold))

                Text(manager.isSearching ? "探索を停止" : "探索を開始")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
            }
            .foregroundStyle(manager.isSearching ? .white : .black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(
                        manager.isSearching
                            ? LinearGradient(
                                colors: [
                                    Color(red: 0.85, green: 0.1, blue: 0.3),
                                    Color(red: 0.6, green: 0.0, blue: 0.45)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            : LinearGradient(
                                colors: [.cyan, Color(red: 0.3, green: 0.88, blue: 1.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                    )
            )
            .shadow(
                color: manager.isSearching ? Color.red.opacity(0.4) : Color.cyan.opacity(0.5),
                radius: 22,
                y: 8
            )
        }
        .animation(.spring(duration: 0.45), value: manager.isSearching)
    }
}

// MARK: - PeerListView

struct PeerListView: View {
    let peers: [PeerInfo]
    let unreadPeers: Set<MCPeerID>
    @Binding var isShowing: Bool
    var onMessage: (PeerInfo) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // ハンドルバー
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 38, height: 4)
                .padding(.top, 14)
                .padding(.bottom, 18)

            HStack {
                Label("近くにいる人たち", systemImage: "person.2.fill")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                Button {
                    withAnimation(.spring(duration: 0.4)) { isShowing = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(peers) { peer in
                        PeerRowView(
                            peer: peer,
                            hasUnread: unreadPeers.contains(peer.id)
                        ) {
                            onMessage(peer)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 30)
            }
        }
        .frame(maxHeight: 420)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.08, green: 0.07, blue: 0.24),
                            Color(red: 0.05, green: 0.04, blue: 0.18)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 32, style: .continuous)
                        .stroke(Color.cyan.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - PeerRowView

struct PeerRowView: View {
    let peer: PeerInfo
    let hasUnread: Bool
    var onMessage: () -> Void
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 14) {
            // アバター
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.cyan.opacity(0.25), .purple.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)

                Text(String(peer.displayName.prefix(1)).uppercased())
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
            .overlay(Circle().stroke(Color.cyan.opacity(0.4), lineWidth: 1))

            VStack(alignment: .leading, spacing: 4) {
                Text(peer.displayName)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)

                HStack(spacing: 8) {
                    // 方向
                    HStack(spacing: 3) {
                        Text(peer.directionArrow)
                            .font(.system(size: 11))
                        Text(peer.directionLabel)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(Color.cyan.opacity(0.8))

                    Text("·")
                        .foregroundStyle(.white.opacity(0.3))

                    // 距離
                    HStack(spacing: 3) {
                        Image(systemName: "location.fill")
                            .font(.system(size: 9))
                        Text(peer.distanceLabel)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                    }
                    .foregroundStyle(Color(red: 0.4, green: 1.0, blue: 0.6))
                }
            }

            Spacer()

            // メッセージボタン
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onMessage()
            } label: {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bubble.left.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.cyan.opacity(0.7))

                    if hasUnread {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                            .offset(x: 3, y: -2)
                    }
                }
                .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            hasUnread ? Color.cyan.opacity(0.4) : Color.cyan.opacity(0.12),
                            lineWidth: hasUnread ? 1.5 : 1
                        )
                )
        )
        .scaleEffect(appeared ? 1 : 0.85)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.spring(duration: 0.5, bounce: 0.35)) { appeared = true }
        }
    }
}
