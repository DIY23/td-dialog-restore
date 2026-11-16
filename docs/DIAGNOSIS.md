# Diagnosis: why TouchDesigner's dialogs open maximized here

This is the investigation behind the tool, kept because the conclusion is unusual and because it
is the basis of a bug report to Derivative. Everything below is measured on the machine, not
inferred from documentation.

Machine: Lenovo Legion Go (Ryzen Z1 Extreme, Radeon 780M iGPU), Windows 11 Home build 26300,
single display — a 1600×2560 panel, physically portrait, presented rotated (`dmDisplayOrientation`
= 1, 90°) as a 1920×1200 landscape desktop at 150 % scaling. TouchDesigner 2025.33230 (build
timestamp 23/01/2026), installed with defaults. Reproduced on 12/11/2026 / 16/11/2026.

## 1. The report

> "Most popup windows, such as the create-op dialog (<kbd>Tab</kbd>), appear fullscreen with black
> borders. The normal behaviour is just popups, so the interface underneath stays visible. I tried
> the compatibility DPI properties, no luck."

## 2. What was measured first

| Probe | Result |
|---|---|
| Window rectangles of all TouchDesigner windows | OP Create Dialog: `rect = (0,0)-(1920,1200)`, i.e. the **full monitor**, including the taskbar area |
| Main window | `(0,0)-(1920,1164)` — the **work area** (taskbar excluded), `IsZoomed = True` |
| `GetProcessDpiAwareness(touchdesigner.exe)` | 2 — **PER_MONITOR_AWARE** (so no bitmap stretching by Windows; the layout decision is TouchDesigner's) |
| About box | 549×251 — normal. Only *some* dialogs misbehave |
| Dialog content width | 1480 px drawn inside a 1920 px window — the padding is empty, not scaled content |

Per-monitor awareness rules out the obvious "Windows is scaling a DPI-unaware app" explanation.

## 3. Hypotheses, and what killed them

Each row was tested; none of them is the cause.

| Hypothesis | Test | Result |
|---|---|---|
| Windows display scaling | set 150 % → 125 % → 100 % | dialog = monitor rect at every scale |
| Resolution | 1920×1200 then 2560×1600 | same |
| Project content | brand-new default project, no file | same |
| User preferences | `pref.txt` empty and writable; also saved preferences via *Edit ▸ Preferences ▸ Save* | same |
| Per-app DPI compatibility override | checked `HKCU`/`HKLM` `AppCompatFlags\Layers` | no override set (and setting one changed nothing) |
| Remote-desktop/virtual display (Parsec) | Parsec processes stopped | same |
| Font cache corruption | `FontCache` deleted, rebuilt from scratch | same |
| TD build regression | user had already tried other builds | same |
| Modified installation (`Config\resources` identical to `resources.small`) | installer timestamps compared to the second | same timestamp as the installer — shipped that way, hypothesis withdrawn |
| Dialog resize grip | dragged the content corner | no grip, no resize |

## 4. The decisive observation

The user's remark was the missing fact:

> "if I grab the create-op dialog by its title bar the window pops back to its normal size"

That is plain Windows **un-maximize** behaviour. Confirmed by `GetWindowPlacement()` on a fresh
dialog: `showCmd = 3` (`SW_SHOWMAXIMIZED`), and after the title-bar drag `showCmd = 1` (`normal`)
with a normal rect of 1176×949.

So the dialog is not mis-sized: it is **created maximized**, deterministically, every time. That
single fact explains all the black padding, the unreachable resize edge, and why nothing
user-settable ever changed it — and why the state never persists (TouchDesigner re-creates the
window on each <kbd>Tab</kbd>).

## 5. Why it is machine-specific

Two legacy-metrics anomalies showed up on this machine and not on a normal desktop:

| Probe | Value | Expected on a normal landscape monitor |
|---|---|---|
| `GetDpiForSystem()` | 96 (100 %) — fixed at logon | matches the monitor scale (144 / 150 % here) |
| `GetDeviceCaps(HORZRES / VERTRES)` | 800 × 1280 — **portrait** | 1920 × 1200 landscape |
| `dmDisplayOrientation` (current mode) | 1 (90°) | 0 |

The panel is portrait hardware presented rotated, so the legacy GDI surface metrics come back
transposed, and the *system* DPI does not track the *monitor* DPI. TouchDesigner is per-monitor
DPI-aware, so it sizes its floating dialogs from a coordinate space in which those two disagree —
and the result is a maximized window.

This is a plausible mechanism, not a proven one: proving it would need TouchDesigner's source or a
second machine with the same panel geometry. What *is* proven is the behaviour (dialogs are created
with `SW_SHOWMAXIMIZED`) and that it is independent of every user-settable setting.

## 6. Fixes that were tried and rejected

| Attempt | Why it was dropped |
|---|---|
| "Un-rotate the display" | orientation 0 gives a sideways desktop on this hardware — not a fix |
| Force TD to *System* DPI compatibility | legitimate lever, but it only changes what TD sees; measured no change in dialog state |
| Repair / reinstall TouchDesigner | the install was never modified; nothing to repair |
| Pin TD 2025.33070 beside 2025.33230 | user had already tried other builds; and it would only sidestep, not fix |
| Polling watcher (every 250 ms) | worked, but cost 0.62 % of one core *continuously* — unacceptable for a permanent install |
| Standalone `.exe` launcher (`--launch`) | covers only TD started *through* it; double-clicking a `.toe`, the taskbar or Legion Space bypass it |
| `.exe` in `shell:startup` | correct coverage, but **Smart App Control refused it** (below) |
| WMI `Win32_Process` creation subscription | nothing resident, but needs admin, lives in `root\subscription`, fiddly to remove |

## 7. What shipped

An event-driven watcher (`SetWinEventHook(EVENT_OBJECT_SHOW)` + a message loop) started at logon
from a Startup shortcut:

- **0.000 s CPU over 12 s idle** (measured), ~72 MB working set — the PowerShell host's floor;
- restores a dialog to **1176×949, centred**, within ~500 ms of <kbd>Tab</kbd>;
- single instance, enforced by a named mutex — a second launch exits immediately;
- detection by window class + *owned window* + `IsZoomed` — no version parsing, no TD path, no TD
  API, so any build and any number of parallel installs are covered;
- fails safe: if nothing matches, it does nothing.

Verified on the machine: Tab with watcher running → normal dialog (screenshot + `GetWindowPlacement`
= `normal`, 1176×949); TD restarted / started by other means → same; second instance → refused;
idle cost → 0.000 s / 12 s.

## 8. Smart App Control note

A 7.5 KB unsigned `.exe` build of the same watcher worked while Smart App Control was still in
evaluation mode. Once SAC enforced (`HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy\VerifiedAndReputablePolicyState = 1`)
it was blocked — CodeIntegrity operational log, event 3077:

> Code Integrity determined that a process (powershell.exe) attempted to load …\td-dialog-restore.exe
> that did not meet the Enterprise signing level requirements or violated code integrity policy
> (Policy ID: {0283ac0f-fff1-49ae-ada1-8a933130cad6})

Turning SAC off is irreversible without reinstalling Windows, so the shipping version is the
PowerShell script (`powershell.exe` is Microsoft-signed and passes). The `.cs` source is kept in
`src/` for anyone who can sign the binary or has SAC off.

## 9. Upstream bug report (copy/paste for Derivative)

> **Floating dialogs are created maximized (OP Create Dialog, colour picker, Window Placement)**
>
> Build 2025.33230 · Windows 11 Home 26200 · single display, 1600×2560 panel presented rotated
> (`dmDisplayOrientation` = 1), desktop 1920×1200 at 150 % scaling.
>
> Press <kbd>Tab</kbd>: the OP Create Dialog window is created with `showCmd = SW_SHOWMAXIMIZED`
> (`GetWindowPlacement`) and a window rect equal to the full monitor — it covers the taskbar — while
> its content is laid out at natural size (1480 px wide inside a 1920 px window). Net effect: black
> padding on both sides and the resize edge off-screen.
>
> Dragging the title bar un-maximizes it to a normal ~1176×949 dialog, but the state does not
> persist: the next <kbd>Tab</kbd>, or a restart, re-creates it maximized. Small dialogs (About,
> 549×251) are unaffected.
>
> Reproduced on a brand-new default project with default preferences, at 100 / 125 / 150 % scaling,
> at 1920×1200 and 2560×1600, with Parsec stopped and with the font cache rebuilt. Not reproducible
> by any user-settable option.
>
> Likely related to the rotated panel: `GetDpiForSystem()` returns 96 (100 %) while the monitor and
> TD's windows are at 144 (150 %), and `GetDeviceCaps(HORZRES/VERTRES)` returns 800×1280 — portrait
> — for a landscape desktop.
