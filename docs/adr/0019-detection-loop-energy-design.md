# 0019. Detection loop: a filtered libproc scan plus FSEvents, no process per tick

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **APP-13**, **DET-01**, **DET-02**, **DET-04**, **DET-07**, **HOLD-02**
- **Related ADRs:** [0017](0017-ignored-entrypoints-sdk-prefix.md), [0018](0018-caffeinate-before-transcript-ordering.md), [0003](0003-opt-in-root-helper-smappservice-daemon.md)

## Context

**APP-13** sets the energy target: under 0.1% CPU on average and under 40 MB, event-driven where possible. **HOLD-02** requires busy state to be detected within about 2 s, which sets the scan cadence while something is being watched.

The detector needs process facts (**DET-01**, **DET-04**, **DET-07**: parent, controlling terminal, argv0) and transcript activity (**DET-02**).

## Decision

- **Process scan.** On a 2 s cadence while something is being watched (10 s and 30 s cadences are cheaper still):
  1. `proc_listpids` for all pids;
  2. `PROC_PIDTBSDINFO` for each pid;
  3. a filter: a controlling TTY, a matching `comm`, or ppid ancestry;
  4. argv0 through `KERN_PROCARGS2` only for the candidates that pass, cached per (pid, start time).
- **Transcripts.** One FSEvents stream on the transcript root, with the `FileEvents`, `UseCFTypes` and `NoDefer` flags, 0.5 s latency, scheduled with `FSEventStreamSetDispatchQueue`. One stream covers every session and every `subagents/` file.
- **No process spawned on a periodic tick.** The helper reports `SleepDisabled` over XPC ([0003](0003-opt-in-root-helper-smappservice-daemon.md)). `pmset`, `sysadminctl` and other tools are for one-off actions and startup checks only.
- **Memory is judged by `phys_footprint`**, not RSS.

## Consequences

- The measured budget for the scan plus the watcher is about 0.03% of a core, under **APP-13**'s 0.1%. The engine, IOKit notifications and the UI still add to it, so it is re-measured once they exist.
- The 2 s cadence is what makes **HOLD-02**'s detection within about 2 s possible.
- The detection rules in [0017](0017-ignored-entrypoints-sdk-prefix.md) and [0018](0018-caffeinate-before-transcript-ordering.md) run on this loop.

Process scan, 639 processes (430 readable as the user):

| Variant | CPU per scan | At 2 s | At 10 s | At 30 s |
|---------|--------------|--------|---------|---------|
| `proc_listpids` only | 0.009 ms | 0.0004% | 0.0001% | 0.0000% |
| + `PROC_PIDTBSDINFO` for every pid | 0.225 ms | 0.011% | 0.002% | 0.0007% |
| + argv0 for **every** pid | 2.632 ms | **0.132%**, over budget | 0.026% | 0.009% |
| + argv0 only for TTY pids (25) | 0.295 ms | 0.015% | 0.003% | 0.001% |

Transcript watcher (0.5 s latency):

| Load | Callbacks | Events | Watcher CPU |
|------|-----------|--------|-------------|
| 10 files, 2,438 appends in 30 s (~81/s) | 61 | 601 (coalesced) | 0.013% of one core |
| Real transcript root, 60 s idle | 0 | 0 | 0.0001% |

**Not verified:** Nothing beyond macOS 27.0. The full app was not measured.

## Alternatives considered

- **argv for every pid.** 0.132% of a core at 2 s on its own, over the whole budget.
- **Spawning a process per tick.** The spike app's 1 s `pmset -g` timer cost 1.2% of a core.
- **`FSEventStreamScheduleWithRunLoop`.** Deprecated in macOS 13.
- **`DispatchSource` file watchers.** One file descriptor per file, and no recursion into `subagents/`.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spike 008, on 2026-09-26. Verdict: VALIDATED.

