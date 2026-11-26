# Mom's Tool Toys

One repo, independent macOS tools — no shared code, each builds on its own:

- `wifimom/` — WifiMom, home Wi-Fi monitor (Node, no deps, + WKWebView app). Details: `wifimom/CLAUDE.md`.
- `perfmom/` — PerfMon, SwiftUI performance/process monitor (SwiftPM, macOS 14+). Details: `perfmom/README.md`.

Run commands from the tool's own folder (`cd perfmom && swift build`, `cd wifimom && node wifimom.mjs`).
Paths baked outside the repo: `~/.local/bin/wifimom` symlink and WifiMom.app's Info.plist point at
`wifimom/wifimom.mjs` — rerun `wifimom/app/install.sh` and re-link after moving the repo.
