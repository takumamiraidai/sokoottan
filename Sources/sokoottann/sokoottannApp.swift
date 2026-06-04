import SwiftUI
import UserNotifications

@main
struct sokoottannApp: App {
    init() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error { print("⚠️ 通知許可エラー: \(error.localizedDescription)") }
        }
        // フォアグラウンド中もバナー通知を表示する
        UNUserNotificationCenter.current().delegate = AppNotificationDelegate.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// フォアグラウンド中もバナーを表示するためのデリゲート
final class AppNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AppNotificationDelegate()
    private override init() { super.init() }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // アプリ起動中でもバナーとサウンドを表示
        completionHandler([.banner, .sound])
    }
}
