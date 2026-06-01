import SwiftUI

struct ContentView: View {
    @AppStorage("userName") private var userName: String = ""

    var body: some View {
        if userName.isEmpty {
            OnboardingView()
        } else {
            DiscoveryView(userName: userName)
        }
    }
}
