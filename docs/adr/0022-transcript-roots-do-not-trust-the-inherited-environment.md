# 0022. Transcript roots: always the home folder, quiet inferred folders and the config folders of running Claude Code sessions

- **Status:** Accepted
- **Accepted:** 2026-10-14. The project author decided to keep watching ~/.claude/projects when an inherited folder is missing and to learn the config folder of each running Claude Code process. The design below was delegated to Claude; the author may revisit it.
- **Date:** 2026-10-14
- **Deciders:** Project author
- **Related requirements:** **DET-02**, **DET-11**, **DET-12**, **APP-13**
- **Related ADRs:** [0017](0017-ignored-entrypoints-sdk-prefix.md), [0019](0019-detection-loop-energy-design.md)

## Context

Overtime finds Claude Code's work through the transcripts it writes under a projects folder. Until this decision, with no folder configured in Settings > Detection, the only root was `$CLAUDE_CONFIG_DIR/projects` when the app's own environment set `CLAUDE_CONFIG_DIR`, and `~/.claude/projects` otherwise.

A GUI app inherits the environment of whatever launched it, not that of the Claude Code sessions it watches. On the author's Mac the app had been started from a shell whose environment carried a `CLAUDE_CONFIG_DIR` pointing at a folder that an account-switching tool had created and that no longer existed. Overtime watched only that missing folder. Settings > Diagnostics warned "Transcript folder not found", and later that a terminal Claude had been silent for 10 minutes, while every running session wrote its transcripts to `~/.claude/projects`. Relaunching the app with a clean environment fixed it; the product must not need that.

The reverse case is the same blind spot: a session started with its own `CLAUDE_CONFIG_DIR` writes to a folder the app's environment never names.

## Decision

- **The defaults never depend only on the app's environment.** With no configured folders the roots are `~/.claude/projects` always, plus the projects folder of the inherited `CLAUDE_CONFIG_DIR` when that value is an absolute path. Both are normalized (no trailing or doubled slash, no `.` or `..` component) and deduplicated, home folder first (`TranscriptRoots.defaults`).
- **Every root carries an origin, and a missing inferred folder is quiet.** A root is configured (chosen in Settings) or inferred (a default or a learned folder). A missing inferred folder is logged once per absence as `CHECK transcriptRoot absent` and is still health-checked, so it is watched as soon as it appears; it raises no detection warning, no Diagnostics row and no attention badge. A missing configured folder warns as before, and any folder that exists but cannot be read warns whoever chose it.
- **The config folders of running Claude Code sessions are learned.** The process scan reads `CLAUDE_CONFIG_DIR` from the environment part of the `KERN_PROCARGS2` buffer it already reads for candidate processes, in the same pass and cached per process identity. The value is bounded at 1024 bytes of valid UTF-8, it is the only environment value kept, and only the user's own Claude Code processes contribute. Each value is keyed by its normalized projects folder, so `/cfg` and `/cfg/` take one slot; a value that is not an absolute path (relative, or starting with `~`) is ignored, because the session's working folder and home are unknown to Overtime. A learned projects folder is watched from the first tick that sees it until `Timing.learnedRootLingerSeconds` (600 s) pass without a sighting, at most 8 at a time, and it is added beside configured folders as well as beside the defaults. A folder seen on the first tick after a long gap in the monotonic clock (a sleep) is kept; one not seen is forgotten on that tick. Each change logs `CHECK transcriptRoot learned` or `CHECK transcriptRoot forgotten` and rebuilds the transcript source once; a rebuild that times out surfaces as a settings rebuild does (`ERROR settings roots notRebuilt` and an unreadable folder) and is retried by the same backoff. When a folder is forgotten, its once-per-absence log memory is forgotten too, so if it is learned again while still missing it is logged absent again.
- **Configured folders keep their meaning.** They are watched verbatim, they replace the two defaults, and a missing one warns.

## Consequences

- **DET-12** is refined: its root-missing warning now applies to configured folders only. The terminal-silence warning is unchanged and stays the backstop for any blind spot, whatever its cause.
- Energy: no new system call (the environment is parsed from the buffer the scan already reads, once per process identity, inside the existing per-process cache), no timer, no process, one FSEvents stream per extra folder (at most 8 learned ones), and a rebuild of the transcript source only when the learned set changes. The linger is read on the existing 2 s tick. See the 2026-10-14 note in [0019](0019-detection-loop-energy-design.md).
- Shadow and once modes do not learn: the engine learns only where the composition gives it a way to rebuild the transcript source (the live engine), and elsewhere it logs nothing about learned folders.
- Measured on 2026-10-14 on macOS 27: an Apple platform binary's `KERN_PROCARGS2` buffer ends after its arguments and carries no environment, while Claude Code's buffer (Team ID signed, hardened runtime, not a platform binary) carries its full environment. A test can therefore not fake a Claude process with a platform binary; the real-buffer test reads the test process's own buffer.
- Privacy: environment values other than `CLAUDE_CONFIG_DIR` are never kept, logged or exported. The only new log lines name projects folders, passed through the same sanitizer as other logged roots, and a diagnostics export shows the home folder as `~`.
- A same-user process named like Claude Code can make Overtime watch a folder of its choice. Writing transcripts there keeps the Mac awake, which the same user can already do through `~/.claude/projects` or `caffeinate`.
- The Detection pane lists both default folders when the inherited variable names another folder, and its caption says that a running session's own config folder is always watched.

## Alternatives considered

- **Trust the app's environment only.** That is the incident above.
- **Warn on every missing folder.** A false alarm on a fresh install, where `~/.claude/projects` may not exist yet, and on every stale inherited environment.
- **Read the environment of every process.** It costs a read per process and widens what Overtime sees of other programs' secrets for no gain; only Claude Code's own setting matters.
- **Start a tool that lists environments.** [0019](0019-detection-loop-energy-design.md) forbids a process per tick.
- **Ask the user to add each folder by hand.** It misses every session started ad hoc with another config folder, which is exactly the session that needs it.

## Evidence

- The test suites `TranscriptRootsTests` (normalization, defaults, the merge of learned folders), `DetectionHealthTests` (configured against inferred, present against missing), `InheritedConfigDirectoryTests` (the incident through the real composition), `ClaudeConfigDirectoryTests` (the environment read from `KERN_PROCARGS2` fixtures: argc, the executable path, padding, arguments that look like the variable, malformed and oversized values), `ProcessScannerTests` (the read stays limited to candidates, and the test process's own buffer), `LearnedConfigDirectoriesTests` (the linger, the cap, equivalent spellings, a clock jump) and `EngineLearnedRootsTests` (learning, forgetting, the additive rule, a timed-out rebuild, an engine that cannot rebuild).
- The buffer measurement above, made on 2026-10-14 with controlled child processes and the reader's own process; only variable names were read from the two running Claude Code processes.

**Not verified:** none of this was observed on a running signed build when it was written. It is a human check: a launch with a bogus `CLAUDE_CONFIG_DIR`, a session with its own config folder learned and then forgotten, the Detection pane, and the energy with several sessions.
