# Changelog

## 0.2.2 - 2026-11-18

- **Pause Charging**, on the Battery page and in the Battery popover: stop taking charge for 30 minutes to 4 hours, or
  until the battery is at a chosen level, for when the macOS limit does not hold. The Mac runs from its battery during
  the pause. It ends at the chosen time or level, at 20% at the latest, before sleep, after a day at most, or on Resume,
  and the helper keeps it going with the app closed. Uses `CHIE`, verified on Mac16,8 with macOS 27 only. The helper
  protocol changed, so update the helper with the installer.
- Menu bar popovers: the fan mode switch includes **Custom**, with a **Saved Curves** menu when you have saved curves,
  and the overview and Battery popovers have a **Pause** menu (30 minutes to 4 hours, or until 80, 70, 60 or 50%) and
  **Resume**.
- Fixed: in the Battery popover, the "Charge limit" label wrapped one letter per line.
- Fixed: the charging row in the popover cut its caption short.
- **Short spikes no longer spin fans up.** A new Response setting on the Fans page: Fast (3 s), Normal (10 s, the
  default) or Calm (30 s). A rise must last that long before a curve follows it, and fans speed up more gently.
- **A curve's top point is its ceiling.** The thermal supervisor used to send fans to maximum whenever one sample of the
  hottest core reached 95 °C, which on an M4 Pro happens on any short burst of work. It now acts on 10 s averages at
  100 °C, or on a single reading of 108 °C, and raises fans in steps of 25% rather than straight to maximum.
- **Never weaker than macOS.** Curves and Constant speed are raised to a floor that follows the hottest CPU or GPU,
  whatever sensor the curve follows. The curve editor shows it as "macOS minimum", and points cannot be dragged into it.
- The curve editor is labeled up to 100 °C, with room for a point at 100 °C.
- P-cores and E-cores are labeled on the Performance page and in the CPU popover: two groups with core numbers, the
  group's average, and each core's load on hover. Sensor groups are named P-cores and E-cores.
- Notifications are off by default, and are turned off once on update; turn them back on in Settings.
- Lower CPU use: menu bar text widths are measured once per value, widget content is worked out once per update,
  slower sources share the faster sources' wakeups (5 s becomes 6 s beside 2 s), window pages refresh every 2 s, and the
  window no longer measures the whole page for size limits on every update. With the owner's menu bar, measured on
  Mac16,8: window closed 1.15% to about 0.9% of one core, Performance page 3.4% to 2.0%, Battery page 2.5% to 1.7%.
- **Fan modes are Auto, Fixed, Custom and Max.** The built-in Silent, Balanced and Performance curves are gone in favor
  of your own saved curves. If one was selected, it becomes your Custom curve and a saved curve of the same name; per-fan
  and power-source choices that used one switch to Custom. Constant is now called Fixed.
- The menu bar popover offers Auto, Fixed and Custom. Fixed has a speed slider; Custom has a list of your saved curves.
- Saving, renaming or importing a curve under a name already in use asks before replacing it. Import can also keep both,
  numbering the new one. The Fans page shows which saved curve is running, or that the curve is not saved.
- **Update check**, off by default: Settings > Updates > Check for updates once a day. It reads the latest version number
  from GitHub, shows a notice at the foot of the sidebar when a newer one is out, and links to its release page. It sends
  nothing about your Mac and never downloads or installs anything. With it off, the app makes no network requests.
- The helper protocol is now version 3, so update the helper with the installer.

## 0.2.1 - 2026-11-10

- The window's title bar keeps one height on every page, so the window buttons no longer jump between pages. Restore
  System Defaults is now in the toolbar of every page; page subtitles moved into the pages.
- Icons in colored tiles are centered and evenly sized, in the sidebar and on the Menu Bar page.
- The temperature chart gives each area its own color (CPU orange, GPU purple, SSD teal, battery green) instead of
  dashed lines.
