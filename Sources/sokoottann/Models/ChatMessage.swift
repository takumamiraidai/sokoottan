import Foundation

struct ChatMessage: Identifiable {
    let id: UUID
    let text: String
    let isFromSelf: Bool
    let timestamp: Date

    init(text: String, isFromSelf: Bool) {
        self.id = UUID()
        self.text = text
        self.isFromSelf = isFromSelf
        self.timestamp = Date()
    }
}
