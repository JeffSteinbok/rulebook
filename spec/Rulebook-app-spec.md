# Rulebook iOS: screen spec

Companion to the prototype in `Rulebook.dc.html`. Every screen maps to
`RulebookKit` types; nothing here needs a new library API except where noted
under **Gaps**.

Bind screens to `ProviderProfile` + `any RuleStore`, never to `GraphRuleStore`.
Every store call is `async throws` — each screen needs a loading and a failure
state, and `RuleStoreError.errorDescription` is already user-readable.

---

## 0. Design tokens

In `DesignTokens.swift`. Derived from the Modernist system, cooled to blue.

| Token | Value | Use |
| --- | --- | --- |
| `accent` | `#1A4ED8` | primary actions, selection, enabled pill |
| `accent700` | `#0F3196` | accent-colored text (contrast on light ground) |
| `accentWash` | `#EFF3FF` | tinted fills, attention banner |
| `ground` | `#F1F3F7` | screen background |
| `ink` | `#1B1F28` | primary text |
| `ink60` | `#5B6371` | secondary text |
| `hairline` | `#D5DAE4` | separators — 1px, not 2px |
| `destructive` | `#D92B1C` | delete, error state |
| `warning` | `#A15C00` | "never runs" and other advisories |

Type: **Archivo** (bundle it; it's the design system's face). Semibold 600 for
titles and buttons, Bold 700 for row names and pills, Regular 400 for body.
Sizes: 34 screen title, 17 row title / button, 15 secondary, 13 caption,
11 section header (uppercase, 0.18em tracking).

Radius 12 on controls, 0 on full-bleed list rows.

**Dark mode.** Every role above has a dark counterpart; the table lists light
values. Dark ground #12151C, surface #1C2027, ink #F2F4F8. Two rules that are
easy to get wrong:

