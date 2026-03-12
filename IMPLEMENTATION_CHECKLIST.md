# PiBar Implementation Checklist

## Phase 1: Fix Immediate Functional Bugs

- [x] Fix the Pi-hole v6 settings screen so "Test Connection" uses `Pihole6API` instead of the legacy `PiholeAPI`.
- [x] Ensure the temporary v6 connection object created during testing uses `isV6: true`.
- [x] Verify the v6 authentication flow updates UI state consistently for success, invalid credentials, and network failure.
- [x] Fix connection identifiers so multiple Pi-holes with the same hostname do not overwrite each other.
- [x] Update any menu-building logic that assumes identifier == hostname.

## Phase 2: Secure Credential Storage

- [x] Remove persistent token and SID storage from `UserDefaults`.
- [x] Add Keychain-backed storage for legacy API tokens and Pi-hole v6 session IDs.
- [x] Add a migration path from existing `UserDefaults`-stored credentials into Keychain.
- [x] Decide whether Pi-hole v6 sessions should persist at all or be re-authenticated on demand.
- [x] Verify edit/save flows still work for both legacy and v6 Pi-hole entries.

## Phase 3: Stabilize Network Update Flow

- [x] Remove the `sleep(1)` synchronization workaround in `PiBarManager.updatePiholes()`.
- [x] Replace shared dictionary mutation from operation completion blocks with a safer model.
- [x] Choose one concurrency model and apply it consistently:
- [x] Option A: keep `OperationQueue`, but return explicit results and merge state in one place.
- [ ] Option B: move the manager to Swift concurrency with `Task` and isolated state.
- [x] Ensure timer-driven refreshes cannot overlap in a way that corrupts state.
- [x] Ensure enable/disable actions and refresh actions serialize cleanly.

## Phase 4: Improve API Client Reliability

- [x] Apply explicit timeouts to both GET and POST requests in `Pihole6API`.
- [x] Remove unused timeout properties or wire them into request creation.
- [x] Normalize timeout behavior between `PiholeAPI` and `Pihole6API`.
- [x] Improve error mapping so UI can distinguish timeout, auth failure, unreachable host, and decoding failure.
- [x] Review URL construction and avoid relying on raw string concatenation where safer URL construction is practical.

## Phase 5: Cleanup and Maintainability

- [x] Remove deprecated persistence code if it is no longer needed for supported upgrades.
- [x] Replace force unwrap patterns in API update operations where feasible.
- [x] Reduce duplicated connection encoding/decoding helpers across V1/V2/V3 structs if those formats remain in code.
- [x] Revisit logging defaults so debug logging is not always enabled in normal app startup.
- [x] Clean up commented-out code in the v6 update operation.

## Validation Checklist

- [ ] Test a single legacy Pi-hole configuration.
- [ ] Test a single Pi-hole v6 configuration.
- [ ] Test multiple Pi-holes with different hosts.
- [ ] Test multiple Pi-holes sharing the same hostname but different ports or protocol settings.
- [ ] Test enable/disable actions for legacy Pi-hole instances.
- [ ] Test enable/disable actions for Pi-hole v6 instances.
- [ ] Test app behavior when one Pi-hole is offline and another is online.
- [ ] Test polling behavior under slow network conditions.
- [ ] Test migration from an older preferences store with existing saved connections.

## Recommended Execution Order

1. Complete Phase 1.
2. Complete Phase 2.
3. Complete Phase 3.
4. Complete Phase 4.
5. Finish with Phase 5 cleanup and the validation checklist.
