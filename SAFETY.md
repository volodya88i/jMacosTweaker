# Safety

The app may only leave the system as safe as the default, or safer. These invariants cannot be disabled by the user.

## Invariants and enforcement

| # | Invariant | Enforcement | Verification |
| --- | --- | --- | --- |
| 1 | Minimal whitelisted API, no raw key write | Closed enum of operations; clamping in the helper | Unit tests, code review |
| 2 | Only the verified app may connect | Audit token, install path, pinned code directory hash | Tests, on-device |
| 3 | Fail safe to system control | Watchdog, disconnect grace, wake handling, boot restore | Chaos tests, on-device |
| 4 | Thermal supervisor overrides everything | Runs in the helper, before every write | Unit and chaos tests |
| 5 | Fans stay within hardware min and max; no manual mode without a live controller | Clamp at the writer; mode tied to controller lifetime | Unit tests, on-device |
| 6 | Read-back after each write: next tick for fan targets, battery state for `CHIE`, which does not echo | Bounded retry, then revert and report | Chaos tests, on-device |
| 7 | Restore journal; idempotent, de-duplicated writes | Journal before write | Unit tests, on-device |
| 8 | Charge floor: never inhibit at or below 20%; unreadable state enables charging | State machine guards | Unit tests, on-device |
| 9 | Never touch unrelated keys | Whitelist; a test that fails on any other key | Unit tests, review |
| 10 | Unknown hardware or OS disables the feature | Capability probe at start and after updates | Unit tests |

## Failure modes

| Failure | Response |
| --- | --- |
| App quits, crashes or is killed | XPC disconnect, short grace period, fans return to Auto |
| Helper crashes or restarts | At launch, read the journal and restore system control |
| Sleep or wake | Hand back to system before sleep; re-evaluate on wake |
| Control sensor stale, missing or implausible | Return to system control and report |
| Repeated write or read-back failure | Stop writing, return to system control, report |
| Critical temperature | Max fans or system control until recovery with hysteresis |
| Battery state unreadable | Enable charging |
| Another tool writing fan or charge keys | Detected by label and by unexpected read-back; control stops and the UI names the tool |
| macOS update changes keys | Probe mismatch; feature becomes read-only with an explanation |
| App rebuilt, hash no longer matches | Connection refused; UI shows the re-pin command |

## Found by on-device testing (2026-11-01, Mac16,8, macOS 27.2)

- Writing the saved mode 3 back did not take effect while `Ftst` was 1, so `F0` stayed manual at minimum speed after the
  app quit. This broke invariant 3 on hardware even though all mock tests passed. Hand-back is now mode 0, then
  `Ftst` back to its saved value.
- `F1Md` fell to 0 after unlocking while the helper believed it held the fan. Held state is now re-read every tick,
  re-asserted a few times, and then control is given up.
- After `Ftst` is set to 1, it reads back late and mode writes are refused for about 3 to 5 s while fans spin up. The
  helper treated that as failure and handed back, so fans stopped. It now retries each tick for up to 15 s.
- A written target could take over 150 ms to read back, which handed back fans that were obeying it. Target read-back
  is now checked on the next tick, with up to 5 consecutive mismatches allowed before control stops.
- `CHIE` does not read back what was written, so a read-back check failed every time and caused a write loop of about 60
  cycles in 19 s during a charge test. Its effect is now checked through battery state instead, within 60 s, and a
  repeated failed request does not retry.
- Each speed change counted as a failed hand-back in the fallback below, which sent fans to maximum while dragging the
  slider. This was a bug in the first version of that fallback, found from the helper's write log. Only real hand-back
  attempts count now, and fans not in manual mode need no write.
- If hand-back fails for 10 ticks, the fan goes to maximum rather than staying low with nothing watching it.

## Charge limit

