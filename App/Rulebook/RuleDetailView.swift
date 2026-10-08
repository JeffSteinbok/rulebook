import SwiftUI
import RulebookKit

/// A rule, read-only, with the one control that matters inline (enable) and
/// everything else behind Edit.
///
/// Section order is deliberate: what it matches, what stops it matching, what
/// it then does. "Then, on the server" — not "then Rulebook will", because
/// Exchange runs these, not the app.
struct RuleDetailView: View {
    /// What was on screen when this view was pushed. Everything renders from
    /// ``rule`` instead, which re-reads the live copy: a toggle or an edit
    /// updates the view model, and a snapshot captured at push time would go
    /// on showing the old state.
    private let snapshot: MailRule
    let model: RulesListViewModel

    init(rule: MailRule, model: RulesListViewModel) {
        self.snapshot = rule
        self.model = model
    }

    private var rule: MailRule {
        model.rules.first { $0.id == snapshot.id } ?? snapshot
    }

    @Environment(\.dismiss) private var dismiss
    @State private var isEditing = false
    @State private var confirmDelete = false

    private var issue: RuleIssue? { model.issue(for: rule) }
    private var isReadOnly: Bool { rule.status.isReadOnly }

    var body: some View {
        List {
            header
            if let issue { issueNotice(issue) }
            conditions
            if !rule.exceptions.isEmpty { exceptions }
            actions
        }
        .listStyle(.plain)
        .background(DS.Palette.ground)
        .navigationTitle(rule.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    guard model.requirePro(.editing) else { return }
                    isEditing = true
                } label: {
                    if model.isLocked {
                        HStack(spacing: 4) {
                            Text("Edit")
                            Image(systemName: "lock.fill")
                        }
                    } else {
                        Text("Edit")
                    }
                }
                    .font(DS.Font.secondary)
                    .disabled(isReadOnly)
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
        .sheet(isPresented: $isEditing) {
            RuleEditorView(editing: rule, list: model)
        }
        .confirmationDialog("Delete this rule?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete rule", role: .destructive) {
                Task { await model.delete(rule); dismiss() }
            }
        } message: {
            Text("It will be removed from the server. Mail it was filing will stay in your inbox.")
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        Section {
            Text(rule.name)
                .font(DS.Font.sectionTitle)
                .foregroundStyle(DS.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)

            if isReadOnly {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Managed by your organisation")
                        .font(DS.Font.rowTitle)
                    Text("Your admin created this rule. You can read it here, but only they can change or delete it.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.ink80)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.fill, in: .rect(cornerRadius: DS.Metric.controlRadius))
            }

            if model.isPending(rule) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not saved to the server yet")
                        .font(DS.Font.rowTitle)
                    Text("Your change is kept on this phone. Until it reaches the server, the rule is still running as it was.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.ink80)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(model.isRetrying ? "Retrying…" : "Retry now") {
                        Task { await model.retryPending() }
                    }
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Palette.onWarning)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(DS.Palette.warning, in: .rect(cornerRadius: 10))
                    .disabled(model.isRetrying)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.warningWash, in: .rect(cornerRadius: DS.Metric.controlRadius))
                .overlay { RoundedRectangle(cornerRadius: DS.Metric.controlRadius).strokeBorder(DS.Palette.warning, lineWidth: 1) }
            }

