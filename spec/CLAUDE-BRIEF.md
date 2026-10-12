# Build the Rulebook iOS app

You are working in the `Rulebook` repository — a Swift package containing
`RulebookKit` (a provider-neutral mail-rules engine with a working Microsoft
Graph implementation) and a CLI harness. Read `README.md` first; it explains the
layout and the design of the library in detail.

**The library is done and tested. The iOS app does not exist yet.** Your job is
to build it, in `App/`, against a design that has already been made.

## What you have to work from

A `handoff/` folder (unzip it into the repo root, or wherever the user put it):

- `Rulebook-app-spec.md` — every screen, every state, and which
  `ProviderProfile` / `RuleStore` call backs each control. **Read this in full
  before writing code.** It ends with four known gaps in `RulebookKit`.
- `App/` — 16 Swift files implementing the whole design, plus `README.md`
  with the build order and the reasoning behind the non-obvious choices. These
  were written against the library's source but **never compiled**, so expect
  SwiftUI API drift and MSAL signature fixes. A strong first draft, not gospel.
- `Rulebook.dc.html` (if the user included it) — the interactive prototype.
  Every state described here is reachable in it, including the failure states,
  via the "Jump to a screen" list and the Appearance / Network switches. When
  the spec and your reading of the Swift disagree, the prototype is the
  tiebreaker.
- `icon-export/` — app icon PNGs. `rulebook-ios-1024.png` goes in the asset
  catalog (square, no alpha, no radius — iOS masks it).

## This handoff is a one-time snapshot

Nothing has been built yet, so these 16 files are a complete starting point —
copy them in wholesale.

**After that, the code in `App/` is the truth, not this folder.** If the
designer changes something later, they will send a short *change brief* in
prose — what moved and why — to apply against the code that exists by then. Do
not expect, or ask for, a second full drop of these files: it would overwrite
work that has since been compiled and fixed.

So: read these files as a first draft to make real. Once they compile and run,
this folder is history — record decisions in the code and its comments, and
keep `App/README.md` current as the place where the non-obvious reasoning
lives.

## Ground rules

**`RulebookKit` imports nothing but Foundation.** No UIKit, no SwiftUI, no
MSAL. That is what lets one target build for iOS, the simulator and the CLI.
Keep it that way: UI belongs in `App/`, and MSAL arrives through the
`TokenProvider` protocol. If you find yourself adding a dependency to the
library, you are solving the problem in the wrong place.

**Screens bind to `ProviderProfile` and `RuleStore`, never to a concrete
provider.** `profile.availableConditions` / `availableActions` already filter to
what the provider supports; `profile.vocabulary` labels them. Never hard-code a
list of condition fields or actions — that is what makes a second store a
drop-in later.

**`MatchMode` has no negation.** There is no "does not contain", no "is not".
Exclusion is expressed with `rule.exceptions`. The editor's "Unless" section
carries the teaching copy for this and it is the single most important piece of
explanatory text in the app. Do not add a negative operator.

**Lossy operations are refused, never silently dropped.** The library is built
this way and the UI must match: when a save fails because the provider cannot
express something, render every `ValidationIssue` — including its `remedy`,
which the library supplies wherever a portable alternative exists. Never
collapse to "something went wrong".

## Order of work

Do not start with auth. The point of `any RuleStore` is that you don't have to.

1. **Create the Xcode project** at `App/Rulebook.xcodeproj`. Add the local
   package: File → Add Package Dependencies → Add Local → `../`. Link
   `RulebookKit`. `Package.swift` stays at the repo root — don't move it.

2. **Copy in every handoff file except `MSALTokenProvider.swift` and
   `RulebookApp.swift`.** Get `RulesListView`'s `#Preview` rendering. It runs on
   `InMemoryRuleStore` with a `StaticFolderDirectory` — no auth, no network, no
   Azure. `accounts` and `tokens` are optional on that view precisely so this
   works. Fix compile errors here, where the loop is fast.

3. **Bundle Archivo** (Regular / SemiBold / Bold / Black) and list the files
   under `UIAppFonts` in `Info.plist`. Until then every custom font silently
   falls back to system and the design looks wrong for reasons that aren't
   obvious.

4. **Run on the simulator with fake data.** Point `RootView.rebuild()` at
   `InMemoryRuleStore` and use the `#Preview` seed. Do this before MSAL exists —
   gestures cannot be judged in previews, and the app has three of them
   (long-press multi-select, swipe-to-delete, drag-to-reorder). The 450ms
   long-press threshold in particular needs a real touch loop.

5. **Add MSAL** via SPM. Copy in `MSALTokenProvider.swift` and
   `RulebookApp.swift`. Add the redirect URI
   `msauth.$(PRODUCT_BUNDLE_IDENTIFIER)://auth` and a `RulebookClientID` key to
   `Info.plist`. The client id comes from `Scripts/register-app.sh`.

6. **First real sign-in on a device, not the simulator.** The simulator has no
   Authenticator app, so number-match MFA can't complete. Use a device, or a
   dev-tenant account with MFA off.

## Things that will bite you

**Authority is `common`, not the tenant GUID.** `register-app.sh` prints the
sign-in authority for exactly this reason: an app accepting personal Microsoft
accounts must authenticate against `common`, and pinning the registration's
tenant locks those accounts out.

**Never render a password field.** `ASWebAuthenticationSession` shows
Microsoft's own page, which owns the password, MFA, conditional access,
federated SSO redirects and the consent grant. A hand-rolled credential form
breaks the moment a tenant uses SSO, which most offices do. The consent screen
is Microsoft's too — the app's job is a short pre-auth explainer, not
collecting the grant.

