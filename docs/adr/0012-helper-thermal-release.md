# 0012. The helper releases at a thermal emergency: Trapping or `.critical`

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **HOLD-16**, **HOLD-17**
- **Related ADRs:** [0003](0003-opt-in-root-helper-smappservice-daemon.md), [0009](0009-helper-release-sequence.md), [0011](0011-helper-battery-floor.md)

## Context

The same `checkSystemSleepAllowed` ordering described in [0011](0011-helper-battery-floor.md) means `SleepDisabled` also blocks thermal-emergency sleep. For example, a dark-wake thermal event (powerd `handleDWThermalMsg`, `pmconfigd.m` L1437-1467, sleep reason `DarkWakeThermalEmergency`) is refused while the helper holds the Mac.

What still happens when the Mac overheats with `SleepDisabled` set:

- CPU throttling does not depend on sleep policy and still happens.
- The last line of defence is the SMC hard shutdown (cause -81, "Thermal shutdown for overtemp"). The hardware is protected; unsaved work is not.

REQUIREMENTS lists "Thermal protection / thermal pause" as out of scope, with the reason "Temperature is not a concern". That conflicts with the helper removing the operating system's own thermal sleep while it holds a closed lid.

## Decision

Option B. While it holds the Mac, the helper runs the release sequence from [0009](0009-helper-release-sequence.md) when `kOSThermalNotificationPressureLevelName` reaches Trapping (level 3 of Nominal 0, Moderate 1, Heavy 2, Trapping 3, Sleeping 4), or when `ProcessInfo.thermalState` reaches `.critical`. This is the source research's stated minimum threshold.

- `IOPMGetThermalWarningLevel` with `kIOPMThermalWarningNotificationKey` is an optional cross-check, since it feeds the kernel's thermal warning state.
- REQUIREMENTS keeps "Thermal protection / thermal pause" out of scope, with one narrow exception for the helper: with the helper engaged and the lid closed, it releases at Trapping or `.critical`.

Why B:

- It gives back exactly the emergency sleep that `SleepDisabled` takes away, at the emergency threshold, instead of releasing during ordinary heavy load. How often Heavy or `.serious` occurs during closed-lid work is unknown, so option A risks unwanted releases.
- It keeps "temperature is not a concern" true for normal operation.
- It honours the project's tie-break: in a failure state, here a Mac overheating, "never stuck awake" wins.

## Consequences

- Phase 3 adds the thermal trigger to the helper's release paths in [0009](0009-helper-release-sequence.md), next to the battery floor from [0011](0011-helper-battery-floor.md).
- The REQUIREMENTS out-of-scope row "Thermal protection / thermal pause" carries the narrow exception above, and **HOLD-16** lists a thermal emergency among the helper's clear conditions.
- Between Heavy and Trapping the helper keeps holding. CPU throttling still applies there, as it does without the helper.

**Not verified:**

- Who sends `kIOPMOverTemp` on Apple Silicon, and how it maps to `.critical`, is closed source.
- How often Heavy or `.serious` occurs during normal closed-lid work was not measured, and neither was how often Trapping or `.critical` does.
- The thermal release has never been triggered: by rule, the spike induced no thermal emergency.

## Alternatives considered

- **Option A: release at Heavy or `.serious`.** The same mechanism one level earlier: Heavy (level 2), or `ProcessInfo.thermalState` at `.serious` or above. It was the source research's recommendation, and the Mac could sleep again before it reached a thermal emergency. Rejected: how often Heavy or `.serious` occurs during normal closed-lid work is unknown, so the rate of unwanted releases is unknown.
- **Option C: no thermal release.** Thermal stays fully out of scope, and the documentation says that with the helper engaged macOS cannot thermal-sleep the Mac, relying on throttling and the SMC shutdown. Rejected: it leaves the helper removing the operating system's thermal protection with only the SMC hard shutdown behind it; a hot Mac in a bag throttles and may hard power-off, losing unsaved work.

## Evidence

Spike 005 source research on 2026-09-26 (pinned sources: xnu-12377.121.6 and PowerManagement-1846.120.8.0.1). Spike verdict: PARTIAL. By rule, the spike never induced a thermal emergency, so there is no heat test.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/sources/005-helper-daemon/research-emergency-sleep.md`.

## Amended by 0024 (2026-10-17)

The thermal-pressure release above is unchanged. The helper also releases at a battery temperature ceiling, the app's release temperature (35 to 60 degrees Celsius) or 60 degrees with temperature protection off, through the same release sequence; a missing battery temperature sets no ceiling. REQUIREMENTS' thermal row now covers the battery temperature (BAT-05). See [0024](0024-configurable-battery-and-temperature-protection.md).
