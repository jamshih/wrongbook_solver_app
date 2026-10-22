import SwiftUI

@main
struct WrongBookHumanSolverApp: App {
    @StateObject private var auth = AuthStore()
    var body: some Scene { WindowGroup { RootView(auth: auth) } }
}