            Toggle(isOn: Binding(
                get: { rule.isEnabled },
                set: { isOn in Task { await model.setEnabled(isOn, on: rule) } }
            )) {
                Text(stateLabel).font(DS.Font.secondary)
            }
            .tint(DS.Palette.accent)
            .disabled(isReadOnly)
            .opacity(isReadOnly ? 0.45 : 1)
        }
        .listRowBackground(DS.Palette.ground)
        .listRowInsets(.init(top: 8, leading: DS.Metric.gutter, bottom: 8, trailing: DS.Metric.gutter))
    }

    /// Never claims the server agrees when it hasn't been told yet.
    private var stateLabel: String {
        if isReadOnly {
            return rule.isEnabled ? "Enabled by your admin" : "Disabled by your admin"
        }
        if model.isPending(rule) {
            return rule.isEnabled ? "Enabled on this phone" : "Disabled on this phone"
        }
        return rule.isEnabled ? "Enabled — running on the server" : "Disabled on the server"
    }

    // MARK: - Issue

    private func issueNotice(_ issue: RuleIssue) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(tint(issue.level))
                    Text(issue.label)
                        .font(DS.Font.rowTitle)
                        .foregroundStyle(tint(issue.level))
                }
                Text(issue.detail)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Button(issue.fixTitle) { Task { await fix(issue) } }
                    .font(DS.Font.secondary)
                    // The fill is destructive OR warning; both share the ink rule.
                    .foregroundStyle(DS.Palette.onDestructive)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 40)
                    .background(tint(issue.level), in: .rect(cornerRadius: 10))
                    .disabled(isReadOnly)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(wash(issue.level), in: .rect(cornerRadius: DS.Metric.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Metric.controlRadius)
                    .strokeBorder(tint(issue.level), lineWidth: 1)
            }
        }
        .listRowBackground(DS.Palette.ground)
        .listRowInsets(.init(top: 8, leading: DS.Metric.gutter, bottom: 8, trailing: DS.Metric.gutter))
    }

    private func fix(_ issue: RuleIssue) async {
        switch issue.kind {
        case .neverRuns:
            // Hoisting above the blocking rule is the whole fix — which is why
            // reorder isn't an optional nicety.
            await model.hoist(rule)
        case .missingFolder, .appliesToEverything:
            // The fix is an edit, so it needs Pro like any other. Finding the
            // broken rule stays free — that is the part worth having first.
            guard model.requirePro(.editing) else { return }
            isEditing = true
        case .serverError:
            // Re-PATCHing unchanged content is what clears hasError.
            await model.setEnabled(rule.isEnabled, on: rule)
            await model.load()
        }
    }

    // MARK: - Sections

    private var conditions: some View {
        Section {
            if rule.conditions.isEmpty {
                phrase("Every message", joiner: "IF")
            } else {
                ForEach(Array(rule.conditions.enumerated()), id: \.offset) { index, condition in
                    phrase(
                        model.profile.phrase(for: condition),
                        joiner: index == 0 ? "IF" : (rule.match == .all ? "AND ALSO" : "OR")
                    )
                }
            }
        } header: {
            SectionHeader(text: "When a message…")
        }
        .listRowBackground(DS.Palette.ground)
    }

    /// Exceptions have no `MatchStrategy` of their own — any one matching
    /// skips the rule, so the joiner is always OR.
    private var exceptions: some View {
        Section {
            ForEach(Array(rule.exceptions.enumerated()), id: \.offset) { index, condition in
                phrase(
                    model.profile.phrase(for: condition),
                    joiner: index == 0 ? "SKIP IF" : "OR IF"
                )
            }
        } header: {
            SectionHeader(text: "Unless…")
        }
        .listRowBackground(DS.Palette.ground)
    }

    private var actions: some View {
        Section {
            ForEach(Array(rule.actions.enumerated()), id: \.offset) { _, action in
                Text(model.profile.phrase(for: action))
                    .font(DS.Font.rowTitle)
                    .padding(.vertical, 14)
                    .listRowInsets(.init(top: 0, leading: DS.Metric.gutter, bottom: 0, trailing: DS.Metric.gutter))
            }
        } header: {
            SectionHeader(text: "Then, on the server…")
        }
        .listRowBackground(DS.Palette.ground)
    }

    private func phrase(_ text: String, joiner: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(joiner)
                .font(DS.Font.sectionHeader)
                .tracking(DS.Metric.sectionTracking)
                .foregroundStyle(DS.Palette.ink60)
            Text(text)
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, alignment: .leading)
        .listRowInsets(.init(top: 0, leading: DS.Metric.gutter, bottom: 0, trailing: DS.Metric.gutter))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Duplicate") {
                Task { _ = await model.duplicate(rule) }
            }
            .buttonStyle(SecondaryButtonStyle())

            Button("Delete") { confirmDelete = true }
                .buttonStyle(SecondaryButtonStyle(destructive: true))
                .disabled(isReadOnly)
                .opacity(isReadOnly ? 0.45 : 1)
        }
        .padding(.horizontal, DS.Metric.gutter)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private func tint(_ level: RuleIssue.Level) -> Color {
        level == .error ? DS.Palette.destructiveInk : DS.Palette.warning
    }

    private func wash(_ level: RuleIssue.Level) -> Color {
        level == .error ? DS.Palette.destructiveWash : DS.Palette.warningWash
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.secondary)
            .foregroundStyle(destructive ? DS.Palette.destructiveInk : DS.Palette.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(DS.Palette.surface, in: .rect(cornerRadius: DS.Metric.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Metric.controlRadius)
                    .strokeBorder(destructive ? DS.Palette.destructiveInk : DS.Palette.hairline, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}
