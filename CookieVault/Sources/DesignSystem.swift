import SwiftUI

// MARK: - Design System
//
// Central tokens + reusable components so the whole app shares one visual
// language. Prefer these over ad-hoc Color(hex:)/padding values in views.

enum Theme {
    // Backgrounds (dark, subtle blue undertone) — darkest → lightest
    static let bg0       = Color(hex: "0A0B10")   // app canvas
    static let bg1       = Color(hex: "0E1017")   // rails / toolbars
    static let surface   = Color(hex: "151824")   // cards
    static let surfaceHi = Color(hex: "1D2130")   // hover / selected
    static let inset     = Color(hex: "0B0C13")   // code / value wells

    // Hairlines
    static let border    = Color.white.opacity(0.07)
    static let borderHi  = Color.white.opacity(0.14)

    // Text
    static let textPri   = Color(hex: "F2F4FA")
    static let textSec   = Color(hex: "9AA1B4")
    static let textTer   = Color(hex: "626A7D")

    // Brand + tiers
    static let accent    = Color(hex: "7C6AF7")
    static let accent2   = Color(hex: "9B8AF8")
    static let gold      = Color(hex: "F5A524")
    static let blue      = Color(hex: "38BDF8")

    // Status
    static let green     = Color(hex: "22C55E")
    static let red       = Color(hex: "F0524B")
    static let amber     = Color(hex: "F59E0B")
    static let orange    = Color(hex: "F97316")
    static let yellow    = Color(hex: "EAB308")
    static let pink      = Color(hex: "EC4899")

    static let accentGrad = LinearGradient(colors: [accent, accent2],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
    static let goldGrad   = LinearGradient(colors: [Color(hex: "F5A524"), Color(hex: "FBBF24")],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)

    // Radii
    static let rSm: CGFloat = 8
    static let rMd: CGFloat = 12
    static let rLg: CGFloat = 18

    static func tierColor(_ tier: AccountTier) -> Color {
        switch tier {
        case .premium: return gold
        case .free:    return blue
        case .unknown: return accent2
        }
    }
}

// MARK: - Hover tracking

final class Hover: ObservableObject { @Published var on = false }

// MARK: - Card container

struct CardStyle: ViewModifier {
    var padding: CGFloat = 16
    var radius: CGFloat = Theme.rMd
    var fill: Color = Theme.surface
    var stroke: Color = Theme.border
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(stroke, lineWidth: 1))
    }
}
extension View {
    func cvCard(padding: CGFloat = 16, radius: CGFloat = Theme.rMd,
                fill: Color = Theme.surface, stroke: Color = Theme.border) -> some View {
        modifier(CardStyle(padding: padding, radius: radius, fill: fill, stroke: stroke))
    }
}

// MARK: - Icon tile (rounded gradient/tinted square with an SF Symbol)
//
// A single glyph container used everywhere (sidebar, cards, headers). The look is
// a soft "squircle" with a top highlight for gentle curvature, a hairline edge so
// the tile reads crisply on dark surfaces, and — when filled — a colored glow plus
// a subtle glyph shadow for depth.

struct IconTile: View {
    let symbol: String
    var tint: Color = Theme.accent
    var size: CGFloat = 44
    var filled: Bool = false        // true = gradient fill + white glyph
    var body: some View {
        let corner = size * 0.28
        ZStack {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(filled
                      ? AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.98), tint.opacity(0.68)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                      : AnyShapeStyle(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.11)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing)))
                .frame(width: size, height: size)
                // Top-edge sheen for a subtle glassy curvature.
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white.opacity(filled ? 0.30 : 0.12), .clear],
                                             startPoint: .top, endPoint: .center))
                        .blendMode(.plusLighter)
                )
                // Crisp hairline edge.
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(filled ? Color.white.opacity(0.20) : tint.opacity(0.32), lineWidth: 1)
                )
                .shadow(color: filled ? tint.opacity(0.42) : .clear, radius: size * 0.22, y: 3)
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundColor(filled ? .white : tint)
                .shadow(color: filled ? Color.black.opacity(0.20) : .clear, radius: 1, y: 1)
        }
    }
}

// MARK: - Pills & badges

struct Pill: View {
    let text: String
    var systemImage: String? = nil
    var tint: Color = Theme.accent
    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 8, weight: .bold)) }
            Text(text).font(.system(size: 9.5, weight: .bold))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.15)))
        .overlay(Capsule().stroke(tint.opacity(0.28), lineWidth: 1))
        .lineLimit(1)
    }
}

struct TierBadge: View {
    let tier: AccountTier
    var plan: String? = nil
    var body: some View {
        let isPremium = tier == .premium
        Pill(text: (plan ?? (isPremium ? "Premium" : "Free")).uppercased(),
             systemImage: isPremium ? "crown.fill" : "tag.fill",
             tint: Theme.tierColor(tier))
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9.5, weight: .bold))
            .tracking(1.1)
            .foregroundColor(Theme.textTer)
    }
}

// A tiny status dot + label ("Active session" / "Expired")
struct StatusDot: View {
    let ok: Bool
    var okText = "Active", badText = "Expired"
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ok ? Theme.green : Theme.red).frame(width: 6, height: 6)
                .shadow(color: (ok ? Theme.green : Theme.red).opacity(0.8), radius: 3)
            Text(ok ? okText : badText)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(ok ? Theme.green : Theme.red)
        }
    }
}

// MARK: - Buttons

/// Primary filled/gradient action button label.
struct FilledButton: View {
    let title: String
    var systemImage: String? = nil
    var gradient: LinearGradient = Theme.accentGrad
    var glow: Color = Theme.accent
    var compact: Bool = false
    var body: some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: compact ? 11 : 13, weight: .bold)) }
            Text(title).font(.system(size: compact ? 11 : 13, weight: .bold))
        }
        .foregroundColor(.white)
        .padding(.horizontal, compact ? 12 : 16).padding(.vertical, compact ? 7 : 10)
        .background(
            RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous).fill(gradient)
                // Top sheen for a raised, tactile feel.
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear],
                                             startPoint: .top, endPoint: .center))
                        .blendMode(.plusLighter)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
        )
        .shadow(color: glow.opacity(0.38), radius: 9, y: 3)
    }
}

/// Neutral, low-emphasis button label.
struct GhostButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = Theme.textSec
    var body: some View {
        HStack(spacing: 5) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
            Text(title).font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(tint)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous).stroke(Theme.border, lineWidth: 1))
    }
}

/// Small square icon button (copy / delete / etc).
struct IconButton: View {
    let symbol: String
    var tint: Color = Theme.textSec
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(tint.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Color(hex:) — single definition for the whole app

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 124, 106, 247)
        }
        self.init(.sRGB,
                  red: Double(r) / 255, green: Double(g) / 255,
                  blue: Double(b) / 255, opacity: Double(a) / 255)
    }
}
