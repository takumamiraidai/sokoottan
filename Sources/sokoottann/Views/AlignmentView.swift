import SwiftUI

/// 「出逢い」ナビゲーション画面
///
/// 3フェーズで構成される:
///   Phase 1 (orient)  : コンパスで相手の方向を向く
///   Phase 2 (walking) : その方向に歩く。距離ゲージ＋「会えた！」ボタン
///   Phase 3 (met)     : UWB/RSSI ≤ 3m で自動、または手動ボタンで確定
struct AlignmentView: View {
    let peer: PeerInfo
    @ObservedObject var manager: UWBManager
    @ObservedObject var headingManager: HeadingManager
    @Environment(\.dismiss) private var dismiss

    // MARK: - Phase

    private enum MeetPhase { case orient, walking, met }
    @State private var phase: MeetPhase = .orient

    // MARK: - Constants

    private static let threshold:      Double = 12.0
    private static let confirmSeconds: Double = 3.0
    private static let meetDistance:   Float  = 3.0

    // MARK: - State

    @StateObject private var walkEstimator = WalkingBearingEstimator()

    @State private var alignedSince:       Date?   = nil
    @State private var alignProgress:      Double  = 0.0
    @State private var arrowGlow:          Bool    = false
    @State private var ringScale:          CGFloat = 1.0
    @State private var successBurst:       Bool    = false
    @State private var cumulativeArrowDeg: Double  = 0
    @State private var lastRawDiff:        Double? = nil

    // MARK: - Computed

    private var livePeer: PeerInfo {
        manager.discoveredPeers.first(where: { $0.id == peer.id }) ?? peer
    }

    /// UWB 距離測定が実際に動作中か（iPhone 11+）
    private var uwbDistanceActive: Bool { livePeer.niDistance != nil }
    /// 歩き回り測位 or remoteBearing による方位推定が有効か
    private var uwbDirectionActive: Bool { angleDiff != nil }
    /// UWB が何らかの形で動作中か（距離 or 方向）
    private var uwbActive: Bool { uwbDistanceActive || uwbDirectionActive }
    /// リアルタイム UWB dir（現在は常に false: dir を使わない方針）
    private var uwbDirectionLive: Bool { false }
    /// 相手が送ってきた remoteBearing が有効か（5秒以内）
    private var remoteBearingActive: Bool {
        guard let at = livePeer.remoteBearingReceivedAt else { return false }
        return Date().timeIntervalSince(at) < 5.0
    }
    /// 歩き回り測位が完了しているか
    private var walkBearingReady: Bool { walkEstimator.estimatedBearing != nil }

    /// 水平角（端末正面=0°, 右が正）。
    /// 優先順: 歩き回り測位 → remoteBearing → nil
    private var angleDiff: Double? {
        // 1. 歩き回り三点測位（最優先）
        if let bearing = walkEstimator.estimatedBearing {
            return relativeBearing(absolute: bearing)
        }
        // 2. 相手デバイスからの remoteBearing
        if remoteBearingActive, let bearing = livePeer.remoteBearing {
            return relativeBearing(absolute: bearing)
        }
        return nil
    }

    /// 絶対方位（北=0°, 時計回り）を自分の向き基準の相対角に変換（-180〜180）
    private func relativeBearing(absolute: Double) -> Double {
        var rel = absolute - headingManager.heading
        rel = rel.truncatingRemainder(dividingBy: 360)
        if rel > 180 { rel -= 360 }
        if rel < -180 { rel += 360 }
        return rel
    }

    private var alignmentColor: Color {
        guard let diff = angleDiff else { return .gray }
        let a = abs(diff)
        if a <= Self.threshold { return Color(red: 0.2, green: 1.0, blue: 0.4) }
        if a <= 30             { return Color(red: 0.6, green: 1.0, blue: 0.2) }
        if a <= 60             { return .yellow }
        if a <= 90             { return .orange }
        return Color(red: 1.0, green: 0.3, blue: 0.2)
    }

