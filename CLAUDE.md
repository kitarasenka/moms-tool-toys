# Mom's Tool Toys

One repo, independent macOS tools — no shared code, each builds on its own:

- `wifimom/` — WifiMom, home Wi-Fi monitor (Node, no deps, + WKWebView app). Details: `wifimom/CLAUDE.md`.
- `perfmom/` — PerfMom, SwiftUI performance/process monitor (SwiftPM, macOS 14+). Details: `perfmom/README.md`.
- `launcher/` — «Mom's Tool Toys.app», single-file SwiftUI launcher. Knows tools only by bundle id
  (`tools` in `main.swift`: `local.wifimom`, `local.perfmon.app` — PerfMom kept its pre-rename id so settings and the
  System Events permission survive) — adding a tool = new entry there +
  its icon copied in `launcher/install.sh`. Root `./install.sh` installs all three into /Applications.

App icons are 1024×1024 PNGs (`wifimom/app/icon.png`, `perfmom/Resources/AppIcon.png`,
`launcher/icon.png`); build scripts turn them into .icns each build.

Run commands from the tool's own folder (`cd perfmom && swift build`, `cd wifimom && node wifimom.mjs`).
Paths baked outside the repo: `~/.local/bin/wifimom` symlink and WifiMom.app's Info.plist point at
`wifimom/wifimom.mjs` — rerun `wifimom/app/install.sh` and re-link after moving the repo.
