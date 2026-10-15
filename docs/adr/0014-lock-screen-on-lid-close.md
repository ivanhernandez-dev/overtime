# 0014. Lock the screen on lid close with `pmset displaysleepnow`

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **LID-01**, **LID-02**, **LID-04**
- **Related ADRs:** [0013](0013-lid-open-holds-timed-assertions.md), [0015](0015-external-display-detection-iokit.md), [0019](0019-detection-loop-energy-design.md)

## Context

A Mac held awake with its lid closed stays **unlocked**, even with the lock delay set to "immediate". In the spike, `CGSSessionScreenIsLocked` stayed false for 15 s after the lid closed and was still false when the lid opened, so the desktop was visible. A laptop carried in a bag while Claude Code works would come out unlocked.

The requirements already cover this:

- **LID-01**: on lid close, turn the display off so the screen locks.
- **LID-02**: while the lid is closed, turn the display off again only after 60 s without keyboard or mouse input, so Screen Sharing stays usable.
- **LID-04**: check that screen lock is "immediately" and warn if it is not.

## Decision

- **LID-01.** When a lid close is detected while the hold is engaged, run `pmset displaysleepnow`. It works unprivileged.
- **LID-04.** At startup and whenever settings change, read the lock delay with `sysadminctl -screenLock status` and warn when it is not "immediate". The command works unprivileged and prints to stderr ("screenLock delay is immediate"), so both output streams are captured.
- **LID-02.** `HIDIdleTime` (in nanoseconds, on `IOHIDSystem`) and the lock state are readable unprivileged; the 60 s idle re-off will use them.

## Consequences

- The lock depends on the user's lock delay. With a delay other than "immediate", turning the display off does not lock at once, which is why **LID-04** warns.
- `pmset displaysleepnow` and `sysadminctl` are one-off actions on events and at startup, never periodic tick work ([0019](0019-detection-loop-energy-design.md)).
- With an external display attached, the display is never turned off (**LID-03**). Detection of external displays is in [0015](0015-external-display-detection-iokit.md).
- On the lid-open side, the display follows [0013](0013-lid-open-holds-timed-assertions.md).

**Not verified:**

- `HIDIdleTime` while Screen Sharing is active, and whether Screen Sharing creates a virtual display. Both need a second device; spike verdict PARTIAL for that reason.
- macOS 14 and 15.

## Alternatives considered

- **Rely on macOS to lock a closed, held Mac.** It does not.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spike 006, on 2026-09-26. Verdict: PARTIAL.

- With the lid closed and held and the lock delay "immediate", the session was not locked for 15 s and was still unlocked on opening.
- With `pmset displaysleepnow` run at lid close, the session locked within 1 s or less, stayed locked while closed, and was locked on opening.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/idle-display-lock.md`.
