# 0013. Lid-open holds use timed IOPM assertions

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **HOLD-11**, **HOLD-10**, **HOLD-03**
- **Related ADRs:** [0014](0014-lock-screen-on-lid-close.md), [0020](0020-verify-by-observed-sleep.md)

## Context

**HOLD-11** requires that, while keep-awake is wanted, the Mac does not idle-sleep with the lid open, on AC or on battery. That includes the release grace and times when only transcripts signal busy, which Claude Code's own `caffeinate -i` does not cover. The mechanism must die with the process, and a hung Overtime must not keep it alive.

**HOLD-10** adds an opt-in "Keep display on while Claude works" setting, off by default. **HOLD-03** says the display may otherwise sleep normally with the lid open.

## Decision

- **Idle hold (HOLD-11).** An `IOPMAssertionCreateWithName` assertion of type `kIOPMAssertPreventUserIdleSystemSleep`, named "Overtime: Claude Code is working".
  - It carries a timeout (for example 5 min) with `kIOPMAssertionTimeoutActionRelease`.
  - It is renewed on every engine tick, so a hung app stops renewing it and the timeout releases it.
  - It is released with `IOPMAssertionRelease`.
- **Display hold (HOLD-10, off by default).** The same call with `kIOPMAssertPreventUserIdleDisplaySleep`, the assertion `caffeinate -d` takes, with the same timeout rule.
- These assertions die with their holder, so the lid-open half needs no sentinel.

## Consequences

- The lid-open path is crash-safe and hang-safe by construction, and needs no root.
- Any idle-sleep self-test or diagnostic checks the assertion table first. Every busy Claude Code session holds `caffeinate -i -t 300`, other apps take transient assertions (one seen: "Address Book Source Sync"), and audio playback takes one. Without that check, an idle-sleep result says nothing about Overtime.
- Idle sleep after a release may take longer than the idle timer suggests (178 s after a kill with a 1 min timer in the spike), so diagnostics judge by observed sleep over a generous window ([0020](0020-verify-by-observed-sleep.md)).
- With the lid closed, the display is turned off to lock the screen ([0014](0014-lock-screen-on-lid-close.md)), whatever **HOLD-10** says, unless an external display is attached.

**Not verified:**

- The display assertion's effect on a 2 to 10 min display timer was not timed.
- Screen Sharing interaction (spike verdict PARTIAL for that reason).
- macOS 14 and 15.

## Alternatives considered

- **An untimed assertion.** A hung app would hold idle sleep forever, against **HOLD-11**.
- **Relying on Claude Code's own `caffeinate -i`.** It does not cover the release grace or transcript-only busy signals.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spike 006, on 2026-09-26. Verdict: PARTIAL.

- While `PreventUserIdleSystemSleep` was held on battery, idle sleep was blocked for the full 4 min. The control, with no assertion, slept 39 s after `displaysleepnow`.
- `kill -9` of the holder released the assertion in 55 ms.
- A 10 s timeout with the release action released at exactly 10.0 s while the holder was still alive.
- After the kill, idle sleep came 178 s later, slower than the 1 min timer. The cause was not isolated.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/idle-display-lock.md`.

## Implementation notes (2026-10-14)

- The launch self-test (**OPS-09**) is not an idle-sleep measurement: it checks only that macOS accepts Overtime's own calls. It still reads the assertion table first. Since 2026-10-14 it runs beside tools that only hold off idle sleep, and it skips only for Amphetamine, for tools that drive lid-close sleep and for `SleepDisabled` ([0016](0016-coexistence-detect-and-warn.md), note of 2026-10-14). The consequence above still binds any check that judges idle sleep itself ([0020](0020-verify-by-observed-sleep.md)).
