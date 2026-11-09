import SwiftUI

struct GeminiKeyView: View {
    @Environment(Engine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    var onConnected: () -> Void = {}
    @State private var key = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Later Now uses your own Gemini API key to pick the best parts of each video. A key is free and takes a minute.")
                        .foregroundStyle(Color.t2)

                    VStack(alignment: .leading, spacing: 14) {
                        step(1) {
                            Text("Open [aistudio.google.com/apikey](https://aistudio.google.com/apikey) and sign in.")
                        }
                        step(2) { Text("Tap **Create API key** and copy it.") }
                        step(3) { Text("Paste it here.") }
                    }
                    .tint(.white)

                    HStack(spacing: 10) {
                        TextField(engine.hasKey ? "Current key \(engine.keyHint)" : "Gemini API key", text: $key)
                            .font(.body.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.go)
                            .onSubmit(connect)
                        PasteButton(payloadType: String.self) { s in key = s.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
                            .labelStyle(.iconOnly)
                            .buttonBorderShape(.circle)
                            .tint(.white.opacity(0.2))
                    }
                    .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)

                    if let error {
                        Text(error).font(.footnote).foregroundStyle(Color.bad)
                    }

                    PrimaryButton(title: busy ? "Checking…" : engine.hasKey ? "Replace key" : "Connect", busy: busy, action: connect)

                    Text("Your key is stored only on this iPhone, in the Keychain, and sent only to Google.")
                        .font(.footnote).foregroundStyle(Color.t3)

                    if engine.hasKey {
                        Button("Remove key", role: .destructive) { engine.removeKey(); dismiss() }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Connect Gemini")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func step(_ n: Int, @ViewBuilder _ text: () -> Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(n)").font(.footnote.weight(.bold)).frame(width: 26, height: 26).glassEffect(.regular, in: .circle)
            text().font(.body)
        }
    }

    private func connect() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { error = "Paste your key first."; return }
        busy = true; error = nil
        Task {
            do {
                try await engine.setKey(k)
                busy = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                dismiss()
                onConnected()
            } catch {
                busy = false
                self.error = error.localizedDescription
            }
        }
    }
}
