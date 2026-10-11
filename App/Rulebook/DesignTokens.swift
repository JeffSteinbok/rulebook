import SwiftUI

/// Design tokens for RuleBook, from the Modernist system cooled to blue.
///
/// Single source of truth: no view should carry a literal color or point size.
enum DS {

    // MARK: - Color
    //
    // Every role is light/dark aware. Dark is NOT an inversion — iOS dark mode
    // is layered greys with the accent lifted, because #1A4ED8 on near-black
    // falls under 4.5:1. Every pair below was checked at 4.5:1 for body text
    // and 3:1 for headline-scale.
    //
    // Prefer these over an asset catalog so the values are readable and
    // reviewable in one place; move them to Colors.xcassets if the team wants
    // Xcode's colour picker.

    enum Palette {
        /// Fills and selection. Darker in dark mode so white-on-accent still
        /// clears 4.5:1 — the lifted #5C86F7 only reached 3.38:1.
        static let accent = dynamic(light: 0x1A4ED8, dark: 0x3B6AE8)
        static let accent600 = dynamic(light: 0x1540C0, dark: 0x5C86F7)
        /// Accent-colored *text*: the base accent is only 3:1 on either ground.
        static let accent700 = dynamic(light: 0x0F3196, dark: 0x9DB9FC)
        static let accentWash = dynamic(light: 0xEFF3FF, dark: 0x1A2340)

        static let ground   = dynamic(light: 0xF1F3F7, dark: 0x12151C)
        static let surface  = dynamic(light: 0xFFFFFF, dark: 0x1C2027)
        static let ink      = dynamic(light: 0x1B1F28, dark: 0xF2F4F8)
        static let ink80    = dynamic(light: 0x414855, dark: 0xC9CED7)
        /// Secondary text. 0x78808F was only 3.58:1 on the light ground.
        static let ink60    = dynamic(light: 0x5B6371, dark: 0xA7ADB8)
        /// Non-text only — dividers, empty checkmarks, disabled glyphs.
        static let ink40    = dynamic(light: 0x969EAE, dark: 0x626A78)
        static let hairline = dynamic(light: 0xD5DAE4, dark: 0x2C313A)
        static let fill     = dynamic(light: 0xE9ECF2, dark: 0x22262E)

        /// Destructive FILL — white on this clears 4.5:1.
        static let destructive = dynamic(light: 0xD92B1C, dark: 0xFF6A5A)
        /// Destructive INK, for text on the ground. The fill red only reaches
        /// 4.38:1 as text, so the two roles can't share one value.
        static let destructiveInk = dynamic(light: 0xB3251A, dark: 0xFF6A5A)
        static let destructiveWash = dynamic(light: 0xFDECEB, dark: 0x2E1A18)

        static let warning     = dynamic(light: 0xA15C00, dark: 0xE0A44A)
        static let warningWash = dynamic(light: 0xFDF3E3, dark: 0x2C2317)

        /// The toggle knob and other always-on-fill chrome.
        static let knob = dynamic(light: 0xFFFFFF, dark: 0xF2F4F8)

        /// Ink ON a destructive or warning FILL. White works in light mode,
        /// but the lifted dark fills are too bright for it — #FF6A5A gives
        /// white 2.81:1 and #E0A44A only 2.19:1. Dark mode uses dark ink.
        static let onDestructive = dynamic(light: 0xFFFFFF, dark: 0x12151C)
        static let onWarning = dynamic(light: 0xFFFFFF, dark: 0x12151C)

        private static func dynamic(light: UInt32, dark: UInt32) -> Color {
            Color(UIColor { $0.userInterfaceStyle == .dark
                ? UIColor(hex: dark)
                : UIColor(hex: light) })
        }
    }

    // MARK: - Type
    //
    // Archivo, bundled with the app. Add the files to the target and list them
    // under UIAppFonts in Info.plist, or these fall back to the system face.
    //
    // Every face is registered `relativeTo:` a text style, so it scales with
    // the user's Dynamic Type setting. Never use `.custom(_:size:)` without a
    // relative style — it produces text that ignores accessibility settings.

    enum Font {
        static let screenTitle   = SwiftUI.Font.custom("Archivo-Bold", size: 34, relativeTo: .largeTitle)
        static let sectionTitle  = SwiftUI.Font.custom("Archivo-Bold", size: 30, relativeTo: .title)
        /// The list's title, sharing the navigation bar's row with its buttons.
        static let barTitle      = SwiftUI.Font.custom("Archivo-Bold", size: 28, relativeTo: .title2)
        static let display       = SwiftUI.Font.custom("Archivo-Black", size: 40, relativeTo: .largeTitle)
        static let rowTitle      = SwiftUI.Font.custom("Archivo-Bold", size: 17, relativeTo: .body)
        static let button        = SwiftUI.Font.custom("Archivo-SemiBold", size: 17, relativeTo: .body)
        static let body          = SwiftUI.Font.custom("Archivo-Regular", size: 15, relativeTo: .subheadline)
        static let secondary     = SwiftUI.Font.custom("Archivo-SemiBold", size: 15, relativeTo: .subheadline)
        static let caption       = SwiftUI.Font.custom("Archivo-Regular", size: 13, relativeTo: .footnote)
        static let captionBold   = SwiftUI.Font.custom("Archivo-SemiBold", size: 13, relativeTo: .footnote)
        static let orderNumber   = SwiftUI.Font.custom("Archivo-Bold", size: 19, relativeTo: .body)
        /// Section headers and state pills — the only uppercase text in the app.
        static let sectionHeader = SwiftUI.Font.custom("Archivo-Bold", size: 11, relativeTo: .caption2)
        static let pill          = SwiftUI.Font.custom("Archivo-Bold", size: 11, relativeTo: .caption2)
    }

