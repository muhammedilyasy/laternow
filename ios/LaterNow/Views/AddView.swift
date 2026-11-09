import SwiftUI

struct AddView: View {
    @Environment(Engine.self) private var engine
    @Environment(AppState.self) private var app
    @State private var text = ""
    @State private var adding = false
    @State private var importing = false
    @State private var result: String?
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Paste YouTube links or a playlist. Each long video becomes a handful of short moments.")
                        .foregroundStyle(Color.t2)

                    if !engine.hasKey {
                        HStack(spacing: 14) {
                            Image(systemName: "sparkles").font(.title3).frame(width: 40, height: 40).glassEffect(.regular, in: .circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connect Gemini first").font(.headline)
                                Text("Free, takes a minute.").font(.footnote).foregroundStyle(Color.t2)
                            }
                            Spacer()
                            Button("Connect") { app.showKey = true }.buttonStyle(.glass)
                        }
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))
                    }

                    VStack(alignment: .trailing, spacing: 10) {
                        ZStack(alignment: .topLeading) {
                            if text.isEmpty {
                                Text("youtube.com/watch?v=…\nyoutube.com/playlist?list=…")
                                    .foregroundStyle(Color.t3).padding(.top, 8).padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                            TextEditor(text: $text)
                                .focused($focused)
                                .scrollContentBackground(.hidden)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.URL)
                        }
                        .font(.body.monospaced())
                        .frame(minHeight: 130)
                        .padding(12)
                        .glassEffect(.regular, in: .rect(cornerRadius: 24, style: .continuous))

                        PasteButton(payloadType: String.self) { strings in
                            let s = strings.joined(separator: "\n")
                            text = text.isEmpty ? s : text + "\n" + s
                        }
                        .buttonBorderShape(.capsule)
                        .labelStyle(.titleAndIcon)
                        .tint(.white.opacity(0.2))
                    }

                    PrimaryButton(title: adding ? "Adding…" : "Add", busy: adding) { Task { await add() } }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let result {
                        Text(result).font(.subheadline).foregroundStyle(Color.t2)
                            .transition(.opacity)
                    }

                    HStack { line; Text("or").font(.footnote).foregroundStyle(Color.t3); line }

                    Button { Task { await importWatchLater() } } label: {
                        HStack(spacing: 12) {
                            if importing { ProgressView().tint(.white) } else { Image(systemName: "clock.arrow.circlepath") }
                            Text(importing ? "Reading Watch Later…" : "Import Watch Later").font(.headline)
                        }
                        .frame(maxWidth: .infinity, minHeight: 30)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                    .disabled(importing)

                    Text("Signs in to YouTube inside Later Now, once, to read your Watch Later list. Your login stays on this iPhone.")
                        .font(.footnote).foregroundStyle(Color.t3)
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(.black)
            .navigationTitle("Add videos")
            .animation(.smooth, value: result)
            .sheet(isPresented: Binding(get: { app.showSignIn }, set: { app.showSignIn = $0 })) {
                YouTubeSignInView { Task { await importWatchLater() } }
            }
        }
    }

    private var line: some View { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }

    private func add() async {
        guard engine.hasKey else { app.showKey = true; return }
        focused = false
        adding = true
        let r = await engine.add(text)
        adding = false
        result = r.message
        if r.new > 0 {
            text = ""
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private func importWatchLater() async {
        guard engine.hasKey else { app.showKey = true; return }
        importing = true
        let r = await engine.importWatchLater()
        importing = false
        if r.needsSignIn { app.showSignIn = true; return }
        result = r.message + (r.notes.isEmpty || r.found == 0 ? "" : ". " + r.notes.joined(separator: " "))
        if r.new > 0 { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
}