The control sets the same macOS value as System Settings, through a private client, from the unprivileged app. macOS
enforces it, including its own safety behavior. No SMC key is written. Only values macOS lists can be sent, and each
change is read back. The helper's limit engine stays unused on the tested Mac, since `CHIE` cuts the adapter rather than
holding charge.

## Pause Charging (2026-11-15)

The owner asked for a manual pause as a backup when the macOS limit does not hold. It is the one use of `CHIE` on Mac16,8,
which is now on the verified list for charge control on macOS 27: the adapter is set aside, the Mac runs from its battery,
and writing 0 brings the adapter back. Run by the helper, so it keeps going with the app closed.

| Rule | Where | Test |
| --- | --- | --- |
| Ends at the chosen time or level, whichever is first | `ChargeStateMachine.evaluate` | `testPauseEndsAtTheChosenLevel`, `testPauseEndsAtTheChosenTime` |
| Never below 20%, whatever was asked | Floor check before the pause; level clamped to 20 to 95 | `testPauseNeverRunsBelowTheFloor` |
| Unreadable battery ends it at once | Percent checked first | `testUnreadableBatteryEndsThePauseAtOnce` |
| Never longer than a day, even when only a level is given | `ChargeStateMachine.validated` | `testPauseIsCappedAtADay` |
| No draining while asleep: charging is allowed before sleep and the pause resumes after wake | `ControlCore.willSleep` | `testSleepAllowsChargingAndWakeResumesThePause` |
| Survives a helper restart, with a wall-clock end | Saved with the charge policy | `testPauseSurvivesAHelperRestart` |
| Restore defaults ends it | `ControlCore.restoreDefaults` | `testRestoreDefaultsEndsThePause` |
| A pause that does not stop charging within 60 s is turned off | Existing effect check | `testInhibitThatHasNoEffectIsTurnedOff` |

Needs on-device verification: a full pause through the app, from start to its time, its level and Resume.

## Force-kill test (2026-11-01, Mac16,8, macOS 27.2)

With both fans held at 2,317 rpm, the app was killed with `SIGKILL`. The helper handed back after 5 s as designed: `F*Md`
went to 0 and `Ftst` to 0, the firmware set `F*Md` to 3 and stopped the fans within 10 s of the kill, and the restore record
was removed.

## Restart test (2026-11-01, Mac16,8, macOS 27.2)

Restarted with Constant active. After boot, `Ftst` was 0, `F*Md` 3, fans stopped and `CHIE` 0. A restore record left over
from shutdown was present at first and was gone within about a minute, without the app doing anything.

Launchd started the helper at 05:34:02, but its listener only came up at 05:34:58, so restoring and accepting connections
took about 56 s at boot. The cause is not confirmed; building the sensor list at start, while system services are still
coming up, is the likely one. The keys were already at rest throughout this test. The sensor list is now built on first
use, after the restore, and the helper logs when it finishes restoring and starts listening.

Macs Fan Control's helper loads at boot, so fan control was correctly blocked when the app reopened at login.

## Review of 2026-11-09