**Don't overclaim on privacy.** `Mail.ReadBasic` grants the sender, recipients
and subject of every message. The scope explainer must not say "never message
bodies" as though that's a tight boundary. `TokenProvider.swift`'s doc comments
explain why the precise scope (`MailboxFolder.Read`) isn't usable.

**Never roll back a local edit on a network failure.** There is no offline
mode, but a blip must not undo someone's change. Writes apply locally, then
push; a failure keeps the local value in `pending` and marks the rule "Not
saved to the server yet", with Retry / Discard. `load()` merges server state
over pending so a refresh can't clobber it. Two exceptions, both deliberate:
deletes are not queued (a rule that looks gone but is still filing mail is the
worst lie available), and reorder rolls back (a half-applied `sequence` is
worse than none).

**Reorder is N writes.** `RuleStore` has no reorder operation, so a drag
renumbers every affected rule via `updateRule` and must handle partial failure
by re-reading the server. `sequence` must be unique on Graph.

**`hasError` is not sufficient.** A rule can point at a deleted folder and
still be reported healthy, silently dropping mail. `RuleDiagnostics` in the
handoff does two local checks alongside the server flag: missing destination
folder, and unreachable rules shadowed by an earlier `stopProcessing`. The
detail copy says "Exchange still reports this rule as healthy" — keep that.

**Read-only rules are withheld, not refused.** `status.isReadOnly` means an
admin owns the rule. No swipe action at all, dimmed toggle, greyed delete,
skipped by bulk ops. An affordance that appears and then fails is worse than
one that was never offered.

**`updateRule` merges.** Empty collections leave stored values alone, so
"remove every condition" cannot currently be expressed.
`RuleEditorModel.revalidate()` detects this and reports a blocking issue. That
is a workaround — see gap 4 below.

**Size is bytes in the model, MB in the UI.** Graph is kilobytes; the neutral
model is bytes. `SizeEditor` converts.

## Error and empty states are part of the design, not an afterthought

These are specified in the spec and implemented in the handoff. Do not
substitute generic alerts for them.

**Three empty states, and they are not interchangeable.** A mailbox with no
rules is a first-run *invitation*: it explains what a rule is and offers three
starters that jump into step 2 with conditions pre-filled. The banner, count
line, search, tabs, Reorder and New rule all hide, so the starters are the only
calls to action. A search that matched nothing is a *dead end* whose only
useful action is clearing the filter. Loading is skeleton rows, not a spinner,
because the list has a known shape.

**Two failure banners that say different things.** One says the LIST is stale
("Showing the rules from your last sync — they're still running on the server,
only this list is out of date"). The other says YOUR EDIT hasn't landed ("1
change not saved · Kept on this phone"). Both can be on screen at once.
Collapsing them loses the distinction that actually matters to the user.

**Admin-consent failure is not a generic error.** The user cannot fix it —
their admin has to. So that screen names the app, the exact permissions, and
the AADSTS code, with a Copy details button, because the useful action is
forwarding it to IT. A cancelled sign-in is a separate, quieter state.

**Save validation mirrors `RuleValidator`.** Errors block the save; warnings
inform and don't. Every issue renders its `remedy`. The three that matter
most: an unnamed rule, a rule with no actions, and a `moveTo` with no folder
chosen — that last one is the most common way to author a rule that silently
loses mail.

## Known gaps in RulebookKit

The app exposed four. All small; decide on them rather than working around them
forever.

1. **No reorder operation.** `func reorder(_ ids: [String]) async throws` on
   `RuleStore` would put renumbering in `GraphRuleStore` where batching is
   possible, instead of a loop in a view model.

2. **Diagnostics live app-side.** `RuleDiagnostics` is provider-neutral policy
   and belongs next to `RuleValidator`. Move it and the CLI gets
   `rulebook doctor` for free.

3. **No account model.** The app manages multiple mailboxes; the library has one
   store per account. `AccountStore` is a `UserDefaults` shim. Fine app-side
   unless the CLI ever needs it.

4. **`updateRule` can't clear a collection.** Needs a sentinel or explicit
   clear flags. Worth deciding before more of the editor is built on the
   workaround.

## Design work still outstanding

Not blockers, but real. Raise them rather than quietly shipping without them.

- **App Store screenshots** beyond the five designed frames, if you want a
  6.5" set as well.
- **iPad and landscape.** Untouched. Phone-only is a legitimate v1.
- **Localisation.** All copy is inline English.

Dynamic Type, dark mode, the empty states, skeleton loading, the error and
pending states, and the icon are all done — don't redo them.

Three things in the palette look like redundancy and are not. Every one was
measured; all are documented in `App/README.md`:

- `destructive` (fill) vs `destructiveInk` (text). #D92B1C clears 4.5:1 under
  white as a fill but only reaches 4.38:1 as ink on the light ground.
- The dark-mode accent is *darker* than the light one for fills (#3B6AE8), not
  lighter. The obvious lift to #5C86F7 gives white text 3.38:1.
- `onDestructive` / `onWarning` exist because white ink fails on the lifted
  dark fills — 2.81:1 on #FF6A5A, 2.19:1 on #E0A44A. Never hard-code `.white`
  on a coloured fill.

Every screen was audited programmatically in both themes at 4.5:1 body / 3:1
headline, with zero failures. If you change a colour, re-run that check.

## What "done" looks like for a first milestone

A signed-in user can see their real Outlook rules in evaluation order, spot a
broken one, enable and disable, reorder, and create a rule with conditions,
exceptions and actions that Exchange accepts — and none of that silently loses
their work when the network drops. Everything else is additive.
