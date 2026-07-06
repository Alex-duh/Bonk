# Bonk (formerly Knocker)

Free open-source macOS menubar app. Detects knocks on the MacBook chassis via the Apple Silicon accelerometer and maps single/double/triple knocks to configurable actions. Inspired by the paid app "Knock." GitHub: https://github.com/Alex-duh/Bonk (GPL-3.0).

## Stack
- Swift 5.9 / Swift Package Manager
- Build target macOS 13+ (so older Macs can launch it and see a friendly explanation), but the
  sensor only streams on **macOS 26 (Tahoe)+** — that's the real requirement. Developed on M4/26.
- **IOKit HID** for accelerometer — NOT CoreMotion (CMMotionManager is unavailable on Apple Silicon macOS)
- AppKit for menubar (`NSStatusItem` + `NSMenu`)
- SwiftUI for settings window
- UserDefaults for settings persistence (per-app rules as JSON blob)
- Fully local: no backend, no network calls — keep it that way

## File Structure

```
Sources/Bonk/
  main.swift                  — NSApplication entry point (3 lines)
  BonkApp.swift               — AppDelegate, NSStatusItem, test-mode menu item, per-app rule resolution
  AccelerometerManager.swift  — IOKit HID device, EMA baseline, waveform ring buffer, both calibrations
  KnockDetector.swift         — Spike detection (min/max duration), sequence window, typing suppression
  CommandExecutor.swift       — built-in commands + custom shortcut/shell/Shortcuts/app actions + AI Accept
  KeyCombo.swift              — parses "cmd+shift+k"-style specs → (keyCode, CGEventFlags)
  AppRules.swift              — AppRule model + frontmost-app matching
  SettingsView.swift          — BonkSettings (UserDefaults), KnockLog, full SwiftUI UI

build_app.sh                  — dev: compile → bundle → ad-hoc sign → launch
package_dmg.sh                — release: build -c release → dist/Bonk.app → dist/Bonk-<ver>.dmg
Packaging/Info.plist          — shared plist template (__VERSION__ substituted by scripts)
Packaging/make_icns.sh        — PNG → .icns (used when Packaging/logo.png exists)
RELEASING.md                  — notarization steps + GitHub release commands
```

## Build & Run

```bash
bash build_app.sh
```

Always use this script — never run `.build/debug/Bonk` directly. Running without a bundle means no Info.plist, no TCC prompts, no sensor access.

## Permissions — CRITICAL

| Permission | Where to grant | Resets? |
|---|---|---|
| Accessibility | System Settings → Privacy & Security → Accessibility | **YES — resets every rebuild** |
| Automation (System Events) | Auto-prompted on first AppleScript use | No |

**Accessibility resets on every rebuild** because ad-hoc signing (`codesign --sign -`) changes the binary hash each time, and macOS TCC invalidates the permission entry. After `bash build_app.sh`, immediately re-grant in Accessibility settings. Do NOT rebuild again before testing. (Goes away once releases are Developer ID-signed.)

## Key Technical Decisions

### Accelerometer (IOKit HID)
- Device: `AppleSPUHIDDevice` matched with `kIOHIDDeviceUsagePageKey: 0xFF00, kIOHIDDeviceUsageKey: 3`,
  then filtered to `kIOHIDTransportKey` containing "SPU" — the internal keyboard ALSO exposes a
  vendor usage-3 device (108-byte reports) that must not be attached
- Reports: 22 bytes, int32 LE at byte offsets 6/10/14 for x/y/z, divide by 65536 for g-force
- Callback fires at ~100 Hz on the main run loop via `IOHIDDeviceRegisterInputReportCallback`;
  buffer sized from `kIOHIDMaxInputReportSizeKey`, never a hardcoded constant
- **Sample rate varies**: ~100 Hz spontaneous on macOS 26; setting `kIOHIDReportIntervalKey`
  bumps to native ~800 Hz. So the EMA uses a fixed 0.5 s time constant (alpha derived from
  measured dt, = 0.02 at 100 Hz) and the waveform/noise-calibration tick is decimated to
  ~100 Hz. Never assume 100 Hz in new code.
