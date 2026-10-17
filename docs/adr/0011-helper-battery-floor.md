# 0011. The helper enforces its own battery floor and heartbeat timeout

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **HOLD-16**, **HOLD-17**, **BAT-01**
- **Related ADRs:** [0003](0003-opt-in-root-helper-smappservice-daemon.md), [0009](0009-helper-release-sequence.md), [0012](0012-helper-thermal-release.md)

## Context

Whether `SleepDisabled` blocks emergency sleep was settled from source, not by draining a battery. Pinned sources: xnu-12377.121.6, xnu-10063.141.1 (macOS 14) and PowerManagement-1846.120.8.0.1.

- **It blocks emergency sleep (HIGH, from source).** In `IOPMrootDomain::checkSystemSleepAllowed`, `userDisabledAllSleep` is checked before the rule that always sleeps on low battery or thermal emergency. Every sleep request, including low-power and thermal-emergency sleep, goes through that gate.
- **On battery, the expected outcome is a hard power-off.** The low-battery sleep request is refused until the SMC cuts power (SMC shutdown cause -60, "Battery fully drained"). No hibernate image is written and unsaved work is lost.
- **MEDIUM exception.** On macOS 15+ on Apple Silicon, a critical battery may request a clean shutdown instead (powerd `pmconfigd.m` L1593-1611, `reboot3(RB_HALT)`), which `SleepDisabled` does not gate. Lockdown Mode forces that branch (HIGH). Which branch shipping hardware takes otherwise is closed source. macOS 14 has no shutdown branch.
- **powerd's own battery code only posts warnings** (`BatteryTimeRemaining.m` L1278-1279, `kSocThresholdEarly` 10, `kSocThresholdFinal` 2).

So while the helper holds the Mac, the operating system's emergency sleep no longer protects it. The app's **BAT-01** floor still exists, but a hung app would not enforce it.

## Decision

The helper protects the Mac on its own, independent of the app. It runs the release sequence from [0009](0009-helper-release-sequence.md):

