import SwiftUI

struct LibraryView: View {
    @Environment(Engine.self) private var engine
    @Environment(AppState.self) private var app
    @State private var toast: String?
    @State private var showAll = false

    var body: some View {
        NavigationStack {
            List {
                Section { stats.listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }

                Section("AI") {
                    Button { app.showKey = true } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "sparkles").font(.title3).frame(width: 36, height: 36)
                                .glassEffect(.regular, in: .circle)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Gemini").font(.body.weight(.semibold)).foregroundStyle(.white)
                                Text(aiDetail).font(.footnote).foregroundStyle(Color.t2).lineLimit(2)
                            }
                            Spacer()
                            Text(engine.hasKey ? "Change key" : "Connect").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        }
                    }
                }

                if engine.working != nil || !engine.activity.isEmpty {
                    Section("Activity") {
                        if let w = engine.working {
                            HStack(spacing: 10) {
                                ProgressView().tint(.white)
                                Text(w.text).font(.subheadline.weight(.medium)).lineLimit(2)
                                Spacer()
                                Text(w.since, style: .timer).font(.footnote.monospacedDigit()).foregroundStyle(Color.t2)
                            }
                        }
                        ForEach(engine.activity.prefix(showAll ? 100 : 6)) { l in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(Date(timeIntervalSince1970: l.t), format: .dateTime.hour().minute())
                                    .font(.caption.monospacedDigit()).foregroundStyle(Color.t3).frame(width: 52, alignment: .leading)
                                Text(l.text).font(.footnote).foregroundStyle(Color.t2)
                            }
                        }
                        if engine.activity.count > 6 {
                            Button(showAll ? "Show less" : "Show all") { withAnimation { showAll.toggle() } }
                                .font(.footnote.weight(.semibold)).foregroundStyle(.white)
                        }
                    }
                }

                Section("Your taste") {
                    if engine.topics.isEmpty {
                        Text("Watch a few moments and this fills in.").foregroundStyle(Color.t2)
                    } else {
                        ForEach(engine.topics.prefix(8)) { t in
                            HStack(spacing: 12) {
                                Text(t.topic).frame(width: 96, alignment: .leading).lineLimit(1)
                                GeometryReader { g in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.white.opacity(0.12))
                                        Capsule().fill(.white).frame(width: g.size.width * max(0.02, min(1, t.score)))
                                    }
                                }
                                .frame(height: 6)
                                Text("\(t.n)").font(.footnote.monospacedDigit()).foregroundStyle(Color.t3).frame(width: 28, alignment: .trailing)
                            }
                        }
                    }
                }

                Section {
                    if engine.videos.isEmpty {
                        Text("No videos yet.").foregroundStyle(Color.t2)
                    }
                    ForEach(engine.videoList.prefix(300)) { v in
                        VideoRow(v: v, moments: engine.momentCount(v.id))
                            .swipeActions {
                                Button(role: .destructive) { withAnimation { engine.remove(v.id) } } label: { Label("Remove", systemImage: "trash") }
                            }
                            .contextMenu {
                                Link(destination: youtubeURL(v.id, 0)) { Label("Open on YouTube", systemImage: "arrow.up.right") }
                                Button(role: .destructive) { withAnimation { engine.remove(v.id) } } label: { Label("Remove", systemImage: "trash") }
                            }
                    }
                } header: {
                    HStack {
                        Text("Videos")
                        Spacer()
                        Button("Retry failed") {
                            let n = engine.retry()
                            toast = n > 0 ? "Retrying \(n)" : "Nothing to retry"
                        }
                        .font(.footnote.weight(.semibold)).textCase(nil).foregroundStyle(.white)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(.black)
            .navigationTitle("Library")
            .overlay(alignment: .top) { Toast(text: $toast).padding(.top, 4).animation(.smooth, value: toast) }
        }
    }

    private var stats: some View {
        let live = engine.liveMoments.count, done = engine.doneLater.done
        return GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                stat("\(live > 0 ? Int((Double(done) / Double(live) * 100).rounded()) : 0)%", "watched")
                stat("\(live)", "moments")
                stat("\(engine.counts[.ready] ?? 0)", "videos")
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ n: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(n).font(.system(size: 26, weight: .bold).monospacedDigit())
            Text(label).font(.footnote).foregroundStyle(Color.t2)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 16)
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
    }

    private var aiDetail: String {
        guard engine.hasKey else { return "Not connected" }
        var s = engine.model == "auto" ? "Connected" : engine.model
        if let q = engine.quota {
            if let at = q.resumesAt { s += " · free quota used up, back \(when(at))" }
            else if q.usedToday > 0 { s += " · \(q.usedToday) request\(q.usedToday == 1 ? "" : "s") today" }
        }
        return s
    }
}

private struct VideoRow: View {
    let v: Video
    let moments: Int

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: thumbURL(v.id, "mqdefault")) { img in img.resizable().scaledToFill() } placeholder: { Color(white: 0.12) }
                .frame(width: 80, height: 45)
                .clipShape(.rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(v.title).font(.subheadline.weight(.medium)).lineLimit(2)
                HStack(spacing: 6) {
                    if v.status.inProgress { ProgressView().controlSize(.mini).tint(.white) }
                    else { Circle().fill(statusColor(v)).frame(width: 7, height: 7) }
                    Text(statusLabel(v, moments: moments)).font(.caption).foregroundStyle(Color.t2).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
