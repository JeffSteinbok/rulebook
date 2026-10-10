import SwiftUI
import RulebookKit

/// Create or edit a rule. Three steps when creating; the editor opens straight
/// on conditions when editing an existing rule.
struct RuleEditorView: View {
    @State private var model: RuleEditorModel
    let list: RulesListViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingDiscard = false

    init(editing rule: MailRule? = nil, list: RulesListViewModel, preset: RulePreset? = nil) {
        self.list = list
        let editor = list.makeEditor(for: rule)
        // Arriving from the empty state, the choice was already made — open on
        // conditions with the preset applied rather than asking for a name.
        if let preset { preset.apply(to: editor) }
        self._model = State(initialValue: editor)
    }

    var body: some View {
        NavigationStack {
            List {
                if model.isEditing { editorTabs } else { progress }

                switch model.step {
                case .name: nameStep
                case .conditions: conditionsStep
                case .actions: actionsStep
                }
            }
            .listStyle(.plain)
            .background(DS.Palette.ground)
            .navigationTitle(model.isEditing ? "Edit rule" : model.step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(backLabel) {
                        guard model.back() else { return }
                        if model.hasUnsavedChanges { isConfirmingDiscard = true } else { dismiss() }
                    }
                    .font(DS.Font.secondary)
                }
            }
            .confirmationDialog("Discard this rule\u{2019}s changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .safeAreaInset(edge: .bottom) { footer }
            .task { await model.loadFolders() }
            // A swipe down would throw the draft away without asking.
            .interactiveDismissDisabled(model.hasUnsavedChanges)
            .alert("Couldn't save", isPresented: errorBinding) {
                Button("OK") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
        }
    }

    private var backLabel: String {
        if model.isEditing { return "Cancel" }
        return model.step == .name ? "Cancel" : "Back"
    }

    // MARK: - Progress

    private var progress: some View {
        HStack(spacing: 4) {
            ForEach(RuleEditorModel.Step.allCases, id: \.self) { step in
                Capsule()
                    .fill(step.rawValue <= model.step.rawValue ? DS.Palette.accent : DS.Palette.hairline)
                    .frame(height: 5)
            }
        }
        .listRowBackground(DS.Palette.ground)
        .listRowSeparator(.hidden)
        .listRowInsets(.init(top: 8, leading: DS.Metric.gutter, bottom: 14, trailing: DS.Metric.gutter))
    }

    // MARK: - Step 1

    private var nameStep: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("Write it the way you'd say it out loud — you'll be scanning a long list later.")
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Palette.ink60)

