# 0016. Coexistence: detect other keep-awake tools and warn, never share the bit

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **HOLD-07**, **APP-07**
- **Related ADRs:** [0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md)

## Context

The lid-close hold ([0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md)) is one kernel bit with no owner and no reference count. Another tool that drives lid-close sleep, such as Amphetamine's Closed-Display Mode, writes the same bit. Whoever writes last wins, so "only clear what Overtime set" cannot be enforced.

**HOLD-07** requires that Overtime not break other tools: it clears the bit only on its own release transitions, never touches other tools' power assertions, and detects and warns about running alongside a tool that drives lid-close sleep.

## Decision

- Overtime **detects** other keep-awake tools and shows a warning ("another tool is managing sleep").
- It **never shares or preserves** the clamshell bit, and never requests a lid-close assertion.
- Detection uses two signals:
  - **Running apps by bundle identifier:** `com.if.Amphetamine`, optionally others, through `NSWorkspace.shared.runningApplications`.
  - **Foreign assertions:** `IOPMCopyAssertionsByProcess`, filtered on `AssertLevel > 0`. It is readable unprivileged for other processes, including `AssertType`, `AssertName`, `BundlePath`, `Process Name`, `TimeoutSeconds` and `HumanReadableReason`.
- Overtime's own pid and Claude Code's own `caffeinate` (whose parent is the `claude` process) are excluded from the warning.
- When Overtime releases, it clears the bit even if another tool might want it. This is the project's tie-break: never stuck awake wins.
- The documented contract: Overtime and Amphetamine's Closed-Display Mode must not run at the same time (**HOLD-07**).

## Consequences

- Running both tools together is unsupported. The panel's hints recommend quitting Amphetamine, and the warning state makes the conflict visible.
- Overtime cannot tell which process last wrote the bit; the warning is based on who is running and what assertions exist, not on the bit.

**Not verified:** Amphetamine is not installed on the test Mac, so what its assertions look like in the table was not observed (spike verdict PARTIAL). The detection mechanisms themselves are settled. Verified on macOS 27.0 only.

## Alternatives considered

- **Share or preserve the bit with the other tool.** One bit, no owner, no count: it cannot work.
- **Hold an `AppliesOnLidClose` assertion instead of the bit.** `IOPMAssertionCreateWithProperties` refuses it to unprivileged processes with `0xE00002C1` (`kIOReturnNotPrivileged`), and no assertion is created at all. Only apps with Apple's private entitlement hold lid-close assertions.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spike 007, on 2026-09-26. Verdict: PARTIAL.