- on battery at or below 10% (**BAT-01**'s `BATT_LOW`);
- unconditionally when `IOPSGetBatteryWarningLevel()` reaches `kIOPSLowBatteryWarningEarly`;
- whenever the power state cannot be read (fail safe).

It subscribes to power-source changes with `IOPSNotificationCreateRunLoopSource` or `notify_register_dispatch(kIOPSNotifyLowBattery)`.

The app's heartbeat timeout to the helper stays at 60 s or less, so a hung app cannot hold the Mac through a battery drain.

10% is far above the SMC critical level, which a field report puts at about 1%.

## Consequences

- The helper replaces the operating system's emergency sleep with its own floors while it holds the Mac. The project's "Scope of awake" statement and the REQUIREMENTS wording on emergency sleep should say that. Both were reworded at the go/no-go review on 2026-09-26.
- Onboarding (**APP-07**) says that while the helper holds the Mac on battery, macOS cannot emergency-sleep it, and the helper's floor is the only protection before a hard power-off.
- The same gate also blocks thermal-emergency sleep; [0012](0012-helper-thermal-release.md) releases the helper at Trapping or `.critical` for that reason.

**Not verified:**

- The floor itself was not exercised in a measured run. By rule, the spike never drains the battery to a critical level.
- Which emergency branch (blocked sleep or clean shutdown) each Apple Silicon SoC takes on macOS 15 to 27 is closed source.

## Alternatives considered

- **Rely on the app's BAT-01 floor alone.** A hung or crashed app would leave the helper holding the Mac through a drain to a hard power-off.
- **Rely on the operating system's emergency sleep.** Blocked by `SleepDisabled`, per the source above.

## Evidence

Spike 005 source research, settled on 2026-09-26 without changing anything on the machine (a MacBook Pro M5 Max running macOS 27.0, 26A428). Spike verdict: PARTIAL. The HIGH findings come from the pinned XNU and PowerManagement sources; the MEDIUM shutdown branch comes from the source plus one field report.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/root-helper.md`.

## Implementation notes (2026-10-08)

The decision above said "on battery at or below 10%", and Phase 3 built it that way: the floor applied only while macOS reported the battery as the power source. The Phase 3 code review (finding H-CR-01) found that this leaves a gap, and the rule changed on 2026-10-08 (delegated by the project author). None of this changes the rest of the decision: the helper still protects the Mac on its own, through the release sequence from [0009](0009-helper-release-sequence.md).

- **The rule now.** The helper releases at or below 10% whatever the power source. The floor reads the charge level and never the source. A set while the charge is at or below 10% is refused, on battery and on external power alike.
- **Why.** On a charger that supplies less than the Mac draws, the battery drains while macOS reports external power. The second limit does not cover that case: the SDK header (`IOKit/ps/IOPowerSources.h`) defines `kIOPSLowBatteryWarningNone` as "The system is not in a low battery situation, or is on drawing from an external power source", so the warning level stays None. With the source reading external power and the warning level at None, no limit fired, and `SleepDisabled` blocks emergency sleep.
- **Observed.** On the author's Mac on 2026-10-07, on a 17 W charger, the charge fell from 66% to 5% with the charger connected. The value `IOPSGetProvidingPowerSourceType` returned during that drain was not recorded; that the source reads external power with an adapter attached comes from the header above and from `pmset -g batt` reporting the battery as charging while it fell.
- **What did not change.** The low-battery warning level still releases on its own. An unreadable power state still releases, and still refuses a set. A Mac with no battery still has no floor: the floor is a charge level and there is none to read. In the helper as built, a Mac with no internal battery has no readable power state, so the helper does not engage there at all; such a Mac has no lid to close either.
- **Cost.** At 10% or less on a charger that is keeping up, the helper refuses until the charge passes 10%. The app's own rootless hold still works during that time.
- **Not changed here.** The app's own floor (**BAT-01**) still unblocks on external power at any charge, so the app can ask for the helper at 10% or less on external power and be refused. The helper answers `refused` with the reason `battery`, and the app retries every 30 s.

**Later the same day (fix group 2, the open item above).** The app no longer asks. Its helper intent treats a known charge at or below 10% as "not ready", on battery and on external power alike, so it does not engage there and releases an engaged helper with the reason `battery`. It asks again once the charge reads above 10%. The app's own floor (BAT-01) and its rootless hold are unchanged, and an unknown charge leaves the decision to the helper, which refuses it. The app's constant `HelperIntent.helperBatteryFloorPercent` is pinned equal to `HelperMachine.batteryFloorPercent` by `EngineHelperTests.theAppStopsAskingTheHelperAtTheHelpersOwnBatteryFloor`; the behaviour is pinned by the floor tests in `HelperIntentTests`.

Evidence: `HelperMachine.powerReason` and the tests `aLowBatteryOnExternalPowerReleasesWhateverThePowerSource`, `onExternalPowerAtOrBelow10PercentReleases`, `aSetOnExternalPowerAtOrBelowTheFloorIsRefused` and `theFloorReadsTheChargeAndNeverThePowerSource` in `HelperMachineTests`. The floor on external power was not exercised on hardware: by rule, the battery is never drained to a critical level on purpose.

## Amended by 0024 (2026-10-17)

The floor is now a setting from 5% to 50% (default 10%), sent with every set and clamped by the helper; a missing value means 10%. It still reads the charge whatever the power source (the H-CR-01 rule above), and it still applies when the app's own battery protection is switched off. The low-battery warning release and the unreadable-power release are unchanged. The constants named above, `HelperIntent.helperBatteryFloorPercent` and `HelperMachine.batteryFloorPercent`, are gone: the app reads the configured floor, and `EngineHelperTests.theAppsHelperLimitsMatchTheHelpersCompiledLimits` pins the app's range and default to the helper's compiled `HelperSafetyLimits`. See [0024](0024-configurable-battery-and-temperature-protection.md).