    private var bestDistance: Float? {
        livePeer.niDistance ?? livePeer.rssiDistance
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.04, blue: 0.14),
                    Color(red: 0.06, green: 0.02, blue: 0.20)
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar.padding(.top, 8)
                Spacer()
                switch phase {
                case .orient:  orientSection
                case .walking: walkingSection
                case .met:     metSection
                }
                Spacer()
                bottomSection.padding(.bottom, 48)
            }


        }
        .onChange(of: alignedSince) { _, since in
            _ = since
        }
        .onChange(of: angleDiff) { _, newDiff in
            checkAlignment(diff: newDiff)
            updateCumulativeAngle()
        }
        .onChange(of: headingManager.heading) { _, _ in
            updateCumulativeAngle()
            if let since = alignedSince, phase == .orient {
                let elapsed = Date().timeIntervalSince(since)
                alignProgress = min(elapsed / Self.confirmSeconds, 1.0)
                if elapsed >= Self.confirmSeconds { triggerWalking() }
            }
        }
        .onChange(of: livePeer.niDistance) { _, dist in
            checkProximity(dist)
        }
        .onChange(of: livePeer.rssiDistance) { _, dist in
            if livePeer.niDistance == nil { checkProximity(dist) }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) {
                arrowGlow = true
            }
            // 歩き回り推定子のセットアップ
            walkEstimator.getHeading  = { [self] in headingManager.heading }
            walkEstimator.getDistance = { [self] in livePeer.niDistance.map { Double($0) } }
            walkEstimator.start()
            if let diff = angleDiff {
                cumulativeArrowDeg = diff
                lastRawDiff = diff
            }
        }
        .onDisappear {
            walkEstimator.stop()
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button { dismiss() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold))
                    Text("戻る").font(.system(size: 15, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.6))
            }
            Spacer()
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: [.cyan.opacity(0.3), .purple.opacity(0.35)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                        .frame(width: 34, height: 34)
                    Text(String(peer.displayName.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
                Text(peer.displayName)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            Spacer()
            // UWB ステータスバッジ
            uwbStatusBadge
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var uwbStatusBadge: some View {
        Group {
            if walkBearingReady {
                Label("歩き回り測位 ✅", systemImage: "figure.walk")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.cyan)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.cyan.opacity(0.18)))
            } else if uwbDistanceActive {
                Label("\(walkEstimator.sampleCount)/\(WalkingBearingEstimator.recommendedSamples) 地点", systemImage: "figure.walk")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(red: 0.2, green: 0.9, blue: 0.6))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color(red: 0.2, green: 0.9, blue: 0.6).opacity(0.15)))
            } else if manager.uwbSupported {
                Label("UWB 待機", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange.opacity(0.8))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.orange.opacity(0.12)))
            } else {
                Label("UWB 非対応", systemImage: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.25))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(0.06)))
            }
        }
    }

    // MARK: - Phase 1: Orient

    private var orientSection: some View {
        VStack(spacing: 28) {
            orientTitleLabel

            ZStack {
                Circle().stroke(alignmentColor.opacity(0.35), lineWidth: 3)
                    .frame(width: 280, height: 280).scaleEffect(ringScale)
                Circle().fill(alignmentColor.opacity(0.06))
                    .frame(width: 280, height: 280).blur(radius: 12)
                compassTicks
                if uwbDirectionActive {
                    // 方向推定完了 — 矢印を表示
                    arrowShape
                        .opacity(1.0)
                        .rotationEffect(.degrees(cumulativeArrowDeg))
                        .animation(.interpolatingSpring(stiffness: 80, damping: 14), value: cumulativeArrowDeg)
                } else if walkEstimator.isActive {
                    // 歩き回り測位中 — 歩き回り待ちアイコン
                    VStack(spacing: 6) {
                        Image(systemName: "figure.walk")
                            .font(.system(size: 44, weight: .ultraLight))
                            .foregroundStyle(.cyan.opacity(0.5))
                        // サンプル数のドット表示
                        HStack(spacing: 6) {
                            ForEach(0..<WalkingBearingEstimator.recommendedSamples, id: \.self) { i in
                                Circle()
                                    .fill(i < walkEstimator.sampleCount ? Color.cyan : Color.white.opacity(0.2))
                                    .frame(width: 8, height: 8)
                            }
                        }
                    }
                } else {
                    // 歩行センサー非対応
                    Image(systemName: "questionmark")
                        .font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.15))
                }
                if let diff = angleDiff {
                    VStack(spacing: 2) {
                        Spacer().frame(height: 170)
                        Text("\(Int(abs(diff).rounded()))°")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(alignmentColor.opacity(0.9))
                            .monospacedDigit()
                    }
                }
            }
            .frame(width: 280, height: 280)

            if uwbDirectionActive {
                // 方向推定完了 — 3秒キープバー
                if let since = alignedSince {
                    TimelineView(.animation) { _ in
                        let elapsed  = Date().timeIntervalSince(since)
                        let progress = min(elapsed / Self.confirmSeconds, 1.0)
                        VStack(spacing: 6) {
                            Text("そのまま保持してください…")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.4).opacity(0.9))
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Color.white.opacity(0.1))
                                    Capsule()
                                        .fill(LinearGradient(
                                            colors: [Color(red: 0.2, green: 1.0, blue: 0.4),
                                                     Color(red: 0.0, green: 0.85, blue: 0.6)],
                                            startPoint: .leading, endPoint: .trailing
                                        ))
                                        .frame(width: geo.size.width * progress)
                                }
                            }
                            .frame(height: 6).padding(.horizontal, 40)
                        }
                        .onChange(of: progress >= 1.0) { _, full in
                            if full { triggerWalking() }
                        }
                    }
                    .transition(.opacity)
                } else {
                    // 方向は分かっているが閾値外 — 向くよう促す
                    Text("矢印の方向に体を向けてください")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.55))
                }
            } else {
                // UWB 接続待ち・サンプル収集中 — 常に歩き方ガイドを表示
                walkScanPrompt
            }
        }
    }

    // MARK: - Phase 2: Walking

    private var walkingSection: some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("この方向に向かって歩いてください")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Text("近づくと自動で検知します（3m 以内）")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .multilineTextAlignment(.center).padding(.horizontal, 24)

            // 小コンパス矢印
            ZStack {
                Circle().stroke(alignmentColor.opacity(0.3), lineWidth: 2).frame(width: 160, height: 160)
                Circle().fill(alignmentColor.opacity(0.05)).frame(width: 160, height: 160)
                if uwbActive {
                    arrowShape
                        .scaleEffect(0.55)
                        .rotationEffect(.degrees(cumulativeArrowDeg))
                        .animation(.interpolatingSpring(stiffness: 80, damping: 14), value: cumulativeArrowDeg)
                } else {
                    Image(systemName: "questionmark")
                        .font(.system(size: 36, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.15))
                }
            }
            .frame(width: 160, height: 160)

            // 距離ゲージ
            VStack(spacing: 10) {
                Text("距離")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                Text(livePeer.distanceLabel)
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundStyle(.white).monospacedDigit()
                if let d = bestDistance {
                    let fraction = CGFloat(max(0.02, min(1.0, 1.0 - Double(d) / 20.0)))
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.1))
                            Capsule()
                                .fill(LinearGradient(
                                    colors: [.cyan, Color(red: 0.2, green: 1.0, blue: 0.4)],
                                    startPoint: .leading, endPoint: .trailing
                                ))
                                .frame(width: geo.size.width * fraction)
                                .animation(.easeOut(duration: 0.4), value: fraction)
                        }
                    }
                    .frame(height: 8).padding(.horizontal, 8)
                }
            }
            .padding(.vertical, 16).padding(.horizontal, 20)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06)))
            .padding(.horizontal, 28)

            // 手動「会えた！」ボタン
            Button { triggerMet() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "person.2.fill").font(.system(size: 18, weight: .semibold))
                    Text("会えた！").font(.system(size: 18, weight: .black, design: .rounded))
                }
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(LinearGradient(
                            colors: [Color(red: 0.2, green: 1.0, blue: 0.4),
                                     Color(red: 0.0, green: 0.85, blue: 0.6)],
                            startPoint: .leading, endPoint: .trailing
                        ))
                )
                .shadow(color: Color.green.opacity(0.5), radius: 16, y: 6)
            }
            .padding(.horizontal, 28)
        }
    }

    // MARK: - Phase 3: Met

    private var metSection: some View {
        VStack(spacing: 32) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.2, green: 1.0, blue: 0.4).opacity(0.12))
                    .frame(width: 200, height: 200).blur(radius: 20)
                Circle()
                    .stroke(Color(red: 0.2, green: 1.0, blue: 0.4).opacity(0.4), lineWidth: 2)
                    .frame(width: 180, height: 180).scaleEffect(ringScale)
                if successBurst {
                    ForEach(0..<8, id: \.self) { i in burstParticle(index: i) }
                }
                Image(systemName: "person.2.fill")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundStyle(LinearGradient(
                        colors: [Color(red: 0.2, green: 1.0, blue: 0.4), .cyan],
                        startPoint: .top, endPoint: .bottom
                    ))
                    .shadow(color: Color.green.opacity(0.8), radius: 20)
            }
            .frame(width: 200, height: 200)

            VStack(spacing: 8) {
                Text("会えました！")
                    .font(.system(size: 28, weight: .black, design: .rounded))
                    .foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.4))
                Text("\(peer.displayName) さんと合流できました")
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
            .multilineTextAlignment(.center)
        }
        .transition(.scale(scale: 0.85).combined(with: .opacity))
    }

    // MARK: - Arrow

    private var arrowShape: some View {
        ZStack {
            Image(systemName: "arrow.up")
                .font(.system(size: 72, weight: .black))
                .foregroundStyle(alignmentColor.opacity(arrowGlow ? 0.5 : 0.2))
                .blur(radius: 14)
            Image(systemName: "arrow.up")
                .font(.system(size: 72, weight: .black))
                .foregroundStyle(LinearGradient(
                    colors: [alignmentColor, alignmentColor.opacity(0.6)],
                    startPoint: .top, endPoint: .bottom
                ))
                .shadow(color: alignmentColor, radius: 8)
        }
    }

    private var compassTicks: some View {
        ZStack {
            ForEach(0..<4, id: \.self) { i in
                let angle  = Double(i) * 90.0
                let radian = angle * .pi / 180
                let r: CGFloat = 118
                Text(["N", "E", "S", "W"][i])
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(i == 0 ? Color.red.opacity(0.7) : Color.white.opacity(0.25))
                    .offset(x: sin(radian) * r, y: -cos(radian) * r)
            }
        }
    }

    // MARK: - Labels

    private var orientTitleLabel: some View {
        Group {
            if uwbDirectionActive {
                VStack(spacing: 6) {
                    Text("矢印が上を向くまで体を回してください")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.75))
                    Text("3秒キープでナビ開始")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
            } else {
                VStack(spacing: 6) {
                    Text("いろんな方向に歩いてください")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                    Text("歩くほど方向が正確になります")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .multilineTextAlignment(.center).padding(.horizontal, 24)
    }

    /// 歩き回りサンプル収集中に表示するガイドプロンプト
    private var walkScanPrompt: some View {
        VStack(spacing: 14) {
            // UWB 接続ステータスバッジ
            if !uwbDistanceActive {
                Label(
                    manager.uwbSupported ? "UWB 距離接続待ち…" : "歩き回りモード（UWB 非対応）",
                    systemImage: manager.uwbSupported ? "antenna.radiowaves.left.and.right" : "figure.walk"
                )
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.orange.opacity(0.85))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(.orange.opacity(0.12)))
            }

            // ステップ別指示テキスト
            walkStepInstruction

            // 方向ガイドコンパス
            walkDirectionCompass
                .frame(width: 120, height: 120)

            // 進捗ドット
            HStack(spacing: 7) {
                ForEach(0..<WalkingBearingEstimator.recommendedSamples, id: \.self) { i in
                    Circle()
                        .fill(i < walkEstimator.sampleCount ? Color.cyan : Color.white.opacity(0.2))
                        .frame(width: 8, height: 8)
                        .animation(.easeOut(duration: 0.3), value: walkEstimator.sampleCount)
                }
            }

            if uwbDistanceActive {
                Text("距離: \(livePeer.niDistance.map { String(format: "%.1fm", $0) } ?? "--")")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            }

            Button { triggerWalking() } label: {
                Text("スキップして歩き始める")
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 20).padding(.vertical, 8)
                    .background(Capsule().fill(.white.opacity(0.07)))
            }
        }
    }

    /// サンプル数に応じたステップ別指示
    private var walkStepInstruction: some View {
        VStack(spacing: 5) {
            switch walkEstimator.sampleCount {
            case 0:
                Text("2〜3歩、どこかへ歩いてください")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                Text("方向はどこでも OK です")
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            case 1:
                Text("別の方向に 2〜3 歩歩いてください")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.cyan)
                Text("コンパスの矢印を目安にどうぞ")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            case 2:
                Text("もう 1 方向歩くとさらに精度 UP")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(.cyan)
                Text("三角形を描くようなイメージで")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
            default:
                Text("歩き続けると精度が上がります")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color(red: 0.2, green: 1.0, blue: 0.4))
                let rem = max(0, WalkingBearingEstimator.recommendedSamples - walkEstimator.sampleCount)
                if rem > 0 {
                    Text("あと \(rem) セグメントで推奨完了")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }

    /// ミニコンパス：歩いた方向（緑タック）と次の推奨方向（シアン矢印）を表示
    private var walkDirectionCompass: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.12), lineWidth: 1.5)
            Circle().fill(Color.white.opacity(0.03))

            // N/E/S/W ラベル
            ForEach(0..<4, id: \.self) { i in
                let labels = ["N", "E", "S", "W"]
                let rad = Double(i) * 90.0 * .pi / 180
                Text(labels[i])
                    .font(.system(size: 9, weight: .black, design: .rounded))
                    .foregroundStyle(i == 0 ? Color.red.opacity(0.7) : Color.white.opacity(0.2))
                    .offset(x: sin(rad) * 47, y: -cos(rad) * 47)
            }

            // 歩いたサンプル方向（シアン小タック）
            ForEach(walkEstimator.sampledHeadings.indices, id: \.self) { i in
                Capsule()
                    .fill(Color.cyan.opacity(0.55))
                    .frame(width: 3, height: 14)
                    .offset(y: -25)
                    .rotationEffect(.degrees(walkEstimator.sampledHeadings[i]))
            }

            // 推奨次方向（シアン矢印）
            if let suggested = walkEstimator.suggestedNextHeading,
               walkEstimator.estimatedBearing == nil {
                Image(systemName: "arrow.up")
                    .font(.system(size: 20, weight: .black))
                    .foregroundStyle(.cyan)
                    .shadow(color: .cyan.opacity(0.7), radius: 6)
                    .rotationEffect(.degrees(suggested))
            }

            // 現在の向き（白いニードル）
            Capsule()
                .fill(Color.white.opacity(0.55))
                .frame(width: 2, height: 22)
                .offset(y: -23)
                .rotationEffect(.degrees(headingManager.heading))

            // 中心ドット
            Circle().fill(Color.white.opacity(0.6)).frame(width: 4, height: 4)
        }
    }

    /// UWB が全く使えないときに表示する手動進行プロンプト
    private var uwbUnavailablePrompt: some View {
        VStack(spacing: 12) {
            if manager.uwbSupported {
                Label("UWB 接続中…", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(.orange.opacity(0.15)))
                Text("相手に近づいてください")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            } else {
                Label("このデバイスは UWB 非対応", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.yellow)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(.yellow.opacity(0.12)))
                Text("相手に向かって歩いてください")
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
            Button { triggerWalking() } label: {
                Text("歩き始める")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 32).padding(.vertical, 12)
                    .background(Capsule().fill(.white.opacity(0.85)))
            }
        }
    }

    private var connectedToThisPeer: Bool {
        manager.connectedPeerIDs.contains(peer.id)
    }

    // MARK: - Bottom

    private var bottomSection: some View {
        VStack(spacing: 20) {
            switch phase {
            case .orient, .walking:
                headingInfoRow
            case .met:
                Button { dismiss() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 20, weight: .semibold))
                        Text("閉じる").font(.system(size: 18, weight: .black, design: .rounded))
                    }
                    .foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical, 20)
                    .background(
                        RoundedRectangle(cornerRadius: 20)
                            .fill(LinearGradient(
                                colors: [Color(red: 0.2, green: 1.0, blue: 0.4),
                                         Color(red: 0.0, green: 0.85, blue: 0.6)],
                                startPoint: .leading, endPoint: .trailing
                            ))
                    )
                    .shadow(color: Color.green.opacity(0.6), radius: 20, y: 8)
                }
                .padding(.horizontal, 28)
            }
        }
    }

    private var headingInfoRow: some View {
        HStack(spacing: 0) {
            headingCell(icon: "iphone", label: "自分",
                        value: String(format: "%.0f°", headingManager.heading), color: .cyan)
            Divider().frame(height: 40).background(Color.white.opacity(0.15))
            headingCell(icon: "person.fill", label: peer.displayName,
                        value: livePeer.peerHeading.map { String(format: "%.0f°", $0) } ?? "---",
                        color: .purple)
            Divider().frame(height: 40).background(Color.white.opacity(0.15))
            headingCell(
                icon:  phase == .walking ? "ruler"              : "arrow.left.and.right",
                label: phase == .walking ? "距離"               : "ズレ",
                value: phase == .walking ? livePeer.distanceLabel
                                         : angleDiff.map { String(format: "%.0f°", abs($0)) } ?? "---",
                color: phase == .walking ? .cyan : alignmentColor
            )
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 1))
        )
        .padding(.horizontal, 28)
    }

    private func headingCell(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color.opacity(0.7))
            Text(value).font(.system(size: 17, weight: .black, design: .rounded))
                .foregroundStyle(color).monospacedDigit()
            Text(label).font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.35)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Burst particle

    private func burstParticle(index: Int) -> some View {
        let angle = Double(index) * 45.0 * .pi / 180
        return Circle()
            .fill(Color(red: 0.2, green: 1.0, blue: 0.4).opacity(0.7))
            .frame(width: 8, height: 8)
            .offset(x: cos(angle) * 90, y: sin(angle) * 90)
            .scaleEffect(successBurst ? 0.3 : 1.0)
            .opacity(successBurst ? 0 : 1)
            .animation(.easeOut(duration: 0.7).delay(Double(index) * 0.04), value: successBurst)
    }

    // MARK: - Alignment logic

    private func updateCumulativeAngle() {
        guard let newDiff = angleDiff else { return }
        if let last = lastRawDiff {
            var delta = newDiff - last
            while delta >  180 { delta -= 360 }
            while delta < -180 { delta += 360 }
            cumulativeArrowDeg += delta
        } else {
            cumulativeArrowDeg = newDiff
        }
        lastRawDiff = newDiff
    }

    private func resetAlignedState() {
        guard phase == .orient else { return }
        alignedSince  = nil
        alignProgress = 0
    }

    private func checkAlignment(diff: Double?) {
        guard phase == .orient, uwbDirectionActive else { alignedSince = nil; alignProgress = 0; return }
        guard let diff else { alignedSince = nil; alignProgress = 0; return }
        if abs(diff) <= Self.threshold {
            if alignedSince == nil { alignedSince = Date() }
            // alignProgress / triggerWalking は TimelineView 側で毎フレーム評価する
        } else {
            alignedSince  = nil
            alignProgress = 0
        }
    }

    private func checkProximity(_ distance: Float?) {
        guard phase == .walking, let d = distance, d < Self.meetDistance else { return }
        triggerMet()
    }

    private func triggerWalking() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(duration: 0.5, bounce: 0.3)) { phase = .walking }
    }

    private func triggerMet() {
        guard phase != .met else { return }
        withAnimation(.spring(duration: 0.5, bounce: 0.4)) { phase = .met; successBurst = true }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        withAnimation(.spring(duration: 0.6, bounce: 0.3)) { ringScale = 1.12 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            withAnimation(.spring(duration: 0.4)) { ringScale = 1.0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { successBurst = false }
    }

}

