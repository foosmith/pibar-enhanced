# PiBar Review

## Findings

1. Plaintext API credentials and session IDs are persisted in `UserDefaults`.

   Files:
   - [Structs.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Data Sources\Structs.swift#L84)
   - [Preferences.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Data Sources\Preferences.swift#L48)
   - [PiholeSettingsViewController.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Views\Preferences\PiholeSettingsViewController.swift#L68)
   - [PiholeV6SettingsViewController.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Views\Preferences\PiholeV6SettingsViewController.swift#L105)

   `PiholeConnectionV3` includes `token`, that struct is encoded and written directly to `UserDefaults`, and both the legacy API token and Pi-hole v6 SID are saved there. For a macOS app handling admin credentials, this should be Keychain-backed. This is the highest-value improvement because it is both a security issue and a migration concern.

2. Multiple Pi-holes can overwrite each other if they share a hostname.

   Files:
   - [PiholeAPI.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Data Sources\PiholeAPI.swift#L17)
   - [Pihole6API.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Data Sources\Pihole6API.swift#L159)
   - [PiBarManager.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Manager\PiBarManager.swift#L19)
   - [MainMenuController.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Views\Main Menu\MainMenuController.swift#L292)

   The dictionary key is just `hostname`. If a user configures the same host on different ports, protocols, or versions, later entries replace earlier ones. That breaks the advertised multi-Pi-hole/failover story. Identifier should include at least host, port, and version, or use a stable UUID stored with the connection.

3. The Pi-hole v6 settings screen's "Test Connection" path is wired to the wrong API.

   File:
   - [PiholeV6SettingsViewController.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Views\Preferences\PiholeV6SettingsViewController.swift#L177)

   The v6 controller builds a v6 connection form, then calls `PiholeAPI` instead of `Pihole6API`, and even constructs the temporary connection with `isV6: false`. So the test button is validating against the legacy `/admin/api.php` flow, not the v6 `/api` flow. This is a real functional bug and likely explains false failures or confusing validation.

4. Network update coordination relies on a `sleep(1)` hack instead of a safe completion model.

   Files:
   - [PiBarManager.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Manager\PiBarManager.swift#L195)
   - [UpdatePiholeOperation.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Manager\Operations\UpdatePiholeOperation.swift#L23)
   - [UpdatePiholeV6Operation.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Manager\Operations\UpdatePiholeV6Operation.swift#L23)
   - [AsyncOperation.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Manager\Operations\AsyncOperation.swift#L23)

   `updatePiholes()` updates shared dictionary state from operation completion blocks and then sleeps for one second before recomputing the overview. That is brittle and can still race under slow responses or future refactors. This should be replaced with explicit result passing or serial state mutation on a dedicated queue or actor.

5. The v6 HTTP client does not apply a timeout to GET requests, only to requests with a body.

   File:
   - [Pihole6API.swift](C:\Users\foosm\OneDrive\Documents\PiBarEnhanced\PiBar\Data Sources\Pihole6API.swift#L231)

   `request.timeoutInterval` is set only inside `if let body`, so `fetchSummary()` and `fetchBlockingStatus()` depend on the default session timeout. There is also an unused `timeout` property. This can make the menu bar app feel hung or stale on bad networks.

## Open Questions / Assumptions

- The v6 SID may or may not be intended to persist. If not, the better fix is to avoid persistent storage entirely and re-authenticate as needed.
- This review is source-based. The app could not be built or run in this environment because it requires macOS and Xcode.

## Recommended Improvement Order

1. Move credentials from `UserDefaults` to Keychain and add a migration path.
2. Fix connection identity to avoid hostname collisions.
3. Correct the v6 "Test Connection" flow.
4. Replace the operation and `sleep(1)` synchronization with a proper concurrency model.
5. Normalize timeout and error handling across both API clients.

## Suggested Execution Plan

1. Fix the v6 test bug and identifier collision first.
2. Then do Keychain migration as a separate, more careful change.