- The accent gets *darker* for fills in dark mode (#3B6AE8), not lighter —
  white-on-#5C86F7 is 3.38:1. Accent-colored *text* goes the other way,
  #9DB9FC.
- `destructive` (fill, #D92B1C) and `destructiveInk` (text, #B3251A) are
  separate roles in light mode; in dark both are #FF6A5A.

Non-text greys (dividers, hollow checkmarks) may sit below 4.5:1 — they carry
no information alone. Everything that reads as text does not. Row min-height 68.

Caps only on: small grey section headers, the ENABLED/DISABLED pills. Everything
else sentence case.

---

## 1. Gate (no account)

Shown **only** when no account is connected. `RulebookApp` decides at launch;
never a screen someone with an account can reach.

- Full-bleed `accent` field, `Rulebook` wordmark, tagline
  "Outlook mail rules,\nmanaged on mobile."
- **Add account** → §2
- **About Rulebook** → §7
- Footer: "Made with ♥ by Jeff Steinbok"

## 2. Add account

Two app screens with a system-owned one between them.

**2a. Explainer.** Lists the three things consent will ask for, worded from
`GraphScopes.default`:

| Shown as | Backed by |
| --- | --- |
| Read your mail rules | `MailboxSettings.ReadWrite` |
| Create and change rules | same |
| Read your folder names | `Mail.ReadBasic` |

Do not say "never message bodies" — `Mail.ReadBasic` grants sender, recipients
and subject. The TokenProvider doc comment is explicit about this; the copy
must not overclaim.

CTA: **Sign in with Microsoft** → presents `ASWebAuthenticationSession`.

**2b. System auth.** Microsoft owns everything inside: sign-in, MFA,
conditional access, and the consent screen. Your app draws nothing. Cancel is
theirs. Never render a password field.

Authority is `common`, not the registration's tenant GUID — `register-app.sh`
prints the sign-in authority for exactly this reason, and pinning the tenant
locks out personal accounts.

**2c. Connected.** Server, rules found, disabled count, "Revocable token".
CTA: **Open my rules** → §3.

Failure: `MSALError` code `userCanceled` returns silently to 2a. Everything
else shows the message inline — an admin who hasn't consented to
`MailboxSettings.ReadWrite` lands here, and the copy should name that.

## 3. Rules list — the primary screen

Title **Rulebook**. `•••` in the nav bar → §8. Not a hamburger, not a bottom
sheet.

Loads `store.listRules()`, already sorted by `order`. Sync line shows
"Syncing with Exchange…" then "Synced HH:MM".

**Row** — a `34 / 1fr / 64` grid:

| Slot | Content |
| --- | --- |
| gutter | a status dot (only when the rule has an issue) then `order` as `01`, `02`… — both tinted `destructive`/`warning`. Fixed 42pt slot, so the number never shifts |
| body | `rule.name`; `profile.describe`-style summary line; issue label; "Managed by your organisation" when `status.isReadOnly` |
| trailing | a 9pt state dot (filled = enabled, hollow = disabled) then the chevron. 34pt slot — the pill it replaced cost 30pt of name width for no extra information |

The dot precedes the number in a fixed-width gutter — never overlaid, never
inline before the title. Every row title sits on the same left edge in every
state.

**Attention banner** above the search field when any rule has an issue:
"2 rules aren't working / Plus 1 warning · tap to review". Tap filters to
affected rules; tap again clears. See §9 for the issue model.

**Gestures**

- **Swipe left** → red Delete with trash glyph → `store.deleteRule(id:)`.
  Refuse on `status.isReadOnly` (snap shut, no destructive affordance).
- **Long press (450ms)** → multi-select. Circular checkmarks, bottom bar with
  Enable / Disable / Delete. Bulk ops skip read-only rules silently.
- **Reorder** in the nav bar → drag handles, order commits on release.

Search filters name, condition values, and action labels.
Filter tabs: All / Enabled / Disabled.

**Three empty states.** No rules at all → a first-run invitation: what a rule
is, three starter rules that jump into step 2, and "Start from scratch
instead". The banner, count line, search field, filter tabs, Reorder and New
rule all hide — the starters are the only calls to action. Search matched
nothing → a dead end with a clear-filters action. Loading → skeleton rows.

A legend under the list names the two dot states; at accessibility sizes the
dot is replaced by the full ENABLED/DISABLED pill inline under the title, where
there's room for words.

**Dynamic Type throughout.** Fonts are `relativeTo:` a text style; rows use
`minHeight` not `height`; at `.accessibility1` and above the trailing pill and
chevron drop and the state moves inline under the title. `DetailRow` stacks its
key and value. Each row is one accessibility element reading position, name,
state, problem.

## 4. Rule detail

Sections in this order, all from one `MailRule`:

1. **Name** (display-scale)
2. **Managed-by-org notice** — only when `status.isReadOnly`. Toggle dims to
   45%, Delete greys out, Duplicate stays live.
3. **Enable toggle** — "Enabled — running on the server" / "Disabled on the
   server". Read-only rules read "Enabled by your admin".
4. **WHEN A MESSAGE…** — `conditions`, joined `IF` / `AND ALSO` (`match == .all`)
   or `IF` / `OR` (`.any`)
5. **UNLESS…** — `exceptions`, joined `SKIP IF` / `OR IF`. Section hidden when
   empty. Any exception matching skips the rule; exceptions have no
   `MatchStrategy` of their own.
6. **THEN, ON THE SERVER…** — `actions`. Not "then Rulebook will" — Exchange
   runs these, not the app.
7. **Issue notice** with a fix button, when applicable (§9)

Footer: **Done** / **Duplicate**. Duplicate writes a disabled copy named
"… (copy)" via `createRule` — `writablePayload()` already strips `id` and
`status`.

## 5. Create rule — three steps

**Step 1 — Name.** Free text plus four presets that pre-fill conditions and
actions and jump to step 2.

**Step 2 — Conditions.** `MATCH ALL` / `MATCH ANY` segmented control writes
`match`. Each condition row: field picker, operator picker, value.

- Field picker = `profile.availableConditions`, labelled
  `profile.vocabulary.name(for:)`. Do not hard-code a field list — providers
  differ and the profile already knows.
- Operator picker = `MatchMode` — `contains`, `equals`, `startsWith`,
  `endsWith`. **There is no negation.**
- **UNLESS** subsection below, with the explanatory line: "Outlook has no
  'does not contain'. To exclude something, add it here instead — if any
  exception matches, the rule is skipped." This is the single most important
  piece of teaching copy in the app.

**Step 3 — Actions.** Multi-select from `profile.availableActions`, labelled
via the vocabulary. Includes **Stop processing later rules** — it's what the
"never runs" diagnostic detects, so it has to be offerable.

Below: the rule in plain words, assembled from the draft.

Save: `RuleValidator.validate(rule, for: profile.capabilities)` first, show
issues inline, then `store.createRule`. `MappingError.unsupported` carries
`[ValidationIssue]` — render each, don't collapse to "something went wrong".

## 6. Manage accounts

iOS selection list. Tap a row to switch; checkmark marks the active mailbox.
Under it, a details group for the active account (address, server, rules on
server, last sync), then a single destructive **Sign out of this mailbox** row
in its own section, two-tap to confirm. No paired buttons per row.

Empty state when nothing is connected. **Add account** → §2.

## 7. About

App info only: version, released, support. Credit line in the footer. No
mailbox data — that lives in §6.

## 8. Overflow menu

`•••` in the nav bar opens an anchored popover (`.menu` / `UIMenu`), not a
sheet: Refresh rules · Add account · Manage accounts · About Rulebook.

## 9. Issue model — the part the library doesn't do yet

Three distinct failure modes. Only the first comes from the server.

| Shown as | Level | Source |
| --- | --- | --- |
| Rule is in error | error | `status.hasError` |
| Folder is missing | error | **local check** — resolve every `moveTo`/`copyTo` folder against `FolderDirectory.folders()` |
| Never runs | warning | **local check** — an earlier rule (lower `order`) carries `.stopProcessing` |

The missing-folder case is the important one: the README notes a rule can point
at a deleted folder and still be reported healthy, silently dropping mail. The
detail copy says so explicitly — "Exchange still reports this rule as healthy."

Fixes: re-save the rule; choose a new folder; move the rule up (the warning's
fix button reorders it, which is why reorder isn't optional).

---

## Gaps in RulebookKit

Four things the app needs that the library doesn't have yet. All small.

1. **No reorder operation.** `RuleStore` has no `reorder`, so a drag becomes N
   `updateRule` calls to rewrite `order`, with partial-failure handling in the
   view model. A `func reorder(_ ids: [String]) async throws` on the protocol
   would put that in one place and let `GraphRuleStore` decide batching.
   Remember `sequence` must be unique.

2. **No issue diagnostics.** The two local checks in §9 are app-side today.
   They're provider-neutral policy and belong next to `RuleValidator` —
   something like `RuleDiagnostics.check(rules, folders:)` returning findings.
   Then the CLI gets `rulebook doctor` for free.

3. **No account model.** §6 manages multiple mailboxes; the library has one
   store per account and no notion of a set. Keep it app-side (an
   `AccountStore` over Keychain) unless the CLI ever needs it.

4. **`updateRule` merge semantics fight the editor.** Empty collections leave
   stored values alone, so a user *removing* every condition or action can't
   be expressed. Either a sentinel or explicit `clearConditions` flags — worth
   deciding before the edit screen is built.
