import SwiftUI

/// The vertical feed: one moment per screen, swipe up for the next.
struct FeedView: View {
    @Bindable var feed: FeedModel
    var showsTopics = true
    var onAdd: () -> Void = {}
    var onConnect: () -> Void = {}
    @Environment(Engine.self) private var engine

    var body: some View {
        GeometryReader { geo in
            let insets = geo.safeAreaInsets
            ZStack(alignment: .top) {
                Color.black
                if feed.loaded && feed.items.isEmpty {
                    EmptyFeed(topic: feed.topic, savedOnly: feed.savedOnly, onAdd: onAdd, onConnect: onConnect)
                        .padding(.top, insets.top).padding(.bottom, insets.bottom)
                } else {
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(feed.items) { item in
                                page(item, insets)
                                    .containerRelativeFrame([.horizontal, .vertical])
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollPosition(id: $feed.currentID)
                    .scrollTargetBehavior(.paging)
                    .scrollIndicators(.hidden)
                    .onChange(of: feed.currentID) { _, id in feed.scrolled(to: id) }
                }
                VStack(spacing: 10) {
                    if showsTopics { TopicBar(feed: feed) }
                    Toast(text: $feed.toast)
                }
                .padding(.top, insets.top + 6)
                .animation(.smooth, value: feed.toast)
            }
            .ignoresSafeArea()
        }
        .background(.black)
        .onChange(of: engine.readyVids.count) { _, _ in feed.refreshIfEmpty() }
    }

    @ViewBuilder private func page(_ item: FeedItem, _ insets: EdgeInsets) -> some View {
        switch item {
        case .moment(let m): MomentPage(m: m, feed: feed, insets: insets, topInset: showsTopics ? 58 : 8)
        case .breather(_, let recap, let secs): BreatherPage(recap: recap, secs: secs, insets: insets)
        case .end: EndPage(feed: feed, insets: insets, onAdd: onAdd)
        }
    }
}

// MARK: - Topic chips

private struct TopicBar: View {
    let feed: FeedModel
    @Environment(Engine.self) private var engine
    @Namespace private var ns

    var body: some View {
        let topics = engine.topics.prefix(14)
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    chip("All", nil)
                    ForEach(topics) { t in chip(t.topic, t.topic) }
                }
                .padding(.horizontal, 16)
            }
        }
        .scrollIndicators(.hidden)
        .frame(height: 40)
    }

    private func chip(_ label: String, _ value: String?) -> some View {
        let on = feed.topic == value
        return Button {
            withAnimation(.smooth) { feed.setTopic(value) }
        } label: {
            Text(label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 14).frame(height: 36)
        }
        .buttonStyle(.plain)
        .glassEffect(on ? .regular.tint(.white).interactive() : .regular.interactive(), in: .capsule)
        .glassEffectID(label, in: ns)
    }
}

// MARK: - Moment card

private struct MomentPage: View {
    let m: FeedMoment
    let feed: FeedModel
    let insets: EdgeInsets
    let topInset: CGFloat
    @Environment(Engine.self) private var engine
    @State private var hearts: [Heart] = []
    @State private var scrubbing = false
    @State private var size = CGSize(width: 400, height: 800)
    /// Portrait: the video fills the whole screen, cropped at the sides. Off: the full 16:9 picture in a card.
    @AppStorage("fill") private var fill = true

    struct Heart: Identifiable { let id = UUID(); let at: CGPoint }

    private var active: Bool { feed.currentID == "m\(m.id)" && feed.isOwner }

