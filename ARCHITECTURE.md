# Architecture

## Targets

| Target | Role | Privilege |
| --- | --- | --- |
| `App` | SwiftUI and AppKit UI, status items, popover, main window | User |
| `Core` | Scheduler, samplers, sensor catalog, curve engine, charge state machine, power math | Linked by App and Helper |
| `Shared` | XPC protocol and Codable types, version constant | Linked by App and Helper |
| `HelperCore` | Supervisor, controllers, watchdog, journal, client verification decisions; talks to hardware only through protocols | Linked by the helper and its tests |
| `PrivilegedHelper` | Root daemon: XPC listener and the only real SMC writer | Root |
| `CoreTests`, `HelperTests` | Unit and chaos tests against mocks | None |

Project generation: XcodeGen, from a checked-in `project.yml`. The signing identity comes from an `.xcconfig` and
defaults to ad-hoc. Swift 6 strict concurrency, minimum macOS 14, universal binary.

## Hardware boundary

All hardware access goes through protocols, each with a real and a mock implementation:

- `SMCReading`: key enumeration, metadata, typed reads. Available to the app and the helper.
- `SMCWriting`: helper only. Takes a closed enum of operations and has no raw-key entry point.
- `HIDSensorReading`, `IOReportReading`, `BatteryReading`, `MemoryReading`, `CPUReading`, `GPUReading`.

Rules confirmed by probing:

- Endianness is decided per key family and cross-checked, never by type name alone.
- Plausibility filtering is mandatory. The tested Mac reports -9200 °C and NaN from real services.
- HID names repeat, so sensor identity combines source, service and name.
- The SMC struct layout has a size test, because a wrong layout fails silently.

## Sampling

One `Scheduler` actor owns a single coalescing timer with leeway. Modules register demand: what is needed and at
what rate. No demand means no polling.

| Situation | Rate |
| --- | --- |
| Popover and window closed, widgets only | Slow, per-widget interval, default 5 s |
| Detail view visible | 1 s |
| Display or system asleep | Paused |
| Low Power Mode or thermal pressure | Rates reduced |

Power-source changes and sleep/wake arrive through OS notifications rather than polling. History uses fixed-size
ring buffers. Graphs use `Canvas`. Models are small and observed separately to keep invalidation narrow.

## Helper

- Installed by `tools/install_helper.sh`. `SMAppService` has not been tested with ad-hoc signing.
- Runs its own control loop at no more than 1 Hz, and only while control is active. Idle means no timer.
- The app sends intent, such as a preset or limit, and heartbeats. The helper evaluates and writes.
- A journal on disk records what changed, so defaults can be restored after a crash or reboot.

Control lives in the helper, so a dead UI cannot strand a fan in a low state, and charge limiting survives closing
the app.

## Data flow

```
Sensors -> Scheduler -> Observable models -> Views and status items
App intent -> XPC -> Helper validation -> Curve or charge engine -> Supervisor -> Writer -> Read-back -> Journal
```

## Repository layout

```
App/  Core/  Shared/  HelperCore/  PrivilegedHelper/  Tests/  tools/  Config/
```

`tools/export_public.sh` works from an explicit allowlist.
