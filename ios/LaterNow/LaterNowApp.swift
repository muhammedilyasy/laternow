import SwiftUI

enum AppTab: Hashable { case feed, library, add }

@MainActor @Observable final class AppState {
    var tab: AppTab = .feed
    var showKey = false
    var showSignIn = false
}

@main
struct LaterNowApp: App {
    @State private var engine = Engine()
    @State private var player = YouTubePlayer()
    @State private var app = AppState()

    init() { _ = Notifier.shared }   // set up before launch finishes, so a tapped notification is delivered

    var body: some Scene {
        WindowGroup {
            RootView(engine: engine, player: player)
                .environment(engine)
                .environment(app)
                .preferredColorScheme(.dark)
                .tint(.white)
                .task { await engine.heartbeat() }
        }
    }
}

struct RootView: View {
    let engine: Engine
    let player: YouTubePlayer
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var phase
    @AppStorage("started") private var started = false
    @State private var feed: FeedModel

    init(engine: Engine, player: YouTubePlayer) {
        self.engine = engine
        self.player = player
        _feed = State(initialValue: FeedModel(engine: engine, player: player))
    }

    var body: some View {
        @Bindable var app = app
        TabView(selection: $app.tab) {
            Tab("For You", systemImage: "play.square.stack", value: AppTab.feed) {
                FeedView(feed: feed, onAdd: { app.tab = .add }, onConnect: { app.showKey = true })
            }
            Tab("Library", systemImage: "books.vertical", value: AppTab.library) {
                LibraryView()
            }
            .badge(engine.busyCount)
            Tab("Add", systemImage: "plus", value: AppTab.add, role: .search) {
                AddView()
            }
        }
        .tabBarMinimizeBehavior(.never)
        .sheet(isPresented: $app.showKey) {
            GeminiKeyView { if engine.liveMoments.isEmpty { app.tab = .add } }
        }
        .fullScreenCover(isPresented: Binding(get: { !started }, set: { started = !$0 })) {
            WelcomeView {
                started = true
                if !engine.hasKey {
                    Task { try? await Task.sleep(for: .milliseconds(450)); app.showKey = true }
                }
            }
        }
        .onChange(of: app.tab) { _, _ in syncPlayback() }
        .onChange(of: app.showKey) { _, _ in syncPlayback() }
        .onChange(of: started) { _, _ in syncPlayback() }
        .onChange(of: phase) { _, p in
            if p == .background { engine.enteredBackground() }
            if p == .active { Notifier.shared.clear(); engine.pump() }
            syncPlayback()
        }
        .onAppear {
            Notifier.shared.onOpen = { app.tab = .feed }
            syncPlayback()
        }
    }

    /// Exactly one feed plays: the one on screen, while the app is in front and nothing covers it.
    private func syncPlayback() {
        let visible = phase == .active && started && !app.showKey
        if visible && app.tab == .feed { feed.attach() } else { feed.detach() }
    }
}