                TextField("e.g. Vendor invoices → Finance", text: $model.draft.name)
                    .textFieldStyle(RuleFieldStyle())
                    .font(DS.Font.rowTitle)
            }
            .padding(.bottom, 8)

            ForEach(RulePreset.all) { preset in
                Button {
                    preset.apply(to: model)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(preset.name)
                            .font(DS.Font.rowTitle)
                            .foregroundStyle(DS.Palette.ink)
                        Text(preset.detail)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Palette.ink60)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
                }
                .listRowInsets(.init(top: 0, leading: DS.Metric.gutter, bottom: 0, trailing: DS.Metric.gutter))
            }
        } header: {
            if !RulePreset.all.isEmpty {
                SectionHeader(text: "Or start from a common one")
                    .padding(.top, 12)
            }
        }
        .listRowBackground(DS.Palette.ground)
    }

    // MARK: - Step 2

    @ViewBuilder
    private var conditionsStep: some View {
        Section {
            if model.supportsMatchAny {
                Picker("Match", selection: $model.draft.match) {
                    Text("Match all").tag(MatchStrategy.all)
                    Text("Match any").tag(MatchStrategy.any)
                }
                .pickerStyle(.segmented)
                .padding(.bottom, 8)
            }

            ForEach(Array(model.draft.conditions.indices), id: \.self) { index in
                if model.draft.conditions.indices.contains(index) {
                    ConditionEditor(
                    condition: $model.draft.conditions[index],
                    model: model,
                        joiner: model.joiner(at: index, isException: false),
                        onRemove: { model.removeCondition(at: index) }
                    )
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                }
            }

            Button("Add condition") { model.addCondition() }
                .buttonStyle(DashedButtonStyle())
                .padding(.vertical, 6)
        }
        .listRowBackground(DS.Palette.ground)
        .listRowInsets(.init(top: 6, leading: DS.Metric.gutter, bottom: 6, trailing: DS.Metric.gutter))

        if model.supportsExceptions {
            Section {
                // The single most important piece of teaching copy in the app:
                // MatchMode has no negation, so exclusion happens here.
                Text("\(model.profile.displayName) has no “does not contain”. To exclude something, add it here instead — if any exception matches, the rule is skipped.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.ink60)
                    .padding(.bottom, 6)

                ForEach(Array(model.draft.exceptions.indices), id: \.self) { index in
                    if model.draft.exceptions.indices.contains(index) {
                        ConditionEditor(
                        condition: $model.draft.exceptions[index],
                        model: model,
                            joiner: model.joiner(at: index, isException: true),
                            onRemove: { model.removeException(at: index) }
                        )
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    }
                }

                Button("Add exception") { model.addException() }
                    .buttonStyle(DashedButtonStyle())
                    .padding(.vertical, 6)
            } header: {
                SectionHeader(text: "Unless").padding(.top, 12)
            }
            .listRowBackground(DS.Palette.ground)
            .listRowInsets(.init(top: 6, leading: DS.Metric.gutter, bottom: 6, trailing: DS.Metric.gutter))
        }
    }

    // MARK: - Step 3

    @ViewBuilder
    private var actionsStep: some View {
        Section {
            Text("Tap all that apply. They run top to bottom.")
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.ink60)
                .listRowBackground(DS.Palette.ground)

            ForEach(model.actionKinds, id: \.self) { kind in
                Button {
                    model.toggle(kind)
                    model.revalidate()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: model.isPicked(kind) ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(model.isPicked(kind) ? DS.Palette.accent : DS.Palette.ink40)
                        Text(model.label(for: kind))
                            .font(DS.Font.rowTitle)
                            .foregroundStyle(DS.Palette.ink)
                        Spacer()
                    }
                    .frame(minHeight: 60)
                }
                .listRowBackground(DS.Palette.ground)
                .listRowInsets(.init(top: 0, leading: DS.Metric.gutter, bottom: 0, trailing: DS.Metric.gutter))

                // An action that carries a value gets its editor right here,
                // under the row it belongs to. It used to sit in an "Action
                // details" section below all ten actions, where nobody found
                // it — and a moveTo with no folder chosen is the single most
                // common way to author a rule that silently loses mail.
                if model.isPicked(kind), let current = model.pickedAction(of: kind) {
                    ActionValueEditor(
                        action: Binding(
                            get: { model.pickedAction(of: kind) ?? current },
                            set: { model.replaceAction(kind: kind, with: $0) }
                        ),
                        folders: model.availableFolders
                    )
                    .padding(.leading, 36)
                    .listRowBackground(DS.Palette.ground)
                    .listRowInsets(.init(top: 0, leading: DS.Metric.gutter, bottom: 10, trailing: DS.Metric.gutter))
                }
            }
        }

        Section {
            Text(model.plainWords)
                .font(DS.Font.body)
                .foregroundStyle(DS.Palette.ink)

            ForEach(model.issues, id: \.self) { issue in
                IssueRow(issue: issue)
            }
        } header: {
            SectionHeader(text: "In plain words").padding(.top, 12)
        }
        .listRowBackground(DS.Palette.ground)
        .listRowInsets(.init(top: 8, leading: DS.Metric.gutter, bottom: 8, trailing: DS.Metric.gutter))
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            PrimaryButton(
                title: model.isEditing ? "Save rule" : model.step.nextLabel,
                trailing: model.step == .actions || model.isEditing ? nil : "arrow.right"
            ) {
                Task { await advance() }
            }
            .opacity(canProceed ? 1 : 0.45)
            .disabled(!canProceed || model.isSaving)
        }
        .padding(.horizontal, DS.Metric.gutter)
        .padding(.vertical, 14)
        .background(.bar)
    }

    /// Only the final step gates on validation; earlier steps let you keep typing.
    private var canProceed: Bool {
        if model.isEditing || model.step == .actions { return model.canSave }
        return true
    }

    /// Creating walks name → conditions → actions, so the step is implied.
    /// Editing opens on conditions and saves from anywhere, which left the
    /// actions pane with no route to it at all.
    private var editorTabs: some View {
        Picker("", selection: Binding(
            get: { model.step },
            set: { model.step = $0 }
        )) {
            Text("Conditions").tag(RuleEditorModel.Step.conditions)
            Text("Actions").tag(RuleEditorModel.Step.actions)
        }
        .pickerStyle(.segmented)
        .listRowBackground(DS.Palette.ground)
        .listRowInsets(.init(top: 4, leading: DS.Metric.gutter, bottom: 8, trailing: DS.Metric.gutter))
    }

    private func advance() async {
        if model.isEditing || model.step == .actions {
            if let saved = await model.save() {
                list.noteSaved(saved)
                await list.load()
                dismiss()
            }
            return
        }
        _ = model.advance()
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }
}

// MARK: - Action values

private struct ActionValueEditor: View {
    @Binding var action: RuleAction
    let folders: [MailboxFolder]

    var body: some View {
        switch action {
        case .moveTo(let folder):
            folderPicker(folder, label: "Move to") { action = .moveTo($0) }
        case .copyTo(let folder):
            folderPicker(folder, label: "Copy to") { action = .copyTo($0) }
        case .addLabel(let folder):
            categoryField(folder, label: "Category") { action = .addLabel($0) }
        case .removeLabel(let folder):
            categoryField(folder, label: "Remove category") { action = .removeLabel($0) }
        case .markImportance(let value):
            Picker("Importance", selection: Binding(
                get: { value }, set: { action = .markImportance($0) }
            )) {
                ForEach(Importance.allCases, id: \.self) { Text($0.rawValue.humanised).tag($0) }
            }
            .pickerStyle(.segmented)
        case .forward(let to):
            recipients(to, label: "Forward to") { action = .forward($0) }
        case .forwardAsAttachment(let to):
            recipients(to, label: "Forward as attachment to") { action = .forwardAsAttachment($0) }
        case .redirect(let to):
            recipients(to, label: "Redirect to") { action = .redirect($0) }
        case .delete(let permanent):
            Toggle("Delete permanently", isOn: Binding(
                get: { permanent }, set: { action = .delete(permanent: $0) }
            ))
            .font(DS.Font.body)
            .tint(DS.Palette.destructive)
        case .markAsRead, .markAsStarred, .markAsSpam, .archive, .stopProcessing:
            EmptyView()
        }
    }

