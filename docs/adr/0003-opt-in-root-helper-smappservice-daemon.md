# 0003. Opt-in root helper: `SMAppService.daemon` setting `SleepDisabled` under T1 signing

- **Status:** Accepted
- **Accepted:** 2026-09-26, at the spike go/no-go review. The project author delegated this review to Claude; the author may revisit it.
- **Gate:** 3 of 3. The project author approves or rejects this before Phase 1 is planned.
- **Date:** 2026-09-26
- **Deciders:** Project author
- **Related requirements:** **HOLD-15**, **HOLD-16**, **HOLD-17**, **APP-11**, **APP-07**, **OPS-06**
- **Related ADRs:** [0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md), [0008](0008-long-lived-t1-signing-identity-and-keys.md), [0009](0009-helper-release-sequence.md), [0010](0010-pinned-helper-binary.md), [0011](0011-helper-battery-floor.md), [0012](0012-helper-thermal-release.md)

## Context

The rootless hold in [0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md) loses to powerd when, with the lid closed, the charger is replugged, a display is connected or disconnected, or the charger is unplugged with a display attached. **HOLD-15** asks that, with an opt-in privileged helper installed, unplugging AC power or disconnecting an external display with the lid closed does not sleep the Mac. **HOLD-16** defines that helper; **HOLD-17** requires that it never leaves the Mac stuck awake. **APP-11** allows root only in this opt-in helper.

Gate 3 asks whether `SMAppService.daemon` works with the self-signed T1 identity, including the user's approval and the code-signing requirement check across an app update. A no-go would change **HOLD-15**, **HOLD-16** and **HOLD-17** and the scope of Phase 3.

## Decision

Go.

- **Registration.** An opt-in launchd daemon registered with `SMAppService.daemon(plistName:)`.
  - Label and Mach service: `io.github.ivanhernandez-dev.overtime.helper`.
  - Plist in `Contents/Library/LaunchDaemons`, with `BundleProgram` `Contents/MacOS/OvertimeHelper`, `RunAtLoad`, `KeepAlive` and `AssociatedBundleIdentifiers` naming the app.
- **XPC, locked both ways by code-signing requirement.** The helper's listener requires the app; the app's connection requires the helper. Both requirement strings pin the T1 certificate recorded in [0008](0008-long-lived-t1-signing-identity-and-keys.md):
  - app: `identifier "io.github.ivanhernandez-dev.overtime" and certificate root = H"9c54a8e3e576cc8e7eb6d5a2dc63aa7607b821ce"`
  - helper: `identifier "io.github.ivanhernandez-dev.overtime.helper" and certificate root = H"9c54a8e3e576cc8e7eb6d5a2dc63aa7607b821ce"`
- **Interface.** Set, clear and status, as **HOLD-16** requires. The spike's protocol was `setSleepDisabled(Bool)` plus `status`; the Boolean covers both set and clear.
- **Scope.** The helper sets `SleepDisabled` only while keep-awake is wanted and the lid is closed. With the lid open everything stays on the rootless path.
- **Safety constraints**, each its own ADR:
  - the release sequence: [0009](0009-helper-release-sequence.md);
  - the pinned helper binary: [0010](0010-pinned-helper-binary.md);
  - the helper's own battery floor and heartbeat timeout: [0011](0011-helper-battery-floor.md);
  - the thermal release at Trapping or `.critical`: [0012](0012-helper-thermal-release.md).

## Consequences

