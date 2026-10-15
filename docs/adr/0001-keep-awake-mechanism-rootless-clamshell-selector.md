# 0001. Keep-awake mechanism: the rootless clamshell selector plus a sentinel

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Gate:** 1 of 3. The project author approves or rejects this before Phase 1 is planned.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **HOLD-01**, **HOLD-05**, **HOLD-12**, **HOLD-15**, **APP-11**
- **Related ADRs:** [0003](0003-opt-in-root-helper-smappservice-daemon.md), [0004](0004-powerd-re-assert-policy.md), [0005](0005-sentinel-watchdog-design.md), [0016](0016-coexistence-detect-and-warn.md), [0020](0020-verify-by-observed-sleep.md)

## Context

**HOLD-01** requires that the Mac not sleep when the lid closes while Claude Code is working, on AC and on battery, with no external display. **APP-11** requires that the default install runs without root.

The only rootless lever is selector 12 (`kPMSetClamshellSleepState`) on the `IOPMrootDomain` user client. It writes one kernel bit that disables clamshell sleep. From the XNU source (xnu-12377.121.6):

- `RootDomainUserClient.cpp` gives selector 12 `checkEntitlement = NULL`, so any local process can call it.
- The bit is shared with powerd. It has no owner, no reference count and no readback. The last writer wins.
- `RootDomainUserClient::clientClose` does not reset the bit, so it outlives the process that wrote it.
- A reboot resets it, because it lives in kernel memory.
- When the mask drops to 0 with the lid closed, the kernel runs `kLocalEvalClamshellCommand` and the Mac sleeps at once.

Because the bit outlives its writer, a crashed Overtime with nothing watching it would leave the Mac unable to sleep on lid close until someone writes 0 or the Mac reboots. That breaks **HOLD-05** ("never stuck awake").

## Decision

Go.

- The default lid-close hold is an unprivileged `IOConnectCallScalarMethod` call on selector 12: 1 holds, 0 releases.
- Every hold is paired with the sentinel from [0005](0005-sentinel-watchdog-design.md), which clears the bit when the holder dies.
- The selector sits behind a backend abstraction. A launch self-test writes 1 then 0 with the lid open and judges only the returned `kern_return_t`, never the registry.
- The bit is written blindly and idempotently. The re-assert rules after wake are in [0004](0004-powerd-re-assert-policy.md).
- Release with the lid closed relies on the kernel's own clamshell evaluation. Overtime makes no explicit sleep call on release.
- **HOLD-12**: about 30 s after a release with the lid closed, Overtime checks whether the Mac actually slept. Only if it is still awake does it request sleep explicitly. `pmset sleepnow` works unprivileged on macOS 27; HID activity during sleep entry aborts it.

### The accepted rootless limitation

With the lid closed and the rootless bit held, powerd clears the bit on some power and display events, and the Mac sleeps:

| Event | Result | Runs |
|-------|--------|------|
| Unplug charger, no display | awake | 3/3 |
| **Replug charger, no display** | **sleeps** 0.96–1.2 s after the power change | 3/3 |
| **Connect a display (AC or battery)** | **sleeps** as the display comes online | 5/5 |
| **Disconnect the display (AC or battery)** | **sleeps** at the unplug | 3/3 |
| **Unplug the charger with a display attached** | **sleeps** at the unplug (entry took up to 20 s) | 2/2 |
| Replug the charger with a display attached | awake (desktop mode) | 2/2 |
| `caffeinate -i`, `-s`, `-d` start or stop | awake, no clamshell message at all | 1/1 each |
| Full wake, then re-assert at +6 s | awake | 2/2 (+7 s: 11/11) |

Every one of these sleeps has the signature of a clear by a write: a `willSleep` with no clamshell message before it. A clear with the lid closed sleeps the Mac in milliseconds, so no rootless re-assert can win. Rootless, nothing prevents these events. **HOLD-15** covers them only with the opt-in helper ([0003](0003-opt-in-root-helper-smappservice-daemon.md)). Onboarding and the README must state this limitation.

## Consequences

- The sentinel is load-bearing. Without it, a crash leaves the Mac stuck awake with the lid closed.
- The bit is one shared bit, so Overtime cannot coexist with another tool that drives lid-close sleep; see [0016](0016-coexistence-detect-and-warn.md).
- Nothing can confirm the hold by reading state. Verification is by observed sleep only; see [0020](0020-verify-by-observed-sleep.md).
- The periodic re-assert only restores the bit. It cannot prevent a sleep that a clear causes while the lid is closed.
- If a future macOS restricts selector 12, the launch self-test fails, Overtime shows its error state, and the fallback below becomes the path.

**Not verified:** macOS 14 and 15, the deployment floor. Lid behaviour needs a physical Mac on each version, because a VM has no lid. This is a release-checklist item.

## Alternatives considered

- **A root daemon plus `pmset -a disablesleep 1` as the default.** Robust against powerd's clears, but rejected as the default: it needs root (against **APP-11**), persists across a reboot and a crash, and blocks every kind of sleep. It is kept as the fallback if a future macOS restricts selector 12, and it is reused as the opt-in helper in [0003](0003-opt-in-root-helper-smappservice-daemon.md).
- **An `IOPMAssertion` with `AppliesOnLidClose`.** Owned and dies with its process, but refused to unprivileged processes with `0xE00002C1`. It needs a private Apple entitlement.
- **`caffeinate -s` or a `PreventSystemSleep` assertion.** Does not cover a closed lid on battery.
- **Vetoing sleep.** Clamshell sleep sends no `canSystemSleep`, only `willSleep`, so there is nothing to veto.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spikes 001, 002 and 003, on 2026-09-26. All three verdicts: VALIDATED.

- Spike 001: an unprivileged `(12, 1)` call returned `KERN_SUCCESS`. With the bit set by a child that then exited, the Mac stayed awake with the lid closed for 46.4 s on battery and 44.7 s on AC. With the bit set by a holder that was then killed with `kill -9`, it stayed awake for 57.5 s. The controls with the bit clear slept. Clearing the bit 15 s after the lid closed produced `willSleep` 0.007 s after the write, and `pmset -g log` recorded "Clamshell Sleep".
- Spike 002: the event table above.
- Spike 003, end to end: `kill -9` of the holder with the lid closed → the sentinel cleared the bit 0.003 s later → `willSleep` 0.014 s after the kill → "Clamshell Sleep".

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/lid-hold-clamshell.md`.
