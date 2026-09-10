import SwiftUI

/// A short caption line with a moving light sweep.
///
/// Used under the "Lyrics" header while a lower-fidelity result is on screen
/// but a higher-fidelity provider is still searching.
struct ShimmerLine: View {
    let text: String

    @State private var phase: CGFloat = -1

    var body: some View {
        Text(self.text)
            .font(.subheadline)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .overlay {
                GeometryReader { proxy in
                    let width = proxy.size.width
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.85), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: max(40, width * 0.45))
                    .offset(x: self.phase * width * 1.5)
                }
                .blendMode(.plusLighter)
                .allowsHitTesting(false)
            }
            .mask {
                Text(self.text)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .onAppear {
                withAnimation(.linear(duration: 1.25).repeatForever(autoreverses: false)) {
                    self.phase = 1
                }
            }
    }
}

#Preview {
    ShimmerLine(text: "Still searching for lyrics")
        .padding()
}