- The first `register()` throws "Operation not permitted" with status `requiresApproval`. That is the normal path: Overtime sends the user to System Settings › Login Items & Extensions (**APP-07**).
- Approving the helper flips the app's own login item to "requires approval" until the user approves it too. Onboarding must say so.
- Switching the helper off in System Settings also quits the app, with no crash report.
- `SleepDisabled` persists across a reboot, and powerd re-applies it at boot before the helper runs. The helper therefore reconciles at `RunAtLoad` and clears any value it left behind.
- `disablesleep` is undocumented: it is missing from `man pmset` on macOS 27.
- With `SleepDisabled=1`, `pmset sleepnow` fails with `0xe00002e2`, so the helper clears before any sleep request ([0009](0009-helper-release-sequence.md)).
- Uninstall unregisters the helper and clears any `SleepDisabled` it set (**OPS-06**).
- Implementation note (2026-10-10, Phase 5 review): uninstall decides who set `SleepDisabled` once, before it unregisters the helper, from the helper's own answer or, when the helper can't answer, from its ownership record. A retry keeps that first answer and never asks a helper that may already be gone. It clears the value only when that answer says the helper set it. When Overtime can't tell (the record can't be read, or macOS doesn't report the helper's status within 5 s), it leaves the value on: the app offers its consent action, and the command-line paths print the command and exit non-zero. A Mac with no record counts as not set by Overtime.
- Implementation note (2026-10-10, Phase 5 review, iteration 2): a helper status that macOS doesn't report within 5 s no longer makes the answer "can't tell" by itself. Uninstall still asks the helper, then reads its record. A missing record folder means Overtime didn't set the value, because the helper writes the record before it turns sleep off. Only when both are inconclusive does the value stay on for the user to decide.
- Implementation note (2026-10-10, Phase 5 review, iteration 2): `uninstall.sh` reads the record in one `sudo` call, so any `sudo` that fails, even after `sudo -v`, means "can't tell" and the record is kept. When `Overtime --uninstall` reports "can't tell", the script removes the app and then reads the record itself with `sudo`, which the app can't do. It clears the value only when the record says the helper set it.
- Implementation note (2026-10-10, Phase 5 review, iteration 3): once uninstall has run the helper step, it never stops between removing the helper and restoring sleep. A quit that arrives during the helper step lets both steps finish, and the quit waits for them, up to the admin prompt's timeout. A restore prompt that starts after the quit began is held, not cancelled, unless a logout, restart or shutdown is under way. The quit checks for one on every pass of its wait, so a logout that begins while the quit is already waiting cancels the prompt at once and logs the manual command, and the logout is never held for the admin timeout. Before the helper step, and after the restore step, a quit still stops the run at the next step.
- Phase 3 builds the helper and runs it through `/gsd-secure-phase`.

**Not verified:**

- T2 (Developer ID) behaviour of registration, approval and the launch constraint.
- The **HOLD-17** case where `SleepDisabled` was already 1 before Overtime engaged. The spike always started from 0.
- macOS 14 and 15.

## Alternatives considered

- **No helper.** This is the no-go outcome. **HOLD-15**, **HOLD-16** and **HOLD-17** would be dropped or reworded, the rootless limitation in [0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md) would be permanent, and Phase 3's scope would shrink.
- **Writing the root-domain `SleepDisabled` property directly** instead of going through `pmset`. It needs the private entitlement `com.apple.private.iokit.rootdomain-set-property`, which a third-party helper cannot have.

## Evidence

Measured on a MacBook Pro M5 Max running macOS 27.0 (26A428), in spike 005, on 2026-09-26. Verdict: PARTIAL.

- Registration and approval under T1 worked with one approval in Login Items & Extensions. `sfltool dumpbtm` shows the helper with no Team ID.
- An ad-hoc-signed intruder and a T1-signed intruder with a different identifier were both refused before `shouldAcceptNewConnection` ran. The check survived an app update.
- `SleepDisabled` held a closed lid awake through every trigger that defeats the rootless bit: charger unplug and replug, display connect and disconnect on AC and on battery, and charger unplug with a display attached.
- App crash → the Mac slept about 1 s after the app died.
- Helper crash → launchd restarted it in about 1 s, and startup reconciliation cleared `SleepDisabled` 1.4 s after the crash.
- Unregister → SIGTERM → release → exit.

The verdict is PARTIAL because the pinned-binary strategy rests on one identical-hash update, T2 behaviour is unknown, and the thermal release had not been chosen at the time ([0012](0012-helper-thermal-release.md) has since chosen it).

Local reference (not needed to read this ADR): `.claude/skills/spike-findings-overtime/references/root-helper.md`.
