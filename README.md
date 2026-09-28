# CookieVault

A macOS (SwiftUI) desktop app for inspecting cookie session files and API-key files, organizing them intelligently, and opening a session in an isolated Chromium window.

## Features

- **Cookie sessions** — import Netscape (`.txt`) / JSON cookie files, folders, or `.zip` archives. Accounts are grouped by **detected site** (from cookie domains) and by **tier** (Premium/Free), with per-service, per-type plan detection.
- **Launch in an isolated browser** — opens a session in a dedicated Chromium profile and injects cookies over the **Chrome DevTools Protocol** (works on modern Chrome/Chromium). Offers to download an open-source Chromium build if none is installed.
- **Adaptive filters** — followers, views, CC, subs, country, year, account state, session validity, plan, and more/less-than numeric ranges — shown only where relevant to each site type.
- **Saved collection** — star the good accounts (premium + usable + live session).
- **API-key checker** — validates keys across 100+ providers concurrently and surfaces account details (plan, balance, scopes, models, latency) inline. Each provider type shows a category + "what this check reveals" descriptor. Multi-select keys for bulk copy/export/delete/check, plus QoL actions (Copy Valid, Check-New-only, valid-first sorting).
- **All Valid Keys view** — one place that collects every valid key across all provider types, grouped by type, with copy-all / export-all.

## Build & run

Requires macOS 14+ and the Swift toolchain / Xcode.

```bash
swift build -c release
./rebuild_and_install.sh --launch   # packages the .app, installs to /Applications, launches
```

## Project layout

- `CookieVault/Sources/` — Swift source
  - `AppStore.swift` — state, persistence, imports, site/tier logic
  - `PlanClassifier.swift` / `AccountMetrics.swift` — per-service plan/state + filename-stat parsing
  - `ChromiumLauncher.swift` — DevTools-Protocol cookie injection + Chromium download
  - `APIKeyChecker.swift` — provider checkers
  - `DesignSystem.swift` + `*View*.swift` — UI
- `Package.swift` — SwiftPM manifest

## Note

This repository contains **source code only**. Cookie/API-key data lives in the user's Application Support directory and is never committed (see `.gitignore`).