    var body: some View {
        ZStack {
            if fill { fullVideo } else { backdrop }
            VStack(alignment: .leading, spacing: 0) {
                if fill {
                    // Reel layout: everything sits at the bottom like Reels/Shorts, so the middle stays clear.
                    Spacer(minLength: insets.top + topInset + 12)
                    HStack(alignment: .bottom, spacing: 14) {
                        VStack(alignment: .leading, spacing: 12) {
                            captionView.opacity(active && feed.caption(for: m) != nil ? 1 : 0)
                            reelInfo
                        }
                        buttons(vertical: true)
                    }
                    .padding(.leading, 18).padding(.trailing, 14)
                    .shadow(color: .black.opacity(0.75), radius: 6, y: 1)
                } else {
                    Spacer(minLength: insets.top + topInset + 12)
                    header.padding(.horizontal, 22)
                    Spacer(minLength: 18).frame(maxHeight: 28)
                    video
                    captionView.padding(.horizontal, 22).padding(.top, 20)
                    Spacer(minLength: 12)
                    bottom.padding(.horizontal, 18)
                }
                progress.padding(.horizontal, 18).padding(.top, 14)
                    .padding(.bottom, insets.bottom + 10)
            }
            ForEach(hearts) { h in
                Image(systemName: "heart.fill")
                    .font(.system(size: 96))
                    .foregroundStyle(Color.likeRed)
                    .shadow(color: .black.opacity(0.3), radius: 12)
                    .position(h.at)
                    .transition(.asymmetric(insertion: .scale(scale: 0.4).combined(with: .opacity), removal: .scale(scale: 1.4).combined(with: .opacity)))
                    .allowsHitTesting(false)
            }
        }
        .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
        .contentShape(.rect)
        .gesture(SpatialTapGesture(count: 2).onEnded { e in doubleTap(e.location) })
        .onTapGesture { if active { feed.togglePlay() } }
        .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 12) {
            if active && feed.player.state == .playing { feed.setFast(true) }
        } onPressingChanged: { pressing in
            if !pressing { feed.setFast(false) }
        }
    }

    private var backdrop: some View {
        Color.black.overlay {
            AsyncImage(url: thumbURL(m.m.vid)) { img in
                img.resizable().scaledToFill()
            } placeholder: { Color.black }
            .blur(radius: 50)
            .saturation(1.2)
            .opacity(0.45)
            .scaleEffect(1.3)
        }
        .clipped()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(m.m.topic.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(Color.t2)
            Text(m.m.title)
                .font(.system(size: 28, weight: .bold))
                .tracking(-0.4)
                .foregroundStyle(.white)
                .lineLimit(3)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Portrait: the video covers the screen, centred, with its sides cropped.
    private var fullVideo: some View {
        Color.black.overlay {
            ZStack {
                // hq720 is a 16:9 frame without the black bars hqdefault has; older videos only have mqdefault.
                AsyncImage(url: thumbURL(m.m.vid, "hq720")) { phase in
                    if let img = phase.image { img.resizable().scaledToFill() }
                    else if phase.error != nil {
                        AsyncImage(url: thumbURL(m.m.vid, "mqdefault")) { $0.resizable().scaledToFill() } placeholder: { Color.black }
                    } else { Color.black }
                }
                if active { PlayerSlot(player: feed.player, active: true, visible: feed.showVideo, fill: true) }
                if active && feed.paused {
                    Image(systemName: "play.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 78, height: 78)
                        .glassEffect(.regular, in: .circle)
                        .transition(.scale.combined(with: .opacity))
                }
                if active && feed.fast {
                    Text("2×").font(.headline).padding(.horizontal, 12).padding(.vertical, 6)
                        .glassEffect(.regular, in: .capsule)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, insets.top + topInset + 12)
                }
            }
        }
        .clipped()
        .animation(.smooth(duration: 0.2), value: feed.paused)
    }

    private var video: some View {
        Color.black.aspectRatio(16 / 9, contentMode: .fit).overlay {
        ZStack {
            // The thumbnail is 4:3; it fills the 16:9 box without setting its size.
            Color.clear.overlay {
                AsyncImage(url: thumbURL(m.m.vid)) { img in img.resizable().scaledToFill() } placeholder: { Color(white: 0.08) }
            }
            .clipped()
            if active { PlayerSlot(player: feed.player, active: true, visible: feed.showVideo) }
            if active && feed.paused {
                Image(systemName: "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 68)
                    .glassEffect(.regular, in: .circle)
                    .transition(.scale.combined(with: .opacity))
            }
            if active && feed.fast {
                Text("2×").font(.headline).padding(.horizontal, 12).padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing).padding(10)
            }
        }
        }
        .clipShape(.rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.08)))
        .padding(.horizontal, 12)
        .animation(.smooth(duration: 0.2), value: feed.paused)
    }

    @ViewBuilder private var captionView: some View {
        let cap = active ? feed.caption(for: m) : nil
        Group {
            if let cap {
                Text(cap.words.enumerated().reduce(into: AttributedString()) { acc, w in
                    var s = AttributedString(w.element + " ")
                    s.foregroundColor = w.offset < cap.spoken ? .white : .white.opacity(fill ? 0.6 : 0.38)
                    acc += s
                })
            } else {
                Text(" ")
            }
        }
        .font(.system(size: fill ? 18 : 21, weight: .semibold))
        .lineSpacing(3)
        .lineLimit(fill ? 2 : 3)
        .frame(maxWidth: .infinity, minHeight: fill ? 0 : 84, alignment: .topLeading)
    }

    private var bottom: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(m.vtitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text("\(m.channel.isEmpty ? "YouTube" : m.channel) · \(fmt(m.m.start))–\(fmt(m.m.end))")
                    .font(.footnote).foregroundStyle(Color.t2).lineLimit(1)
            }
            .padding(.leading, 4)
            Spacer(minLength: 8)
            buttons(vertical: false)
        }
    }

    /// Reel mode: the moment's title and where it's from, small, above the progress bar.
    private var reelInfo: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(m.m.title).font(.system(size: 17, weight: .bold)).lineLimit(2)
            Text("\(m.channel.isEmpty ? m.vtitle : m.channel) · \(fmt(m.m.start))–\(fmt(m.m.end))")
                .font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func buttons(vertical: Bool) -> some View {
        GlassEffectContainer(spacing: 10) {
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 10))
            layout {
                let liked = feed.liked.contains(m.id)
                GlassIconButton(symbol: liked ? "heart.fill" : "heart", tint: liked ? .likeRed : .white, label: "Like") {
                    likeHere(nil)
                }
                GlassIconButton(symbol: fill ? "rectangle.ratio.16.to.9" : "rectangle.ratio.9.to.16",
                                label: fill ? "Show the whole picture" : "Fill the screen") {
                    withAnimation(.smooth(duration: 0.3)) { fill.toggle() }
                }
                GlassIconButton(symbol: "arrow.up.right", label: "Open full video on YouTube") {
                    if active { feed.openInYouTube() }
                }
            }
        }
    }

    private var progress: some View {
        GeometryReader { g in
            let f = active ? feed.fraction(for: m) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Capsule().fill(.white).frame(width: max(0, g.size.width * f))
            }
            .frame(height: scrubbing ? 7 : 3)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    guard active else { return }
                    scrubbing = true
                    feed.seek(fraction: v.location.x / max(1, g.size.width))
                }
                .onEnded { _ in scrubbing = false })
            .animation(.smooth(duration: 0.15), value: scrubbing)
        }
        .frame(height: 20)
    }

    private func doubleTap(_ p: CGPoint) {
        guard active else { return }
        likeHere(p)
    }

    private func likeHere(_ p: CGPoint?) {
        guard active else { return }
        let h = Heart(at: p ?? CGPoint(x: size.width / 2, y: size.height * 0.42))
        withAnimation(.spring(duration: 0.35, bounce: 0.4)) { hearts.append(h) }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        feed.like()
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.3)) { hearts.removeAll { $0.id == h.id } }
        }
    }
}

