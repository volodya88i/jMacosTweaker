# Changelog

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
