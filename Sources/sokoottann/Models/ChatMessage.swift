import Foundation

struct ChatMessage: Identifiable {
    let id: UUID
    let text: String
    let isFromSelf: Bool
    let timestamp: Date
    /// true = まだ送信待ちキュー内（接続後に自動送信される）
    var isPending: Bool

    init(text: String, isFromSelf: Bool, isPending: Bool = false) {
        self.id = UUID()
        self.text = text
        self.isFromSelf = isFromSelf
        self.timestamp = Date()
        self.isPending = isPending
    }
}