- Faster page switching. The window has one toolbar that pages never change; the Sensors controls moved into the page.
  Cards no longer stretch to fill their row except where a row lines them up, big numbers no longer shrink-to-fit,
  sensor statistics are written once per sample instead of once per sensor, repeated helper and charge limit replies
  no longer redraw the page, and Settings reads the login item state once instead of on every redraw. Measured with
  `--benchmark` (debug builds): Sensors 86 to 125 ms per switch before, 60 to 95 ms after.

## 0.2.0 - 2026-11-09

Design
- A native macOS look throughout: a System Settings style sidebar, grouped forms, cards, and system colors and materials in
  both appearances. Liquid Glass on macOS 26 and later, through stock controls, with the classic look on macOS 14 and 15.
- The menu bar panel is a native popover with fan tiles, a fan mode switch, load tiles and a temperature chart.
- Fan modes are cards with a picture of each curve. The curve editor shows where the temperature is now.
- The Sensors page is a native list with search in the toolbar, a Main and All switch, and a button that resets min and max.
- Temperature and battery bars use state colors: green, then orange, then red. The graph color follows the system accent
  color by default.
- The true black theme and the Instrument style are retired.

Fixes
- Temperatures: placeholder values are filtered out. On Mac16,8, die sensors of a powered-down cluster report fixed
  values instead of a temperature: `Tp1*`/`Tp2*` exactly 40.0, `Tg*` -4.0 to 2.4, `Tp0*` 40.0 to 5.2, and `Ta0*` sit at
  8.3. They showed up as minimums of about 5 °C and as a CPU stuck at exactly 40°. Readings below 10 °C (except the
  battery), exactly 40.0 on a die, many identical die readings, and readings far below their group are rejected.
- Sensors asleep at launch, such as the GPU's on an idle Mac, are no longer missing for the whole session: they join the
  list when they first report a real temperature, in the app and in the helper's thermal supervisor.
- Fan control no longer stops by itself after one slow reply from the helper.
- Dragging on the curve editor no longer picks up a point it passes over.
- Pinning a sensor no longer reads settings while they are being changed.
- The main window shows its section as the title instead of "Untitled".

Safety and security
- The helper hands fans back to macOS if it cannot read any CPU or GPU temperature for 5 s, whatever the mode except Max.
  Before, Constant could keep running with the thermal supervisor blind.
- A curve no longer takes manual control before it has a temperature to follow.
- `install_helper.sh` checks the app on a root-owned copy, verifies the code signature and identifier, and writes the
  LaunchDaemon file itself instead of copying one from a folder the user can write to.
- The helper refuses a pinned hash that is not plain hex, before it becomes part of a code signing requirement.
- Imported or hand-edited settings are brought back into range, so an update interval of 0 cannot make sampling spin.

Install
- The disk image has **Install jMacosTweaker.command**: one double-click copies the app to Applications, installs the
  helper and opens the app. Dragging the app still works for monitoring only.


## 0.1.1 - 2026-11-01

- README: how to remove helpers left behind by other fan and battery tools.
- Fixed: the helper would not load from a downloaded copy if its quarantine flag was still set.

## 0.1.0 - 2026-11-01

First public release.

- Monitoring: CPU, memory, GPU, temperatures, fans, battery and power.
- Independent menu bar modules with styles, thresholds and visibility rules.
- Optional accent color for lines. True black dark theme.
- Fan presets, curve editor and charge limit, enforced by a root helper. Control is off until verified on a given Mac
  and macOS version.
- Live power figures, network and disk speed, top processes, time to charge limit.
- Named fan curves, live module previews on the Widgets page, main menu, settings reset.
- Power drawn by accessories, such as a phone charging from the Mac.
- A choice of sensor for the Temperature module.
- App icon.
- A GitHub link in Settings, under About.
- License changed from MIT to MIT with the Commons Clause, which forbids selling the software.
