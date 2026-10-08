# Recorded Graph behaviour

Every file here is a real exchange with `/me/mailFolders/inbox/messageRules`,
recorded by `Tests/RulebookLiveTests/GraphProbe.swift` against a test mailbox
(a personal Microsoft account) on 2026-10-08. Account-identifying values are
redacted: request ids, the user in `@odata.context`, addresses outside
`@example.invalid` (→ `personN@example.com`), and the names of rules the probe
did not create (→ "Existing rule N").

Re-record with:

    RULEBOOK_LIVE=1 RULEBOOK_PROBE=1 RULEBOOK_CLIENT_ID=<id> swift test --filter GraphProbe

Each file holds `exchanges`: method, path, request body, status, response
body, and a label. A create is always followed by a GET of the same rule,
because what Graph stores is not always what it was sent.

## What Graph does that the code must account for

### Writes
- **PATCH replaces a top-level object; it does not merge.** Sending
  `conditions: {bodyContains}` to a rule with `{senderContains, subjectContains}`
  leaves only `bodyContains` (`patch-conditions.json`). The same applies to
  `actions` and `exceptions`.
- **To clear `conditions` or `exceptions`, send `{}`.** `null` and omitting the
  key both leave the stored value alone (`patch-exceptions.json`).
- **`actions` can never be empty:** `{}` → 400 `MissingAction`. `null` is ignored.
- **A null *inside* a predicate object is a 400** (`RequestBodyRead`), not a clear.
- **Unknown keys, wrong types and unknown enum values are 400s**
  (`UnableToDeserializePostBody` / `RequestBodyRead`). Graph is strict.
- `isReadOnly` / `hasError` in a POST body are ignored.
- Duplicate `displayName`s are allowed. An empty name is a 400
  (`EmptyValueFound`). Names are limited to 256 characters (`StringValueTooBig`).
  A POST with **no** `displayName` succeeds, and the rule gets the name of a
  different rule (`unnamed.json`). Always send a name.

### False booleans are silently dropped
- **`isMeetingRequest: false`, `hasAttachments: false`, `isEncrypted: false`,
  `sentToMe: false` are stored as *no condition at all*** (`predicates-negated.json`).
  A rule whose only condition is a false boolean then matches **every
  message**. This applies to exceptions too (`casing.json`).
- `markAsRead: false` counts as no action → 400 `MissingAction`.

### Actions Graph rewrites
- **Moving to Deleted Items is stored as `delete: true`** (`folders.json`).
  Copying to Deleted Items is kept as a copy.
- **`delete` and `permanentDelete` always come back with
  `stopProcessingRules: true`**, even when `false` was sent.
- `moveToFolder` takes a folder id or a well-known name (`deleteditems`),
  never a display name: `"Deleted Items"` → 400 `InvalidValue` "Id is malformed."
- Unknown categories in `assignCategories` are accepted as-is.
- `moveToFolder` and `copyToFolder` can coexist.

### Sequence
- **Graph keeps sequences dense, 1…N.** A POST or PATCH to position *k*
  inserts there and shifts everything at or below *k* down by one. A value
  past the end (901, 2 000 000 000) is clamped to N+1. Duplicates never exist
  (`sequence.json`).
- So reordering is **one PATCH of the moved rule's `sequence`**, 1-based.
  Renumbering every rule is unnecessary.
- `0`, negative, and **omitted** sequence → 400 `InvalidValue` (Field `Sequence`).

### Casing
- **`senderContains` and `recipientContains` are upper-cased on storage.**
  `subjectContains`, `bodyContains`, `headerContains`, `bodyOrSubjectContains`,
  and the addresses and names in `fromAddresses`/`sentToAddresses`/`forwardTo`
  keep their case (`casing.json`). Compare those two predicates case-insensitively.
- Display names on recipients (`fromAddresses`, `forwardTo`, …) are stored
  and returned.

### Size (`withinSizeRange`, kilobytes)
- **There is no "at least" alone:** an omitted `maximumSize` is read as 0, so
  `{minimumSize: 50}` → 400 `InvalidSizeRange` "minimum size 50 is greater than
  the maximum size 0" (`size-bounds.json`). Send a large maximum instead;
  `2097151` (2 GB in KB) is accepted, `2147483647` is not.
- An omitted `minimumSize` reads back as `0`.
- Negative → 400 `SizeLessThanZero`. min > max → 400 `InvalidSizeRange`.

### Reads and errors
- The list is not paged at this size: `$top=1` is ignored and no
  `@odata.nextLink` comes back (`baseline.json`).
- Rule ids look like `AQAAAAA1fo4=`: short base64 with `=` padding.
- Unknown id on GET/PATCH/DELETE → 404 `ErrorMessageRuleNotFound`. A second
  DELETE of the same rule → 404, so treat "not found" on delete as success.
- An encoded `/` (`%2F`) in the id segment is decoded by Graph as a path
  separator → 400 `BadRequest` "Resource not found for the segment".
- Bad or empty token → 401 `InvalidAuthenticationToken`.
- PATCH returns the full rule (same shape as GET), with `@odata.context`.