- CPU was measured with `getrusage`, with no sudo and no powermetrics.
- The SwiftUI `MenuBarExtra` plus Sparkle 2.10 shell is 23 MB by footprint, while RSS reads 78.5 MB (mostly shared framework pages).

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/energy-budget.md`.

## Implementation notes (2026-10-13)

The detection loop ships as decided: the filtered libproc scan on the engine tick, one FSEvents stream on a dispatch queue, and no process started by the tick's own reads (one network path the tick reaches can start one, on a Wi-Fi recovery retry; see below). Every periodic cadence in the app, the sentinel and the helper is listed below with the requirement that sets it and what it costs. The full app has not yet been measured over a week of daily use; the author's run on a Release build fills the results table at the end (**APP-13** stays Pending until then).

| Cadence | Every | Requirement | Runs | Cost or the path it avoids |
|---------|-------|-------------|------|----------------------------|
| `Timing.tickSeconds` | 2 s | **HOLD-02** (with **DET-01**, **DET-02**) | always, for the app's whole life | the filtered scan, about 0.015% of a core at 2 s in spike 008 (BSD info for every pid and argv for candidates only, measured together: the spike's rows are cumulative), and IORegistry reads of the lid state and the system capabilities (`Composition.swift:252`, `Composition.swift:257`); with the lid closed, also an IOKit display count and the HID idle time on every tick (`Composition.swift:256`, `Composition.swift:258`); no process |
| `Hold.acquireOrRenew` | 2 s | **HOLD-11**, **HOLD-10** | on every tick while a hold backend is held and wanted | one or two IOPM assertion calls per tick: the idle assertion, and the display assertion when "Keep display on while Claude works" is set (`Hold.swift:106-109`); no process |
| `Timing.coexistenceCheckSeconds` | 30 s | **HOLD-07** | while keep-awake is not known to be unwanted | one `IOPMCopyAssertionsByProcess` call and one IORegistry read of `SleepDisabled` (`CoexistenceProbe.swift:32-39`); when a foreign `caffeinate` holds an assertion, a lookup of its parent in the process list the last tick already read; no process |
| `Timing.healthCheckSeconds` | 30 s | **DET-12** | while the transcript watcher runs | a health read of the transcript roots on the watcher's queue; the FSEvents stream itself cost about 0.0001% of a core when idle in spike 008; no process |
| `Timing.batteryPollSeconds` | 30 s | **BAT-01**, **BAT-05** | always, next to the power source notifications | one IOPS read and one IORegistry read of the battery temperature, about 32 microseconds ([0024](0024-configurable-battery-and-temperature-protection.md)); no process |
| `Timing.displayRecheckSeconds` | 30 s | **LID-03** | lid closed and holding | the reducer uses the display count every 30 s; the count itself, an IOKit display iteration, is read on every 2 s tick while the lid is closed, held or not (`Composition.swift:256`); no process |
| `Timing.resleepEverySeconds` | 10 s | **LID-02** | lid closed and holding | the reducer uses the HID idle time every 10 s; the IORegistry read is made on every 2 s tick while the lid is closed, held or not (`Composition.swift:258`); no process |
| `Timing.reassertEverySeconds` | 10 s | **HOLD-01** | lid closed and holding | one IOPMrootDomain selector call; no process |
| `Timing.netEverySeconds` | 10 s | **NET-02** | network failover armed | an in-process URLSession request; no process |
| `LiveNetworkPort.recoveryRetrySeconds` | 30 s | **NET-04**, **NET-06** | only while a Wi-Fi cycle marker is left over and not settled; the tick's network facts check it, and it also runs sooner when those facts change; it ends when the marker clears | a CoreWLAN power-on of the Wi-Fi radio, and only when CoreWLAN fails, `networksetup -setairportpower` up to twice per attempt (`LiveNetworkPort.swift:201-231`, `WiFiController.swift:229-239`, `WiFiController.swift:296-299`); a process only on that fallback |
| `HelperMachine.watchPeriodSeconds` | 5 s | **HOLD-17**, **HOLD-18** | helper installed, while it holds or owns `SleepDisabled` | an in-process heartbeat check and one IORegistry read of the battery temperature in the helper; no process |
| `HelperWatchdog.checkSeconds` | 5 s | **HOLD-17** | helper installed, for the helper's whole life | an in-process queue check in the helper; no process |
| `overtime-sentinel` | 1 s | **HOLD-05** | always, while the app runs | an uptime comparison against the last heartbeat read from a pipe; no process |
| `PanelModel.livenessIntervalSeconds` | 5 s | **APP-01** | while the menu bar panel is visible | an in-process engine probe; no process |
| `PanelView.TimelineView` | 1 s | **APP-01** | while the menu bar panel is visible | a SwiftUI redraw of the panel so its timing line stays current (`PanelView.swift:12`); no process |
| `HelperPaneModel.pollIntervalSeconds` | 2 s | **HOLD-16**, **APP-02** | while the Unplug protection pane is visible | `pmset -g` once per poll while `SleepDisabled` reads 1 or unknown, about 0.6% of a core while the pane is open (spike 008: 1.2% for a 1 s `pmset` timer) |

- **The tick runs always.** This corrects the Decision's "while something is being watched": the 2 s loop in `Engine.timerLoop` runs for the app's whole life and only wakes earlier for a reducer deadline. Its measured cost is inside the budget, so it stays as it is.
- **One path the tick reaches can start a process, and not on every tick.** The tick asks for the network facts (`Composition.swift:258`, `LiveNetworkPort.swift:188-205`), which start the Wi-Fi recovery while a Wi-Fi cycle marker is left over (the `LiveNetworkPort.recoveryRetrySeconds` row). Nothing else the tick reaches starts a process. `WiFiController` also runs `networksetup` for the failover's one-off effects, joining the hotspot (`-setairportnetwork`, `WiFiController.swift:264-265`) and cycling Wi-Fi (`-setairportpower` through the same `runPowerTool` as the recovery, `WiFiController.swift:296-299`); the engine runs those as effects of a failover decision, not as reads of the tick.
- **The hold renewal rides the tick.** While a hold backend is held, `Hold.step` renews it on every tick: one IOPM call per held backend, so two with "Keep display on while Claude works", and no process.
- **The Unplug protection pane polls `pmset -g`.** Every 2 s while the pane is visible and `SleepDisabled` reads 1 or unknown. It is visible-only and not part of the engine tick, so "no process per tick" still holds for the engine; this phase does not change it (no cadence moves without a measurement that shows a component over budget).
- **Bounded waits are not cadences.** `SentinelLink.waitForExit` and the two waits in `UninstallModel` sleep 10 to 50 ms in a loop, but only while the sentinel stops or an uninstall settles before a quit, and never past a fixed deadline (a few seconds, or the uninstall's admin prompt timeout while that prompt is open). They start no process and end with their action, so they have no row.
- **How the budget is measured.** `scripts/energy/sample.sh` records cumulative CPU time from `ps` and `phys_footprint` from `footprint` for the app, the sentinel and the helper of the bundle installed at `/Applications/Overtime.app` (a Debug build, also named `Overtime.app`, is never counted) and for `overtimed`, without `sudo`; `scripts/energy/report.sh` averages CPU over the awake intervals in which the app itself was counted: in those intervals it adds the CPU time of the app, the sentinel and the helper in whole centiseconds and divides once by their length, so a total of exactly 0.1% fails however it is split across them, and time in which only the helper or the sentinel ran is left out of both sides (the helper's own line still averages over all of its awake time). It judges the app plus the sentinel against 40,000,000 bytes, per sample; a sample in which either footprint is unreadable is skipped rather than summed with 0, and a record with no readable sample is INSUFFICIENT. A verdict also needs coverage: the record must span at least 168 hours by default (`--min-span-hours`), and every sampler start writes a `run` row, so a gap of more than 12 hours between two runs, when no sampler was running, makes the verdict INSUFFICIENT; a sleep inside one run is excluded from the average and allowed. The app must also be counted in at least 75% of the sampler's awake time (the report's `app coverage` line), so a record in which the sampler ran all week but Overtime ran for a day is INSUFFICIENT. Two known limits stay: an interval counts as a sleep only when it lasts more than 1.5 times the sampling interval, so a sleep shorter than half an interval (30 s at the default 60 s) stays in the awake time and lowers the average slightly; and the `restarts` line counts a changed pid or start time between two consecutive samples in which the process is present, so a relaunch across a sample where it was absent, or a second restart inside one interval, is not counted, which does not affect the verdict. `powermetrics` is an optional cross-check by the author. The roadmap's "measured with powermetrics and RSS" is read this way: memory is judged by `phys_footprint`, and RSS is recorded but never judged.
- **What guards it.** `CadenceTableGateTests` fails when a cadence in this table and the code disagree, when a `Timing` constant is not classified, or when a periodic mechanism appears in a product source file, or in a number, that this note does not justify: a dispatch timer, `Timer.scheduledTimer`, `Timer.publish`, a periodic or animated `TimelineView`, or a `Task.sleep` or a clock's sleep (`clock.sleep(`, `ContinuousClock().sleep(`) written inside a loop. It checks those spellings only: a loop that sleeps through a helper function, as the Unplug protection pane's poll does, is not seen by that count (the pane's interval has its own value check), and neither are other forms such as `TimelineView(.everyMinute)`, `Thread.sleep` in a loop or a recursive `asyncAfter`. `TickSamplerToolGateTests` fails when a file the engine tick reaches, the network facts path included, or the tick closure in `Composition.swift`, names a way to start a process. It also matches the forms in which `LiveNetworkPort.swift` and `WiFiController.swift` start a process: a `makeTools(` call, a `tools.run(` call, and a call to `runPowerTool(`, the helper through which `WiFiController` runs `networksetup -setairportpower`. In those two files it allows only the lines it pins, each tied to the text of this note that names it: the declarations and the process-starting calls of the path above, of the hotspot join and of the Wi-Fi cycle. So a new process start there fails it, whether it is written as these files already write one, as a new `runPowerTool(` call, or with `ToolRunner`, `Process` or a tool path literal. It checks only the text of the calls in the files it scans, so it cannot see a new call, from any function in these files, to another function that leads to a pinned call: for example a call to `turnOnConfirmed`, `recoverIfLeftOff`, `cycleWifi` or `joinHotspot` added to `markerKept`, which the network facts read on every tick while Wi-Fi is powered (`LiveNetworkPort.swift:210`). Nor can it see a start through a tool port held under another name. `ProcessScannerTests.argvIsReadOnlyForCandidatePids` (it counts the argv and path reads of one sample and requires them to be exactly the candidate pids), `ProcessScannerTests.aSecondSampleReadsNothingAgainForUnchangedProcesses` (the per-identity cache) and `EngineSnapshotTests` (edge-only publishing) keep the per-tick work small.

Results of the week of daily use on a Release build:

| Measure | Result |
|---------|--------|
| Total CPU (app, sentinel and helper), average over the awake time in which the app was counted: the report's `total cpu` line | not measured yet (A-8) |
| App plus sentinel `phys_footprint` per sample, maximum: the report's `total memory max` line | not measured yet (A-8) |
| App plus sentinel `phys_footprint` per sample, 95th percentile: the report's `total memory p95` line | not measured yet (A-8) |
| Helper `phys_footprint` (read by hand, needs root) | not measured yet (A-8) |

Evidence: `scripts/energy/sample.sh`, `scripts/energy/report.sh` and `scripts/tests/test_energy.sh` (fixture input only); `CadenceTableGateTests`, `TickSamplerToolGateTests` and `ProcessScannerTests.argvIsReadOnlyForCandidatePids`; spike 008's measurements above.

## Implementation notes (2026-10-14, working sessions)

- The per-session working signal of [0023](0023-the-panel-lists-the-claude-sessions-that-are-working.md) runs on the existing tick over the records the scan already returned: a terminal Claude Code session with a `caffeinate` child is busy in that sample. There is no new process-table, file or IOKit read; the tick adds one read of the monotonic clock, and there is no process and no timer.
- `Timing.sessionWorkingGraceSeconds` (90 s) is a window read on the existing 2 s tick, not a cadence, so `CadenceTableGateTests` classifies it as not periodic and the table has no row for it.
- `SessionSummary.workingSince` changes only when an episode starts or ends, so the snapshot stays edge-only (`EngineSnapshotTests.aWorkingSessionIsPublishedOnceAcrossBusyTicks`).
- The panel's working durations are drawn by the existing one-second refresh of the `PanelView.TimelineView` row of the table, only while the panel is visible.
- The four `Composition.swift` line references of the 2026-10-13 note were re-checked on 2026-10-14 and still hold: `:252` (lid state), `:256` (display count), `:257` (system capabilities) and `:258` (HID idle time and network facts). The sessions call on line 250 changed in place.

## Implementation notes (2026-10-14)

- The scan keeps one more fact from the buffer it already reads: the `CLAUDE_CONFIG_DIR` value of a candidate process, parsed from the environment part of its `KERN_PROCARGS2` buffer in the same pass and cached per pid and start time with the other details. There is no new system call, and a non-candidate still reads nothing, which `ProcessScannerTests.argvIsReadOnlyForCandidatePids` now also checks for the config folder.
- On macOS 27 an Apple platform binary's buffer carries no environment; Claude Code's does (measured 2026-10-14).
- Each learned folder adds one FSEvents stream, at most 8, idle at the cost of the transcript watcher row above, and a change of the learned set rebuilds the transcript source once. Nothing is rebuilt while the set is unchanged.
- `Timing.learnedRootLingerSeconds` (600 s) is a hysteresis window read on the existing 2 s tick, not a cadence, so `CadenceTableGateTests` classifies it as not periodic and the table has no row for it.
- The learned set changes only on a tick: no process, no timer and no delayed work.
- The decision is recorded in [0022](0022-transcript-roots-do-not-trust-the-inherited-environment.md).
- The four `Composition.swift` line references of the 2026-10-13 note were re-checked on 2026-10-14 and still hold: `:252` (lid state), `:256` (display count), `:257` (system capabilities) and `:258` (HID idle time and network facts).
- The coexistence check names the process that started a foreign `caffeinate` from the process list the last tick already read, with no new system call and no lookup unless a foreign `caffeinate` holds an assertion ([0016](0016-coexistence-detect-and-warn.md), note of 2026-10-14). The `CoexistenceProbe.swift` reference of the cadence row was re-checked on 2026-10-14.
