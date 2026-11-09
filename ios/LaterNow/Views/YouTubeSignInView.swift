import SwiftUI
import WebKit

/// Signs in to YouTube inside the app so Later Now can read the Watch Later list. The login cookies stay in this
/// app's web data on the phone and are only sent to youtube.com.
struct YouTubeSignInView: View {
    var onSignedIn: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var done = false

    var body: some View {
        NavigationStack {
            SignInWeb { finish() }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign in to YouTube")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { finish() } }
                }
        }
    }

    private func finish() {
        guard !done else { return }
        done = true
        dismiss()
        Task {
            if await YouTube.isSignedIn() { onSignedIn() }
        }
    }
}

private struct SignInWeb: UIViewRepresentable {
    let onSignedIn: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSignedIn) }

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.customUserAgent = YouTube.mobileUA
        w.navigationDelegate = context.coordinator
        let next = "https://m.youtube.com/feed/library"
        let url = "https://accounts.google.com/ServiceLogin?service=youtube&passive=true&continue=" +
            ("https://www.youtube.com/signin?action_handle_signin=true&next=" + next).addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        w.load(URLRequest(url: URL(string: url)!))
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let onSignedIn: () -> Void
        init(_ f: @escaping () -> Void) { onSignedIn = f }

        func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
            guard w.url?.host?.hasSuffix("youtube.com") == true else { return }
            Task { @MainActor in
                if await YouTube.isSignedIn() { onSignedIn() }
            }
        }
    }
}
