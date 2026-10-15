# 0015. Detect external displays through IOKit `DCPAVServiceProxy`

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **LID-03**, **HOLD-15**
- **Related ADRs:** [0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md), [0014](0014-lock-screen-on-lid-close.md), [0020](0020-verify-by-observed-sleep.md)

## Context

Several lid-closed decisions depend on whether an external display is attached:

- **LID-03**: with an external display (clamshell use), never turn the display off.
- **HOLD-15** and the rootless limitation in [0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md): display connect and disconnect with the lid closed defeat the rootless hold.

The project's stack notes proposed `CGGetOnlineDisplayList` plus `CGDisplayIsBuiltin` for the display monitor. In spike 002, with the lid closed, `CGGetOnlineDisplayList` kept listing an unplugged display until the lid opened, and its list flickered.

## Decision

- Count external displays through IOKit: the `DCPAVServiceProxy` services whose `Location` property is "External".
- Never use `CGGetOnlineDisplayList` for decisions while the lid is closed.
- Treat both signals as eventually consistent: act on a change, but expect it to settle over seconds.

This supersedes the stack notes' CoreGraphics display monitor for lid-closed decisions. Whether CoreGraphics is still used for anything with the lid open is left to Phase 1.

## Consequences

- The consumers are **LID-03** (never turn the display off with an external display attached; see [0014](0014-lock-screen-on-lid-close.md)) and the lid-closed trigger handling behind **HOLD-15** and the rootless limitation.
- Diagnostics that attribute an unexpected lid-closed sleep to a display reconfiguration use the reconfiguration timing described in [0020](0020-verify-by-observed-sleep.md).
- Because the IOKit count can lag (about 14 s on battery after a disconnect), no decision may assume it is instantaneous.

**Not verified:**

- Docks and multiple external displays were not tested separately.
- macOS 14 and 15.

## Alternatives considered

- **`CGGetOnlineDisplayList` plus `CGDisplayIsBuiltin`.** Stale and flickering with the lid closed, as measured.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spike 002, on 2026-09-26. Verdict: VALIDATED.

- With the lid closed, `CGGetOnlineDisplayList` kept listing an unplugged display until the lid opened, and flickered.
- On battery, the IOKit `DCPAVServiceProxy` count reached 0 about 14 s after a disconnect.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/lid-hold-clamshell.md`.
