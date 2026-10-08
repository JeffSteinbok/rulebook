import SwiftUI
import RulebookKit

/// What someone sees when the mailbox has no rules at all.
///
/// This is a real first-run state, not an edge case: plenty of people have
/// never opened Outlook's rules screen. So it can't be a shrug — it has to
/// explain what a rule *is* and offer a concrete first one.
///
/// Deliberately not the same as the search-empty state, which is a dead end to
/// back out of. This one is an invitation.
struct EmptyRulesView: View {
    let profile: ProviderProfile
    let onCreate: (RulePreset?) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("No rules yet")
                    .font(DS.Font.sectionTitle)
                    .foregroundStyle(DS.Palette.ink)

                // Says what a rule does before asking anyone to make one.
                Text("A rule is a job your mail server does before you ever see a message — filing it in a folder, marking it read, flagging it. It runs whether your phone is on or not.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.ink60)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(text: "A good first rule")
                    .padding(.horizontal, 0)

                ForEach(RulePreset.all.prefix(3)) { preset in
                    Button { onCreate(preset) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preset.name)
                                    .font(DS.Font.rowTitle)
                                    .foregroundStyle(DS.Palette.ink)
                                    .multilineTextAlignment(.leading)
                                Text(preset.rationale)
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Palette.ink60)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 8)
                            if !DS.Metric.isAccessibilitySize(typeSize) {
                                Image(systemName: "chevron.right")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(DS.Palette.ink40)
                                    .padding(.top, 3)
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.Palette.surface, in: .rect(cornerRadius: DS.Metric.controlRadius))
                        .overlay {
                            RoundedRectangle(cornerRadius: DS.Metric.controlRadius)
                                .strokeBorder(DS.Palette.hairline, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Button("Start from scratch instead") { onCreate(nil) }
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Palette.accent700)

            Spacer(minLength: 0)
        }
        .padding(DS.Metric.gutter)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Search and filter came back empty. A dead end — the only useful move is out.
struct NoMatchesView: View {
    let isIssuesFilter: Bool
    let onClear: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isIssuesFilter ? "Every rule is running cleanly." : "No rule matches that search.")
                .font(DS.Font.rowTitle)
                .foregroundStyle(DS.Palette.ink)

            if !isIssuesFilter {
                Text("Try a sender, a folder name, or clear the filter.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.ink60)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(isIssuesFilter ? "Show all rules" : "Clear search and filters", action: onClear)
                .font(DS.Font.secondary)
                .foregroundStyle(DS.Palette.accent700)
        }
        .padding(.horizontal, DS.Metric.gutter)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Loading

/// Skeleton rows instead of a spinner.
///
/// The list has a known shape, so showing that shape stops the layout jumping
/// when real rules arrive — and it reads as "your rules are coming" rather
/// than "something is happening".
struct RuleSkeletonList: View {
    var count = 5

    @State private var isAnimating = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                HStack(alignment: .top, spacing: 12) {
                    bar(width: 22, height: 18)
                        .frame(width: DS.Metric.orderColumn)

                    VStack(alignment: .leading, spacing: 7) {
                        // Varying widths so it doesn't read as a loading bar.
                        bar(width: index.isMultiple(of: 2) ? 190 : 150, height: 15)
                        bar(width: index.isMultiple(of: 3) ? 230 : 200, height: 12)
                    }

                    Spacer(minLength: 8)
                    bar(width: 62, height: 20)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)

                Divider().overlay(DS.Palette.hairline)
            }
        }
        .opacity(isAnimating && !reduceMotion ? 0.55 : 1)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
            value: isAnimating
        )
        .onAppear { isAnimating = true }
        .accessibilityElement()
        .accessibilityLabel("Loading your rules")
        // A repeating animation would be reported as constant motion otherwise.
        .accessibilityAddTraits(.updatesFrequently)
    }

    private func bar(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: height / 2)
            .fill(DS.Palette.fill)
            .frame(width: width, height: height)
    }
}
