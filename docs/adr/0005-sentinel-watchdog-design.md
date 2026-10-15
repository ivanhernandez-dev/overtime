# 0005. Sentinel watchdog: a Foundation `Process` on a stdin pipe

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **HOLD-05**, **HOLD-04**, **HOLD-13**
- **Related ADRs:** [0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md), [0002](0002-ops-01-restart-login-item-plus-sentinel-relaunch.md)

## Context

The clamshell bit outlives the process that wrote it, including after `kill -9` ([0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md)). **HOLD-05** requires that a crash, hang or kill of Overtime restores normal lid-close sleep. **HOLD-04** requires that Overtime reclaims its own hold after any restart. Something outside the holder must clear the bit when the holder dies or hangs.

## Decision

- **Process.** The sentinel is a headless tool shipped in `Contents/MacOS/` next to the app binary. The holder spawns it with Foundation `Process`, with a `Pipe` on stdin and stdout and stderr sent to the null device. It shows no UI.
- **Holder setup.** Right after spawning, the holder sets `FD_CLOEXEC` on the pipe's write end (Foundation's `Pipe` creates it without) and ignores SIGPIPE.
- **Protocol.** Newline-delimited text, four lines only. Unknown lines are ignored. The sentinel's only action on the Mac is to clear the bit.

  | Line | Meaning |
  |------|---------|
  | `ARM` | The holder has set the bit. Start watching. |
  | `HB` | Heartbeat, every 1 s, tied to the engine's tick. |
  | `DISARM` | The holder has cleared the bit itself. |
  | `BYE` | Exit without clearing. |

- **Clean shutdown.** The holder writes 0 to the selector, then sends `DISARM`, then `BYE`.
- **Watchdog lost.** On `EPIPE` the holder clears the bit itself, respawns the sentinel, sends `ARM` again and re-asserts.
- **When the sentinel clears.** On EOF on stdin (if armed); on SIGTERM, SIGHUP or SIGINT (if armed); and on a heartbeat timeout. The timeout is measured on `CLOCK_UPTIME_RAW`, so time asleep never counts as a missed heartbeat.
- **After a heartbeat timeout** the sentinel clears the bit, sends SIGTERM to the holder and SIGKILL 2 s later.
- **No `setsid()`** in the sentinel.
- **Reclaim at launch.** A boot-session-fenced `state.json` records an owned hold. The next launch reads it and either writes 0 or re-owns the hold, so a hold orphaned by the death of both processes is cleared at the next start (**HOLD-04**).

The spike used a 3 s heartbeat timeout. Phase 1 sets the product value.

## Consequences

- A Foundation `Process` child is already its own process-group leader (pgid = pid). A group kill of the holder, and launchd `bootout` or `kill` of the holder's job, do not reach the sentinel, which is what lets it clear afterwards.
- A SIGTERM to the sentinel alone clears the bit but leaves the holder running unwatched until its next heartbeat write fails with `EPIPE` and it respawns the sentinel.
- `kill -9` of both processes leaves the bit set. Only the reclaim at the next launch, the **HOLD-13** emergency reset or a reboot clears it.
- The sentinel also drives the **OPS-01** restart after it clears ([0002](0002-ops-01-restart-login-item-plus-sentinel-relaunch.md)).

Measured latencies (sentinel action after the event):

| Scenario | Result | Latency |
|----------|--------|---------|
| `kill -9` of the holder | clear on EOF | 0.009 s |
| Grandchild via raw `posix_spawn`, no CLOEXEC | no EOF; heartbeat timeout (3 s) | 2.53 s |
| Same, with `FD_CLOEXEC` | clear on EOF | 0.002 s |
| Grandchild via Foundation `Process` | clear on EOF | 0.003 s |
| Holder SIGSTOP'd | heartbeat timeout, then SIGTERM | 2.54 s |
| Group kill of the holder | clear on EOF | 0.001 s |
| SIGTERM to the sentinel alone | clear; **the holder keeps running unwatched** | 0.001 s |
| SIGKILL to the sentinel alone | no clear; the holder died of SIGPIPE (fixed by SIG_IGN + EPIPE handling) | - |
| SIGTERM to both (logout) | clear | 0.002 s |
| `launchctl bootout` of a LaunchAgent holder | clear on EOF | 0.016 s |
| `launchctl kill SIGKILL` of a LaunchAgent holder | clear on EOF | 0.021 s |
| `kill -9` of both | **no clear** (needs the reclaim) | - |

