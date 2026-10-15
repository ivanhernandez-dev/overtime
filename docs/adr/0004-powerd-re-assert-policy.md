# 0004. Re-assert the clamshell bit blindly, on full wake only, in a burst after each wake

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **HOLD-01**, **HOLD-02**
- **Related ADRs:** [0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md), [0005](0005-sentinel-watchdog-design.md), [0020](0020-verify-by-observed-sleep.md)

## Context

The lid-close hold ([0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md)) is one kernel bit shared with powerd, with no readback. powerd writes that bit around every sleep and wake. If Overtime re-asserts at the wrong moment, powerd's write lands after it, the bit is 0, and a lid close shortly after waking sleeps the Mac while Claude Code is busy (**HOLD-01**).

During a dark wake the Overtime process runs and its timers fire, but a dark wake must never engage a hold. So Overtime must also tell a dark wake from a full wake without root.

Source versions read: PowerManagement-1846.120.8.0.1 and xnu-12377.121.6. The source research recorded function names, not line numbers, for the powerd paths below.

## Decision

- **Write blindly.** Write selector 12 idempotently and never read the registry to decide whether to write. Writing 1 when the bit is already 1 is harmless.
- **Full wake only.** Gate every engage and every re-assert, including the periodic one, on `System Capabilities & 0x2` on `IOPMrootDomain` (the Graphics capability, present only in a full wake).
- **Burst after each full wake.** On `hasPoweredOn`, poll `System Capabilities` until Graphics appears, for up to about 6 s. Then re-assert every 1 s from `hasPoweredOn` + 1 s to + 6 s. Then fall back to the normal 10 s cadence.
- **Never delay sleep.** Acknowledge `canSystemSleep` and `willSleep` at once with `IOAllowPowerChange`.

Do not shorten or remove this schedule to save calls: it costs six Mach calls per wake and does not depend on the exact delay.

### Timing table

| Event | powerd or kernel behaviour (source) | Measured on macOS 27.0 | Rule |
|-------|-------------------------------------|------------------------|------|
| `willSleep` | On arm64, powerd `pmconfigd.m` calls `disableClamshellSleepState()` on `kIOMessageSystemWillSleep`, its "last resort safety net". It writes 1 and marks its private state non-zero. | Not observable directly (no readback); it sets up the clear after the wake. | Acknowledge at once with `IOAllowPowerChange`. |
| Dark wake | powerd never writes the bit during a dark wake. | The process runs and timers fire, but `willPowerOn` and `hasPoweredOn` arrive only at the dark → full transition (4 of 4). `System Capabilities` reads 9 throughout. | Never engage or re-assert without the Graphics bit. A hook on `hasPoweredOn` is dark-safe by itself; a periodic timer is not. |
| `hasPoweredOn` of a full wake | `System Capabilities` bits: CPU 0x1, Graphics 0x2, Audio 0x4, Network 0x8. A full wake reads 15. | It can still read 9 (no Graphics) for 10 ms to about 5 s after `hasPoweredOn`, and it reads 9 during sleep entry too. | Poll until Graphics appears (up to about 6 s); never classify the wake from one read. |
| powerd's post-wake evaluation | On `WillPowerOn` or `WillNotSleep`, powerd schedules `evaluateClamshellSleepState()` after `kClamshellEvaluateDelay` = 5 s. With no desktop mode and no lid-modifier assertions it computes 0 and writes 0, clearing Overtime's bit. | On a lid-driven full wake the clear lands 1 to 3 s after the app-level `hasPoweredOn`: a re-assert at +1.04 s lost and one at +3.04 s held (one run each). | Re-assert every 1 s from +1 s to +6 s. |
| Re-assert after the evaluation | - | A re-assert at +6 s held 2 of 2. Recovery re-asserts at +7 s held 11 of 11. | Then the 10 s cadence. |
| Interrupted `pmset sleepnow` | Not traced separately in the source. | powerd's post-wake evaluation still ran about 5 s after the wake. | Expect the clear; the bit must be re-asserted afterwards, as after any wake. |
| Power-source change, desktop-mode change | powerd re-evaluates on every power-source change (`BatteryTimeRemaining.m`) and on desktop-mode updates, and writes whenever its computed state crosses zero. | With the lid closed, see the event table in [0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md). With the lid open, not measured. | The 10 s cadence restores the bit. |

## Consequences

- The periodic re-assert only restores the bit. It cannot prevent a sleep that a clear causes while the lid is closed, because a clear with the lid closed sleeps the Mac in milliseconds ([0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md)).
- The rule is written in terms of observed timing, so a future macOS that moves powerd's clear inside the 1 to 6 s window is still covered. A clear later than about 6 s would be restored only by the 10 s cadence.
- Diagnostics that need to know whether the hold held use observed sleep ([0020](0020-verify-by-observed-sleep.md)), never the registry.
- A relaunched app follows the same Graphics gate ([0005](0005-sentinel-watchdog-design.md), [0002](0002-ops-01-restart-login-item-plus-sentinel-relaunch.md)).

**Not verified:** lid-open clears caused by power-source or display changes were not measured. The 10 s cadence restores the bit after them; an extra idempotent re-assert right after those events would be harmless but is unproven. macOS 14 and 15 were not tested.

## Alternatives considered

- **A single re-assert at wake + 1 s.** Lost on a lid-driven full wake: powerd's clear landed after it.
- **Re-asserts at about +6 s and +10 s only.** This was the project research's recommendation, derived from `kClamshellEvaluateDelay` = 5 s. Superseded: spike 003 bracketed the real clear at 1 to 3 s after `hasPoweredOn`, earlier than the source suggests, so the window between wake and +6 s would be unprotected.
- **Read, then write only if needed.** Impossible: there is no readback. `AppleClamshellCausesSleep` is stale ([0020](0020-verify-by-observed-sleep.md)).
- **A periodic re-assert without the Graphics gate.** It would write during a dark wake.
- **Classifying the wake from one read at `hasPoweredOn`.** Misclassifies full wakes as dark for up to about 5 s.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spikes 002 and 003, on 2026-09-26. Both verdicts: VALIDATED.

- Spike 002: the dark-wake behaviour (4 of 4), the `System Capabilities` transition window of 10 ms to about 5 s, re-asserts at +6 s (2 of 2) and +7 s (11 of 11), and the interrupted `pmset sleepnow`.
- Spike 003: the bracket. With a re-assert at `hasPoweredOn` + 1.04 s and the lid closed at +23 s, the Mac slept (lid-close `sleepBit=true`). With a re-assert at + 3.04 s and the lid closed at +20 s, it stayed awake.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/lid-hold-clamshell.md`.