    // MARK: - Metrics

    enum Metric {
        static let gutter: CGFloat = 20
        /// A floor, not a fixed height — rows grow with Dynamic Type.
        static let rowMinHeight: CGFloat = 68
        /// Wide enough for the issue dot plus a two-digit order number.
        static let orderColumn: CGFloat = 42
        static let controlRadius: CGFloat = 12
        /// Also a floor: `PrimaryButton` grows when the label wraps.
        static let controlHeight: CGFloat = 56
        static let hairline: CGFloat = 1
        static let sectionTracking: CGFloat = 1.9   // ~0.18em at 11pt

        /// Above this size class, trailing accessories and side-by-side layouts
        /// stop fitting and views should stack instead.
        static func isAccessibilitySize(_ size: DynamicTypeSize) -> Bool {
            size >= .accessibility1
        }
    }
}

// MARK: - Section header

/// The app's one uppercase treatment: small, grey, wide-tracked.
struct SectionHeader: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(DS.Font.sectionHeader)
            .tracking(DS.Metric.sectionTracking)
            .foregroundStyle(DS.Palette.ink60)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DS.Metric.gutter)
            .padding(.bottom, 8)
            // As a List section header the system adds its own inset on top
            // of the gutter, which pushed headers in past the rows they head.
            // The gutter alone lines them up; outside a List this is inert.
            .listRowInsets(EdgeInsets())
    }
}

// MARK: - Primary CTA

struct PrimaryButton: View {
    let title: String
    var trailing: String? = "arrow.right"
    let action: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(DS.Font.button)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                // The chevron is decoration; at accessibility sizes the label
                // needs the room more than the arrow does.
                if let trailing, !DS.Metric.isAccessibilitySize(typeSize) {
                    Image(systemName: trailing)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, DS.Metric.gutter)
            .padding(.vertical, 14)
            .frame(minHeight: DS.Metric.controlHeight)
            .frame(maxWidth: .infinity)
            .background(DS.Palette.accent, in: .rect(cornerRadius: DS.Metric.controlRadius))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - State pill

struct StatePill: View {
    let isEnabled: Bool

    var body: some View {
        Text(isEnabled ? "ENABLED" : "DISABLED")
            .font(DS.Font.pill)
            .tracking(1.1)
            .foregroundStyle(isEnabled ? .white : DS.Palette.ink80)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background {
                if isEnabled {
                    Capsule().fill(DS.Palette.accent)
                } else {
                    Capsule().strokeBorder(DS.Palette.ink40, lineWidth: 1.5)
                }
            }
            // The pill duplicates what the toggle on the detail screen says;
            // one announcement is enough.
            .accessibilityLabel(isEnabled ? "Enabled" : "Disabled")
    }
}

/// The compact form of `StatePill` for dense list rows — filled when enabled,
/// hollow when not. Always paired with a legend under the list, since a dot
/// alone can't say which is which.
struct StateDot: View {
    let isEnabled: Bool

    var body: some View {
        Circle()
            .strokeBorder(
                isEnabled ? DS.Palette.accent : DS.Palette.ink40,
                lineWidth: 1.5
            )
            .background(isEnabled ? DS.Palette.accent : .clear, in: .circle)
            .frame(width: 9, height: 9)
            .accessibilityLabel(isEnabled ? "Enabled" : "Disabled")
    }
}

// MARK: - Key-value row

/// The repeated "SERVER · outlook.office365.com" row. Stacks at accessibility
/// sizes, where a label and value side by side leave neither enough width.
struct DetailRow: View {
    let key: String
    let value: String
    /// Styles the value as a link — accent, underlined, with an outward
    /// arrow — so a tappable row doesn't read like plain text.
    var isLink = false

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                label
                Spacer(minLength: 12)
                valueText
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 4) {
                label
                valueText
            }
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var valueText: some View {
        if isLink {
            HStack(spacing: 4) {
                Text(value).underline()
                Image(systemName: "arrow.up.right")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .font(DS.Font.secondary)
            .foregroundStyle(DS.Palette.accent700)
        } else {
            Text(value).font(DS.Font.secondary)
        }
    }

    private var label: some View {
        Text(key.uppercased())
            .font(DS.Font.sectionHeader)
            .tracking(DS.Metric.sectionTracking)
            .foregroundStyle(DS.Palette.ink60)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8)  & 0xFF) / 255,
            blue:  Double(hex & 0xFF) / 255
        )
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red:   CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8)  & 0xFF) / 255,
            blue:  CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
