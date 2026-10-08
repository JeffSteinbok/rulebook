# Testing Rulebook

The question every layer answers: **does the rule someone builds on screen do,
in Outlook, what they meant?** The layers below each cover part of that, from
cheapest to most real.

| Layer | Where | Runs | Talks to |
| --- | --- | --- | --- |
| Library | `Tests/RulebookKitTests` | `swift test`, every PR | FakeGraph |
| Fake ↔ Graph conformance | `GraphConformanceTests` | `swift test`, every PR | Recorded Graph traffic |
| App logic | `App/RulebookTests` | Xcode / CI, every PR | FakeGraph through the real `GraphRuleStore` |
| UI | `App/RulebookUITests` | Xcode / CI, every PR | `-demo` mailbox, `Rulebook.storekit` |
| Live | `Tests/RulebookLiveTests` | By hand, before a release | The test mailbox |
| Probe | `GraphProbe` | By hand, when Graph may have changed | The test mailbox |

## The fake, and why to trust it

`Sources/RulebookTesting/FakeGraph.swift` is a stateful stand-in for the Graph
endpoints the app uses. It is not a guess. `GraphProbe` sent about 270 requests
to a real mailbox and recorded every answer under
`Tests/RulebookKitTests/Fixtures/graph/`, and `GraphConformanceTests` replays
every one of those against the fake, requiring the same status and body. The
README in that folder lists what Graph does that you wouldn't expect. Each of
those things was a bug in 1.0.

When Graph might have changed (a new year, an odd bug report), re-record and
see whether the conformance suite still passes:

    RULEBOOK_LIVE=1 RULEBOOK_PROBE=1 RULEBOOK_CLIENT_ID=72997602-da76-49bd-a1cd-90f67d51bcc6 \
        swift test --filter GraphProbe
    swift test --filter GraphConformance

## Running everything

    swift test                                   # library + conformance, ~1s

    cd App && xcodegen generate && cd ..
    xcodebuild test -project App/Rulebook.xcodeproj -scheme Rulebook \
        -destination "platform=iOS Simulator,name=iPhone 16" CODE_SIGNING_ALLOWED=NO

    # Before a release, against the test mailbox (writes disabled scratch rules
    # named "RuleBook live – …" and deletes them):
    swift run rulebook list                      # confirm it's the test mailbox!
    RULEBOOK_LIVE=1 RULEBOOK_LIVE_WRITE=1 RULEBOOK_CLIENT_ID=72997602-da76-49bd-a1cd-90f67d51bcc6 \
        swift test --filter LiveOutlook

The CLI's cached token (`~/.rulebook/token.json`) decides which mailbox the
live suites use. Sign in to the **test** account with `swift run rulebook login`
in a private browser window, and check `rulebook list` before any write run.

Xcode writes the app's MSAL pin into the root `Package.resolved` when it
resolves. That file belongs to `Package.swift`; don't commit the pin
(`git checkout Package.resolved`).

## What only a person can check

Run through this on a real device before each App Store release. Nothing
automated can reach these.

**Sign-in (MSAL)**
- [ ] A personal Outlook.com account and a work/school account both connect.
- [ ] A work account with MFA or conditional access completes, through
      Authenticator when it's installed and through the web page when it isn't.
- [ ] A tenant that requires admin consent shows Microsoft's message, not a crash.
- [ ] Two mailboxes: switching shows each one's own rules. Toggle a rule in B and
      check in Outlook on the web that it changed in B, not A.
- [ ] Sign out of one mailbox: the other still loads. Relaunch: still right.
- [ ] Revoke the app at account.microsoft.com → the app asks to sign in again
      for that mailbox only.

**Purchases (real App Store, sandbox account)**
- [ ] Buy Pro; every write unlocks without a relaunch.
- [ ] Restore on a second device signed in to the same Apple Account.
- [ ] Launch in airplane mode after buying: still unlocked.
- [ ] Ask to Buy: the pending message is calm, and approving later unlocks.
- [ ] Refund through reportaproblem.apple.com → locks again on next foreground.

**Outlook itself**
- [ ] Create one rule of each kind in the app, then open Outlook on the web →
      Settings → Rules and read each back. Do they say what the app said?
- [ ] Send real mail that should and shouldn't match one or two of them.
- [ ] A rule created in Outlook on the web with options the app doesn't model
      (e.g. "at the time it arrives" variants) opens without losing anything
      when saved unchanged.
- [ ] An admin-managed (read-only) rule in a work tenant can't be dragged,
      toggled or deleted.

**Device**
- [ ] Largest accessibility text size on the smallest supported iPhone: banners,
      bulk buttons and issue cards wrap instead of clipping.
- [ ] VoiceOver: every row, toggle and fix button is labelled; "Select multiple
      rules" is offered as an action.
- [ ] Airplane mode mid-toggle: the pending banner appears, Retry works once
      back online, and closing the app loses the change (as the banner says).
