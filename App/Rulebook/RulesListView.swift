import SwiftUI
import RulebookKit

/// The primary screen. Binds only to `RulesListViewModel`, which binds only to
/// `RuleStore` + `ProviderProfile` — so this view runs identically against an
/// in-memory store in Previews and against Graph in the app.
struct RulesListView: View {
    @State var model: RulesListViewModel
    /// Both are nil in Previews — the list screen runs with no auth stack at
    /// all, which is the point of holding `any RuleStore`.
    var accounts: AccountStore?
    var tokens: MSALTokenProvider?

    @State private var editingRule: MailRule?
    @State private var isCreating = false
    @State private var seedPreset: RulePreset?
    @State private var isAddingAccount = false
    @State private var showingAccounts = false
    @State private var showingAbout = false

    var body: some View {
        NavigationStack {
            content
                .background(DS.Palette.ground)
                .navigationTitle(title)
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom) { bottomBar }
                .task { await model.load() }
                .refreshable { await model.load() }
                .alert(model.needsSignIn ? "Sign in again" : "Something went wrong", isPresented: errorBinding) {
                    if model.needsSignIn {
                        Button("Sign in") { Task { await signInAgain() } }
                        Button("Not now", role: .cancel) { model.errorMessage = nil }
                    } else {
                        Button("OK") { model.errorMessage = nil }
                    }
                } message: {
                    Text(model.errorMessage ?? "")
                }
                .sheet(isPresented: $isCreating) {
                    RuleEditorView(list: model, preset: seedPreset)
                }
                .sheet(item: Binding(
                    get: { model.paywall },
                    set: { model.paywall = $0 }
                )) { trigger in
                    if let pro = model.pro {
                        PaywallView(trigger: trigger, pro: pro)
                    }
                }
                .sheet(isPresented: $isAddingAccount) {
                    if let tokens, let accounts {
                        AddAccountView(tokens: tokens, accounts: accounts)
                    }
                }
                .navigationDestination(isPresented: $showingAccounts) {
                    if let tokens, let accounts {
                        AccountsView(
                            accounts: accounts,
                            tokens: tokens,
                            ruleCount: model.rules.count,
                            lastSync: model.lastSync
                        )
                    }
                }
                .navigationDestination(isPresented: $showingAbout) {
                    AboutView()
                }
                // Must sit here, not on the row: List builds rows lazily, so a
                // destination declared inside it is never visible to the
                // navigation stack and is silently ignored.
                .navigationDestination(item: $editingRule) { rule in
                    RuleDetailView(rule: rule, model: model)
                }
        }
    }

    private var title: String {
        switch model.mode {
        case .normal: "Rulebook"
        case .select: model.selection.isEmpty ? "Select" : "\(model.selection.count) selected"
        case .reorder: "Reorder"
        }
    }

    // MARK: - Content

    private var content: some View {
        List {
            if model.mode == .normal && !model.hasNoRulesAtAll {
                Section {
                    if model.hasPending {
                        PendingBanner(
                            title: model.pendingTitle,
                            isRetrying: model.isRetrying,
                            retry: { Task { await model.retryPending() } },
                            discard: { Task { await model.discardPending() } }
                        )
                    }
                    if let attention = model.attentionTitle {
                        AttentionBanner(
                            title: attention,
                            subtitle: model.attentionSubtitle,
                            level: model.attentionLevel
                        ) { model.issuesOnly.toggle() }
                    }
                    syncLine
                    filterTabs
                }
                .listRowInsets(.init(top: 6, leading: DS.Metric.gutter, bottom: 6, trailing: DS.Metric.gutter))
                .listRowBackground(DS.Palette.ground)
                .listRowSeparator(.hidden)
            }

            if model.mode == .reorder {
                hint("Rules run top to bottom. Drag a handle to change the order.")
            } else if model.mode == .select {
                hint(model.selection.isEmpty
                     ? "Tap the rules you want to change."
                     : "Tap to add or remove. Choose an action below.")
            }

            Section {
                // First load with nothing on screen shows the list's shape
                // rather than a spinner — no layout jump when rules arrive.
                if model.isLoading && model.rules.isEmpty {
                    RuleSkeletonList()
                        .listRowBackground(DS.Palette.ground)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                }

                ForEach(model.visibleRules) { rule in
                    row(for: rule)
                }
                .onMove { source, destination in
                    Task { await model.move(from: source, to: destination) }
                }

                if model.hasNoRulesAtAll {
                    EmptyRulesView(profile: model.profile) { preset in
                        guard model.requirePro(.editing) else { return }
                        seedPreset = preset
                        isCreating = true
                    }
                    .listRowBackground(DS.Palette.ground)
                    .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                    .listRowSeparator(.hidden)
                } else if model.visibleRules.isEmpty && !model.isLoading {
                    NoMatchesView(isIssuesFilter: model.issuesOnly) { model.clearFilters() }
                        .listRowBackground(DS.Palette.ground)
                        .listRowInsets(.init(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(model.mode == .reorder ? .active : .inactive))
        // iOS 26 anchors an unplaced `.searchable` to the bottom of the screen,
        // below the New rule bar. The spec puts search directly under the
        // attention banner, above the list, so the placement is explicit.
        .searchable(
            text: $model.query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search rules, senders, folders"
        )
    }

    @ViewBuilder
    private func row(for rule: MailRule) -> some View {
        let issue = model.issue(for: rule)

        RuleRow(
            rule: rule,
            order: model.orderLabel(for: rule),
            summary: model.summary(for: rule),
            issue: issue,
            isSelected: model.selection.contains(rule.id ?? ""),
            isPending: model.isPending(rule),
            mode: model.mode
        )
        .contentShape(.rect)
        .onTapGesture {
            switch model.mode {
            case .select: model.toggleSelection(rule)
            case .reorder: break
            case .normal: editingRule = rule
            }
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            guard model.mode == .normal else { return }
            model.beginSelection(with: rule)
        }
        // Swipe-to-delete is withheld entirely on admin-managed rules rather
        // than offered and refused.
        .swipeActions(edge: .trailing, allowsFullSwipe: !rule.status.isReadOnly) {
            if !rule.status.isReadOnly {
                Button(role: .destructive) {
                    Task { await model.delete(rule) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .listRowBackground(DS.Palette.ground)
        .listRowInsets(.init(top: 14, leading: 16, bottom: 14, trailing: 16))
    }

    // MARK: - Chrome

    private var syncLine: some View {
        HStack {
            Text("\(model.enabledCount) of \(model.rules.count) enabled")
            Spacer()
            Text(model.isLoading ? "Syncing with Exchange…" : syncedLabel)
                .foregroundStyle(model.isLoading ? DS.Palette.accent700 : DS.Palette.ink60)
        }
        .font(DS.Font.captionBold)
        .foregroundStyle(DS.Palette.ink60)
    }

    private var syncedLabel: String {
        guard let lastSync = model.lastSync else { return "Not synced" }
        return "Synced \(lastSync.formatted(date: .omitted, time: .shortened))"
    }

    private var filterTabs: some View {
        Picker("Filter", selection: $model.filter) {
            ForEach(RulesListViewModel.Filter.allCases, id: \.self) { filter in
                Text(filter.label).tag(filter)
            }
        }
        .pickerStyle(.segmented)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Palette.ink60)
            .listRowBackground(DS.Palette.ground)
            .listRowSeparator(.hidden)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                // Asked on the way in. Letting someone drag a row and only then
                // refusing the write is the trick this app shouldn't play.
                if model.mode == .normal {
                    guard model.requirePro(.reorder) else { return }
                }
                model.mode = model.mode == .normal ? .reorder : .normal
                model.selection = []
            } label: {
                if model.mode == .normal && model.isLocked {
                    // Explicit HStack, not Label: a toolbar imposes its own
                    // label style and renders icon-only, which drops the word
                    // and leaves an unexplained padlock.
                    HStack(spacing: 4) {
                        Text("Reorder")
                        Image(systemName: "lock.fill")
                    }
                } else {
                    Text(model.mode == .normal ? "Reorder" : "Done")
                }
            }
            .font(DS.Font.secondary)
        }

        if model.mode == .normal {
            // Anchored menu, not a bottom sheet — these are utility actions,
            // not destinations.
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await model.load() } } label: {
                        Label("Refresh rules", systemImage: "arrow.clockwise")
                    }
                    if tokens != nil {
                        Button { isAddingAccount = true } label: {
                            Label("Add account", systemImage: "plus")
                        }
                        Button { showingAccounts = true } label: {
                            Label("Manage accounts", systemImage: "person.crop.circle")
                        }
                    }
                    Button { showingAbout = true } label: {
                        Label("About Rulebook", systemImage: "info.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
    }

    @ViewBuilder
    private var bottomBar: some View {
        switch model.mode {
        case .select:
            HStack(spacing: 8) {
                Button("Enable") { Task { await model.applyToSelection(enabled: true) } }
                    .buttonStyle(BulkButtonStyle(destructive: false))
                Button("Disable") { Task { await model.applyToSelection(enabled: false) } }
                    .buttonStyle(BulkButtonStyle(destructive: false))
                Button { Task { await model.deleteSelection() } } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(BulkButtonStyle(destructive: true))
            }
            .disabled(model.selection.isEmpty)
            .opacity(model.selection.isEmpty ? 0.45 : 1)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)

        case .normal:
            // The empty state has its own calls to action; a second one below
            // would compete with them.
            if !model.hasNoRulesAtAll {
                PrimaryButton(title: "New rule", trailing: model.isLocked ? "lock.fill" : "plus") {
                    guard model.requirePro(.editing) else { return }
                    seedPreset = nil
                    isCreating = true
                }
                .padding(.horizontal, DS.Metric.gutter)
                .padding(.vertical, 14)
                .background(.bar)
            }

        case .reorder:
            EmptyView()
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    /// Runs from the alert's button, so the scene is active and Microsoft's
    /// page has a window to present on.
    private func signInAgain() async {
        guard let tokens else { return }
        model.errorMessage = nil
        do {
            try await tokens.signIn()
            await model.load()
        } catch MSALTokenProvider.AuthError.cancelled {
            // The person closed Microsoft's page; leave the list as it was.
        } catch {
            model.report(error)
        }
    }
}

// MARK: - Row

private struct RuleRow: View {
    let rule: MailRule
    let order: String
    let summary: String
    let issue: RuleIssue?
    let isSelected: Bool
    let isPending: Bool
    let mode: RulesListViewModel.Mode

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            if mode == .select {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? DS.Palette.accent : DS.Palette.ink40)
                    .frame(width: 26)
            } else {
                orderGutter
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(rule.name)
                    .font(DS.Font.rowTitle)
                    .foregroundStyle(DS.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Text(summary)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Palette.ink60)
                    .lineLimit(DS.Metric.isAccessibilitySize(typeSize) ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)

                if mode == .normal && DS.Metric.isAccessibilitySize(typeSize) {
                    StatePill(isEnabled: rule.isEnabled)
                }

                if isPending {
                    Text("Not saved to the server yet")
                        .font(DS.Font.captionBold)
                        .foregroundStyle(DS.Palette.warning)
                }

                if rule.status.isReadOnly {
                    Text("Managed by your organisation")
                        .font(DS.Font.captionBold)
                        .foregroundStyle(DS.Palette.ink60)
                }

                if let issue {
                    Text(issue.label)
                        .font(DS.Font.captionBold)
                        .foregroundStyle(tint(issue.level))
                }
            }

            Spacer(minLength: 8)

            // At accessibility sizes the pill and chevron squeeze the name to
            // two characters — the state moves inline below the title instead.
            // A dot, not a pill: the state is glanceable either way, and the
            // 30pt the pill used to take goes back to the rule name.
            if mode == .normal && !DS.Metric.isAccessibilitySize(typeSize) {
                HStack(spacing: 8) {
                    StateDot(isEnabled: rule.isEnabled)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.Palette.ink40)
                }
            }
        }
        .frame(minHeight: DS.Metric.rowMinHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(mode == .normal ? "Opens the rule" : "")
        .accessibilityAddTraits(mode == .select && isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// One sentence, in reading order: position, name, state, problem.
    private var spokenLabel: String {
        var parts = ["Rule \(order)", rule.name]
        parts.append(rule.isEnabled ? "enabled" : "disabled")
        if isPending { parts.append("not saved to the server yet") }
        if rule.status.isReadOnly { parts.append("managed by your organisation") }
        if let issue { parts.append(issue.label) }
        parts.append(summary)
        return parts.joined(separator: ", ")
    }

    /// A dot to the LEFT of the order number, in its own reserved slot — the
    /// number never moves, and nothing overlaps it. The gutter is sized for
    /// dot + number whether or not the dot is there.
    private var orderGutter: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(issue.map { tint($0.level) } ?? .clear)
                .frame(width: 8, height: 8)
            Text(order)
                .font(DS.Font.orderNumber)
                .foregroundStyle(issue.map { tint($0.level) } ?? DS.Palette.ink40)
        }
        .frame(width: DS.Metric.orderColumn, alignment: .trailing)
        .accessibilityHidden(true)
    }

    private func tint(_ level: RuleIssue.Level) -> Color {
        level == .error ? DS.Palette.destructiveInk : DS.Palette.warning
    }
}

// MARK: - Attention banner

private struct AttentionBanner: View {
    let title: String
    let subtitle: String
    let level: RuleIssue.Level
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.Font.secondary)
                        .foregroundStyle(DS.Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.ink60)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }
            .padding(14)
            .background(wash, in: .rect(cornerRadius: DS.Metric.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Metric.controlRadius)
                    .strokeBorder(tint, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title). \(subtitle)")
        .accessibilityAddTraits(.isButton)
    }

    private var tint: Color { level == .error ? DS.Palette.destructiveInk : DS.Palette.warning }
    private var wash: Color { level == .error ? DS.Palette.destructiveWash : DS.Palette.warningWash }
}

/// Distinct from `AttentionBanner`: that one says the LIST is stale, this says
/// YOUR EDIT hasn't landed. Both can be on screen at once.
private struct PendingBanner: View {
    let title: String
    let isRetrying: Bool
    let retry: () -> Void
    let discard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 18))
                    .foregroundStyle(DS.Palette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.Font.secondary).foregroundStyle(DS.Palette.ink)
                    Text("Kept on this phone. Your change is safe — it just hasn't reached the server yet.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Palette.ink80)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(isRetrying ? "Retrying…" : "Retry now", action: retry)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Palette.onWarning)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(DS.Palette.warning, in: .rect(cornerRadius: 10))
                    .disabled(isRetrying)

                Button("Discard my change", action: discard)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Palette.ink)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(DS.Palette.hairline, lineWidth: 1) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Palette.warningWash, in: .rect(cornerRadius: DS.Metric.controlRadius))
        .overlay { RoundedRectangle(cornerRadius: DS.Metric.controlRadius).strokeBorder(DS.Palette.warning, lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}

private struct BulkButtonStyle: ButtonStyle {
    let destructive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(DS.Font.secondary)
            .foregroundStyle(destructive ? DS.Palette.onDestructive : DS.Palette.ink)
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(destructive ? DS.Palette.destructive : DS.Palette.surface,
                        in: .rect(cornerRadius: DS.Metric.controlRadius))
            .overlay {
                if !destructive {
                    RoundedRectangle(cornerRadius: DS.Metric.controlRadius)
                        .strokeBorder(DS.Palette.hairline, lineWidth: 1)
                }
            }
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

// MARK: - Preview
//
// No auth, no network: exactly what InMemoryRuleStore(seed:capabilities:) is for.

#Preview("Empty mailbox") {
    RulesListView(
        model: RulesListViewModel(
            store: InMemoryRuleStore(seed: [], capabilities: GraphRuleMapper.capabilities),
            folders: StaticFolderDirectory(["f1": "Reading"])
        )
    )
}

#Preview("Accessibility XXL") {
    RulesListView(model: RulesListViewModel(
        store: PreviewSeed.store(),
        folders: PreviewSeed.folders
    ))
    .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Loading") {
    RulesListView(model: RulesListViewModel(
        store: SlowRuleStore(),
        folders: PreviewSeed.folders
    ))
}

/// Never returns, so the skeleton state stays on screen to be looked at.
private struct SlowRuleStore: RuleStore {
    let capabilities = GraphRuleMapper.capabilities
    func listRules() async throws -> [MailRule] {
        try await Task.sleep(for: .seconds(600)); return []
    }
    func rule(id: String) async throws -> MailRule { throw RuleStoreError.notFound(id: id) }
    func createRule(_ rule: MailRule) async throws -> MailRule { rule }
    func updateRule(id: String, with rule: MailRule) async throws -> MailRule { rule }
    func deleteRule(id: String) async throws {}
}

#Preview("Rules list — dark") {
    RulesListView(model: RulesListViewModel(
        store: PreviewSeed.store(),
        folders: PreviewSeed.folders
    ))
    .preferredColorScheme(.dark)
}

#Preview("Rules list") {
    RulesListView(model: RulesListViewModel(
        store: PreviewSeed.store(),
        folders: PreviewSeed.folders
    ))
}
