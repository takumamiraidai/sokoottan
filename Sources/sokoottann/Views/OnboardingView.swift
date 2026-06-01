import SwiftUI

struct OnboardingView: View {
    @AppStorage("userName") private var userName: String = ""
    @State private var inputName: String = ""
    @State private var titleScale: CGFloat = 0.4
    @State private var titleOpacity: Double = 0.0
    @State private var contentOpacity: Double = 0.0
    @State private var iconRotation: Double = 0

    var canProceed: Bool {
        !inputName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        ZStack {
            // ── 背景 ──────────────────────────────────────────
            spaceBackground

            // ── コンテンツ ────────────────────────────────────
            VStack(spacing: 0) {
                Spacer()

                // アイコン＆タイトル
                VStack(spacing: 24) {
                    iconView
                    titleView
                }
                .scaleEffect(titleScale)
                .opacity(titleOpacity)

                Spacer()

                // 名前入力フォーム
                VStack(spacing: 20) {
                    Text("あなたの名前を入力してください")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))

                    nameField

                    startButton
                }
                .padding(.horizontal, 32)
                .opacity(contentOpacity)

                Spacer(minLength: 60)
            }
        }
        .onAppear { playEntryAnimation() }
    }

    // MARK: - Subviews

    private var spaceBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.04, blue: 0.15),
                    Color(red: 0.08, green: 0.02, blue: 0.22),
                    Color(red: 0.02, green: 0.06, blue: 0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            StarFieldView()
        }
    }

    private var iconView: some View {
        ZStack {
            // 外側グロー
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color.cyan.opacity(0.25), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 90
                    )
                )
                .frame(width: 180, height: 180)

            // アイコン背景
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.1, green: 0.1, blue: 0.3),
                            Color(red: 0.15, green: 0.05, blue: 0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 110, height: 110)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [.cyan.opacity(0.8), .purple.opacity(0.5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.5
                        )
                )

            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 48, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.cyan, Color(red: 0.5, green: 0.9, blue: 1.0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .cyan.opacity(0.7), radius: 16)
                .rotationEffect(.degrees(iconRotation))
        }
    }

    private var titleView: some View {
        VStack(spacing: 10) {
            Text("そこいた！")
                .font(.system(size: 46, weight: .black, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.cyan, .white, Color(red: 0.8, green: 0.6, blue: 1.0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .shadow(color: .cyan.opacity(0.4), radius: 12)

            Text("近くにいる人を見つけよう")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.65))
                .tracking(1.5)
        }
    }

    private var nameField: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 20))
                .foregroundStyle(.cyan.opacity(0.8))

            TextField("ニックネーム", text: $inputName)
                .foregroundStyle(.white)
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(.white.opacity(0.07))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    .cyan.opacity(canProceed ? 0.7 : 0.3),
                                    .purple.opacity(canProceed ? 0.5 : 0.2)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1.5
                        )
                )
        )
        .animation(.easeInOut(duration: 0.3), value: canProceed)
    }

    private var startButton: some View {
        Button {
            let name = inputName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            userName = name
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: 18, weight: .bold))
                Text("はじめる")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
            }
            .foregroundStyle(canProceed ? .black : .white.opacity(0.4))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        canProceed
                            ? LinearGradient(
                                colors: [.cyan, Color(red: 0.3, green: 0.85, blue: 1.0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            : LinearGradient(
                                colors: [.white.opacity(0.1), .white.opacity(0.08)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                    )
            )
            .shadow(color: canProceed ? .cyan.opacity(0.45) : .clear, radius: 18, y: 6)
        }
        .disabled(!canProceed)
        .animation(.spring(duration: 0.35), value: canProceed)
    }

    // MARK: - Animation

    private func playEntryAnimation() {
        withAnimation(.spring(duration: 1.1, bounce: 0.35)) {
            titleScale = 1.0
            titleOpacity = 1.0
        }
        withAnimation(.easeOut(duration: 0.8).delay(0.5)) {
            contentOpacity = 1.0
        }
        withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
            iconRotation = 8
        }
    }
}

// MARK: - StarFieldView

struct StarFieldView: View {
    @State private var stars: [StarData] = StarData.generate(count: 70)

    var body: some View {
        GeometryReader { geo in
            ForEach(stars) { star in
                Circle()
                    .fill(Color.white)
                    .frame(width: star.size, height: star.size)
                    .opacity(star.opacity)
                    .position(
                        x: star.x * geo.size.width,
                        y: star.y * geo.size.height
                    )
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

struct StarData: Identifiable {
    let id = UUID()
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let opacity: Double

    static func generate(count: Int) -> [StarData] {
        (0 ..< count).map { _ in
            StarData(
                x: CGFloat.random(in: 0 ... 1),
                y: CGFloat.random(in: 0 ... 1),
                size: CGFloat.random(in: 1 ... 2.8),
                opacity: Double.random(in: 0.2 ... 0.85)
            )
        }
    }
}