- **macOS 15 (Sequoia) is a dead end**: the device attaches and opens fine but streams ZERO
  reports — verified on M3 Pro / 15.7.7 with `--probe` both unprivileged AND as root, with the
  report-interval poke applied. (Prior art worked with root on 15.6; 15.7.x apparently closed
  that too.) Product requirement is therefore macOS 26+. The 1.5 s report-interval rescue in
  attach() stays — harmless, and other 15.x builds may differ.
- NOT gated by Input Monitoring (verified: works on a machine where it was never granted)
- Diagnostics: attach/skip/open failures and a one-time first-report hex dump go to
  ~/Library/Logs/Bonk.log. Terminal probe: `Bonk.app/Contents/MacOS/Bonk --probe` (5 s listen,
  prints rate + first report hex; run plain and with sudo to isolate privilege issues).

### EMA Baseline (alpha = 0.02)
```
emaBaseline = 0.02 * magnitude + 0.98 * emaBaseline
delta = abs(magnitude - emaBaseline)
```
A 0.5g knock spike shifts the EMA by only 0.01g. The floor re-stabilises in ~100 samples (1 second). Do NOT switch to a rolling window — rolling windows chase spikes and inflate the baseline, making short knocks invisible.

### Spike Detection Model
A raw sensor excursion becomes a "knock" only if:
1. `delta >= thresholdG` (crossing above starts the spike, dropping below ends it)
2. Spike did not exceed `maxSpikeDurationMs` (default 120 ms — filters sustained fan vibration).
   When exceeded, `suppressUntilQuiet` holds off re-triggering until delta drops below threshold,
   so a long vibration's tail can't register as a knock.
3. At least `kDebounce` = 80 ms has passed since the last registered knock (filters sensor ringing)

**There is deliberately NO minimum spike duration.** At 100 Hz a sharp knock is frequently above
threshold for a single sample (~10 ms). A 15 ms minimum-duration filter shipped once and silently
rejected almost every real knock (calibration still worked — it uses its own 0.04 g floor with no
duration check — which made the bug confusing). Do not reintroduce it.

`KnockDetector.lastStatus` records why the last threshold crossing did or didn't count
("ignored — typing pause", "vibration longer than X ms", "fired: double knock", …); the settings
window shows it live under the waveform. Use it first when debugging detection.

### Sequence Window & Dispatch
After each valid knock, the window timer restarts for `windowMs` (default 450 ms); when it
fires, the accumulated count (1–4) dispatches. Quad defaults to "None"; 5+ knocks cancel the
sequence. Dispatch order in `BonkApp.handleKnock`:
1. Per-app rule for frontmost app's bundle ID + pattern (from `BonkSettings.appRules`) wins
2. Otherwise global single/double/triple mapping
3. Test mode (`BonkSettings.testMode`): log + menu flash only, nothing fires

### Guards (in order, checked per sample)
1. Typing suppression: ignore if a keypress was seen within 800 ms
2. Post-fire cooldown: ignore during `cooldownMs` (default 1000 ms) after a command fired
3. Spike duration [min, max] filter above

Detection is also skipped (in the `accel.start` closure) while either calibration is collecting samples.

### Calibration — two flows, both inside `parseReport` so they work while paused
- **Noise floor**: 300 rest samples (3 s), threshold = `mean + 3σ` of delta
- **Knock to calibrate**: waits for 3 taps above a fixed 0.04 g floor (independent of the
  configured threshold, so it recovers from a badly misconfigured one), 250 ms debounce between
  taps; threshold = `min(peaks) * 0.5`, clamped to [0.02, 0.8] g. Auto-cancels after 30 s —
  detection is muted while `isTapCalibrating`, so a stuck flag would kill knock detection
  silently (closing the settings window mid-flow used to do exactly that).

