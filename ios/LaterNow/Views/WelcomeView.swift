import SwiftUI

struct WelcomeView: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            LogoMark(size: 112)
                .shadow(color: .white.opacity(0.08), radius: 30)
            Text("Later Now")
                .font(.system(size: 40, weight: .bold))
                .tracking(-0.8)
                .padding(.top, 28)
            Text("Your long videos and podcasts, as a scroll of short moments. It learns what you like from how you watch.")
                .font(.title3)
                .foregroundStyle(Color.t2)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
                .padding(.horizontal, 36)
            Spacer()
            VStack(alignment: .leading, spacing: 18) {
                point("rectangle.stack", "Long videos become 25 to 90 second moments")
                point("sparkles", "Picked by Gemini, with your own free key")
                point("lock", "Everything stays on this iPhone")
            }
            .padding(.horizontal, 40)
            Spacer()
            PrimaryButton(title: "Start watching", action: onStart)
                .padding(.horizontal, 24)
            Text("Best with sound on").font(.footnote).foregroundStyle(Color.t3).padding(.top, 14).padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44).glassEffect(.regular, in: .circle)
            Text(text).font(.body).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
