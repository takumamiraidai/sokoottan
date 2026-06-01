import SwiftUI
import MultipeerConnectivity

struct ChatView: View {
    let peer: PeerInfo
    @ObservedObject var manager: MultipeerManager
    @Environment(\.dismiss) private var dismiss

    @State private var inputText: String = ""
    @FocusState private var isInputFocused: Bool

    private var chatMessages: [ChatMessage] {
        manager.messages[peer.id] ?? []
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.04, blue: 0.15),
                    Color(red: 0.06, green: 0.02, blue: 0.20)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // ── ヘッダー ──────────────────────────────────
                headerView
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Divider()
                    .background(Color.cyan.opacity(0.2))

                // ── メッセージ一覧 ────────────────────────────
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            if chatMessages.isEmpty {
                                emptyPlaceholder
                            } else {
                                ForEach(chatMessages) { msg in
                                    MessageBubble(message: msg)
                                        .id(msg.id)
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 16)
                    }
                    .onChange(of: chatMessages.count) { _, _ in
                        if let last = chatMessages.last {
                            withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                        }
                    }
                }

                // ── 入力エリア ───────────────────────────────
                inputBar
            }
        }
        .onAppear {
            manager.markAsRead(peerID: peer.id)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack(spacing: 14) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.cyan.opacity(0.3), .purple.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)

                Text(String(peer.displayName.prefix(1)).uppercased())
                    .font(.system(size: 18, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
            .overlay(Circle().stroke(Color.cyan.opacity(0.4), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                HStack(spacing: 6) {
                    Text(peer.directionArrow)
                        .font(.system(size: 12))
                    Text("\(peer.directionLabel) · \(peer.distanceLabel)")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                }
                .foregroundStyle(Color.cyan.opacity(0.8))
            }

            Spacer()
        }
    }

    // MARK: - Empty placeholder

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.white.opacity(0.15))
                .padding(.top, 60)

            Text("メッセージを送ってみよう！")
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.3))
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 12) {
            TextField("メッセージを入力…", text: $inputText, axis: .vertical)
                .font(.system(size: 15, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1...4)
                .focused($isInputFocused)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 22)
                        .fill(.white.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22)
                                .stroke(Color.cyan.opacity(isInputFocused ? 0.5 : 0.2), lineWidth: 1.5)
                        )
                )

            Button {
                sendMessage()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(inputText.trimmingCharacters(in: .whitespaces).isEmpty ? .gray : .black)
                    .frame(width: 46, height: 46)
                    .background(
                        Group {
                            if inputText.trimmingCharacters(in: .whitespaces).isEmpty {
                                Circle().fill(Color.white.opacity(0.1))
                            } else {
                                Circle().fill(
                                    LinearGradient(
                                        colors: [.cyan, Color(red: 0.3, green: 0.88, blue: 1.0)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            }
                        }
                    )
            }
            .disabled(inputText.trimmingCharacters(in: .whitespaces).isEmpty)
            .animation(.spring(duration: 0.25), value: inputText.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            Color(red: 0.05, green: 0.04, blue: 0.18)
                .overlay(
                    Rectangle()
                        .fill(Color.cyan.opacity(0.12))
                        .frame(height: 1),
                    alignment: .top
                )
        )
    }

    // MARK: - Actions

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        manager.sendMessage(text, to: peer.id)
        inputText = ""
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
}

// MARK: - MessageBubble

struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.isFromSelf { Spacer(minLength: 50) }

            VStack(alignment: message.isFromSelf ? .trailing : .leading, spacing: 3) {
                Text(message.text)
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18)
                            .fill(
                                message.isFromSelf
                                    ? LinearGradient(
                                        colors: [.cyan.opacity(0.75), Color(red: 0.2, green: 0.6, blue: 1.0).opacity(0.75)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                    : LinearGradient(
                                        colors: [Color.white.opacity(0.12), Color.white.opacity(0.08)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 18)
                                    .stroke(
                                        message.isFromSelf ? Color.clear : Color.white.opacity(0.1),
                                        lineWidth: 1
                                    )
                            )
                    )

                Text(timeString(message.timestamp))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.3))
                    .padding(.horizontal, 4)
            }

            if !message.isFromSelf { Spacer(minLength: 50) }
        }
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
