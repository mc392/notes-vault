import SwiftUI

/// The launch screen, and the app's privacy shield.
///
/// GroundWork's own splash, translated rather than copied: the same sage ground, the same
/// rise-and-settle, the same wordmark treatment — with this app's mark, the page with a
/// green band and GroundWork's leaf stamped on it, in place of their three bars. Side by
/// side on a phone the two read as one practice's apps; nobody has to be told which is
/// which.
///
/// It has a second job beyond looking like something. It is what covers the app whenever
/// the app is not being looked at by somebody who has proved they should be — while the
/// initial checks run, and every time the app leaves the foreground. Until then this is
/// *all* there is to see: no client codes, no dates, no count of notes.
struct SplashView: View {
    /// What is being waited for, when the wait is long enough to be worth explaining.
    var status: String?

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var risen = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: Brand.ground(scheme),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 30) {
                NotesPageMark()
                    .frame(width: markSize, height: markSize)
                    .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.10), radius: 18, y: 8)

                VStack(spacing: 6) {
                    (Text("Ground").foregroundStyle(Brand.wordPrimary(scheme))
                        + Text("Work").foregroundStyle(Brand.wordSecondary(scheme)))
                        .font(.system(size: 34, weight: .heavy, design: .default))
                        .kerning(-0.4)
                    Text("NOTES")
                        .font(.system(size: 14, weight: .semibold))
                        .kerning(4.2)
                        .foregroundStyle(Brand.wordSecondary(scheme))
                }

                if let status {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(Brand.wordSecondary(scheme))
                        Text(status)
                            .font(.footnote)
                            .foregroundStyle(Brand.wordSecondary(scheme))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 4)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, 32)
            .offset(y: -18)
            .opacity(risen ? 1 : 0)
            .offset(y: risen ? 0 : 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status ?? "GroundWork Notes")
        .onAppear {
            guard !reduceMotion else {
                risen = true
                return
            }
            withAnimation(.spring(response: 0.62, dampingFraction: 0.82)) { risen = true }
        }
    }

    private var markSize: CGFloat {
        #if os(macOS)
        140
        #else
        132
        #endif
    }
}

/// This app's icon, drawn rather than loaded: the asset catalogue's PNGs are square,
/// opaque and sized for a home screen, and a launch screen wants the mark itself at
/// whatever size the window happens to be.
///
/// The geometry is `tools/icon.py`'s, in the same 512-unit space, so the two cannot drift
/// apart without somebody noticing. The leaf is GroundWork's own Bézier, not a redrawing.
private struct NotesPageMark: View {
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let page = Path(
                roundedRect: CGRect(x: 0, y: 0, width: side, height: side),
                cornerRadius: side * 0.205,
                style: .continuous
            )
            context.fill(page, with: .color(Brand.paper))
            context.clip(to: page)

            context.fill(
                Path(CGRect(x: 0, y: 0, width: side, height: side * 0.205)),
                with: .color(Brand.brand)
            )

            // Four ruled lines rather than a dense ruling: at 132pt the page has to read as
            // a page, and five would be a grey band.
            for index in 0..<4 {
                let y = side * (0.300 + Double(index) * 0.202)
                var rule = Path()
                rule.move(to: CGPoint(x: side * 0.130, y: y))
                rule.addLine(to: CGPoint(x: side * 0.870, y: y))
                context.stroke(
                    rule,
                    with: .color(Brand.rule),
                    style: StrokeStyle(lineWidth: side * 0.016, lineCap: .round)
                )
            }

            let leaf = Self.leaf(in: side)
            context.fill(leaf.outline, with: .color(Brand.brand))
            context.stroke(
                leaf.midrib,
                with: .color(Brand.vein),
                // 24 units wide in the icon's 512-unit space, at the icon's own scale.
                style: StrokeStyle(lineWidth: side * 0.00108 * 24, lineCap: .round)
            )
        }
    }

    /// The leaf, scaled about its own centre, rotated and placed exactly as the icon does.
    private static func leaf(in side: CGFloat) -> (outline: Path, midrib: Path) {
        let scale = side * 0.00108
        let centre = CGPoint(x: side * 0.690, y: side * 0.735)
        let transform = CGAffineTransform(translationX: centre.x, y: centre.y)
            .rotated(by: 34 * .pi / 180)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -256, y: -256)

        var outline = Path()
        outline.move(to: CGPoint(x: 256, y: 84))
        outline.addCurve(
            to: CGPoint(x: 256, y: 428),
            control1: CGPoint(x: 368, y: 150),
            control2: CGPoint(x: 368, y: 362)
        )
        outline.addCurve(
            to: CGPoint(x: 256, y: 84),
            control1: CGPoint(x: 144, y: 362),
            control2: CGPoint(x: 144, y: 150)
        )
        outline.closeSubpath()

        var midrib = Path()
        midrib.move(to: CGPoint(x: 256, y: 112))
        midrib.addLine(to: CGPoint(x: 256, y: 404))

        return (outline.applying(transform), midrib.applying(transform))
    }
}

/// The palette, hard-coded rather than taken from the colour scheme.
///
/// This is the product's identity: it looks the same whatever the phone is set to, in the
/// same way GroundWork's own launch screen does. Values are the ones in `tools/icon.py`
/// and GroundWork's `#splash`, not approximations of them.
enum Brand {
    static let brand = Color(red: 0x5C / 255, green: 0x7A / 255, blue: 0x6D / 255)
    static let deep = Color(red: 0x3C / 255, green: 0x4F / 255, blue: 0x44 / 255)
    static let paper = Color(red: 0xFB / 255, green: 0xFD / 255, blue: 0xFB / 255)
    static let rule = Color(red: 0xDC / 255, green: 0xE6 / 255, blue: 0xDF / 255)
    static let vein = Color(red: 0xF5 / 255, green: 0xF8 / 255, blue: 0xF5 / 255)
    static let mistWord = Color(red: 0xB7 / 255, green: 0xC7 / 255, blue: 0xBC / 255)

    static func ground(_ scheme: ColorScheme) -> [Color] {
        scheme == .dark
            ? [Color(red: 0x49 / 255, green: 0x62 / 255, blue: 0x56 / 255),
               Color(red: 0x38 / 255, green: 0x49 / 255, blue: 0x3F / 255),
               Color(red: 0x26 / 255, green: 0x33 / 255, blue: 0x2B / 255)]
            : [Color(red: 0xF5 / 255, green: 0xF8 / 255, blue: 0xF5 / 255),
               Color(red: 0xEF / 255, green: 0xF3 / 255, blue: 0xF0 / 255),
               Color(red: 0xE4 / 255, green: 0xEB / 255, blue: 0xE5 / 255)]
    }

    static func wordPrimary(_ scheme: ColorScheme) -> Color { scheme == .dark ? paper : deep }
    static func wordSecondary(_ scheme: ColorScheme) -> Color { scheme == .dark ? mistWord : brand }
}

#Preview {
    SplashView(status: "Checking it's you…")
}
