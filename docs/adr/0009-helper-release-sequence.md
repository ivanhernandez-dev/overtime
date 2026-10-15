# 0009. Helper release: clear `SleepDisabled`, verify it, then force a clamshell re-evaluation

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **HOLD-16**, **HOLD-17**, **HOLD-05**, **OPS-06**, **APP-03**
- **Related ADRs:** [0003](0003-opt-in-root-helper-smappservice-daemon.md), [0011](0011-helper-battery-floor.md), [0012](0012-helper-thermal-release.md), [0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md)

## Context

The opt-in helper ([0003](0003-opt-in-root-helper-smappservice-daemon.md)) holds a closed lid by setting `SleepDisabled`. **HOLD-17** requires that it never leaves the Mac stuck awake.

Clearing `SleepDisabled` does not make a closed-lid Mac sleep. In the XNU source (xnu-12377.121.6), `IOPMrootDomain.cpp` `dispatchPowerEvent` (L8556-8559) handles `kPowerEventUserDisabledSleep` by only flipping `userDisabledAllSleep`; it re-evaluates nothing. Clamshell re-evaluation (`kLocalEvalClamshellCommand`) runs only on:

- lid close (L8951);
- desktop mode (L8968);
- an AC change (L8992);
- clamshell enable (L9021);
- boot complete (L8528);
- `fullWakeDelayedWork` (L9623);
- `setClamShellSleepDisable` when the clamshell mask drops to 0 with the lid closed (L4696-4700).

So after a bare clear, a Mac with its lid closed stays awake until one of those events happens.

## Decision

Every release the helper performs is three steps, in this order:

1. Clear `SleepDisabled` (`pmset -a disablesleep 0`).
2. Verify that it reads 0.
3. If the lid is closed, write selector 12 as 1 and then 0. The 1 → 0 edge drops the mask to 0 with the lid closed, which triggers `kLocalEvalClamshellCommand`. The kernel then decides whether to sleep, so desktop mode (an external display on AC) is still respected.

The sequence runs on every release path:

- the last app connection invalidated or interrupted (app crash or quit);
- SIGTERM, SIGINT or SIGHUP (unregistering the helper sends SIGTERM);
- startup reconciliation at `RunAtLoad`, because powerd re-applies a persisted `SleepDisabled=1` at boot before the helper runs;
- an explicit off from the app;
- the battery floor ([0011](0011-helper-battery-floor.md)) and the thermal release at Trapping or `.critical` ([0012](0012-helper-thermal-release.md));
- before any "Sleep Now", Pause or Apple-menu path that the app initiates (**APP-03**).

Rules that follow from it:

- **Never release the clamshell bit before `SleepDisabled` is confirmed clear.** A clamshell evaluation that runs while `SleepDisabled` is still 1 is refused, and nothing retries it.
- **The edge is a full release.** It also clears the app's rootless bit, because it is one shared bit. It is never used to step down from the helper to the rootless hold.
- **One registry of holds.** Every hold, direct or through the helper, is recorded in one place that cleanup releases and verifies.

## Consequences

- With `SleepDisabled=1`, `pmset sleepnow` fails with `0xe00002e2` (`kIOReturnNotPermitted`). The helper therefore clears before any sleep request.
- The helper performs its own edge even when the app also held the rootless bit. When the app dies, its sentinel clears the bit while `SleepDisabled` may still be 1, and that evaluation is refused; the helper's edge afterwards is what makes the Mac sleep.
- Uninstall (**OPS-06**) unregisters the helper, which sends it SIGTERM and so runs this sequence.

**Not verified:**

- The spike verified the clear with `pmset -g`. Reading the `SleepDisabled` property on `IOPMrootDomain` in process (the kernel sets it synchronously) is the research's suggestion and is untested.
- The **HOLD-17** path that restores a `SleepDisabled` value that was already 1 before Overtime engaged.
- macOS 14 and 15.

## Alternatives considered

- **Clear `SleepDisabled` only.** With the lid closed the Mac stayed awake for 20 s after the clear, and would have stayed awake indefinitely.
- **Release the clamshell bit first, then clear `SleepDisabled`.** The evaluation triggered by the bit is refused while `SleepDisabled` is 1, and it is never retried.
- **Call `IOPMSleepSystem` after the clear.** The research's other option. The selector edge was chosen instead because the kernel then makes the decision and still respects desktop mode.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spike 005, on 2026-09-26. Verdict: PARTIAL. The mechanism above was settled from source and confirmed on the machine.

- A release that only cleared `SleepDisabled` left a closed-lid Mac awake for 20 s. The spike's v0.0.4 build added the verify and edge steps.
- With the sequence in place, an app crash led to sleep about 1 s after the app died. A helper crash led to a launchd restart in about 1 s and reconciliation cleared `SleepDisabled` 1.4 s after the crash.
- A harness interrupt that cleared the selector bit but not `SleepDisabled` left the Mac unable to sleep for about 6 minutes, which is why every hold goes through one registry.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/root-helper.md`.

## Implementation notes (2026-10-08)

The decision above lists "the last app connection invalidated or interrupted" as a release path, and Phase 3 built it that way: the helper released when the last of all its connections ended, and a `status` call from any connection refreshed its heartbeat. The Phase 3 code review (finding H-WR-02, threat T-03-19) found that both protections then depend on a rule outside the helper: a second connection that stays open, or that calls `status`, keeps a hold alive while the engine that asked for it is hung. The rule changed on 2026-10-08 (delegated by the project author), before the helper binary is pinned ([0010](0010-pinned-helper-binary.md)). None of this changes the release sequence itself, its order, or any other release path.

- **The rule now.** The helper remembers the connection that engaged. Only that connection refreshes the heartbeat, and the end of that connection (invalidated or interrupted) releases, whatever else is connected.
- **A clear is unchanged.** A clear is still accepted from any connection that passes the app requirement. It is the safe direction, and the app's emergency restore and a blocked second instance rely on it.
- **A `status` from another connection** still answers, with the same readings, and does not refresh the heartbeat. The stale-version exit works as before from any connection.
- **A set from another connection** engages for that connection: the connection that engaged last is the one the hold is tied to. This is what a reconnecting app needs, because its new connection's set can arrive before the helper hears that the old connection ended. A caller that can set could already hold the helper by itself, so this gives it nothing new.
- **Kept as a second net.** If no connection at all remains while the helper is engaged, it releases, whichever connection ended last.
- **The app side is unchanged.** The app still builds one port, sends the engine's heartbeat over the connection that engaged, and while the port is engaged answers every other status request from that port's last answer (`XPCHelperPort.probe()`). That convention is no longer what the two protections rest on.

Evidence: `HelperMachine` (`set(from:)`, `status(appVersion:from:)`, `connectionEnded(_:remaining:)`) and `HelperXPCService`, with the tests named for the rule in `HelperMachineTests`, `HelperXPCTests` (a real connection pair in process) and `EngineHelperTests` (the app's port and the clear-only client against an in-process helper). Not exercised against the installed root helper: that stays on the human verification list.