### Custom actions (CommandExecutor)
- `Press Keyboard Shortcut…` — arg parsed by `KeyCombo.parse` ("cmd+shift+k"); UI shows live validity
- `Run Shortcuts Shortcut…` — `/usr/bin/shortcuts run <name>`; settings dropdown populated from `shortcuts list` (loaded off-main)
- `Run Shell Command…` / `Open App…` — renamed from "Run Custom Command"/"Open App"; legacy names still dispatch (persisted defaults from before the rename)
- `AI Accept (Press Enter)` — posts Return to frontmost app; pair with per-app rules for Claude Code/Cursor
- User shell commands and Shortcuts run via `shellAsync` (termination-handler logging) — never block the main run loop, the sensor callback lives there

### Lock Screen
**Control+Command+Q** — the standard macOS lock shortcut (real lock screen). `ScreenSaverEngine.app` is wrong — screensaver only, no lock. With Accessibility: `cgKey`; without: AppleScript keystroke via System Events.

### Media Keys (without Accessibility)
AppleScript F-key fallbacks: Play/Pause=100 (F8), Next=101 (F9), Prev=98 (F7), VolumeUp=111 (F12), VolumeDown=103 (F11), Mute=74 (F10).

### Waveform Display
- `AccelerometerManager.waveformSamples`: 300-element ring buffer (3 s @ 100 Hz), main thread only
- `WaveformSection` polls at 30 fps; Canvas draws right-aligned
- Knock flash: `NotificationCenter` posts `.bonkKnockDetected`; last ~300 ms highlighted for 200 ms

## Settings Persisted to UserDefaults

| Key | Default | Description |
|---|---|---|
| `singleKnockCommand` / `doubleKnockCommand` / `tripleKnockCommand` / `quadKnockCommand` | Play/Pause, Lock Screen, Screenshot, None | + `…Arg` counterparts |
| `thresholdG` | `0.30` | Sensitivity threshold in g; set by calibration |
| `windowMs` | `450` | Knock sequence window |
| `cooldownMs` | `1000` | Dead-time after command fires |
| `maxSpikeDurationMs` | `120` | Vibration filter (no min — see Spike Detection Model) |
| `testMode` | `false` | Detect + log without firing |
| `appRules` | `[]` | JSON-encoded `[AppRule]` |

## Packaging & Release
- `./package_dmg.sh` → `dist/Bonk-<ver>.dmg` (hdiutil, Applications-symlink layout). Ad-hoc by default; `SIGN_IDENTITY="Developer ID Application: …"` for notarizable builds. Bump `VERSION` in both scripts together.
- Notarization + GitHub release steps: see RELEASING.md. Do not push or publish without the user's say-so.

## Known Issues / Open Questions
- Accessibility resets every rebuild until Developer ID signing lands
- Keyboard-shortcut commands silently no-op without Accessibility — banner in settings is the only UX signal
- Does the 800 ms typing suppression need to be longer for fast typists?

## Do Not Change
- IOKit HID approach — only way to reach the Apple Silicon accelerometer
- Ad-hoc `codesign` in build_app.sh — required for TCC in dev
- EMA alpha = 0.02 — empirically good; smaller = too slow to adapt to angle changes, larger = chases spikes
- `kDebounce = 0.08` in KnockDetector — matches sensor ringing; changing it causes double-counts or missed knocks
- `kWaveformCapacity = 300` — shared between AccelerometerManager and WaveformCanvas; must match
- No minimum spike duration filter — rejects real knocks at 100 Hz (shipped bug, see Spike Detection Model)
- No network calls, ever — "fully local" is the product promise

## Debug
Log: `~/Library/Logs/Bonk.log` — every command call logs name + `trusted=true/false` + any errors.
Accelerometer not detected → run `Bonk --probe`; macOS 15 and earlier block the sensor entirely (Input Monitoring is irrelevant — folklore from early development). Commands silently failing → check Accessibility; rebuild invalidates it.
