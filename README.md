# PiBar Enhanced for macOS

PiBar Enhanced is a fork of [PiBar by amiantos](https://github.com/amiantos/pibar) — a macOS menu bar app for managing your [Pi-hole](https://pi-hole.net)(s). This fork adds full **Pi-hole v6 support**, a **Primary → Secondary sync engine**, and a range of reliability and stability improvements.

> **Version 2.0 (beta)** — Pi-hole v6 required for sync features.

## Features

### Core (inherited from PiBar)

- Display DNS query stats (queries, blocked, % blocked) in your macOS menu bar
- Support for multiple Pi-holes, including quadruple failover setups
- Toggle Pi-hole(s) on/off from the menu or via keyboard shortcut ⌘⌥⇧P
- Warnings when any Pi-hole is inaccessible or disabled
- Supports both legacy Pi-hole (v5 and earlier) and Pi-hole v6 connections

### New in PiBar Enhanced

#### Pi-hole v6 Support
- Full Pi-hole v6 API client (`Pihole6API`) with proper authentication flow
- Fixed connection testing to use the v6 API instead of legacy endpoints
- Unique connection identifiers so multiple Pi-holes sharing a hostname (different ports/protocols) no longer overwrite each other
- Explicit request timeouts on all API calls with actionable error messages for auth failures, timeouts, and unreachable hosts

#### Primary → Secondary Sync *(Pi-hole v6 only)*
Keep two Pi-hole v6 instances in sync automatically. The Primary is the source of truth; the Secondary is reconciled to match.

**What gets synced:**
- **Adlists** — URLs upserted/deleted to match Primary
- **Domain lists** — All 4 buckets: allow/exact, deny/exact, allow/regex, deny/regex
- **Groups** — Created/updated by name; Secondary-only groups are disabled
- **Group assignments** — Adlists and domains on Secondary get the same group memberships as Primary (IDs translated by name across instances)

**Controls:**
- **Sync Now** button in Sync Settings and in the menu bar (appears when sync is configured)
- **Interval scheduling** — configurable from 5 minutes (default: 15 min)
- **Scope toggles** — independently enable/disable Groups, Adlists, and Domains sync
- **Dry-run mode** — computes the full diff and reports what *would* change without writing anything
- **Wipe secondary before sync** — optional destructive pre-clean (confirmation required)
- **In-flight indicator** — "Sync Now" becomes "Syncing…" and disables while a sync is running
- **Activity log** — live progress messages in the Sync Settings window
- **Last sync status** — timestamp, result (success / dry-run / failed / skipped), and detail message

**Requirements:**
- Two Pi-hole v6 connections configured in PiBar
- Secondary Pi-hole must have `webserver.api.app_sudo=true` in its config for write operations

#### Reliability & Stability
- Replaced `sleep(1)` synchronization workaround in the update loop with a proper completion-operation model
- Concurrent Pi-hole status updates now merge state safely via `NSLock`-guarded snapshots
- Sync coalescing: overlapping sync requests queue one follow-up run instead of stacking operations
- Domain bucket syncs run in parallel (4× throughput vs. sequential)
- Credentials stored without repeated Keychain prompts; one-time migration from Keychain on first launch

#### Code Quality
- Debug logging disabled in Release builds
- Removed all deprecated/unused persistence code
- Force-unwrap patterns replaced with safe handling at API boundary

## Download & Install

### Latest Release — 2.0 (beta)

**[⬇ Download PiBar-2.0-beta.zip](https://github.com/foosmith/pibar-enhanced/releases/download/v2.0-beta/PiBar-2.0-beta.zip)**

Requires macOS 13 or later.

1. Download and unzip **PiBar-2.0-beta.zip**
2. Move **PiBar.app** to your `/Applications` folder
3. Launch PiBar — it will appear in your menu bar

> **First launch on macOS:** Because this build is not notarized, Gatekeeper may block it. Right-click (or Control-click) **PiBar.app** and choose **Open**, then confirm in the dialog that appears.

All releases are listed on the [Releases page](https://github.com/foosmith/pibar-enhanced/releases).

## Screenshots

![PiBar Screenshots](/.github/screenshots.jpg?raw=true)

## Quick Start

1. Launch PiBar Enhanced
2. Click the PiBar icon in your menu bar → Preferences
3. Click **Add** and enter your Pi-hole connection details
4. Click **Test Connection** — if successful, click **Save & Close**
5. Repeat for additional Pi-holes
6. Adjust menu bar display preferences on the General tab

### Enabling Sync

1. Open Preferences → **Sync** tab
2. Check **Enable Primary → Secondary Sync**
3. Select your Primary and Secondary Pi-holes (must both be v6)
4. Set the sync interval (minutes)
5. Choose scope: Groups, Adlists, Domains (all enabled by default)
6. Click **Sync Now** to run immediately, or wait for the first scheduled sync

> Ensure `webserver.api.app_sudo=true` is set on your Secondary Pi-hole. PiBar will show a clear error if this is missing.

## Building from Source

```bash
git clone https://github.com/foosmith/pibar-enhanced.git
cd pibar-enhanced
open PiBar.xcodeproj
```

Requires Xcode 15+ and macOS 13+.

## Get Help

- [Open an issue](https://github.com/foosmith/pibar-enhanced/issues/new) for bugs or feature requests

## Credits

- PiBar Enhanced maintained by [foosmith](https://github.com/foosmith)
- Original PiBar created by [Brad Root (amiantos)](https://github.com/amiantos)
- App icon designed by [Jozef Bañuelos](https://jozef.design)
- Pi-hole® is a registered trademark of Pi-hole LLC
- PiBar Enhanced is an independent project and is not affiliated with Pi-hole LLC or the Pi-hole project