| Finding | Risk | Change |
| --- | --- | --- |
| With Constant or Custom and every temperature unreadable, fans kept their speed and the supervisor saw nothing | Invariants 3 and 4 | Fans return to system control after 5 s without a CPU or GPU reading, unless every policy is Max. `testConstantSpeedReturnsToSystemWhenTemperaturesVanish` |
| A curve entered manual mode before it had a temperature, leaving the fan at the unlock target | Invariant 5 | A curve waits for a reading. `testCurveWithNoReadingYetStaysUnderSystemControl` |
| `install_helper.sh` checked entitlements on the user-writable source before copying it | A swap between check and copy | All checks run on a root-owned staged copy: `codesign --verify --strict --deep`, identifier, hardened runtime on app and helper, no `get-task-allow` |
| The LaunchDaemon plist was copied from the script's folder, which can be user-writable | Root code execution through an edited plist | The script writes the plist itself and lints it |
| The pinned hash went unchecked into `setCodeSigningRequirement` | Requirement injection, if the root-owned pin file were ever wrong | `ClientVerifier` refuses anything but 40 or 64 hex characters. `testMalformedPinIsRefusedBeforeUse` |
| One slow helper reply stopped the app's heartbeat for good | Fans handed back unexpectedly (fails safe, but wrong) | The heartbeat survives up to 6 missed beats |
| Imported settings were not range-checked | An interval of 0 would make sampling spin | `AppSettings.normalized` clamps every number |
| Placeholder temperatures passed the 1 to 130 °C check: 1.5 to 8.3 °C, and exactly 40.0 from every P-cluster sensor while the cluster is powered down | Wrong minimums; worse, a CPU really at 90 °C could read 40.0 to the supervisor | Placeholders are rejected per sample: floor, exact 40.0 on a die, identical die readings, median check |
| Sensors asleep when the list was built, such as the GPU's at idle, were missing for the whole session | The supervisor never saw the GPU | They wait and join when they first report a real value; the helper rebuilds its groups when that happens. Verified on Mac16,8: all 45 P and 22 GPU sensors listed, no exact 40.0 accepted, lowest accepted value 24 °C |

Not changed, and why: `FileStore` sets 0600 after an atomic write, so a journal is briefly world-readable; it holds no
secrets. The native charge limit client leaks one object once per launch through its private `alloc`/`init` path.

## Review of 2026-11-18

| Finding | Risk | Change |
| --- | --- | --- |
| The supervisor acted on single samples at 95 °C, and the hottest P-core on an M4 Pro passes that on short bursts | Fans at maximum many times an hour, ignoring the curve | 10 s averages at 100 °C, critical single sample at 108 °C, steps of 25% instead of a jump to maximum. `SupervisorTests` |
| A curve could be flat at 0% up to 100 °C, or follow a cool sensor such as the SSD while the CPU is hot | Weaker cooling than macOS | The macOS floor, applied in the helper against the hottest CPU or GPU. `testNoRequestIsWeakerThanTheMacOSFloor` |
| A curve's top point was not a ceiling below the supervisor | Fans above what the owner set | Spikes are filtered; the top point holds unless the supervisor engages. `testCurveTopIsTheCeilingBelowTheSupervisor` |

## Installing from the app

**Install Helper…** runs the bundled `install_helper.sh` as root through `osascript` with `do shell script … with
administrator privileges`, so macOS shows its own password dialog; the app never receives the password. Before that the
app checks its own bundle with `SecStaticCodeCheckValidity` (all architectures, strict, nested code), so a copy whose
scripts were edited after signing is refused (tested: a one-line change to the script fails the check). The script then
applies all of its own checks to a root-owned staged copy, as before. Arguments are single-quoted for the shell and
escaped for AppleScript (tested with spaces, quotes and apostrophes in paths). **Remove Helper…** restores defaults
first, then runs `uninstall_helper.sh` the same way.

## Network

The app makes one kind of network request, and only with Settings > Updates on (off by default): a GET of
`https://api.github.com/repos/volodya88i/jMacosTweaker/releases/latest` at most once a day, from an ephemeral session
with no cookies, cache or credentials. The only header beyond the defaults is `User-Agent: jMacosTweaker`. Only
`tag_name`, `draft` and `prerelease` are read; replies over 512 KB are refused, and a tag must be one to three plain
numbers (`ReleaseCheckTests`). The release link is built from that number, never taken from the reply. Nothing is
downloaded or installed. The helper makes no network requests.

## Known weaknesses

- **Client verification is weaker without a Developer ID.** Ad-hoc signing has no team identity. The helper relies
  on a pinned hash and a root-owned install path. A root attacker defeats this, but one already has full control.
  A user-level process cannot pass the pinned hash check unless it is the pinned binary, and code injection into
  that binary must be blocked by the hardened runtime. This must be tested, not assumed.
