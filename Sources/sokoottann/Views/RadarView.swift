import SwiftUI

// MARK: - RadarView

struct RadarView: View {
    let peers: [PeerInfo]
    let isSearching: Bool
    let userName: String

    private let radarSize: CGFloat = 300

    var body: some View {
        ZStack {
            // グリッド（同心円＋十字線）
            RadarGridView(size: radarSize)

            // ピアドット
            ForEach(peers) { peer in
                PeerDotView(peer: peer, radarSize: radarSize)
                    .transition(.scale(scale: 0.1, anchor: .center).combined(with: .opacity))
            }

            // アクティブ時のエフェクト
            if isSearching {
                // パルスリング x3（時間差）
                PulseRingView(radarSize: radarSize, delay: 0.0, color: .cyan)
                PulseRingView(radarSize: radarSize, delay: 0.9, color: .cyan)
                PulseRingView(radarSize: radarSize, delay: 1.8, color: .cyan)

                // スイープライン
                SweepView(radarSize: radarSize)
            }

            // センター（自分）
            CenterAvatarView(userName: userName, isSearching: isSearching)
        }
        .frame(width: radarSize, height: radarSize)
        .animation(.spring(duration: 0.5), value: isSearching)
    }
}

// MARK: - RadarGridView

struct RadarGridView: View {
    let size: CGFloat
    private let accentColor = Color.cyan

    var body: some View {
        ZStack {
            // 背景グロー
            Circle()
                .fill(
                    RadialGradient(
                        colors: [accentColor.opacity(0.06), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: size / 2
                    )
                )
                .frame(width: size, height: size)

            // 同心円
            ForEach([0.28, 0.52, 0.76, 1.0], id: \.self) { scale in
                Circle()
                    .stroke(
                        accentColor.opacity(scale == 1.0 ? 0.35 : 0.18),
                        style: StrokeStyle(
                            lineWidth: scale == 1.0 ? 1.5 : 1,
                            dash: scale == 1.0 ? [] : [6, 4]
                        )
                    )
                    .frame(width: size * scale, height: size * scale)
            }

            // 水平線
            Rectangle()
                .fill(accentColor.opacity(0.14))
                .frame(width: size, height: 1)

            // 垂直線
            Rectangle()
                .fill(accentColor.opacity(0.14))
                .frame(width: 1, height: size)

            // 斜め線
            Rectangle()
                .fill(accentColor.opacity(0.07))
                .frame(width: size, height: 1)
                .rotationEffect(.degrees(45))

            Rectangle()
                .fill(accentColor.opacity(0.07))
                .frame(width: size, height: 1)
                .rotationEffect(.degrees(-45))
        }
    }
}

// MARK: - SweepView

struct SweepView: View {
    let radarSize: CGFloat
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            // スイープトレイル（AngularGradient の扇形）
            // 明るい端が右（270°）、90°のトレイルが後ろに広がる
            Circle()
                .fill(
                    AngularGradient(
                        stops: [
                            .init(color: .cyan.opacity(0.0), location: 0.00),
                            .init(color: .cyan.opacity(0.0), location: 0.68),
                            .init(color: .cyan.opacity(0.15), location: 0.82),
                            .init(color: .cyan.opacity(0.45), location: 1.00)
                        ],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    )
                )
                .frame(width: radarSize, height: radarSize)

            // 明るいエッジライン（右方向）
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [.clear, .cyan.opacity(0.9)],
                        startPoint: .center,
                        endPoint: .trailing
                    )
                )
                .frame(width: radarSize / 2, height: 2)
                .offset(x: radarSize / 4)
                .shadow(color: .cyan.opacity(0.6), radius: 4)
        }
        .rotationEffect(.degrees(rotation))
        .task {
            withAnimation(.linear(duration: 3).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - PulseRingView

struct PulseRingView: View {
    let radarSize: CGFloat
    let delay: Double
    let color: Color

    @State private var scale: CGFloat = 0.08
    @State private var opacity: Double = 0.75

    var body: some View {
        Circle()
            .stroke(color.opacity(opacity), lineWidth: 2)
            .frame(width: radarSize, height: radarSize)
            .scaleEffect(scale)
            .task {
                try? await Task.sleep(for: .seconds(delay))
                withAnimation(.easeOut(duration: 2.8).repeatForever(autoreverses: false)) {
                    scale = 1.0
                    opacity = 0.0
                }
            }
    }
}

// MARK: - CenterAvatarView

struct CenterAvatarView: View {
    let userName: String
    let isSearching: Bool
    @State private var glowPulse: Double = 0.4

    var body: some View {
        ZStack {
            // グローリング（探索中のみ）
            if isSearching {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.cyan.opacity(glowPulse * 0.35), .clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: 40
                        )
                    )
                    .frame(width: 80, height: 80)
                    .task {
                        withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                            glowPulse = 1.0
                        }
                    }
            }

            // ボーダーリング
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.cyan, .white.opacity(0.8), Color(red: 0.8, green: 0.5, blue: 1.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
                .frame(width: 50, height: 50)

            // アバター本体
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.1, green: 0.1, blue: 0.35),
                            Color(red: 0.18, green: 0.08, blue: 0.45)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 46, height: 46)

            // イニシャル
            Text(String(userName.prefix(1)).uppercased())
                .font(.system(size: 20, weight: .black, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

// MARK: - PeerDotView

struct PeerDotView: View {
    let peer: PeerInfo
    let radarSize: CGFloat

    @State private var dotPulse: Bool = false

    private var offsetX: CGFloat { cos(peer.radarAngle) * (radarSize / 2 * peer.radarDistanceFraction) }
    private var offsetY: CGFloat { sin(peer.radarAngle) * (radarSize / 2 * peer.radarDistanceFraction) }

    var body: some View {
        ZStack(alignment: .center) {
            // 外側グロー
            Circle()
                .fill(Color.green.opacity(dotPulse ? 0.20 : 0.08))
                .frame(width: 42, height: 42)
                .blur(radius: 6)
                .animation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: dotPulse)

            // ドット本体
            Circle()
                .fill(
                    RadialGradient(
                        colors: [.white, Color(red: 0.3, green: 1.0, blue: 0.5)],
                        center: .center,
                        startRadius: 0,
                        endRadius: 7
                    )
                )
                .frame(width: 13, height: 13)
                .shadow(color: .green, radius: 7)

            // 名前ラベル（ドットの上）
            VStack(spacing: 2) {
                Text(peer.displayName)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                HStack(spacing: 3) {
                    Text(peer.directionArrow)
                        .font(.system(size: 9))
                    Text("\(peer.directionLabel) \(peer.distanceLabel)")
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(Color(red: 0.5, green: 1.0, blue: 0.7))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(Color.black.opacity(0.72))
                    .overlay(Capsule().stroke(Color.green.opacity(0.45), lineWidth: 1))
            )
            .offset(y: -30)
        }
        .offset(x: offsetX, y: offsetY)
        .onAppear { dotPulse = true }
    }
}