**Not verified:** the reclaim at launch was designed from these results, not exercised in the spike. Verified on macOS 27.0 only.

## Alternatives considered

- **Raw `posix_spawn` without `POSIX_SPAWN_CLOEXEC_DEFAULT`, `fork`/`exec`, `system()` or `popen()` from the holder while the write end lacks CLOEXEC.** The grandchild inherits the write end, so EOF never reaches the sentinel. Only the heartbeat timeout saved the measured case, at 2.53 s.
- **`setsid()` in the sentinel.** It returns -1 with EPERM, because a Foundation `Process` child is already a group leader. It is not needed. If a new session were ever required, it would have to come from the spawn side.
- **Default SIGPIPE handling in the holder.** A sentinel death would kill the holder on its next heartbeat write, leaving the bit set with nobody to clear it.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spike 003, on 2026-09-26. Verdict: VALIDATED.

- The latency table above.
- End to end with the lid closed: `kill -9` of the holder → the sentinel cleared the bit 0.003 s later → `willSleep` 0.014 s after the kill → `pmset -g log` recorded "Clamshell Sleep".
- A SIGTERM was enough even for a SIGSTOP'd holder; the SIGKILL 2 s later found it gone. The SIGKILL fallback stays anyway.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/sentinel-watchdog.md`.

## Implementation notes (2026-09-27)

Phase 1 built the watchdog from this decision. The three code reviews of Phase 1 (`01-REVIEW.md` and its iterations 2 and 3) refined the protocol in the ways below. None of these changes the decision above. They make it hold under slow starts, failing clears and respawns.

**The invariant.** While the clamshell bit may be set by Overtime, an armed sentinel exists. "May be set" means any of these: the hold is owned, an engage is in flight, a launch decision is still pending, or a clear has not been confirmed yet. Every rule below either keeps this invariant or restores it.

- **Heartbeat timeout.** The product value is 45 s (`Timing.sentinelTimeoutSeconds`). The holder sends `HB` after every engine step, and the engine ticks every 2 s.
- **READY line.** The sentinel's stdout is no longer the null device. It is a pipe back to the holder. The sentinel writes `READY` on it once three things are done: its clear backend is open, its signal and timer sources are running, and it is reading stdin. The holder waits for `READY` with a bounded `poll` (2 s on `CLOCK_UPTIME_RAW`). If `READY` does not arrive, the start has failed: the holder kills the child, and an `ARM` never counts as delivered to a sentinel that did not report ready. A sentinel that exits early closes the pipe, so the holder sees EOF at once instead of waiting out the timeout. Early exits are: a usage error (exit 64), a failed IOKit open (exit 71), or EOF before `READY`.
- **Start-up checks.** A live parent that differs from `--parent` is a usage error (exit 64). A sentinel started as an orphan (ppid 1) still runs: it reads what is already in the pipe and clears if it finds `ARM`. A signal handler first drains the input already in the pipe, so a pending `ARM` still counts. The holder sets `FD_CLOEXEC` and `O_NONBLOCK` on the write end before `run()`, and keeps the `Pipe` object for as long as the link lives.
- **Final clear on every exit after a heartbeat timeout.** After a timeout the sentinel enters a terminating state and stays in it. From then on, every way out clears the bit unconditionally, whether an `ARM` arrived since or not. That covers EOF, a signal, `BYE`, and the final "post-terminate" clear after the SIGTERM and SIGKILL of the holder.
- **Clear retry budget and exit 70.** If a clear fails, the sentinel retries it every 250 ms for up to 10 s (`SentinelWatch.defaultClearBudgetSeconds`). If the last attempt also failed, it logs `exit reason=<reason> clearFailed` and exits 70.
- **Respawn is make-before-break.** The holder starts the replacement first and waits for its `READY`. Whenever the bit may be set, it sends `ARM` to the replacement. Only then does it retire the old sentinel:
  1. It closes the old pipe and, if the old sentinel is still running, sends SIGTERM.
  2. It waits for the old sentinel to exit, for the whole clear budget plus 1 s, so that sentinel's own clear gets its full retry budget.
  3. A sentinel that is stopped (`pbi_status == SSTOP`) cannot act, so for that one the wait is only 0.5 s.
  4. If the sentinel is still there after the wait, the holder sends SIGKILL.

  So an armed sentinel exists at every point of a respawn. For a moment two sentinels may run side by side, both armed. If the holder dies then, both clear, and a second clear changes nothing. The retirement acts on the old sentinel only and never sends anything to the replacement. If the replacement cannot start or cannot be armed, the old sentinel stays in place.

  The respawn waits for the retirement before the next effect runs, so in a re-engage the old sentinel's clear lands before the new on-write. The holder logs `SENTINEL retired signal=TERM|KILL|none`, where `none` means the old sentinel had already exited and no signal was sent. It runs the replacement's `start()` on a dispatch queue, off the Swift concurrency pool.
