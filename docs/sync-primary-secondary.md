# Primary → Secondary Pi-hole v6 Sync (Phased Plan)

## Goal
Add an optional feature to PiBar that keeps two **Pi-hole v6** instances in sync using a **Primary → Secondary** model:
- Primary is source of truth
- Secondary is reconciled to match Primary
- Sync runs **manually (“Sync Now”) + on an interval**
- Sync scope (locked): **Adlists + Allow/Deny (Exact + Regex)** + **Groups + assignments**
- Secondary extras policy (locked): **delete** extra adlists/domains; **disable** extra groups

## Non-Goals (for v1)
- Legacy Pi-hole (< v6) syncing
- Bi-directional merge/conflict resolution
- Client/group membership syncing
- Teleporter full backup/restore (unless later phase)

## Prerequisites
- Two configured connections in PiBar, both `isV6 == true`
- Secondary Pi-hole allows API writes (likely requires `webserver.api.app_sudo=true`)
- Both connections have valid auth (`sid`) in Keychain or are not password protected

---

## Phase 0 — Discovery + Endpoint Verification (no UX)
**Deliverable**
- A short internal note listing the exact Pi-hole v6 endpoints and payloads used for:
  - listing/upserting/deleting adlists
  - listing/upserting/deleting domainlists (exact/regex allow/deny)
  - listing/upserting/disabling groups
  - applying group assignments for adlists/domains

**Implementation Tasks**
- Validate endpoint paths, required query params (e.g. `app_sudo=true`), and encoding rules for:
  - list URL strings
  - domain strings
  - regex strings
  - group name strings
- Decide stable identifiers:
  - Adlist key: `address` (URL)
  - Domain key: `domain` string within the specific bucket (allow/deny + exact/regex)
  - Group key: `name`

**Acceptance Criteria**
- A single “known-good” curl/Postman sequence exists for each CRUD action.

---

## Phase 1 — Preferences Storage + UX Scaffolding (no sync yet)
**Deliverable**
- Preferences UI section “Sync” that lets the user:
  - enable/disable sync
  - pick Primary + Secondary (v6 only, cannot be equal)
  - set interval minutes (min 5, default 15)
  - click “Sync Now” (placeholder until Phase 3)

**Implementation Tasks**
- Add new `UserDefaults` keys for sync config + last-run status fields:
  - enabled, primary identifier, secondary identifier, interval minutes
  - last run timestamp, last status, last message
- Add a `PreferencesDelegate` callback for “Sync Now”.

**Acceptance Criteria**
- Settings persist across restarts.
- Only v6 connections appear in the Primary/Secondary pickers.
- Primary cannot equal Secondary (UI prevents or shows validation error).

---

## Phase 2 — Sync Engine Skeleton + Scheduling (dry-run only)
**Deliverable**
- A sync scheduler that runs:
  - on “Sync Now”
  - on an interval timer
- A `SyncPrimaryToSecondaryOperation` that:
  - loads Primary/Secondary APIs
  - performs read calls only
  - computes a reconciliation plan without applying it
  - records a summary to preferences

**Implementation Tasks**
- Implement sync coalescing:
  - `isSyncInFlight` + `syncRequested` to avoid overlap
- Serialize sync behind the existing `PiBarManager.operationQueue`.
- Implement “diff” data structures for:
  - adlists
  - domainlists (4 buckets)
  - groups

**Acceptance Criteria**
- Clicking “Sync Now” updates status (“dry run”) and does not crash.
- Interval sync triggers without blocking menu refresh.

---

## Phase 3 — Adlists Sync (apply mode)
**Deliverable**
- Full Primary → Secondary reconciliation for **adlists**:
  - upsert all primary adlists onto secondary
  - delete secondary adlists not present on primary

**Implementation Tasks**
- Extend `Pihole6API` with safe URL building for:
  - `PUT` and `DELETE`
  - query parameters (including `app_sudo=true`)
  - strict percent-encoding for path components
- Implement:
  - fetch adlists from both
  - compute diff
  - apply writes to secondary

**Acceptance Criteria**
- Secondary adlists match Primary after Sync Now.
- If `app_sudo` is missing, user sees a clear error message.

---

## Phase 4 — Domainlist Sync (exact + regex; allow + deny)
**Deliverable**
- Full Primary → Secondary reconciliation for all 4 domainlist buckets:
  - allow/exact, deny/exact, allow/regex, deny/regex

**Implementation Tasks**
- Implement per-bucket fetch/diff/apply:
  - delete extras on secondary
  - upsert all primary entries
- Ensure encoding works for regex strings.

**Acceptance Criteria**
- Secondary-only entries are removed on sync.
- Primary entries propagate to Secondary.

---

## Phase 5 — Groups + Assignments
**Deliverable**
- Group definitions synced by name:
  - create/update groups on secondary to match primary
  - disable groups that exist only on secondary
- Group assignments for adlists/domains synced to match primary.

**Implementation Tasks**
- Implement group upsert/disable flows.
- Ensure group mapping is stable:
  - resolve group IDs by name on each side
  - translate primary group IDs → secondary group IDs by name during writes
- Apply assignments during adlist/domain upserts.

**Acceptance Criteria**
- Group enabled states match Primary.
- Adlists/domains on Secondary have the same group assignments as Primary.

---

## Phase 6 — UX Polish + Safety Controls
**Deliverable**
- Better visibility and guardrails:
  - “Last sync: time/status/message” display
  - optional “Dry run” toggle (default off)
  - optional “Confirm deletions” mode (lists extras before removal)

**Implementation Tasks**
- Improve error mapping:
  - 401: re-authenticate
  - 403: enable `app_sudo`
  - offline/timeouts: retry next interval
- Add structured logging for sync steps.

**Acceptance Criteria**
- Errors are actionable and don’t spam the user.
- Dry-run previews destructive changes.

---

## Manual Test Checklist (per release)
- Configure two v6 Pi-holes; enable sync; Sync Now succeeds.
- Secondary missing `app_sudo` → clear failure message.
- Drift tests:
  - secondary extra adlist removed
  - secondary extra deny regex removed
  - secondary-only group becomes disabled
- Interval sync triggers at configured cadence without UI lag.

## Rollback
- Disabling sync stops the timer and prevents any sync writes.
- No sync settings affect existing polling/enable/disable behaviors.

