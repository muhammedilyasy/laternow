import SwiftUI

extension Color {
    static let likeRed = Color(red: 1, green: 0.216, blue: 0.373)     // #ff375f
    static let ok = Color(red: 0.188, green: 0.82, blue: 0.345)       // #30d158
    static let warn = Color(red: 1, green: 0.84, blue: 0.04)          // #ffd60a
    static let bad = Color(red: 1, green: 0.271, blue: 0.227)         // #ff453a
    static let t2 = Color(white: 0.92).opacity(0.64)
    static let t3 = Color(white: 0.92).opacity(0.38)
}

/// The Later Now mark: a stack of cards with a play button, drawn from icon.svg (128-unit grid).
struct LogoMark: View {
    var size: CGFloat = 96

    var body: some View {
        let u = size / 112   // the tile is 112 units wide inside the 128 grid
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 26 * u, style: .continuous).fill(.black)
            RoundedRectangle(cornerRadius: 26 * u, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: max(1, u))
            bar(x: 38, y: 14, w: 36, opacity: 0.3, u: u)
            bar(x: 32, y: 26, w: 48, opacity: 0.55, u: u)
            RoundedRectangle(cornerRadius: 14 * u, style: .continuous).fill(.white)
                .frame(width: 60 * u, height: 60 * u).offset(x: 26 * u, y: 38 * u)
            PlayTriangle().fill(.black).frame(width: 22 * u, height: 27 * u).offset(x: 49 * u, y: 54.5 * u)
        }
        .frame(width: size, height: size)
    }

    private func bar(x: CGFloat, y: CGFloat, w: CGFloat, opacity: Double, u: CGFloat) -> some View {
        Capsule().fill(.white.opacity(opacity)).frame(width: w * u, height: 8 * u).offset(x: x * u, y: y * u)
    }
}

/// A play triangle with softly rounded corners.
struct PlayTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let c = min(r.width, r.height) * 0.12
        p.move(to: CGPoint(x: r.minX, y: r.minY + c))
        p.addQuadCurve(to: CGPoint(x: r.minX + c * 1.2, y: r.minY + c * 0.25), control: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - c * 0.8, y: r.midY - c * 0.55))
        p.addQuadCurve(to: CGPoint(x: r.maxX - c * 0.8, y: r.midY + c * 0.55), control: CGPoint(x: r.maxX, y: r.midY))
        p.addLine(to: CGPoint(x: r.minX + c * 1.2, y: r.maxY - c * 0.25))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - c), control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

/// A round Liquid Glass button with an SF Symbol.
struct GlassIconButton: View {
    let symbol: String
    var size: CGFloat = 50
    var tint: Color = .white
    var label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// A full-width primary button.
struct PrimaryButton: View {
    let title: String
    var busy = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if busy { ProgressView().tint(.black) }
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(.glassProminent)
        .tint(.white)
        .foregroundStyle(.black)
        .controlSize(.large)
        .disabled(busy)
    }
}

/// A short message that floats in and fades.
struct Toast: View {
    @Binding var text: String?

    var body: some View {
        if let t = text {
            Text(t)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: t) {
                    try? await Task.sleep(for: .seconds(1.8))
                    withAnimation(.smooth) { text = nil }
                }
        }
    }
}

/// Status dot colours for videos in the library.
func statusColor(_ v: Video) -> Color {
    switch v.status {
    case .ready: .ok
    case .failed: .bad
    case .waiting, .needsKey: .warn
    case .queued: .t3
    case .fetching, .finding: .white
    }
}

func statusLabel(_ v: Video, moments: Int) -> String {
    switch v.status {
    case .ready:
        let e = v.error ?? ""
        return "\(moments) moments" + (e.isEmpty ? "" : e.hasPrefix("No captions") ? " · no captions" : " · plain chunks")
    case .failed: return v.error ?? "Failed"
    case .waiting:
        let e = (v.error ?? "Waiting").rxReplace(#"\. (Continues|Retrying) automatically\.?$"#, with: "")
        return e + (v.retryAt > 0 ? ", continues \(when(v.retryAt))" : "")
    case .needsKey: return "Waiting for your Gemini key"
    case .queued: return "Queued"
    case .fetching: return "Fetching captions…"
    case .finding: return "Finding moments…"
    }
}