- **Re-arm on respawn.** Whenever the bit may be set, a respawn is followed at once by `ARM`, before any other effect. The holder delivers that `ARM` to the replacement before it retires the old sentinel. This holds for a lost sentinel, for an escalation, and during a stop. `DISARM` is sent only after a clear is confirmed.
  - **Escalation.** A failed clear is retried every 10 s. The second consecutive failure in a failure run escalates to a fresh armed sentinel. A lost sentinel and a stop each start a new failure run.
  - **Launch.** At launch the holder arms the sentinel whenever the launch may find the bit set.
  - **Sentinel lost.** On a lost sentinel the holder clears the bit itself and then respawns, as the decision says.
  - **Failed respawn.** A respawn that fails is reported to the reducer again from the heartbeat path. The retries back off from 2 s up to a 60 s cap, and the first heartbeat that gets through ends the backoff.
- **Stop during a respawn.** `Engine.stop` waits at most 6 s for the stop sequence, then closes the installed sentinel. A close that lands while a respawn is in flight applies to whichever sentinel the respawn ends up installing, so that sentinel sees EOF while armed and clears. After the close, no sentinel is reported lost and none is respawned. The final `STOP` line is written directly, not behind queued effects, so the 6 s bound holds.
- **No sentinel at launch.** If the sentinel cannot start at launch and the launch may find the bit set, the holder writes 0 itself through its already-open backend. It logs `ERROR sentinel unavailable clearStale=<result>` and then exits 70. It leaves `state.json` alone, so the next launch still reclaims or clears.
- **Shared runner key.** Every clamshell write runs under a 5 s deadline. The holder's on and off writes share one deadline-runner key (`LiveInterpreter.clamshellRunnerKey`). While an abandoned on-write is still running, every clear by the holder therefore fails fast as timed out. So a successful clear by the holder proves that no earlier holder on-write can land after it. The sentinel's clears use their own IOKit connection and are not ordered after a hung holder write. This, not a late second result, is what makes a timed-out engage safe. Keep the key shared.
- **`overtimed --reset` exit codes** (the **HOLD-13** emergency reset). It always writes 0 first. It exits 0 when the clear succeeded, and also updates `state.json` if it took the instance lock. It exits 1 if the clear failed or timed out, and 71 if the clamshell writer cannot be opened. It exits **75** if the clear succeeded but a live `overtimed` holds the instance lock: in that case it leaves `state.json` alone and warns that the live instance will re-assert its hold.

## Implementation notes (2026-10-08)

`Overtime --reset`, the app's copy of the emergency reset, uses the same exit codes with two additions for the opt-in helper (Phase 3 code review, iteration 2, findings R2-WR-03 and R2-IN-05). `overtimed --reset` is unchanged.

- **The helper is asked first.** When the helper is enabled, `Overtime --reset` sends its clear-only `SleepDisabled` clear before it opens the clamshell writer, and prints the `sudo pmset -a disablesleep 0` line when the helper did not confirm. It still asks when the writer can't be opened, and then exits 71.
- **An unconfirmed helper clear exits 1, ahead of 75.** If the app's own clear succeeded but the helper did not confirm its clear, the command exits 1 even when a live instance holds the lock. 75 now means "the clear succeeded, a live instance is running, and nothing else is in doubt".
