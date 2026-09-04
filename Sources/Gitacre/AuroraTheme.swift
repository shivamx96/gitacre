import SwiftUI

enum GitacreAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum MenuBarDisplayMode: String, CaseIterable, Identifiable {
    case glyph
    case glyphAndCount

    var id: Self { self }
    var title: String { self == .glyph ? "Glyph" : "Glyph + count" }
}

enum GitacreTheme {
    static let accentLight = Color(red: 74 / 255, green: 88 / 255, blue: 196 / 255)
    static let accentDark = Color(red: 139 / 255, green: 150 / 255, blue: 232 / 255)

    static func surface(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 34 / 255, green: 35 / 255, blue: 39 / 255)
            : Color(red: 253 / 255, green: 253 / 255, blue: 252 / 255)
    }

    static func surfaceSunk(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 38 / 255, green: 40 / 255, blue: 44 / 255)
            : Color(red: 241 / 255, green: 241 / 255, blue: 238 / 255)
    }

    static func chrome(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 25 / 255, green: 26 / 255, blue: 29 / 255)
            : Color(red: 247 / 255, green: 247 / 255, blue: 245 / 255)
    }

    static func primaryInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 233 / 255, green: 234 / 255, blue: 236 / 255)
            : Color(red: 25 / 255, green: 26 / 255, blue: 28 / 255)
    }

    static func secondaryInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 155 / 255, green: 160 / 255, blue: 168 / 255)
            : Color(red: 92 / 255, green: 97 / 255, blue: 106 / 255)
    }

    static func tertiaryInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 113 / 255, green: 118 / 255, blue: 126 / 255)
            : Color(red: 140 / 255, green: 145 / 255, blue: 153 / 255)
    }

    static func hairline(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.09) : Color(red: 20 / 255, green: 22 / 255, blue: 26 / 255).opacity(0.10)
    }

    static func separator(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.06) : Color(red: 20 / 255, green: 22 / 255, blue: 26 / 255).opacity(0.06)
    }

    static func hover(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white.opacity(0.05) : Color(red: 20 / 255, green: 22 / 255, blue: 26 / 255).opacity(0.045)
    }

    static func selected(_ scheme: ColorScheme) -> Color {
        accent(scheme).opacity(scheme == .dark ? 0.15 : 0.09)
    }

    static func segmentSelection(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 49 / 255, green: 51 / 255, blue: 57 / 255) : .white
    }

    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? accentDark : accentLight
    }

    static func clean(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 111 / 255, green: 165 / 255, blue: 126 / 255)
            : Color(red: 63 / 255, green: 125 / 255, blue: 83 / 255)
    }

    static func drift(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 193 / 255, green: 163 / 255, blue: 102 / 255)
            : Color(red: 138 / 255, green: 106 / 255, blue: 40 / 255)
    }

    static func blocked(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 208 / 255, green: 138 / 255, blue: 131 / 255)
            : Color(red: 162 / 255, green: 79 / 255, blue: 73 / 255)
    }
}

struct BrandMark: View {
    @Environment(\.colorScheme) private var colorScheme
    var size: CGFloat = 19

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .fill(GitacreTheme.accent(colorScheme))

            BranchMark(strokeColor: .white.opacity(0.96), lineWidth: max(1.15, size * 0.095))
                .padding(size * 0.24)

            RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                .strokeBorder(.white.opacity(0.04), lineWidth: 0.5)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct BranchMark: View {
    let strokeColor: Color
    let lineWidth: CGFloat

    var body: some View {
        Canvas { context, size in
            let trunkX = size.width * 0.35
            let top = size.height * 0.16
            let middle = size.height * 0.51
            let bottom = size.height * 0.84
            let spurX = size.width * 0.72

            var path = Path()
            path.move(to: CGPoint(x: trunkX, y: top))
            path.addLine(to: CGPoint(x: trunkX, y: bottom))
            path.move(to: CGPoint(x: trunkX, y: middle))
            path.addCurve(
                to: CGPoint(x: spurX, y: top),
                control1: CGPoint(x: spurX, y: middle),
                control2: CGPoint(x: spurX, y: top)
            )
            context.stroke(path, with: .color(strokeColor), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))

            let radius = max(1.25, size.width * 0.115)
            for point in [
                CGPoint(x: trunkX, y: top),
                CGPoint(x: trunkX, y: bottom),
                CGPoint(x: spurX, y: top)
            ] {
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(strokeColor)
                )
            }
        }
    }
}

struct QuietIconButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(configuration.isPressed ? GitacreTheme.primaryInk(colorScheme) : GitacreTheme.tertiaryInk(colorScheme))
            .frame(width: 22, height: 22)
            .background(GitacreTheme.hover(colorScheme).opacity(configuration.isPressed ? 1 : 0), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(prominent ? Color.white : GitacreTheme.primaryInk(colorScheme))
            .padding(.horizontal, 10)
            .frame(height: 23)
            .background(
                prominent ? GitacreTheme.accent(colorScheme) : GitacreTheme.segmentSelection(colorScheme),
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .overlay {
                if !prominent {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(GitacreTheme.hairline(colorScheme), lineWidth: 0.5)
                }
            }
            .opacity(configuration.isPressed ? 0.74 : 1)
    }
}

struct Hairline: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle().fill(GitacreTheme.separator(colorScheme)).frame(height: 1)
    }
}
