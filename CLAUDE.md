# Mom's Tool Toys

One repo, independent macOS tools — no shared code, each builds on its own:

- `wifimom/` — WifiMom, home Wi-Fi monitor (Node, no deps, + WKWebView app). Details: `wifimom/CLAUDE.md`.
- `perfmom/` — PerfMom, SwiftUI performance/process monitor (SwiftPM, macOS 14+). Details: `perfmom/README.md`.
- `cleanermom/` — CleanerMom, SwiftUI Mac cleaner (SwiftPM, macOS 14+; CleanMyMac-like). Details:
  `cleanermom/README.md`. Deletes files — keep every removal inside a known root (`Cleaner.isSafe`),
  user files go to Trash, and run `swift run CleanerMom --selftest-clean` after touching `Junk.swift`.
  Never read other apps' `~/Library/Containers` without Full Disk Access (triggers TCC prompts).
- `diskmom/` (DiskMom: disk map sunburst, duplicates, volumes), `privacymom/` (PrivacyMom: TCC.db
  permissions + `tccutil reset`, camera/mic indicators, browser history/cookie cleanup, Wi-Fi networks),
  `batterymom/` (BatteryMom: IOKit battery, history, per-app energy, peripherals, menu bar),
  `clipmom/` (ClipMom: clipboard history, ⇧⌘V panel, menu bar) — same SwiftPM layout as cleanermom,
  each with `--selftest` (sandboxed; never touches real user data or `NSPasteboard.general`). Details in
  each `README.md`.
- `launcher/` — «Mom's Tool Toys.app», single-file SwiftUI launcher. Knows tools only by bundle id
  (`tools` in `main.swift`: `local.wifimom`, `local.perfmon.app`, `local.cleanermom`, `local.diskmom`,
  `local.privacymom`, `local.batterymom`, `local.clipmom` — PerfMom kept its pre-rename id so settings and the
  System Events permission survive) — adding a tool = new entry there +
  its icon copied in `launcher/install.sh`. Root `./install.sh` installs all of them into /Applications.

App icons are 1024×1024 PNGs (`wifimom/app/icon.png`, `perfmom/Resources/AppIcon.png`,
`<tool>/Resources/AppIcon.png` for the SwiftPM tools, `launcher/icon.png`); build scripts turn them into .icns each build.

Run commands from the tool's own folder (`cd perfmom && swift build`, `cd wifimom && node wifimom.mjs`).
Paths baked outside the repo: `~/.local/bin/wifimom` symlink and WifiMom.app's Info.plist point at
`wifimom/wifimom.mjs` — rerun `wifimom/app/install.sh` and re-link after moving the repo.

SwiftUI pitfall shared by all tools: a VStack with a List/ScrollView/Table in a NavigationSplitView detail
can get unbounded height and slide the whole window content off-screen — wrap such screens in
`.fillAvailable()` (GeometryReader-sized frame); don't use HSplitView with Lists.
