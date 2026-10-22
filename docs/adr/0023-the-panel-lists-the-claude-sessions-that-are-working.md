# 0023. The panel lists the Claude Code sessions that are working

- **Status:** Accepted
- **Accepted:** 2026-10-14. The project author decided that the panel lists only the Claude Code sessions that are working, counts them in the reason line and sums up the idle ones in one line. The signal, the grace and the rest of the design below were delegated to Claude; the author may revisit them.
- **Date:** 2026-10-14
- **Deciders:** Project author
- **Related requirements:** **APP-01**, **DET-01**, **DET-02**, **DET-05**, **APP-13**
- **Related ADRs:** [0018](0018-caffeinate-before-transcript-ordering.md), [0019](0019-detection-loop-energy-design.md), [0021](0021-app-owned-status-item-and-panel.md)

## Context

The panel's sessions section listed every Claude Code process with a controlling terminal. Each row was titled by its working folder, abbreviated in the middle so that the project name was often the part cut out, and captioned with the terminal device and the process uptime. The reason line counted every listed process.

On the author's Mac, 11 Claude Code processes were open, 10 of them in a terminal, and 3 were working. The reason line said "Claude is working in 10 sessions.", five rows of middle-truncated paths with uptimes of several days followed, then "and 5 more". Nothing in the section said which sessions were keeping the Mac awake, which is the one thing a user opens the panel to learn.

## Decision

- **A session is busy in a sample when it has a caffeinate child.** A terminal Claude Code session is busy in one sample of the process table when it is the parent of a `caffeinate` process. This is **DET-01**'s rule applied per session (`ClaudeCodeDetector.busySessionPIDs`), over the records the existing scan already returned.
- **It counts as working for one episode, with a grace.** A session counts as working from the first 2 s tick that sees it busy until `Timing.sessionWorkingGraceSeconds` (90 s) pass without a sighting (`SessionActivity`). A reused pid with a new start time, or a gap of 90 s or more between two ticks (a system sleep included), starts a new episode. The episode's start is the first tick that saw it, kept unchanged while the episode lasts.
- **The busy gate.** The panel lists and counts working sessions only while Overtime's own busy signal is on, so the list never contradicts the reason line through the stuck guard (**DET-05**), a blind transcript folder or Grace.
- **What the section shows.** The header reads "Claude Sessions". Each working session is one row: the project folder name (with its parent folder when two working rows share a name but not a path, and the folder path with the home folder as ~ if that still collides), then "Working · " and the elapsed time in the panel's format ("<1m", "45m", "1h 5m"). The tooltip and VoiceOver carry the path with the home folder as ~ ("Session in ~/work/alpha, working for 1 hour 5 minutes"). No terminal name appears. One quiet line under the rows counts the idle sessions and the working sessions beyond five rows ("8 more open, idle", "3 open, idle", "2 more working", "2 more working, 3 idle"). The reason line counts working sessions ("Claude is working in 2 sessions.", "Claude is working in 1 session.", "Claude is working." with none). With no working row the section says "No terminal session is working" while Claude is busy elsewhere, in an editor or a subagent (this heading replaces "No terminal session found", which was false while idle terminal sessions were open; its body is unchanged), "No Claude session is working" while idle sessions are open and Claude is not busy, and "No Claude sessions" when none is open.
- **The hold is unchanged.** The global busy decision, the reducer and the hold logic are unchanged. The per-session state is presentation only and cannot keep the Mac awake or delay a release.

## Consequences

- **Why 90 s.** Claude Code 2.1.300 holds `caffeinate -i -t 300` while its session is busy (a query loading, or a background agent it started still running). When the session stops being busy it keeps the caffeinate for 30 s and then kills it, and while busy it kills and respawns it every 240 s. **DET-02** keeps Overtime busy for 120 s after the last transcript write. 120 s minus 30 s is 90 s, so a finished session leaves the list when Overtime's busy signal for it ends. With a grace of a few seconds, every turn end would show the reason "Claude is working." over the transcript-only placeholder for about 80 s, which says Claude is active in another app, false for a terminal session that has just finished. The respawn alone needs much less: in 17 observed restarts the gap between the old and the new process was always under one 2 s tick.
- **Costs of the grace.** A finished session stays listed and counted for up to about 2 minutes when another session keeps Overtime busy. A session waiting at a permission prompt or for input is not busy for Claude Code, so it drops out of the list after about 2 minutes. A session that was already working when Overtime started shows "<1m" until Overtime has watched it. A transcript window set above 120 s can show the transcript-only placeholder for the difference at the end of a turn.
- **The transcript-only placeholder follows the busy signal**, not "keep-awake is wanted for busy". In Grace no session is working and the reason says Claude went idle, so the section shows "No Claude session is working" (or "No Claude sessions") there.
- **Energy (APP-13).** No new process-table, file or IOKit read: the classification runs on the existing 2 s tick over the records the scan already returned, and the tick adds one read of the monotonic clock. No process and no timer. The episode start changes only when an episode starts or ends, so the deduplicated snapshot stays edge-only and busy ticks republish nothing. The durations are drawn by the panel's existing one-second refresh, only while the panel is visible. See the working-sessions note in [0019](0019-detection-loop-energy-design.md).
- **Privacy.** The diagnostics export is unchanged: it keeps the four session fields it had, and the episode start is not exported. Nothing new is logged.
- **This refines [0018](0018-caffeinate-before-transcript-ordering.md).** In this Claude Code version the caffeinate ends 30 s after the session stops being busy and is restarted only while busy or within those 30 s, so **DET-05**'s premise that it restarts even when idle does not hold for it. **DET-05** stays as the guard for other versions.

