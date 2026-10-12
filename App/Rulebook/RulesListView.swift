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
    @State private var showingMailboxes = false

    var body: some View {
        NavigationStack {
            content
                .background(DS.Palette.ground)
                .navigationTitle(title)
                // Inline: a large title is a whole row spent saying "Rulebook".
                // The bar carries the title and mailbox instead.
                .navigationBarTitleDisplayMode(.inline)
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
        // Reordering keeps the list's own title: the row handles and the lit
        // button already say what's happening.
        case .normal, .reorder: "Rulebook"
        case .select: model.selection.isEmpty ? "Select" : "\(model.selection.count) selected"
        }
    }

    // MARK: - Content

    private var content: some View {
        List {
            // Kept while reordering, inert: removing it made the rules jump up
            // the moment the reorder button was tapped.
            if model.mode != .select && !model.hasNoRulesAtAll {
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
                        .disabled(isReordering)
                    }
                    syncLine
                    filterTabs
                        .disabled(isReordering)
                }
                .listRowInsets(.init(top: 6, leading: DS.Metric.gutter, bottom: 6, trailing: DS.Metric.gutter))
                .listRowBackground(DS.Palette.ground)
                .listRowSeparator(.hidden)
            }

            if model.mode == .select {
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
                    EmptyRulesView(profile: model.profile, isLocked: model.isLocked) { preset in
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
        .modifier(RuleSearch(query: $model.query))
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
        // No tap or long-press while reordering: either one claims the touch
        // the list needs to start a drag, and the drag never begins.
        .modifier(RowGestures(isEnabled: model.mode != .reorder, onTap: {
            switch model.mode {
            case .select: model.toggleSelection(rule)
            case .reorder: break
            case .normal: editingRule = rule
            }
        }, onLongPress: {
            guard model.mode == .normal else { return }
            model.beginSelection(with: rule)
        }))
        // Long-press is the only way into multi-select; VoiceOver needs a named route.
        .accessibilityAction(named: "Select multiple rules") {
            guard model.mode == .normal else { return }
            model.beginSelection(with: rule)
        }
        // Only while reordering, and never admin-managed rules: Outlook won't
        // move those.
        .moveDisabled(model.mode != .reorder || rule.status.isReadOnly)
        // Swipe-to-delete is withheld entirely on admin-managed rules, and on
        // the free tier, rather than offered and refused: a swipe that opens
        // a paywall is a gesture that lies about what it does.
        .swipeActions(edge: .trailing, allowsFullSwipe: canSwipeDelete(rule)) {
            if canSwipeDelete(rule) {
                Button(role: .destructive) {
                    Task { await model.delete(rule) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                // The app-wide accent tint overrides the destructive role's
                // red on swipe actions; put it back.
                .tint(DS.Palette.destructive)
            }
        }
        .listRowBackground(DS.Palette.ground)
        // A tight leading inset: the order gutter reserves room for an issue
        // dot ahead of the number, and at 16 that pushed the numbers well in
        // from the gutter everything else lines up on.
        .listRowInsets(.init(top: 14, leading: 8, bottom: 14, trailing: 16))
    }

    private func canSwipeDelete(_ rule: MailRule) -> Bool {
        !rule.status.isReadOnly && !model.isLocked
    }

    // MARK: - Chrome

    /// The mailbox named under the title. Kept while reordering so the bar
    /// doesn't jump; only selection replaces it with a count.
    private var activeMailbox: Account? {
        model.mode == .select ? nil : accounts?.active
    }

    /// Switching mailbox, or anything in the ⋯ menu, would abandon a drag in
    /// progress; both stay in place but inert until reordering ends.
    private var isReordering: Bool { model.mode == .reorder }

    /// The title, in the app's own face, on the same row as the bar's buttons
    /// — a large title spends a whole row of the screen saying "Rulebook".
    ///
    /// Under it, which mailbox these rules belong to: with more than one
    /// connected, the list alone can't say. It doubles as the switcher.
    @ViewBuilder
    private var barTitle: some View {
        // Its own size: a toolbar item is offered almost nothing and
        // truncates the title to "R…" otherwise — in every mode.
        let heading = Text(title)
            .font(DS.Font.barTitle)
            .foregroundStyle(DS.Palette.ink)
            .lineLimit(1)
            .fixedSize()

        if let accounts, let active = activeMailbox {
            Button {
                // Opens in place: no press fade, no grow-from-the-title.
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) { showingMailboxes = true }
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    heading
                    HStack(spacing: 3) {
                        Text(active.address)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "chevron.down")
                            .imageScale(.small)
                            .opacity(isReordering ? 0.3 : 1)
                            .accessibilityHidden(true)
                    }
                    .font(DS.Font.captionBold)
                    .foregroundStyle(DS.Palette.ink60)
                    // A cap, so a long work address truncates in the middle
                    // instead of running under the bar's buttons.
                    .frame(maxWidth: 220, alignment: .leading)
                }
                // Its own size: a plain button in a toolbar is offered almost
                // nothing and truncated the title to "R…". The address's cap
                // above still bounds it, since an ideal size honours maxWidth.
                .fixedSize()
            }
            // The bar is a fixed height; past this the two lines clip.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .buttonStyle(StillButtonStyle())
            .disabled(isReordering)
            .accessibilityLabel("Mailbox: \(active.address)")
            .accessibilityHint("Switch mailbox or manage accounts")
            // A popover, not a Menu: a system menu sets its own type size and
            // wraps a full address mid-word ("out-look.com"). This keeps each
            // mailbox to one line, in the app's face.
            .popover(isPresented: $showingMailboxes, arrowEdge: .top) {
                MailboxSwitcher(accounts: accounts, activeID: active.id) {
                    showingMailboxes = false
                    // Pushed once the popover has gone: on iOS 17 a push in
                    // the same update as the dismissal can be dropped.
                    Task {
                        try? await Task.sleep(for: .milliseconds(350))
                        showingAccounts = true
                    }
                }
                .presentationCompactAdaptation(.popover)
            }
        } else {
            heading
        }
    }

    private var syncLine: some View {
        HStack {
            Text("\(model.enabledCount) of \(model.rules.count) enabled")
            Spacer()
            Text(model.isLoading ? "Syncing with Outlook…" : syncedLabel)
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
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { barTitle }
                // A title, not a button: no glass capsule around it.
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { barTitle }
        }
        // Takes the system's centred copy of the title out of the bar. The
        // navigation title itself stays set: it still names the back button.
        ToolbarItem(placement: .principal) { Color.clear.frame(width: 1) }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                // Asked on the way in. Letting someone drag a row and only then
                // refusing the write is the trick this app shouldn't play.
                if model.mode == .normal {
                    guard model.requirePro(.reorder) else { return }
                }
                // Reordering shows every rule: dragging within a filtered
                // list silently jumps the hidden ones, and the filter can't
                // be changed mid-reorder.
                if model.mode == .normal { model.clearFilters() }
                model.mode = model.mode == .normal ? .reorder : .normal
                model.selection = []
            } label: {
                switch model.mode {
                case .normal:
                    // An icon, not "Edit": the only thing this mode does is
                    // reorder, and a word that promises more misleads.
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down")
                        if model.isLocked {
                            Image(systemName: "lock.fill")
                                .imageScale(.small)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(model.isLocked ? "Reorder rules, requires Pro" : "Reorder rules")
                case .reorder:
                    // The same button, lit, as a check: tap it to finish. No
                    // "Done" word, so the bar doesn't change shape mid-task.
                    Image(systemName: "checkmark")
                        .foregroundStyle(.white)
                        .padding(6)
                        .background(DS.Palette.accent, in: Circle())
                        .accessibilityLabel("Finish reordering")
                case .select:
                    Text("Done")
                }
            }
            .font(DS.Font.secondary)
            .accessibilityIdentifier(model.mode == .select ? "endSelection" : "reorder")
        }

        if model.mode != .select {
            // Anchored menu, not a bottom sheet — these are utility actions,
            // not destinations.
            ToolbarItem(placement: .topBarTrailing) {
                // No Refresh item: pull-to-refresh on the list already does it.
                Menu {
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
                .disabled(isReordering)
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
        guard let tokens, let mailbox = accounts?.active else { return }
        model.errorMessage = nil
        do {
            let signedIn = try await tokens.signInAgain(accountID: mailbox.id)
            if signedIn.identifier != mailbox.id {
                // MSAL had lost this mailbox and someone signed in as another:
                // add that one (which switches to it) rather than show its rules
                // under this mailbox's name.
                accounts?.add(Account(id: signedIn.identifier, address: signedIn.address,
                                      displayName: Account.displayName(for: signedIn.address)))
                return
            }
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
                    .font(.title2)
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
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(DS.Palette.ink40)
                }
                // Reordering hides this slot and the list's own drag handle
                // takes its place. The handle is a little wider than the slot
                // plus its spacing; the padding makes up the difference, so no
                // rule name or summary rewraps when the mode changes.
                .padding(.trailing, 6)
            }
        }
        .frame(minHeight: DS.Metric.rowMinHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenLabel)
        .accessibilityHint(mode == .normal ? "Opens the rule" : mode == .reorder ? "Rules run top to bottom. Use the drag handle to move this rule." : "")
        // Not a button while reordering: a tap does nothing then.
        .accessibilityAddTraits(mode == .reorder ? [] : mode == .select && isSelected ? [.isButton, .isSelected] : .isButton)
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
        .frame(width: DS.Metric.orderColumn, alignment: .leading)
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
                    .font(.title3)
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
                    .font(.body)
                    .foregroundStyle(DS.Palette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(DS.Font.secondary).foregroundStyle(DS.Palette.ink)
                    Text("Outlook doesn\u{2019}t have this change yet. It\u{2019}s kept here until you retry, discard it, or close Rulebook.")
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
                    .frame(minHeight: 36)
                    .background(DS.Palette.warning, in: .rect(cornerRadius: 10))
                    .disabled(isRetrying)

                Button("Discard my change", action: discard)
                    .font(DS.Font.secondary)
                    .foregroundStyle(DS.Palette.ink)
                    .padding(.horizontal, 14)
                    .frame(minHeight: 36)
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
            .frame(minHeight: 48)
            .multilineTextAlignment(.center)
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
    func moveRule(id: String, toPosition position: Int) async throws {}
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

/// The mailbox list behind the title: one line per mailbox, a checkmark on
/// the active one, and the way into Manage accounts.
private struct MailboxSwitcher: View {
    let accounts: AccountStore
    let activeID: String
    let manage: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(accounts.accounts) { account in
                let isActive = account.id == activeID
                Button {
                    accounts.activate(account)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(DS.Palette.accent)
                            .opacity(isActive ? 1 : 0)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(account.address)
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Palette.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isActive ? [.isSelected] : [])
            }

            Divider().padding(.vertical, 4)

            Button(action: manage) {
                HStack(spacing: 10) {
                    Image(systemName: "person.crop.circle")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text("Manage accounts")
                        .font(DS.Font.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(DS.Palette.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Bounded both ways: long addresses truncate in the middle rather
        // than pushing the popover past the screen edge.
        .frame(minWidth: 260, maxWidth: 340)
        .fixedSize()
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

// MARK: - Search

/// Switches that hold back a finished feature without deleting it.
enum FeatureFlag {
    /// Off: the search box took a full row above every list for something a
    /// few dozen rules rarely need. The query plumbing stays in the model.
    static let ruleSearch = false
}

private struct RuleSearch: ViewModifier {
    @Binding var query: String

    func body(content: Content) -> some View {
        if FeatureFlag.ruleSearch {
            // iOS 26 anchors an unplaced `.searchable` to the bottom of the
            // screen, below the New rule bar. The spec puts search directly
            // under the attention banner, above the list, so the placement is
            // explicit.
            content.searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search rules, senders, folders"
            )
        } else {
            content
        }
    }
}

/// A button that doesn't dim or bounce when pressed — for a title, which
/// shouldn't flicker as if it were a control.
private struct StillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}

/// A row's tap and long-press, attachable or not as a whole — so reordering
/// can take them off and leave the touch to the list's drag.
private struct RowGestures: ViewModifier {
    let isEnabled: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .onTapGesture(perform: onTap)
                .onLongPressGesture(minimumDuration: 0.45, perform: onLongPress)
        } else {
            content
        }
    }
}