- The `AppliesOnLidClose` request was refused with `0xE00002C1`, and no assertion was created.
- The per-process assertion table was fully readable for other processes, including `BundlePath` and `Process Name`.

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/coexistence-detection.md`.

## Implementation notes (2026-10-07)

Phase 1 built the foreign-assertion signal as every other process holding `PreventUserIdleSystemSleep` or `PreventSystemSleep`. A read-only `pmset -g assertions` on the development Mac on 2026-10-07 shows `powerd`, `bluetoothd`, `sharingd`, `coreaudiod` and `cameracaptured` each holding one, and powerd's is named for the display being on. So the signal was on during ordinary use: the "is also managing sleep" hint would always show, and the launch self-test (**OPS-09**) would almost always be skipped. `sw_vers` on that Mac on the same day reads macOS 27.0.1 (26A434). None of this changes the decision above: Overtime detects and warns, never shares the bit, and clears it on its own release.

- **The narrowed rule.** A foreign assertion counts only when its owner is a known keep-awake tool: a process named Amphetamine; a `caffeinate` whose parent is not the `claude` process; or a process on a fixed list, matched on the table's `Process Name`, whole name, any letter case. The list, in order: Caffeine, KeepingYouAwake, Lungo, Theine, Coca, Owly, Jolt of Caffeine, InsomniaX, NoSleep, Sleep Control Center, Lidless. It lives once, in `CoexistenceProbe.knownToolProcessNames`, and a test pins it.
- **What never counts.** System daemons, browsers, media and conferencing apps, and every other app.
- **What did not change.** Amphetamine is still detected by its executable path. `SleepDisabled = 1` is still its own signal. Overtime's own pid and Claude Code's own `caffeinate` are still excluded.
- **Why this is acceptable.** **HOLD-07** asks for detection where possible. Missing an unknown tool is acceptable; a constant false warning is not.
- **Limits.**
  - No listed tool appears in the capture, so how each one shows up in the table (process name and assertion type) is not verified.
  - Only the two assertion types above are read. In the capture a browser's rows carry `NoIdleSleepAssertion` and `NoDisplaySleepAssertion`, so a listed tool that holds only such a type is not seen.
  - Claude's own `caffeinate` is excluded through the process list of the last tick (ticks are 2 s apart), while the self-test decides on a single sample. A self-test sampled after Claude starts a new `caffeinate` and before the next tick reads skipped and names caffeinate; a request after that tick is not affected. The warning needs the same assertion in two samples 30 s apart, so this window does not reach it.

Evidence: the capture is kept as the test fixture `Packages/OvertimeRuntime/Tests/Fixtures/pmset-assertions-ordinary-mac.txt`. It is the raw capture passed through one fixed redaction: the Apple daemon rows and the caffeinate row are as captured, apart from the removals that follow; every other process name is a placeholder with a neutral assertion name; device addresses and device UUIDs are zeros; the capture time, the row durations, the input-device details and the kernel-assertion block are removed. It holds 15 assertion rows from 9 processes, 10 of them of a watched type. `CoexistenceCaptureTests` runs it from the probe through the engine to the hint and the self-test. The decision was delegated by the author and recorded on 2026-10-07.

## Implementation notes (2026-10-14)

A launch self-test (**OPS-09**) read Skipped on the development Mac because a background script there wraps itself in `caffeinate`. The detection was right: that `caffeinate` was not started by Claude, so it counts. The skip was not needed. On 2026-10-14 the author decided to run the self-test beside tools that only hold off idle sleep, to name who started a foreign `caffeinate`, and to explain a disabled Run Self-Test button. The classification below was delegated to Claude, and the author may revisit it.

- **Why the self-test can run beside an idle-only tool.** The self-test checks only that macOS accepts Overtime's own calls: selector 12 on and off, and one idle assertion acquired and released. It measures no sleep. An assertion that only holds off idle sleep cannot change those results, and a tool that holds only such assertions never writes the clamshell bit, so the test cannot break it. The idle-only list is `CoexistenceProbe.idleOnlyToolProcessNames`: `caffeinate`, Caffeine, KeepingYouAwake, Lungo and Theine, matched like the list above (the table's `Process Name`, whole name, any letter case). `Engine.selfTestFacts` drops those assertions before it picks the tool that skips the self-test.
- **What still skips.** The self-test still skips for Amphetamine, for every other listed tool, and for `SleepDisabled = 1` or unreadable. InsomniaX and NoSleep are kernel extensions that disable lid sleep. Sleep Control Center says it prevents sleep with the lid closed. Lidless sets `SleepDisabled` through a privileged helper. Coca, Owly and Jolt of Caffeine say nothing public about the lid, so they stay in the skip set. The list is an allow-list: a name added to the known list later skips until it is classified, and `CoexistenceProbeTests` fails until it is.
- **What did not change.** The warning and the hint still count every listed tool and every `caffeinate` not started by Claude, in two samples 30 s apart.
- **The single-sample race is gone from the self-test.** The race noted on 2026-10-07 no longer reaches the self-test: a `caffeinate` that Claude starts between two ticks is idle-only, so it cannot skip the test.
- **Who started a foreign `caffeinate`.** The hint, the snapshot's `otherTools` and the diagnostics export show "caffeinate (started by <process name>)", for example "caffeinate (started by python3)", when its parent is a process of the user in the process list the last tick read. Nothing new is read from the system. No argument, environment value, path or pid is kept. The parent's name is cleaned and capped at 32 characters like the tool name. An unknown or nameless parent leaves "caffeinate". When both a named and a bare `caffeinate` are present, the hint names the one with a known starter, and the snapshot and the export list both. The `WARN coexistence` log line still lists process names only. A wrapper app that starts `caffeinate` (KeepingYouAwake does) now shows by name through its child.
- **Sources, read on 2026-10-14.** The `caffeinate` manual page on macOS 27 (idle, display, disk, system and user-active assertions, no lid control); IOPMLib.h in the macOS 27 SDK (with PreventUserIdleSystemSleep "the system may still sleep for lid close"); github.com/domzilla/Caffeine (one PreventUserIdleDisplaySleep assertion, a type the probe does not watch); github.com/newmarcel/KeepingYouAwake (a wrapper around `caffeinate` that works only with the lid open); sindresorhus.com/lungo (a closed Mac stays awake only in macOS's own clamshell mode); the Mac App Store page of Theine (it cannot prevent sleep on a closed MacBook without an external display); github.com/semaja2/InsomniaX; github.com/integralpro/nosleep; prevent-mac-from-sleeping.3bitlab.com; github.com/nghialuong/Lidless; and the Mac App Store pages of Owly and Jolt of Caffeine. No public description of Coca was found.
- **Evidence.** `CoexistenceProbeTests`, `EngineSelfTestTests`, `CoexistenceCaptureTests` (the committed capture with a `caffeinate` started from a shell and from a background script), `EngineSnapshotTests` and `DiagnosticsManifestTests`.
