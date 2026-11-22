# Eventure Fleet Repair Tracker: Automation & "AI" Logic

*A technical explainer for the owner, staff trainers, and developers.*

This document describes how the app pulls email from Gmail, decides which repair
case an email belongs to, files the attached documents, and drafts outbound
follow-ups. The single most important thing to understand up front:

> **There is no LLM and no AI API key anywhere in this system.** Every "smart"
> decision is made by deterministic, rule-based code you can read, test, and
> audit. The engine cannot invent a case, leak your email to a third party, or
> behave differently on two identical inputs. Section 5 explains why this design
> was chosen.

All file paths below are relative to the project root.

---

## Table of contents

1. [Email pull / sync automation](#1-email-pull--sync-automation)
2. [Email → case routing](#2-email--case-routing-the-keyless-matching-engine)
3. [Document routing](#3-document-routing)
4. [Email creation automation](#4-email-creation-automation)
5. [The "AI" logic, explained](#5-the-ai-logic-explained)

---

## 1. Email pull / sync automation

**Files:** `lib/gmail/config.ts`, `lib/gmail/client.ts`, `lib/gmail/crypto.ts`,
`lib/gmail/sync.ts`, `app/api/gmail/connect/route.ts`,
`app/api/gmail/callback/route.ts`, `app/api/gmail/sync/route.ts`,
`netlify/functions/gmail-sync.mts`, `netlify/functions/gmail-sweep.mts`,
`app/actions/mailbox.ts`.

### 1.1 Connecting a mailbox (OAuth, read-only)

A staff member links a Gmail inbox once. The scope requested is **read-only**:

```ts
// lib/gmail/config.ts
export const GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.readonly";
```

The connect route (`app/api/gmail/connect/route.ts`) is staff-gated, then builds
Google's consent URL in `buildConsentUrl` (`lib/gmail/client.ts`):

| OAuth parameter | Value | Why |
|---|---|---|
| `scope` | `gmail.readonly` | The app can read mail but never send, delete, or modify it. |
| `access_type` | `offline` | Returns a **refresh token** so the app can mint access tokens later without the user present. |
| `prompt` | `consent` | Forces Google to re-issue a refresh token even on re-link. |
| `response_type` | `code` | Authorization-code flow. |
| `include_granted_scopes` | `true` | Incremental auth. |
| `state` | 32-byte random nonce | **CSRF protection** (see below). |

**CSRF defense.** The connect route generates
`crypto.randomBytes(32).toString("base64url")` and stores it in an **httpOnly**
cookie `gmail_oauth_state` (`secure` in production, `sameSite: "lax"`,
`maxAge: 600` = 10 minutes). On callback (`app/api/gmail/callback/route.ts`) the
returned `state` is compared to the cookie with a **constant-time** comparison
(`crypto.timingSafeEqual` in `sameState`). The cookie is deleted on *every*
terminal response (`back()`), so a state value is single-use. The callback even
distinguishes a **missing** cookie (`error=state_cookie_missing`, usually an
origin mismatch between the connect and callback hosts) from a **value mismatch**
(`error=state_mismatch`).

**Callback discovery + storage.** On a verified callback the route:
1. Exchanges the code for tokens (`exchangeCode`), requiring a `refresh_token`
   (else `error=no_refresh_token`).
2. Discovers the mailbox address via `getProfile`.
3. Encrypts the refresh token (`encryptToken`) and upserts a `gmail_connections`
   row keyed on `email_address` (`onConflict: "email_address"`), via the
   service-role admin client.

**No-SSRF hardening.** All Google endpoints are hard-coded constants in
`config.ts` (`GOOGLE_AUTH_URL`, `GOOGLE_TOKEN_URL`, `GMAIL_API_BASE`, …) and the
OAuth `redirect_uri` is derived from `NEXT_PUBLIC_SITE_URL` / an explicit env var, **never** from the request `Host` header (`oauthRedirectUri`).

### 1.2 Refresh-token encryption at rest (AES-256-GCM)

**File:** `lib/gmail/crypto.ts`. The refresh token is the long-lived secret, so
it is encrypted before it touches the database:

- Algorithm: `aes-256-gcm`.
- A random **12-byte IV** per encryption (`crypto.randomBytes(12)`).
- A **16-byte GCM auth tag** (tamper detection).
- Only `{ enc, iv, tag }` (base64) are stored, in the `refresh_token_enc`,
  `token_iv`, `token_tag` columns (`text`; created as `bytea` in migration
  `20260620000024_add_gmail_routing.sql`, then converted to `text`/base64 in
  `20260620000025_gmail_token_text.sql`). The **key never enters the database**;
  it lives in `GMAIL_TOKEN_ENC_KEY` and is accepted as 64 hex chars, 44-char
  base64, or (last resort) a passphrase hashed to 32 bytes with SHA-256.

The access token is minted from the refresh token **per run** (`refreshAccessToken`)
and **never stored**. If Google rejects the refresh token, `InvalidGrantError`
flips the connection to `needs_reauth` rather than erroring the whole run
(`connectionAccessToken` in `sync.ts`).

### 1.3 The two ingestion passes: `syncNow` vs `pullThreadsNow`

Both entry points share one idempotent per-message function, `ingestMessage`.
They differ only in **which message ids** they feed it.

| | `runSync` (→ `syncNow`) | `runThreadSweep` (→ `pullThreadsNow`) |
|---|---|---|
| What it pulls | **Every** message in the last 7 days | The **latest message of every thread** in the last 7 days |
| Gmail IDs via | `listMessageIds` | `listThreadIds` + `getThreadLatestMessageId` (picks max `internalDate`) |
| Typical trigger | Continuous poll (every 10 min) + staff "Sync now" | Daily/weekly scheduled sweep + staff "Pull now" |
| Scope control | n/a | `onlyDue` (scheduler respects cadence) and `connectionId` (one mailbox) |

Both use the same Gmail search query and per-run message cap:

```ts
// lib/gmail/sync.ts + config.ts
const SYNC_QUERY = "newer_than:7d -in:sent -in:chats -in:drafts"; // inbound only
export const SYNC_MESSAGE_CAP = 100;                               // per pass
```

The thread sweep exists because a long reply chain only needs its **newest**
message re-read; `getThreadLatestMessageId` fetches thread metadata in Gmail's
cheap `minimal` format and returns the id with the greatest `internalDate`.

**Sweep cadence** (`sweepDue` in `sync.ts`, column added in
`20260620000026_gmail_sweep_cadence.sql`): `daily` runs every scheduled day;
`weekly` runs when `now - last_swept_at >= 7 days`; `off` never runs on a
schedule (on-demand "Pull now" only). Staff set this via `setSweepCadence`.

### 1.4 The 7-day window

Only mail received in the last 7 days is ever ingested. The Gmail query already
filters (`newer_than:7d`), and `ingestMessage` re-checks with `withinSevenDays`
(`lib/email-routing.ts`):

```ts
const SEVEN_DAYS_MS = 7 * 86_400_000;
export function withinSevenDays(internalDateMs, nowMs) {
  return internalDateMs >= nowMs - SEVEN_DAYS_MS && internalDateMs <= nowMs + 86_400_000;
}
```

The timestamp used is Gmail's server-side `internalDate`, **never** the spoofable
`Date:` header. The `+ 86_400_000` (one day) is a small future tolerance to
absorb clock skew.

### 1.5 Time-boxing: `RUN_BUDGET_MS` + the `partial` flag

Netlify's serverless function is killed at ~10 s, so each run stops starting new
work after a wall-clock budget:

```ts
// lib/gmail/sync.ts
const RUN_BUDGET_MS = Number(process.env.GMAIL_RUN_BUDGET_MS) || 6000; // 6 s default
```

The budget is checked **before each connection and before each message**; when
exceeded the loop breaks and `result.partial = true` is returned. Because ingest
is idempotent (next section), the next run simply continues where this one
stopped, nothing is lost or doubled. `SyncResult` reports
`{ connections, fetched, routed, queued, skipped, errors, partial }`.

### 1.6 Idempotency (no double-logging)

The dedup key is **`inbound_emails.gmail_message_id`** (a `unique` column). Every
message is written with a **claim-first upsert that ignores duplicates**:

```ts
// ingestMessage, upsert BEFORE spending a download on attachments
.upsert({ … }, { onConflict: "gmail_message_id", ignoreDuplicates: true })
.select("id");
const inboundId = rows?.[0]?.id;
if (!inboundId) return; // already processed in an earlier run/pass
```

If the message was already ingested, the upsert returns **no row**, so the
function returns immediately, before any attachment download or case write. This
makes overlapping 7-day windows, the two passes, and retries all safe.

### 1.7 Retention purge

`purgeOldInboundEmails` runs at the start of every `runSync` / `runThreadSweep`:

- Deletes `inbound_emails` with `received_at` older than `RETENTION_DAYS`
  (`GMAIL_RETENTION_DAYS` env, **default 8**), a 1-day margin over the 7-day
  fetch window, so a purged message is already outside what a `newer_than:7d`
  query can re-pull.
- Deletes aged `gmail_ignored_messages` tombstones (same cutoff).
- Failures are swallowed, a purge problem must never break a sync.

The **permanent** record of a routed email is its `case_updates` row plus the
stored files; `case_updates.source_email_id` simply becomes `null` via
`ON DELETE SET NULL` when the raw inbound row is purged. This keeps the ledger
table small on the free plan.

### 1.8 The scheduled `/api/gmail/sync` route (CRON_SECRET)

**File:** `app/api/gmail/sync/route.ts`. This is the only network trigger for
automatic syncing and it authenticates itself:

- Returns `503 not_configured` if Gmail isn't configured or `CRON_SECRET` is
  unset.
- Compares the `x-cron-secret` header to `CRON_SECRET` with a **constant-time**
  comparison **before any work**; mismatch → `401 unauthorized`.
- Reads **no request body** and contacts only hard-coded Google hosts, so it
  can't be turned into an SSRF or an open trigger. It is exempted from the
  auth-redirect middleware (hence it must guard itself).
- Mode comes from a header set by the app's own scheduler:
  `x-gmail-mode: sweep` → `runThreadSweep({ onlyDue: true })`; otherwise
  `runSync()`.

Two Netlify Scheduled Functions call it:

| Function | Schedule (cron) | Effect |
|---|---|---|
| `netlify/functions/gmail-sync.mts` | `*/10 * * * *` (every 10 min) | POSTs with `x-cron-secret` → continuous `runSync` |
| `netlify/functions/gmail-sweep.mts` | `0 6 * * *` (daily 06:00 UTC) | POSTs with `x-cron-secret` + `x-gmail-mode: sweep` → `runThreadSweep({onlyDue:true})` |

Each function does nothing but forward the POST (all real work stays inside the
Next route, in one deploy), and both no-op cleanly when `CRON_SECRET` or the site
base URL is unset.

### 1.9 The ignored-message tombstone table

Because Gmail is connected **read-only**, the app cannot mark a message
read/archived on Google's side to stop it being re-pulled. The solution is a
one-column tombstone table (`20260620000028_gmail_ignored_messages.sql`):

```sql
create table gmail_ignored_messages (
  gmail_message_id text primary key,
  ignored_at timestamptz not null default now()
);
```

When a staff member clicks **Ignore** (`ignoreInboundEmail` in
`app/actions/mailbox.ts`), the app:
1. Records the tombstone **first** (`upsert … ignoreDuplicates`).
2. Hard-deletes the `inbound_emails` row.

On the next run, `loadIgnoredSet` loads all tombstones once, and `ingestMessage`
checks `ignored.has(id)` **before any network/DB fetch**, a cheap in-memory
skip. Tombstones are themselves purged once they age past the fetch window
(1.7), by which point the message can no longer be re-pulled anyway.

> **Disconnect note.** `disconnectMailbox` best-effort revokes the token at
> Google, nulls out the stored token columns, and scrubs PII from the inbound
> rows (`from_email`, `from_name`, `subject`, `snippet`, `match_reason`), but
> **keeps** the `gmail_message_id` + `status` dedup ledger. Deleting it would
> drop the only idempotency key, so reconnecting the same mailbox within 7 days
> would re-ingest and double-log every message.

---

## 2. Email → case routing (the keyless matching engine)

**File:** `lib/email-routing.ts`. This is a **pure, deterministic** scoring
engine: given a `ParsedEmail` and a prebuilt `CaseIndex`, it returns a
`MatchResult` with no I/O. The sync layer owns all side effects. The design
guardrails (from the file header) are worth stating plainly:

- **Content beats sender identity.** An adjuster emails one address about many
  claims, so a VIN or claim number in the body outranks "we recognize this
  sender."
- **Misfiling is the worst outcome.** Near-ties and content-vs-sender conflicts
  go to a human review queue, never silently to the wrong case.
- **Injection defense.** The string written to `case_updates.summary` is
  system-generated and carries no email body (section 4/5).
- **DoS bound.** All text is truncated to 64 KB before any regex, and every
  pattern is linear.

### 2.1 Building the index (`buildCaseIndex`)

Once per run, `loadCaseIndex` loads **active cases only** (`.neq("status",
"closed")`) and builds lookup maps. A closed case is never a routing target, the correspondence is stale. The index contains:

| Map | Key → value | Built from |
|---|---|---|
| `byId` | caseId → case | n/a |
| `claim` | normalized claim → caseIds | `claim_number` (if `isIndexableClaim`) |
| `vin` | normalized VIN → caseIds | `vin` (if `isIndexableVin`) |
| `vinLast6` | last 6 of VIN → caseIds | `vin` |
| `contact` | email → `{caseId, party}` | `adjuster_contact`, `appraiser_contact`, `owner_contact`, body shop `contact_email` |
| `contactDomain` | domain → `{caseId, party}` | same, by domain |
| `corroboration` | owner/vehicle/shop tokens | `owner_name`, `vehicle_name`, `body_shop_name` |

Indexability guards keep junk out: `isIndexableClaim` requires length 6-25, at
least one digit, and rejects placeholders (`N/A`, `PENDING`, `TBD`, all-zeros,
…). `isIndexableVin` requires exactly 17 chars with at least one digit **and**
one letter. The app's own domain (`eventure.tech`, `INTERNAL_DOMAINS`) is never
indexed as a counterparty contact.

### 2.2 The signal → weight table

Each matched signal contributes a **base weight**. These are the real numbers
(`WEIGHTS` in `lib/email-routing.ts`):

| Signal (`SignalKind`) | Weight | What it means |
|---|---:|---|
| `vin` | **100** | A full 17-char VIN that matches a case. The gold standard. |
| `claim_labeled` | **85** | A claim number preceded by a label ("Claim #…", "RRN:", "File no."). |
| `claim_prefixed` | **72** | A claim-shaped token with a letter prefix or ≥9 chars (distinctive). |
| `sender_exact` | **60** | The sender's address is a stored contact on the case. |
| `claim_digits` | **45** | A bare all-digit claim match (weaker, collides with other numbers). |
| `vin_last6` | **30** | The last 6 of the VIN (how shops often reference a car). |
| `sender_domain` | **22** | The sender's domain matches a stored contact's domain. |
| `vehicle_name` | **16** | The vehicle description appears in the text. |
| `owner_name` | **15** | The owner's first **and** last name appear as whole words. |
| `body_shop_name` | **10** | The shop's name (or ≥2 non-generic shop tokens) appears. |

**Location & modifier adjustments.** The effective contribution of one raw hit
is `max(0, (base + modifier) * multiplier)` (`effectiveWeight`):

| Adjustment | Value | When |
|---|---:|---|
| `QUOTED_MULTIPLIER` | **×0.5** | The signal sits in trailing reply-thread quotes, not the new text. |
| `SUBJECT_CLAIM_BONUS` | **+15** | A claim number found in the **subject** (where adjusters put it). |
| `VIN_LABEL_BONUS` | **+25** | A last-6 token preceded by a "VIN" / "last 6" cue, lifts it out of noise. |
| `NUMERIC_CLAIM_PENALTY` | **−15** | A labeled claim whose token is all digits (could be a phone/ZIP/date). |

Subject and new-body text are scanned at full weight; trailing quotes at half.
**Attachment text (a PDF estimate) is scanned at full weight**, authoritative
content, so a bare "estimate attached" email routes on the VIN/claim *inside*
the PDF (`extractSignals`).

### 2.3 Tiers and their numeric cutoffs

The best case's **raw (uncapped) score** maps to a confidence tier (`tierOf`):

| Tier | Raw score | Meaning |
|---|---|---|
| **HIGH** | ≥ 80 | Strong, specific evidence (e.g. a full VIN, or a labeled claim in the subject). |
| **MEDIUM** | 45-79 | Good evidence (e.g. a labeled claim, or an exact sender + a name). |
| **LOW** | 20-44 | Weak, always queued for a human. |
| **NONE** | < 20 | No usable match, queued as `no_match`. |

### 2.4 Scoring (`scoreCases`), anti-self-corroboration

For each case, **each signal *kind* contributes at most once** (its strongest
hit). Three subsumption rules prevent double-counting the same underlying fact:

- `sender_exact` deletes `sender_domain` (a known exact sender subsumes its own
  domain).
- `vin` deletes `vin_last6` (a full VIN subsumes its own last 6).
- **All claim kinds collapse to a single strongest contribution.** A case has
  exactly one claim number, so "Claim #X" (labeled, 85) plus a bare "X"
  (digits, 45) refer to the *same* string in two surface forms. Collapsing them
  stops one claim from self-corroborating (85 + 45 = 130) and falsely clearing
  an ambiguity margin.

### 2.5 The decision (`decide`), margins, guards, and conflict handling

After scoring, cases are ranked by score (ties broken by caseId for
determinism). Then:

**Skip gate first.** `classifyMessageType` (section 2.7) runs: `auto_reply` and
`bounce` always skip; `bulk` skips unless the score is ≥ 80.

**Low-confidence queueing.**
- `tier === NONE` → queue `no_match`.
- `tier === LOW` → queue `low_confidence`.
- **Quoted-only evidence** → queue `low_confidence`. Even if a VIN sitting only
  in the quotes scores 100 × 0.5 = 50 (clearing MEDIUM), it may belong to a
  different, merged, or mis-replied conversation, so it is never auto-routed.

**Margin guards (ambiguity).** The winner must beat the runner-up by a minimum
margin, or a human decides:

| Guard | Value | Effect |
|---|---:|---|
| `ROUTE_MARGIN.HIGH` | **25** | At HIGH tier, best − second must be ≥ 25. |
| `ROUTE_MARGIN.MEDIUM` | **20** | At MEDIUM tier, best − second must be ≥ 20. |
| `CONFLICT_MARGIN` | **25** | Content-vs-sender conflict window (below). |

If `margin < need`, the result is queued as `ambiguous_multiple_cases` with the
two contenders attached.

**"Content beats sender" conflict handling.** This is the signature misfiling
guard. Define *strong content* as `vin`, `claim_labeled`, or `claim_prefixed`
(`STRONG_CONTENT`). If the winner has strong content but a **recognized sender**
(`sender_exact`) points at a *different* case:

- If that sender's case is within `CONFLICT_MARGIN` (25) of the winner →
  **queue** `conflict_content_vs_sender`, listing both case ids. A human decides.
- If the sender's case is **beyond** the conflict margin → **content wins and it
  routes**, but confidence is **capped to MEDIUM** (`capTier`) *unless* the
  winner is self-backed (it also has `sender_exact`, `owner_name`,
  `vehicle_name`, or `body_shop_name`). Either way the result carries
  `senderPointsElsewhere` so the review UI can surface it, never a silent
  override.

**Optional corroboration gate.** If `GMAIL_REQUIRE_CORROBORATION=true` (default
false; the mailbox is claim-number heavy, so lone strong claims auto-route), a
claim-only match must also carry a `vin` or `sender_exact` on the routed case,
else it queues as `needs_corroboration`.

The `QueueReason` values a developer will see in the ledger:
`ambiguous_multiple_cases`, `low_confidence`, `conflict_content_vs_sender`,
`needs_corroboration`, `no_match`.

### 2.6 Party inference (`inferParty`)

The party label (`adjuster | appraiser | body_shop | owner | other`) is derived
**from the sender, never from body prose** (which is attacker-controlled). Order:

1. **Exact contact on the routed case** is authoritative. (It does *not* fall
   back to a party from some *other* case's contact record, the same address
   can be an owner on one case and an appraiser on another.)
2. **Carrier / TPA domain** → `adjuster`, upgraded to `appraiser` when the text
   has an appraisal cue (`apprais|estimat|re-inspect|supplement`) and no adjuster
   cue. (`CARRIER_DOMAINS` = State Farm, GEICO, Progressive, Allstate, USAA, …;
   `TPA_DOMAINS` = CCC, Mitchell, Audatex, Solera, Sedgwick, …)
3. **Body-shop** domain or ≥2 distinctive shop-name tokens shared with the case.
4. **Owner**, sender is the owner's email, or only `owner_name` corroborated.
5. Otherwise `other`.

### 2.7 Message-type classification (`classifyMessageType`)

The skip gate recognizes automated mail that should not be treated as
correspondence, from headers (never body text):

| Result | Triggers |
|---|---|
| `bounce` | `Return-Path: <>` or `<mailer-daemon>`; From `mailer-daemon@`/`postmaster@`; `X-Failed-Recipients`; `multipart/report` + `delivery-status`. |
| `auto_reply` | `Auto-Submitted: auto*`; `X-Autoreply`/`X-Autorespond`/`X-Auto-Response-Suppress`; `Precedence: auto_reply`; subject like "Automatic reply"/"Out of office"/"OOO". |
| `bulk` | `List-Unsubscribe`/`List-Id`; `Precedence: bulk` or `list`. |
| `normal` | none of the above. |

### 2.8 What "logging onto a case" actually writes

When `decide` returns `action: "route"` with a `caseId`, `ingestMessage` inserts
a **contact-log row** into `case_updates`:

| `case_updates` field | Value |
|---|---|
| `case_id` | the matched case |
| `party` | the inferred party |
| `direction` | `"inbound"` |
| `channel` | `"email"` |
| `occurred_on` | civil date (YYYY-MM-DD) of `internalDate` in the business timezone, `occurredOn`, default `America/Chicago` (`GMAIL_BUSINESS_TZ`) |
| `created_by` | `"gmail-ingest"` |
| `summary` | `buildLogSummary`, system text, **no email body** (section 4) |
| `source` | `"gmail"` |
| `source_email_id` | the `inbound_emails` row id |

The raw `inbound_emails` ledger row records the full decision for audit:
`action`, `matched_case_id`, `matched_party`, `confidence`, `confidence_tier`,
`match_reason` (a JSONB blob of tier/score/reason/signals/conflicts, see
`reasonJson`), and a `status` derived by `statusFor`:

| `action` | `inbound_emails.status` |
|---|---|
| `route` | `matched` |
| `queue` | `unrouted` |
| `skip` | `ignored` |

**Failure safety.** If the `case_updates` insert fails after a route decision,
the inbound row is flipped to `status: "error"` so it surfaces in the review
queue for a human, it never silently vanishes (dedup means it is never retried).

### 2.9 What happens on low confidence (the Inbox review queue)

Anything not routed or skipped lands in the **Inbox** with `status: 'unrouted'`
(or `'error'`). `getInboundQueue` (`lib/gmail/queries.ts`) serves these as the
queue, plus recent `matched` rows. A staff member then either:

- **Assigns** it (`assignInboundEmail`), picks a case + party, which creates the
  same badged, sanitized `case_updates` row the auto-route path would
  (`composeLogSummary`), files any queued attachments (section 3), and optionally
  saves the sender onto an *empty* case contact field (a confirmed "learning
  loop", never automatic, never overwriting).
- **Ignores** it (`ignoreInboundEmail`), tombstone + hard delete (section 1.9).

---

## 3. Document routing

**File:** `lib/gmail/attachments.ts` (+ `lib/gmail/pdf.ts` for text extraction).
This decides, keylessly, what each PDF/image attachment *is* and where it belongs.

### 3.1 Which attachments are ingested (`pickIngestable`)

Only PDFs and images, within size and count caps:

| Bound | Value |
|---|---|
| `MAX_ATTACHMENT_BYTES` | 15 MB per file |
| `MAX_ATTACHMENTS` | 6 per email |
| Accepted types | `application/pdf` / `.pdf`, and `image/(jpe?g\|png\|heic\|heif\|webp\|gif\|tiff?)` |

### 3.2 Keyless PDF text extraction (`extractPdfText`)

**File:** `lib/gmail/pdf.ts`. Uses the **`pdfjs-dist` legacy build** (Node-side,
no worker), loaded via a **dynamic import inside try/catch** so that if it can't
initialize in a serverless runtime, extraction degrades to `""` (the file is
still stored) instead of crashing the whole sync.

| Guard | Value | Purpose |
|---|---:|---|
| `PARSE_TIMEOUT_MS` | 4000 ms | `Promise.race` with a timeout that resolves `""`, stays well under the function budget. |
| `MAX_PAGES` | 15 | Only the first 15 pages are read. |
| `MAX_TEXT_CHARS` | 200,000 | Hard cap before the matcher's own 64 KB slice; the loop breaks once exceeded. |

Safety flags: `isEvalSupported: false` (no eval-based font parsing on untrusted
PDFs), `disableFontFace`, `useSystemFonts`; the input buffer is copied before
handing it to pdfjs (which mutates it). A **scanned / image-only PDF has no text
layer**, so this returns little or nothing, such a document is **stored but
queued for a human**, never auto-routed on content.

### 3.3 How extracted text feeds routing (`ingestMessage`, `readAttachments`)

`ingestMessage` first does a **provisional match on the email text alone**
(cheap, enough to claim + dedup the message). Only after it owns the message does
it download attachments (`readAttachments`), extract PDF text, set
`email.attachmentText`, and **re-run `matchEmail`** to refine the decision. This
is why a bare "estimate attached" email can still route, on the VIN or claim
*inside* the PDF, scanned at full weight.

### 3.4 Document kind (`classifyDocument` → `DocKind`)

`DocKind` is `"estimate" | "image_report" | "payment" | "other"`. The decision
order (filename-type precedence matters here):

1. **Payment first.** A receipt / paid-confirmation is money *we paid out*, not
   an estimate. `PAYMENT_CUE_RE` on the attachment name or text always wins; an
   **email-level** payment cue counts too, *unless* the attachment clearly reads
   as an estimate. (Notably, a bare "invoice" is **not** a payment cue, that's a
   bill, not proof of payment.) → kind `payment`, with `extractPaidAmount` and
   `detectMethod`.
2. **Image by MIME/extension** → `image_report`.
3. **Filename precedence over text.** An explicit image filename beats
   estimate-ish line items ("labor", "refinish") that a photo report's captions
   may contain:
   - `nameLooksImage && !nameLooksEstimate` → `image_report`
   - else `looksEstimate` (cue or "estimate"/"supplement" in the name) → `estimate`
   - else `IMAGE_CUE` in the text → `image_report`
   - else default → `estimate` (a PDF from a shop/appraiser with no cue is most
     likely an estimate).

The regex vocabulary (all in `attachments.ts`): `ESTIMATE_CUE`
(estimate/supplement/repair order/RO#/labor/refinish/paint & materials/…),
`IMAGE_CUE` (photo/images/damage report/inspection…), `PAYMENT_CUE_RE`
(payment receipt/confirmation/remittance/proof of payment/paid in full/…),
`TOTAL_RE` and `PAID_AMOUNT_RE` (dollar extraction, largest match wins),
`PAYMENT_METHOD_RE` (ACH/wire/e-check/check #/card/Zelle/PayPal/Venmo/EFT).

### 3.5 Estimate source: body shop vs appraiser (`classifyEstimateSource`)

For an estimate, *whose* estimate is it?

- **The recognized sender is authoritative.** `party === "body_shop"` →
  `body_shop`; `party === "appraiser"` or `"adjuster"` → `appraiser`.
- **Ambiguous sender (owner/other) → read the document.** Points are tallied:
  - Body-shop side: the shop's own name branding the doc (full name +3, ≥2
    distinctive tokens +2, ≥1 token +1) and `BODYSHOP_CUE_RE` (repair order, RO#,
    collision center, body shop…) +2.
  - Insurer side: `APPRAISAL_STRONG_RE` (apprais*/desk review/independent
    appraisal/re-inspection) +3. A mere carrier or insurer mention
    (`CARRIER_NAME_RE` / `INSURER_WEAK_RE`) is **weak**, it counts +1 *only when
    a strong appraisal signal is already present*, because a shop's own CCC
    printout names the carrier too.
  - Higher side wins; **a tie or no signal defaults to `body_shop`**, in this
    pipeline an unattributed estimate is far more likely the shop's.

> **Design note in the code:** "Estimate of Record" is deliberately **not** an
> insurer tell, in the Tesla collision workflow the *shop's* own estimate is
> titled "Estimate of Record."

**`isClearlyInsurerAppraisal(text)`** is the strict test: `APPRAISAL_STRONG_RE`
**AND** `CARRIER_NAME_RE` both present. It's used by the historical re-file (3.7)
to avoid flipping genuine appraisals to the shop side.

### 3.6 Where each kind is stored (`storeAttachmentOnCase`)

| Kind | Storage bucket + path | DB table | Notes |
|---|---|---|---|
| `payment` | `payments` → `{caseId}/{stamp}-{name}` | `case_payments` | `direction: "outbound"` = **"paid by us"**; `amount`, `paid_on`, `method`. **Never** marks the case paid-to-us. |
| `estimate` | `estimates` → `{caseId}/{source}/{stamp}-{name}` | `case_estimates` | `source` = `body_shop`/`appraiser`; `amount` = `extractTotal`. |
| `image_report` / `other` | `documents` → `damage_report/{yyyy}/{mm}/{caseId}/{uuid}.{ext}` | `documents` (`module: "damage_report"`, `record_id: caseId`) | Photos / damage reports. |

Every stored row is stamped `uploaded_by: "gmail-ingest"`. Hardening:
`safeFilename` strips unsafe chars; **`safeContentType` pins the stored type to
image/PDF/`application/octet-stream`** regardless of what the sender declared, so
a malicious `text/html` attachment can never execute through a signed-URL view;
and if the DB insert fails, the just-uploaded object is removed (no orphans).

In the auto-route path, `storeAttachmentsOnCase` classifies and stores every
attachment, passing the body-shop name and the email text (so an email-stated
payment can classify a terse receipt PDF) and the `occurredOn` date as `paid_on`.

### 3.7 The historical re-file (`reclassifyIngestedEstimates`)

**File:** `app/actions/mailbox.ts`. A re-runnable, staff-triggered one-time fix
for documents ingested **before** the content-aware classifier existed. The
original emails are gone, so it classifies from the stored file alone (party
`"other"`):

- Reads every `case_estimates` row with `uploaded_by = 'gmail-ingest'`, downloads
  the file from the `estimates` bucket, re-extracts PDF text, and re-classifies.
- A **receipt** (→ payments / paid-by-us) or a **photo report** (→ case
  documents) that was mistaken for an estimate is stored in the right place, then
  the estimate row + file are removed.
- An estimate sitting on the `/appraiser/` path that is **not**
  `isClearlyInsurerAppraisal` is moved to `/body_shop/` and its `source` flipped, this catches docs whose text extraction was thin (they score as a tie; only a
  real carrier-named appraisal stays on the appraiser side).
- Time-boxed at 7000 ms with a `partial` flag; per-file errors are swallowed so
  one bad file never fails the run. Returns `{ checked, refiled, partial }`.

---

## 4. Email creation automation

### 4.1 The app is read-only Gmail, it never auto-sends

State this plainly to staff: **the app does not send, reply to, forward, or
modify any email.** The OAuth scope is `gmail.readonly` and the code comment is
explicit: *"Read-only: we never send, delete, or modify mail."* (`config.ts`).
There is no `send`, `reply`, or `compose` call to Gmail anywhere in the codebase.
What the app *does* is **generate text for humans**, in three distinct places.

### 4.2 System-generated log lines (`buildLogSummary` / `composeLogSummary`)

For every routed or assigned email, the app writes a short, structured
`case_updates.summary` such as:

> `Inbound email from adjuster jane@statefarm.com, subj: Estimate approved`

This is produced by `composeLogSummary` (`lib/email-routing.ts`), used by both
the auto-route path (via `buildLogSummary`) and the manual assign path
(`assignInboundEmail`). Crucially it carries **no email body content**, only the
party, the *extracted canonical* sender address (`detectEmail`, which returns
just the address substring), and the de-prefixed subject, each run through
`sanitizeInline`. This split is load-bearing for injection safety (section 5).

### 4.3 The review-queue preview (`buildQueueSnippet`)

`buildQueueSnippet` produces `inbound_emails.snippet`, a **UI-only** triage
preview: `sanitizeInline(e.topText, 300)`. It *does* contain (sanitized) body
text, is React-escaped at render (never `dangerouslySetInnerHTML`), and the
follow-up drafter **never reads it**. It exists so staff can glance at a queued
email without opening Gmail.

### 4.4 The follow-up drafter (`lib/followups.ts`), prefills, doesn't send

This is the real "email creation" feature, and it is **also keyless and
deterministic**, "no external service or API key." `buildFollowUpEmail` turns a
case's pipeline position and latest notes into a ready-to-review email tailored
to the recipient (`body_shop | adjuster | appraiser | owner`). It produces
`{ subject, body, to, recipientLabel }`.

How it's grounded in real case data (not generated prose):

- **Recipient targeting**, `suggestedRecipient` picks who to chase from the case
  status (e.g. `claim_filed_awaiting_adjuster` → adjuster; `in_repair` → body
  shop; a denied/below-deductible case → owner).
- **Note-signal taxonomy**, `readNoteSignals` scans the latest notes with
  regexes for `noResponse`, `priorOutreach`, `totalLoss`, `supplement(Approved/
  Pending)`, `partsDelay`, `rental`, `approvalGiven`, and a `lastContactRef`.
  These switch the email into "second-request" tone, parts/supplement/total-loss
  context, etc.
- **Concrete expert asks**, `asksFor` emits the specific "what we need to move
  forward" bullets per status and recipient (inspection date, written supplement
  approval with the dollar gap, ACV + valuation report, itemized invoice + scan
  reports, …).
- **Real-time, never-stale deadlines**, every "reply by" date is computed from
  `today()` via `deadlinePhrase`/`addBusinessDays` (never the internal
  `next_follow_up` reminder), and time-sensitive facts are quantified ("the Jul 1
  ETA passed 9 days ago", "in the shop 21 days").
- **Context awareness**, `acknowledgeInbound` opens with a line referencing what
  the party last actually told us (from the `case_updates` contact log), so the
  draft reads as up to date, unless a live no-response chase makes that stale.

**Delivery is manual.** The UI (`components/case/follow-up-email-dialog.tsx`)
renders the draft in editable Subject/Message fields and offers exactly two
actions:

- **Copy** → `navigator.clipboard.writeText(...)`.
- **Open in email app** → builds a `mailto:${to}?subject=…&body=…` link and
  clicks it.

The staff member reviews, edits, and sends from **their own email client**.
Nothing leaves the app automatically.

The same drafter powers the **daily action queue** (`caseActionPlan`,
`nextActionLine`, `actionPriority`), a deterministic priority score (overdue
follow-up age, ETA breach, time stuck past a stage SLA, dollar exposure band, and
note-signal boosts) that ranks which cases need attention, each with its
one-line next action and a pre-drafted email.

> **The injection split, restated.** `inboundAckSentence` can splice a
> `case_updates.summary` into a follow-up draft. Because that summary is the
> system-generated line from 4.2 (no body content), **no attacker-controlled
> email prose can ever reach a staff-signed outbound email.** The rich,
> untrusted preview lives only in `inbound_emails.snippet`, which the drafter
> never touches.

---

## 5. The "AI" logic, explained

### 5.1 It is keyless and deterministic, there are no LLM calls

Every routing, classification, and drafting decision in this app is made by
plain, readable rules, scored weights, regexes, and thresholds. There is **no
call to any external LLM or AI model**, and **no AI API key** is required or
used at runtime. The file headers say so directly:

- *"Deterministic inbound-email → repair-case routing. NO LLM, NO API key at
  runtime…"* (`lib/email-routing.ts`)
- *"Keyless PDF text extraction … no LLM, no API key."* (`lib/gmail/pdf.ts`,
  `lib/gmail/attachments.ts`)
- *"Deterministic follow-up email drafting, no external service or API key."*
  (`lib/followups.ts`)

### 5.2 Why it was built this way

The rationale is stated in the routing engine's own header and holds for the
whole system:

- **Accuracy for this data.** Emails carry *structured identifiers*, claim
  numbers, VINs, known contact addresses. A scored rule matcher is *more*
  reliable here than a language model: **it cannot hallucinate a case.**
- **Auditability.** Every decision carries a reason. The `match_reason` JSONB on
  each `inbound_emails` row records the tier, the numeric score, the queue/skip
  reason, the exact signals that fired (with their weights and locations), and
  any conflicting case ids. A developer or staff member can see *why* an email
  went where it went, and reproduce it.
- **Determinism & testability.** The engine is a pure function, same input,
  same output, so it is unit-testable against fixtures and never drifts.
- **Privacy.** No email content is ever sent to a third-party model. The data
  stays inside your Supabase project and the hard-coded Google endpoints.
- **Cost & free-plan friendliness.** No per-token inference bill, no extra
  vendor, and retention/purge keep the tables small on the free plan.

### 5.3 Input sanitization (`sanitizeInline`)

Everything that reaches a persisted field passes through `sanitizeInline`
(`lib/email-routing.ts`), which neutralizes the tricks hostile text uses:

| Stripped / normalized | Characters | Why |
|---|---|---|
| Control chars (incl. CR/LF/TAB) | `U+0000-001F`, `U+007F-009F` → space | Prevents header/line injection into log lines. |
| Zero-width chars | `U+200B-200D`, `U+2060`, `U+FEFF` removed | Stops invisible splitting of keywords. |
| Bidi overrides + soft hyphen | `U+00AD`, `U+200E/200F`, `U+202A-202E`, `U+2066-2069` removed | Stops right-to-left spoofing of addresses/subjects. |
| Whitespace | collapsed to single spaces | Normalization. |
| Length | hard cap with an ellipsis | Bounds every stored field. |

Sender fields, subjects, filenames, and snippets are all sanitized **at rest**,
so nothing unsanitized is ever persisted, even for display.

Alongside sanitization, the engine is bounded against denial-of-service: all text
is truncated to **64 KB** (`MAX_SCAN_BYTES`) before any regex; the body
accumulator is capped (`CAP = 256 KB`) before `htmlToText`, whose quantifiers are
deliberately bounded to stay linear; and the address parser caps header length
and avoids backtracking-prone patterns. A forged `From:` line inside a forwarded
body is only trusted when the *real* envelope sender is an internal
(`@eventure.tech`) forwarder (`parseGmailMessage` → `innerFrom`).

### 5.4 How the score + tiers make it auditable

The confidence model is the opposite of a black box:

1. Each signal contributes a **known integer weight** (section 2.2), adjusted by
   **known modifiers** (subject bonus, quoted half-weight, numeric penalty, VIN
   label bonus).
2. The sum maps to a **named tier** with **published cutoffs** (HIGH ≥ 80,
   MEDIUM ≥ 45, LOW ≥ 20).
3. Auto-routing additionally requires clearing **explicit margins** (HIGH 25,
   MEDIUM 20) and surviving the **content-vs-sender conflict** check (margin 25).
4. The full breakdown is **persisted** in `match_reason` and shown in the review
   UI, and every borderline case is **queued to a human** rather than guessed.

Because the weights, cutoffs, and margins are all constants in one file, the
owner can tune the system's caution (or flip on `GMAIL_REQUIRE_CORROBORATION`)
without retraining anything, and a developer can explain or reproduce any
decision the system has ever made.

---

### Quick reference, key constants

| Constant | Value | File |
|---|---|---|
| `GMAIL_SCOPE` | `gmail.readonly` | `lib/gmail/config.ts` |
| `SYNC_QUERY` | `newer_than:7d -in:sent -in:chats -in:drafts` | `lib/gmail/sync.ts` |
| `SYNC_MESSAGE_CAP` | 100 | `lib/gmail/config.ts` |
| `RUN_BUDGET_MS` | 6000 (env `GMAIL_RUN_BUDGET_MS`) | `lib/gmail/sync.ts` |
| `RETENTION_DAYS` | 8 (env `GMAIL_RETENTION_DAYS`) | `lib/gmail/config.ts` |
| `SEVEN_DAYS_MS` | 7 × 86.4 M (+1 day future tolerance) | `lib/email-routing.ts` |
| Tier cutoffs | HIGH ≥ 80, MEDIUM ≥ 45, LOW ≥ 20, NONE < 20 | `lib/email-routing.ts` |
| `ROUTE_MARGIN` | HIGH 25, MEDIUM 20 | `lib/email-routing.ts` |
| `CONFLICT_MARGIN` | 25 | `lib/email-routing.ts` |
| `MAX_SCAN_BYTES` | 64 KB | `lib/email-routing.ts` |
| PDF caps | 15 pages, 200 K chars, 4000 ms timeout | `lib/gmail/pdf.ts` |
| Attachment caps | 15 MB/file, 6/email | `lib/gmail/attachments.ts` |
| Sync schedule | every 10 min | `netlify/functions/gmail-sync.mts` |
| Sweep schedule | daily 06:00 UTC | `netlify/functions/gmail-sweep.mts` |
| Token encryption | AES-256-GCM (12-byte IV, 16-byte tag) | `lib/gmail/crypto.ts` |
