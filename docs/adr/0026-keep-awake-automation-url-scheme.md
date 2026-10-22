# 0026. Keep Awake can be turned on and off with an overtime:// link

- **Status:** Accepted
- **Accepted:** 2026-10-22. The project author accepted the four links as proposed, including `overtime://keep-awake` with no limit, which any app, or a web page once the browser asks, can open. Checked on a Mac with a signed release build: `open -g` with `minutes`, `until`, a mistyped parameter and `stop-keep-awake` behaved as described and took no focus, and a link opened while Overtime was not running started it and ran once the engine was ready. `open -g` from a launchd job was not run.
- **Date:** 2026-10-21
- **Deciders:** Project author
- **Related ADRs:** [0005](0005-sentinel-watchdog-design.md), [0017](0017-ignored-entrypoints-sdk-prefix.md), [0021](0021-app-owned-status-item-and-panel.md), [0025](0025-lid-closed-keep-awake-setting-and-custom-durations.md)

## Context

Keep Awake could only be turned on by hand, in the panel or with ⌃⌘K. Scheduled work that Overtime does not count as Claude working, such as `claude -p` runs started by launchd (ignored by default as `sdk-*`, ADR [0017](0017-ignored-entrypoints-sdk-prefix.md)), had no way to ask for it. Between two runs of a night of jobs with the lid closed, Overtime correctly lets go and the Mac sleeps before the next run.

The app already has an external surface: the engine's control socket, which `overtimed ctl` uses. It is not usable here: `overtimed` is a development tool that is not in the app bundle, and the socket path differs between builds. A URL is the standard macOS way for a script to reach a running menu bar app, needs no extra binary, works with `open -g` from launchd, Shortcuts and shell scripts, and opens the app if it isn't running.

## Decision

- **Four links.** `overtime://keep-awake?minutes=N` (N a whole number from 1 to 1440, the range of the Keep Awake durations in Settings), `overtime://keep-awake?until=HH:MM` (24-hour local time; the next such time strictly after now, so a time already passed today means tomorrow; a time skipped by a daylight saving change means the next existing time), `overtime://keep-awake` (until stopped) and `overtime://stop-keep-awake`.
- **The same path as the panel.** A link becomes a `ControlAction` and goes through `PanelModel.perform`, the method the Keep Awake menu and the Stop Keeping Awake button call, so it reaches the engine as the same `force` or `resume` request. Every guarantee of Keep Awake follows: the battery and temperature limits, "Keep awake with the lid closed", the watchdog, the Keep Awake reminder, and the disabled controls while Overtime uninstalls or has no working engine. `minutes` maps to the menu's own `.keepAwake(.timed(minutes:))`, the bare link to `.untilStopped`. `until` adds one case, `ControlAction.keepAwakeUntil(Date)`, that maps to `force(forSeconds:)` with the seconds left at the moment the request is built, at least 1 second, so the hold ends at the requested minute and not up to 59 seconds later.
- **Stop never ends a pause.** Stop Keeping Awake sends `resume`, which also ends a pause. The panel only shows it while Keep Awake is on, so the link does the same check as the notification's Turn Off action: it probes the engine and sends nothing unless Keep Awake is on (`COMMAND url ignored ... reason=notKeepingAwake`).
- **Strict parsing, no partial meaning.** An unknown parameter, a repeated one, `minutes` with `until`, any parameter on `stop-keep-awake`, a sign, a decimal, an out-of-range value, a fragment, a user, a port or an extra path is refused, and nothing changes. A typo such as `minute=30` must not silently become until stopped. The parser lives in `OvertimeAppSupport` next to `ControlMapping`, where `ControlAction` and `KeepAwakeChoice` are, not in `OvertimeCore`, which knows nothing of the panel's actions.
- **The decision log (OPS-03).** Each link writes one line: `COMMAND url command=keep-awake minutes=90`, `until=05:30`, `until=stopped`, `COMMAND url command=stop-keep-awake`; `COMMAND url waiting ...` while the engine starts; `WARN url ignored reason=<malformed|wrongScheme|unknownCommand|unexpectedParameter|invalidMinutes|invalidTime>`; `WARN url ignored ... reason=controlsUnavailable`; `ERROR url failed ...`. A refused link never logs what it carried, so a crafted link cannot write into the log. The engine's own `OVERRIDE force` line follows as for a click.
- **No window, no focus.** The app installs its own handler for the `GetURL` Apple event in `applicationWillFinishLaunching`, before AppKit delivers the launch event, instead of `application(_:open:)`. That keeps the URL away from SwiftUI's scene routing, which could open a window, and the handler never activates the app. `open -g` keeps it in the background.
- **A link that starts Overtime.** While the engine is starting, the live app keeps the latest link and runs it once the engine is bound; if the engine cannot start, the link is dropped and logged as failed. Links run one at a time, in the order they arrive.
- **One scheme per build.** Release builds register `overtime`, Debug builds `overtime-dev` (`OVERTIME_URL_SCHEME` in `project.yml`, read by `CFBundleURLTypes` in `Info.plist`), so a development build never takes the links of the installed release, the same separation as its bundle identifier and support folder.

## Consequences

- **Any local app, and a web page once the browser asks, can turn Keep Awake on.** The worst case is the Mac kept awake under Keep Awake's limits, with the menu bar icon in its kept-awake shape and the Keep Awake reminder; the control socket already lets any process of the user do the same. The links carry no data back and cannot pause, change settings or reach the helper.
- **Nothing changes for a user who never opens a link.** No setting, no new process, no new permission.
- **The README documents the links** in a new Automation section, with a launchd example.

## Alternatives considered

- **Shipping `overtimed ctl` in the bundle.** Another binary to sign and pin, with a socket protocol that is internal and was never meant to be public.
- **App Intents / Shortcuts actions.** Heavier, and launchd would still need a URL or a CLI to reach them.
- **A permissive parser** that ignores unknown parameters. A mistyped parameter would turn a timed request into until stopped.
- **`application(_:open:)`.** Simpler, but it runs through SwiftUI's URL routing in an app that uses the SwiftUI lifecycle.

## Not verified

- No run of the built app: this change was written on a machine without Xcode. The package code and its tests were compiled and run there with `swiftc`, and the app target was type-checked with its Swift 6 and `MainActor` default isolation settings, but the URL registration, the Apple event handler and `open -g` from launchd need a run on a Mac with the release build.
- Since then (2026-10-22): the full CI gate passed with Xcode (core, runtime, app tests, script tests, strict lint, helper pin), and a signed release build checked the URL registration and the Apple event handler while running and at launch. Only `open -g` from a launchd job is still unverified.

## Notes (2026-10-22)

- A `claude -p` run now keeps the Mac awake while it runs, whatever started it, launchd included (**DET-14**, [0027](0027-background-commands-and-claude-p-runs-keep-the-mac-awake.md)), so the Context above no longer holds for the runs themselves.
- The links remain for the gaps between scheduled runs, where Overtime still lets go, and for work Overtime does not see, such as Agent SDK scripts, which launch Claude Code without `-p`.
