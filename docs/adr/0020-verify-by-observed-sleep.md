# 0020. Judge sleep behaviour by observed sleep, never by registry state

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **HOLD-01**, **HOLD-12**, **APP-07**
- **Related ADRs:** [0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md), [0004](0004-powerd-re-assert-policy.md), [0013](0013-lid-open-holds-timed-assertions.md), [0015](0015-external-display-detection-iokit.md)

## Context

The lid-close hold ([0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md)) has no readback. The obvious candidate, `AppleClamshellCausesSleep` in the registry, did not change on any of 5 writes. It copies the last clamshell message and is refreshed only on lid and power events. Before one test it read `No` while the bit was clear, which is wrong in the dangerous direction: a lid close would have slept the Mac.

Self-tests (the **APP-07** onboarding hold test), **HOLD-12**'s post-release check, diagnostics and future verification all need a way to decide whether the Mac slept.

## Decision

**The lid hold is judged only by observed sleep:**

- the clock gap across a sleep;
- power notifications, with `willSleep` as the primary evidence;
- `pmset -g log` entries such as "Clamshell Sleep".

Never by reading `AppleClamshellCausesSleep` or `ioreg`. Never by a fixed time window, because sleep entry can take 20 s with a display attached.

**Diagnostics:**

- The lid-close clamshell message carries a `sleepBit`: the kernel's full sleep decision at the instant the lid closes. It is exact evidence, but too late to prevent anything (`willSleep` follows within about 10 ms). Diagnostics count a `sleepBit=true` while a hold is wanted and show it in the lid-open summary.
- An unexpected lid-closed sleep while a hold is wanted is attributed to a power-source change within about 1.5 s before it, or to a display reconfiguration within about 0.5 s ([0015](0015-external-display-detection-iokit.md)), and shown in the lid-open summary.
- A dark wake with the lid closed shows as a clamshell message with `lidClosed=true` and `sleepBit=false`, with `System Capabilities` reading 9 ([0004](0004-powerd-re-assert-policy.md)).

**Measurement preconditions** for spikes, self-tests and verification:

- Run from processes Claude Code did not spawn (Terminal or launchd).
- No other keep-awake tool is running, Amphetamine is quit, and `SleepDisabled` is 0.
- Idle-sleep measurements only after every Claude Code session has been idle for more than 5 min, with the assertion table checked first ([0013](0013-lid-open-holds-timed-assertions.md)).
- External display connect and disconnect with the lid closed are part of the test matrix.
- Any installed helper is cleaned up afterwards: unregistered, and `SleepDisabled` reset to 0.
- Never drain the battery to a critical level, and never induce a thermal emergency.
- `log show` from a Claude Code session returned nothing at all, even for the last 20 s. Silence there is a broken instrument, not evidence.
- Lid behaviour on macOS 14 and 15 is verified on a physical Mac before release, because a VM has no lid.

## Consequences

- The launch self-test ([0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md)) judges only the call's return code; whether the hold works is shown by observed sleep over time.
- Tests that assert on registry values are rejected in review.
- Verification needs real lid closes, so parts of it stay manual.

**Not verified:** macOS 14 and 15. The attribution windows (about 1.5 s and about 0.5 s) come from a small number of runs on macOS 27.0.

## Alternatives considered

- **A registry-readback self-test.** Stale, and it hides real failures.
- **Judging sleep by a fixed time window.** Sleep entry varies from about 5 s to 20 s with a display, so any fixed window misjudges some runs.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spikes 001, 002, 004 and 006, on 2026-09-26.

- Spike 001 (VALIDATED): `AppleClamshellCausesSleep` did not change on any of 5 writes and read `No` while the bit was clear.
- Spike 002 (VALIDATED): sleep entry took up to 20 s with a display; the dark-wake signature; the attribution windows.
- Spike 004 (VALIDATED): `log show` from a Claude Code session returned nothing.
- Spike 006 (PARTIAL): foreign assertions (every busy Claude Code session's `caffeinate -i -t 300`, other apps, audio) affect idle-sleep measurements.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/lid-hold-clamshell.md`.
