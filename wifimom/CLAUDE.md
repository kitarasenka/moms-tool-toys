# WifiMom

Local macOS tool for home Wi-Fi: tells Wi-Fi glitches from ISP ones, with a web UI.
Only makes sense on the Mac on home Wi-Fi — it pings the default gateway.

- `wifimom.mjs` — monitor (two `ping` children: gateway + 1.1.1.1, Wi-Fi sampled from
  `system_profiler` every 30 s), incident detection, CSV logs, HTTP server on
  `127.0.0.1:7357` (`/`, `/api/state`, `/api/stream` SSE). No dependencies.
- `rf.swift` — CoreWLAN helper, prints RSSI/noise/rate/channel every second (system_profiler
  takes ~6 s). Compiled on first run with `swiftc` into `~/.wifimom/bin/rf` (rebuilt when the
  source is newer); without swiftc signal falls back to the 30 s sample. Values go into each tick
  (`sig`, `noise`, `rate`, `ch`) and `rf.csv`.
- `ui.html` — single-page UI, canvas charts, read from disk on each request. macOS look: sidebar
  sections (Обзор / События / Устройства / Карта покрытия / Как читать, `/#<view>`, ⌘1…⌘5), system
  colors with light/dark tokens (tokens read by canvas must stay hex). In WifiMom.app `<html>` gets
  class `app`: sidebar goes transparent over native vibrancy; `[data-drag]` areas move the window via
  the `win` message handler. Tab «Карта покрытия»
  (`/#map`): click where you stand on the floor plan → 10 s of ticks become a point; IDW heatmap
  per layer. Stored via `GET/PUT /api/survey` in `~/.wifimom/survey.json` (plan as data URL — private,
  keep out of the project). PUT only from the page itself (Host/Origin + JSON content-type check).
- Devices: every 60 s a UDP packet to port 9 on each address of the subnet (capped to the /24
  around us) makes macOS ARP-resolve them; `arp -an -i <if>` then lists who is online (macOS ARP
  entries expire in ~2 min, so a leaving device disappears on its own). No names: the router
  gives no reverse DNS, phones don't advertise Bonjour and use private MACs, so names are
  user labels by MAC in `~/.wifimom/devices.json` (`PUT /api/devices/name`, same write guard as
  survey + strict MAC check). Per-device traffic is not visible from the Mac — only the router has it.
- Vendor by MAC: IEEE MA-L registry downloaded once to `~/.wifimom/oui.csv` (refreshed after 90 days;
  the IEEE server is slow, ~1–1.5 min for 4 MB, hence the 5 min timeout; runs in background), looked
  up locally — device addresses never leave the Mac. `KINDS` maps vendor → device-type hint. Private
  (locally administered) MACs have no vendor; macOS/iOS "rotating" private addresses also break
  labels keyed by MAC.
- Logs: `~/.wifimom/logs/<date>/` (`WIFIMOM_LOGS` overrides) — kept out of the project,
  they hold network names and LAN addresses.
- Incident = in the last 10 s ≥2 lost pings or median above 60 ms (router) / 200 ms
  (internet). Router bad ⇒ Wi-Fi; only internet bad ⇒ ISP. Ends after 5 s clean (no flapping).
  Each incident carries kind (lag / loss / down = 3+ lost in a row; only escalates), peak RTT,
  lost count, min signal, roam flag, and a cause hint (`title`, `details`, `hint`) shown in
  events, the status pill and the chart tooltip.
- Don't poll `system_profiler` while `rf` works: it scans the air and itself causes latency
  spikes (measured: ~20–25% of router pings >60 ms with 30 s polling vs ~8% without). It runs
  once at start and when `rf` sees the channel change (roam), to re-read the SSID.
- Installed as `~/.local/bin/wifimom` → symlink to `wifimom.mjs`.
- `app/` — `WifiMom.app` (`app/install.sh` builds it with swiftc into /Applications; display name WifiMom, while the CLI, `~/.wifimom`, Keychain service and bundle id `local.wifimom` stay lowercase so saved data carries over). A WKWebView
  window that runs `node wifimom.mjs --no-open` (node and script paths baked into Info.plist at
  install — rerun after moving the project or switching node), loads the URL from its `Окно:` line,
  and sends SIGINT on quit. Reuses a monitor already on 7357. Handles file input/alert/confirm/prompt
  natively; external links go to the default browser. The monitor stops its ping/rf children on
  SIGINT/SIGTERM/SIGHUP and on stdout EPIPE, so a killed app leaves no orphans.
- Router login (section «Роутер», `GET/PUT /api/router`, same write guard): login in
  `~/.wifimom/router.json`, password in the macOS Keychain (service `wifimom.router`; read with `-g`,
  since `-w` returns non-ASCII passwords as unmarked hex). Saved only after the router accepts it.
  The GM203-7B (Silknet GPON, "xPON ONU" Realtek firmware on Boa) uses HTTP Basic, so each request
  carries the credentials; login check = 200 on `/cgi-bin/index.asp`, cached 60 s (wrong passwords
  can lock the login). `wifimom router <path>` prints a router page with the saved login — for
  mapping its pages (read-only; don't GET `/boaform/*`, those are actions).
- Speed (section «Скорость», `GET/PUT /api/speed`, same write guard): runs macOS `networkQuality -c -M 40
  -I <if>` (~30–45 s, tens–hundreds of MB). Results (bit/s, RPM, base RTT + SSID/channel/signal at the
  time) in `~/.wifimom/speed.json`, last 500; optional auto run every 1/3/6 h (off by default). The test
  saturates the link on purpose, so the monitor holds new incidents from start until 12 s after the end
  (`m.hold`) and marks those ticks `load: 1` — the latency chart shades them. Latency under load =
  60000 / RPM ms.