    private func folderPicker(
        _ folder: MailboxFolder, label: String, set: @escaping (MailboxFolder) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if folders.isEmpty {
                // Folder list needs Mail.ReadBasic; typing a name still works
                // because the mapper resolves either half of a MailboxFolder.
                TextField("Folder name", text: Binding(
                    get: { folder.name ?? "" }, set: { set(.named($0)) }
                ))
                .textFieldStyle(RuleFieldStyle())
            } else {
                // Shows what the draft holds, never a stand-in: a picker that
                // displayed the first folder while the rule had none is how a
                // move to nowhere got saved.
                Picker("", selection: Binding(
                    get: { folder.id ?? folders.first { $0.name == folder.name && folder.name != nil }?.id ?? "" },
                    set: { id in
                        guard !id.isEmpty else { return }
                        set(folders.first { $0.id == id } ?? .id(id))
                    }
                )) {
                    if folder.id == nil {
                        Text("Choose a folder").tag("")
                    }
                    ForEach(folders, id: \.id) { candidate in
                        Text(candidate.label).tag(candidate.id ?? "")
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(DS.Palette.accent700)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
    }

    private func categoryField(
        _ folder: MailboxFolder, label: String, set: @escaping (MailboxFolder) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField(label, text: Binding(
                get: { folder.name ?? "" }, set: { set(.named($0)) }
            ))
            .textFieldStyle(RuleFieldStyle())
        }
        .padding(.vertical, 6)
    }

    private func recipients(
        _ to: [MailAddress], label: String, set: @escaping ([MailAddress]) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Addresses, comma separated", text: Binding(
                get: { to.map(\.address).joined(separator: ", ") },
                set: { text in
                    let parts = text.split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                    set(parts.map { MailAddress($0) })
                }
            ))
            .textFieldStyle(RuleFieldStyle())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Issues

private struct IssueRow: View {
    let issue: ValidationIssue

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(isError ? DS.Palette.destructive : DS.Palette.warning)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.message)
                    .font(DS.Font.captionBold)
                    .foregroundStyle(DS.Palette.ink)
                // The library supplies a remedy wherever a portable
                // alternative exists — always show it.
                if let remedy = issue.remedy {
                    Text(remedy)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.ink60)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var isError: Bool { issue.severity == .error }
}

private struct DashedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.secondary)
            .foregroundStyle(DS.Palette.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .overlay {
                RoundedRectangle(cornerRadius: DS.Metric.controlRadius)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(DS.Palette.ink40)
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Presets

struct RulePreset: Identifiable {
    let name: String
    /// Form-shaped: what the conditions and actions are, for step 1's list.
    let detail: String
    /// Why you'd want this — for the empty state, where nobody yet knows what
    /// a rule is for.
    let rationale: String
    let conditions: [RuleCondition]
    let exceptions: [RuleCondition]
    let actions: [ActionKind]

    var id: String { name }

    // RuleEditorModel is main-actor isolated, so applying a preset is too.
    @MainActor
    func apply(to model: RuleEditorModel) {
        model.draft.name = name
        model.draft.conditions = conditions
        model.draft.exceptions = exceptions
        model.draft.actions = []
        for kind in actions where model.profile.supports(kind) {
            model.toggle(kind)
        }
        model.step = .conditions
    }

    static let all: [RulePreset] = [
        .init(
            name: "Newsletters out of the inbox",
            detail: "body contains · 2 actions",
            rationale: "Anything with an unsubscribe link goes to a folder, already read.",
            conditions: [.body(.init("unsubscribe"))],
            exceptions: [],
            actions: [.moveTo, .markAsRead]
        ),
        .init(
            name: "Anything from one sender",
            detail: "from is exactly · 1 action",
            rationale: "Mail from your manager, or one client, marked high importance.",
            conditions: [.from(.init("", mode: .equals))],
            exceptions: [],
            actions: [.markImportance]
        ),
        .init(
            name: "Invoices to a finance folder",
            detail: "subject contains · 1 action",
            rationale: "Keeps billing out of the way until you sit down to it.",
            conditions: [.subject(.init("invoice"))],
            exceptions: [],
            actions: [.moveTo]
        ),
        .init(
            name: "External mail only",
            detail: "from contains, with an exception",
            rationale: "Everything from outside the company, minus your own domain.",
            conditions: [.from(.init("@"))],
            exceptions: [.from(.init("@company.com"))],
            actions: [.markImportance]
        ),
    ]
}
