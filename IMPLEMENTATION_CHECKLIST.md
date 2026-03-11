# PiBar Implementation Checklist

## Phase 1: Fix Immediate Functional Bugs

- [ ] Fix the Pi-hole v6 settings screen so "Test Connection" uses `Pihole6API` instead of the legacy `PiholeAPI`.
- [ ] Ensure the temporary v6 connection object created during testing uses `isV6: true`.
- [ ] Verify the v6 authentication flow updates UI state consistently for success, invalid credentials, and network failure.
- [ ] Fix connection identifiers so multiple Pi-holes with the same hostname do not overwrite each other.
- [ ] Update any menu-building logic that assumes identifier == hostname.

## Phase 2: Secure Credential Storage

- [ ] Remove persistent token and SID storage from `UserDefaults`.
- [ ] Add Keychain-backed storage for legacy API tokens and Pi-hole v6 session IDs.
- [ ] Add a migration path from existing `UserDefaults`-stored credentials into Keychain.
- [ ] Decide whether Pi-hole v6 sessions should persist at all or be re-authenticated on demand.
- [ ] Verify edit/save flows still work for both legacy and v6 Pi-hole entries.

## Phase 3: Stabilize Network Update Flow

- [ ] Remove the `sleep(1)` synchronization workaround in `PiBarManager.updatePiholes()`.
- [ ] Replace shared dictionary mutation from operation completion blocks with a safer model.
- [ ] Choose one concurrency model and apply it consistently:
- [ ] Option A: keep `OperationQueue`, but return explicit results and merge state in one place.
- [ ] Option B: move the manager to Swift concurrency with `Task` and isolated state.
- [ ] Ensure timer-driven refreshes cannot overlap in a way that corrupts state.
- [ ] Ensure enable/disable actions and refresh actions serialize cleanly.

## Phase 4: Improve API Client Reliability

- [ ] Apply explicit timeouts to both GET and POST requests in `Pihole6API`.
- [ ] Remove unused timeout properties or wire them into request creation.
- [ ] Normalize timeout behavior between `PiholeAPI` and `Pihole6API`.
- [ ] Improve error mapping so UI can distinguish timeout, auth failure, unreachable host, and decoding failure.
- [ ] Review URL construction and avoid relying on raw string concatenation where safer URL construction is practical.

## Phase 5: Cleanup and Maintainability

- [ ] Remove deprecated persistence code if it is no longer needed for supported upgrades.
- [ ] Replace force unwrap patterns in API update operations where feasible.
- [ ] Reduce duplicated connection encoding/decoding helpers across V1/V2/V3 structs if those formats remain in code.
- [ ] Revisit logging defaults so debug logging is not always enabled in normal app startup.
- [ ] Clean up commented-out code in the v6 update operation.

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
