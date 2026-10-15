# 0002. OPS-01 restart mechanism: a login item plus the sentinel's relaunch

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Gate:** 2 of 3. The project author approves or rejects this before Phase 1 is planned.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **OPS-01**, **HOLD-04**, **HOLD-05**, **HOLD-13**
- **Related ADRs:** [0005](0005-sentinel-watchdog-design.md), [0004](0004-powerd-re-assert-policy.md), [0006](0006-t1-self-signed-distribution.md), [0007](0007-frozen-bundle-identifier.md)

## Context

**OPS-01** requires that Overtime starts at login, is restarted if it dies, and keeps working after reboots. It leaves the mechanism to this ADR: a login item plus a relaunch by the sentinel, or `SMAppService.agent` with `KeepAlive`.

`SMAppService.mainApp` is a login item only. Apple's documentation describes it as launching the app at login and says nothing about restarting it. The spike confirmed that it never relaunches a dead app.

## Decision

Go.

- **Start at login** with `SMAppService.mainApp.register()`.
- **Restart after a crash** through the sentinel ([0005](0005-sentinel-watchdog-design.md)):
  1. The sentinel clears the clamshell bit **first**.
  2. Then it relaunches the app with `open -b io.github.ivanhernandez-dev.overtime`.
  3. At most 3 relaunches per 10 min, so a crash loop cannot spin.
- The relaunched app runs the reclaim at launch (**HOLD-04**, [0005](0005-sentinel-watchdog-design.md)) before it does anything else.
- The relaunched app never engages during a dark wake. It gates every engage on `System Capabilities & 0x2` (the Graphics capability, present only in a full wake), as in [0004](0004-powerd-re-assert-policy.md).
- **Plan B**, promoted only if this proves insufficient: `SMAppService.agent(plistName:)` with `KeepAlive`, its plist in `Contents/Library/LaunchAgents` with `BundleProgram`. Plan B is untested.

**OPS-01**'s "restarted if it dies" is read as "restarted by the sentinel".

## Consequences

- **Residual risk:** if the app and the sentinel both die (for example `kill -9` of both), nothing restarts the app until the next login. The clamshell bit then stays set until the reclaim at that launch, the **HOLD-13** emergency reset, or a reboot. The "never stuck awake" rule still holds for every single-process failure, because the sentinel clears the bit before it relaunches.
- The relaunch reuses the frozen bundle identifier from [0007](0007-frozen-bundle-identifier.md). Permissions survive the relaunch because the signing identity is stable ([0006](0006-t1-self-signed-distribution.md)).
- Any program that launchd runs must live outside TCC-protected folders such as the user's Documents folder. A LaunchAgent program placed there exited with status 78 (`EX_CONFIG`), because launchd-spawned processes have no TCC grant for that folder. This matters for Plan B.

**Not verified:**

- The chain was proven piece by piece, not as one flow: the clear-on-death in spike 003 and the `open -b` relaunch in spike 004. It has not been run end to end as a single sequence.
- The relaunch path was verified on macOS 27.0 only.
- Plan B (`SMAppService.agent` with `KeepAlive`) was not tested.

## Alternatives considered

- **`SMAppService.mainApp` alone.** Rejected: it never restarts a dead app.
- **`SMAppService.agent(plistName:)` with `KeepAlive`.** Kept as Plan B. launchd would restart the app itself, but it is untested here, and it adds a second background item for the user to approve.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spikes 003 and 004, on 2026-09-26. Both verdicts: VALIDATED.