// MARK: - Breather and end cards

private struct BreatherPage: View {
    let recap: [String]
    let secs: Double
    let insets: EdgeInsets

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Take a breather").font(.system(size: 30, weight: .bold))
            Text("That was \(recap.count) ideas in about \(max(1, Int((secs / 60).rounded()))) minutes. Which one stuck with you?")
                .font(.body).foregroundStyle(Color.t2)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(recap.enumerated()), id: \.offset) { i, t in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(i + 1)").font(.footnote.monospacedDigit().weight(.semibold)).foregroundStyle(Color.t3).frame(width: 18, alignment: .trailing)
                        Text(t).font(.subheadline)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 26, style: .continuous))
            Text("Swipe up when you're ready. Or stop here, that counts too.")
                .font(.footnote).foregroundStyle(Color.t3)
        }
        .padding(.horizontal, 24)
        .padding(.top, insets.top).padding(.bottom, insets.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

private struct EndPage: View {
    let feed: FeedModel
    let insets: EdgeInsets
    let onAdd: () -> Void
    @Environment(Engine.self) private var engine

    var body: some View {
        let later = engine.doneLater.later
        VStack(spacing: 16) {
            Image(systemName: "checkmark").font(.system(size: 28, weight: .bold))
                .frame(width: 72, height: 72).glassEffect(.regular, in: .circle)
            Text(feed.savedOnly ? "That's everything you saved" : "You're all caught up").font(.system(size: 28, weight: .bold))
            if !feed.savedOnly {
                Text(later > 0 ? "\(later) moment\(later == 1 ? "" : "s") you skipped will come back later, so nothing gets lost."
                     : "You've watched every moment from your videos.")
                    .multilineTextAlignment(.center).foregroundStyle(Color.t2)
                PrimaryButton(title: "Add videos", action: onAdd).frame(maxWidth: 240).padding(.top, 8)
                Text("New moments appear here as your videos finish processing.")
                    .font(.footnote).foregroundStyle(Color.t3).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, insets.top).padding(.bottom, insets.bottom)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}

private struct EmptyFeed: View {
    let topic: String?
    let savedOnly: Bool
    let onAdd: () -> Void
    let onConnect: () -> Void
    @Environment(Engine.self) private var engine

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            if savedOnly {
                Image(systemName: "bookmark").font(.system(size: 30, weight: .semibold))
                    .frame(width: 80, height: 80).glassEffect(.regular, in: .circle)
                Text("Nothing saved yet").font(.system(size: 28, weight: .bold))
                Text("Tap the bookmark on a moment to keep it here.").foregroundStyle(Color.t2).multilineTextAlignment(.center)
            } else {
                LogoMark(size: 88)
                Text(topic.map { "Nothing left in \($0)" } ?? "Your feed is empty").font(.system(size: 28, weight: .bold))
                if engine.busyCount > 0 && topic == nil {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("Finding moments in \(engine.busyCount) video\(engine.busyCount == 1 ? "" : "s")…").foregroundStyle(Color.t2)
                    }
                    Text("They show up here as soon as they're ready.").font(.footnote).foregroundStyle(Color.t3)
                } else {
                    Text(topic != nil ? "Pick another topic, or add more videos."
                         : "Add a few long YouTube videos. Their best moments show up here in a minute or two.")
                        .foregroundStyle(Color.t2).multilineTextAlignment(.center)
                    if !engine.hasKey {
                        PrimaryButton(title: "Connect Gemini", action: onConnect).frame(maxWidth: 260).padding(.top, 6)
                        Text("Step 1 of 2. Then add videos.").font(.footnote).foregroundStyle(Color.t3)
                    } else {
                        PrimaryButton(title: "Add videos", action: onAdd).frame(maxWidth: 260).padding(.top, 6)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
