import AppKit
import SwiftUI

/// Shown while Android starts or restarts. Uses Splash.png/.jpg/.webp from the app's resources
/// (copied from Assets/ by the build script), else a plain MyEmu screen.
struct SplashView: View {
    let status: String

    private static let image: NSImage? = ["png", "jpg", "jpeg", "webp"].lazy
        .compactMap { Bundle.main.url(forResource: "Splash", withExtension: $0) }
        .compactMap { NSImage(contentsOf: $0) }
        .first

    var body: some View {
        ZStack(alignment: .bottom) {
            if let image = Self.image {
                // Whole image fitted (portrait windows too), over a blurred fill so there are no bars.
                Color.clear // takes exactly the window's size; the filled image would grow past it
                    .overlay { Image(nsImage: image).resizable().aspectRatio(contentMode: .fill) }
                    .blur(radius: 30, opaque: true).clipped()
                    .accessibilityHidden(true)
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityHidden(true)
            } else {
                fallback
            }
            HStack(spacing: 8) {
                if !status.hasPrefix("Error") && !status.hasPrefix("Couldn't") { ProgressView().controlSize(.small) }
                Text(status == "Running" ? "Starting Android…" : status)
                    .font(.callout)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var fallback: some View {
        LinearGradient(colors: [Color(red: 0.93, green: 0.99, blue: 0.85), Color(red: 0.55, green: 0.88, blue: 0.75)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 64))
                    Text("MyEmu").font(.system(size: 44, weight: .bold, design: .rounded))
                    Text("Android Emulator for Gaming").font(.headline)
                }
                .foregroundStyle(Color(red: 0.1, green: 0.45, blue: 0.35))
            }
    }
}