- Spike 004: `SMAppService.mainApp.register()` moved the status from `notFound` to `enabled` and showed one "Background item added" notification. After the app called `abort()`, nothing relaunched it within 35 s. After `kill -9` with the login item `enabled`, nothing relaunched it within 90 s. `open -b` with the bundle identifier then relaunched it with Location, Notifications and the login item intact.
- Spike 003: when the holder died and its pipe closed, the sentinel cleared the bit 1 to 21 ms later (a `kill -9` of the holder cleared in 9 ms; a launchd `kill SIGKILL` of a LaunchAgent holder in 21 ms).

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/sentinel-watchdog.md`.

## Implementation notes (2026-09-27)

Phase 2 built the relaunch from this decision, refined by Phase 2 decision D-24. None of this changes the decision above: the login item starts Overtime, the sentinel restarts it after a crash, the clear always comes first, and at most 3 relaunches happen per 10 min.

- **Relaunch by path, not by bundle identifier.** The app passes its own absolute bundle path to the sentinel at spawn (`--relaunch-app`), and the sentinel relaunches with `/usr/bin/open -g <path>` instead of `open -b`. LaunchServices cannot resolve a copy that sits in a temporary folder (it flags it `in-temp-dir`, and `open -b` exits 1), and among several registered copies it picks its own preferred one, which may not be the copy that was running. `-g` keeps the relaunched app in the background. The sentinel starts `/usr/bin/open` with `posix_spawn`, an argv array, `POSIX_SPAWN_CLOEXEC_DEFAULT` and `/dev/null` for all three standard streams, never through a shell, and waits for it at most 5 s.
- **Only on a confirmed holder death.** The sentinel relaunches after EOF only when `getppid()` leaves the `--parent` pid within a 1 s poll (every 10 ms), or after it terminated a hung holder following a heartbeat timeout. A measured `kill -9` of the holder left `getppid()` at the dead parent for one poll at EOF before it changed. A retire or a close by a living holder keeps `getppid()` equal to the parent, so it never relaunches. Since the make-before-break respawn in [0005](0005-sentinel-watchdog-design.md) closes an old sentinel's pipe while the holder lives, EOF alone does not mean the holder died.
- **Never after a graceful or deliberate exit.** No relaunch after `BYE`, on a signal to the sentinel, within 120 s of the suppression stamp, while a process already runs `<app>/Contents/MacOS/Overtime`, when the app path no longer exists, or when it is not an Overtime bundle. `--relaunch-app` must be an absolute path ending in `.app`, in any letter case (otherwise the sentinel exits 64), and at relaunch time the folder must be owned by the user or root, hold an executable `Contents/MacOS/Overtime`, and carry the release or Debug bundle identifier in `Contents/Info.plist`; otherwise the sentinel logs `relaunch skipped reason=notAnApp` (Phase 2 review IN-54). The app writes the suppression stamp (`relaunch-suppressed` in the support folder) before its clear-first stop whenever it quits: a user Quit, the logout quit Apple event and SIGTERM all reach the same quit path, so a logout that kills the app before `BYE` does not bring it back. `NSWorkspace.willPowerOffNotification` writes no stamp; it only logs `CHECK logout pending`, so a cancelled logout leaves the app, its engine and its lock untouched (Phase 2 review CR-02). The sentinel's own SIGTERM after a heartbeat timeout reaches the same quit path, so the sentinel records the wall-clock time at which it sent that SIGTERM, with sub-second precision (`CLOCK_REALTIME`), and ignores any stamp whose mtime (`st_mtimespec`) is at or after it. Such a stamp is the holder's reaction to the sentinel, not a user quit, so a wedged engine is still relaunched (Phase 2 review CR-51). A user Quit stamped before the SIGTERM, even within the same second, still suppresses the relaunch (WR-102). After it has sent that SIGTERM, the sentinel no longer decides on EOF or `BYE`. It clears, waits for the holder to leave (SIGKILL at +2 s, then a 1 s poll), and only then decides, with the departed holder's pid excluded from the running-app check. Without that wait, a holder that says `BYE` while it is still quitting would count as a running copy, and the relaunch would be skipped (WR-101).
- **The limit is a locked history file.** `relaunch-history` in the support folder holds whole wall-clock seconds, one per line, 0600. The sentinel takes `flock` on it before it reads and writes, because two sentinels can coexist briefly during a make-before-break respawn, and it skips a relaunch within 30 s of the last one as a duplicate. An entry counts while it is less than 600 s old; entries in the future (a clock set back) are dropped. A suppression stamp more than 5 s in the future is stale and does not suppress, so a clock set back cannot disable the relaunch for hours, and the next successful launch removes the stamp, because it was meant only for the dying instance's sentinel (Phase 2 review WR-56).
- **Only the app relaunches.** `overtimed` passes no relaunch flags, so its sentinel never relaunches anything. A sentinel given only some of the three flags exits 64.
- **The clear comes first.** The relaunch runs in the sentinel's final exit step, after any clear has finished. Nothing on the relaunch path can delay or skip the clear.

Evidence: 02-RESEARCH.md Pattern 6 (this Mac, macOS 27.0): the `getppid()` measurements at EOF after `kill -9` and after a close by a living parent, the end-to-end `open -g <path>` relaunch of a `kill -9`'d LSUIElement app in 57 ms, and the `open -b` failure for a copy in a temporary folder. The automated tests use a record spawner and a fake app folder; the relaunch of the real app is on the Phase 2 human verification list.