- **`auditToken` is not public API on `NSXPCConnection`.** If it goes away, the helper refuses all connections, which
  fails safe. `setCodeSigningRequirement` with the pinned hash is applied as well.
- **Conflict detection only knows listed tools.** Others show up as read-back mismatches, which stop control.
- **Every rebuild requires re-pinning** by re-running the install script with sudo.
- **Key semantics come from observation.** Apple publishes no SMC documentation, so behavior can change in any update.
- **The charge limit uses a private macOS interface** that an update could change or lock down. Then the control is not
  offered, and the setting in System Settings keeps working.

## Where each invariant is enforced

| # | Code | Tests |
| --- | --- | --- |
| 1 | `HelperXPC`, `ControlWrite`, `ControlCore.validate` | `WhitelistTests`, `ValidationTests` |
| 2 | `ClientVerifier`, `CodeInspector`, `HelperDaemon` | `ClientVerifierTests`. Real connections need on-device verification |
| 3 | `ControlCore` events, `HelperDaemon` power and signal handling | `FailSafeTests`. Real sleep and SIGTERM need on-device verification |
| 4 | `ThermalSupervisor`, `ControlCore.tickFans` | `SupervisorTests` |
| 5 | `CurveMath.rpm`, `ControlCore.command` | `LimitsAndReadbackTests` |
| 6 | `VerifiedWriter` | `LimitsAndReadbackTests`, `ChargeControlTests` |
| 7 | `RestoreJournal`, `ControlCore.enterManual` | `FailSafeTests`, `testIdenticalTargetsAreNotRewritten` |
| 8 | `ChargeStateMachine`, `ControlCore.applyChargeAction` | `ChargeMachineTests`, `ChargeControlTests` |
| 9 | `KeyWhitelist`, checked again in `RawSMCPort.write` | `WhitelistTests` |
| 10 | `CapabilityProbe` | `CapabilityTests` |

Control stays off unless the model and macOS major version are on the verified list, which is empty until an on-device
test passes. A root-owned flag file, created only by `install_helper.sh --allow-unverified-control`, allows a deliberate
test. An update to a new macOS major version turns control off again.

Thermal limits are judged on 10 s averages: 100 °C for CPU and GPU, 75 °C for SSD and 50 °C for the battery. A single
CPU or GPU sample at 108 °C or more engages at once and sends fans to maximum. Otherwise the supervisor adds a quarter of
each fan's range to whatever the request wants, then another quarter every 5 s, until the CPU and GPU averages fall below
92 °C (SSD and battery: 10 °C below their limits). The limits are not read from the system, because no readable system
limit was found on this hardware. Until 0.2.2 any single sample at 95 °C sent fans to maximum; on an M4 Pro the hottest
P-core passes that on any short burst of work, so fans went to maximum many times an hour.

No request is weaker than macOS: every curve and Constant speed is raised, in the helper, to a floor that follows the
hottest CPU or GPU temperature (`CurveMath.macOSFloor`: fans at their minimum to 85 °C, 20% at 95 °C, 40% at 100 °C,
70% at 110 °C). Fans under this app never stop, because 0% is the hardware minimum speed. The floor is modeled on the
owner's report that macOS keeps fans below half speed at 100 °C, and is UNVERIFIED against a measured firmware curve:
`tools/probes/fanlog.sh` records one, read-only, for a later revision.

Short spikes are skipped before a curve sees them: the control temperature, and the temperature the floor follows, rise
only once a value has held for the chosen Response window (3, 10 or 30 s) and fall at once. The supervisor does not use
this filter.

Discharge on adapter has no verified key. If requested, it behaves as inhibit: charging stops and the battery holds.
The UI does not offer it.

## On-device write policy

No SMC write, helper registration or helper installation happens on the development machine without explicit
approval, stated per step: keys, values, revert path and failsafe. All development before that is mock-backed.

Before any fan test, Macs Fan Control must be quit. Before any charge test, current state is read first, because an
installed charge tool may have changed it in the past.