## Alternatives considered

- **List every terminal session.** The reported problem: idle sessions outnumber working ones and the count is false.
- **Attribute transcript writes to sessions by project folder.** It adds a path to every transcript event and to the reducer's event type, two sessions in one folder share one transcript folder, and it would not shorten the end-of-turn tail, which comes from **DET-02**'s window. The caffeinate also covers long tool calls that write no transcript.
- **A grace of a few seconds.** The false transcript-only placeholder for about 80 s after every turn, described above.
- **The caffeinate's own start as the episode start.** Claude Code restarts it every 240 s, so the duration would reset every 4 minutes.
- **CPU or other process heuristics.** Detection uses deterministic system state only (**DET-09**), and CPU use is a noisier guess at what Claude Code's own caffeinate already states.
- **A timer to refresh the durations.** The panel already redraws once a second while it is visible; a timer would cost energy while it is not.

## Evidence

- **The process table, measured on 2026-10-14** on macOS 27.0 with Claude Code 2.1.300: `ps` every 0.5 s for 1,500 s (2,596 samples), plus whether each session's transcript folder had a recent write. 11 Claude Code processes were open, 10 in a terminal; 3 had a `caffeinate` child and wrote transcripts during the whole window, and the 7 idle ones never held a caffeinate and wrote nothing. Claude Code replaced each caffeinate every 239 to 240 s (17 restarts); in 16 of them no sample fell between the old and the new process, and once one sample did (a gap under 1.2 s). One busy session wrote no transcript for about 170 s while its caffeinate stayed (a long tool call). Other `caffeinate` processes belonged to shells and scripts, never to an idle Claude Code process.
- **Claude Code 2.1.300's sleep inhibitor**, read from its installed bundle (behaviour only; no code is quoted here): it starts `caffeinate -i -t 300` when the session becomes busy and keeps a reference count; when the count drops to zero it waits 30 s and then kills the caffeinate, and a new busy period within those 30 s keeps the same process; while busy or within the 30 s it kills and respawns it every 240 s. A session waiting at a permission prompt or for input is not busy.
- **The test suites:** `SessionActivityTests` (the episode, the grace, a respawn gap, a long gap, a reused pid, a session that leaves, the detector rule and the measured process shape), `SessionReaderTests` (the episode start in the summaries, start-time jitter, a reused pid), `PanelContentTests` (working rows, the busy gate, titles and their collisions, the caption and the spoken text, the quiet line, the three placeholders, the header, and the path from process records to a row and the reason count), `StatusPresentationTests` (the reason counts only working sessions), `EngineSnapshotTests` (a working session is published once across busy ticks) and the hosted `PanelModelTests` (the snapshot's working sessions become rows).

**Not verified:** none of this was observed on a running signed build when it was written. How the section looks and reads, with VoiceOver too, how the list follows sessions that really start and finish work, and the energy with several sessions are human checks.

## Implementation notes (2026-10-22)

- The list also shows `claude -p` runs ("Working · claude -p · " and the time since the run started) and sessions waiting on a command Claude started ("Waiting · background command · " for a terminal session, "Running a command · " for a session outside a terminal), terminal-less ones included ([0027](0027-background-commands-and-claude-p-runs-keep-the-mac-awake.md)).
- One row per Claude Code process. A session that is working by the rule above shows as working; otherwise a `claude -p` run shows as one; otherwise a waiting session shows as waiting or running a command.
- The busy gate still applies to every row, and beside it a waiting row is listed only while background commands keep the Mac awake and a `claude -p` row only while `claude -p` runs do, so the list never shows work that no longer holds.
- The quiet idle line counts terminal sessions only; a session outside a terminal is listed only while it is active.
- The reason line counts waiting rows apart ("Claude is waiting on a background command.", "Claude is working in 2 sessions and waiting in 1 more."); a "Running a command" row counts as working. Without a waiting row the reason line is unchanged.
- The diagnostics export gains three booleans per session, `waiting`, `printRun` and `terminal`, and still holds no command line.
- The durations stay edge-only: a waiting row runs from the first tick that saw it waiting, kept through a 6 s grace, and a `claude -p` row from the run's start, frozen at the first sample.
