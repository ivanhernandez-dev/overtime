# 0025. Keep awake with the lid closed is a setting, and the Pause and Keep Awake timed choices are settings

- **Status:** Accepted
- **Accepted:** 2026-10-17. The project author chose three options for the release after 1.0.1: keep the Mac awake with the lid closed only on the power adapter, turn the lid-closed hold off, and custom Pause and Keep Awake durations, each with a default equal to how Overtime 1.0.1 behaves, and chose one three-way picker, "Keep awake with the lid closed: Always / Only on power adapter / Never", over two switches. The form of the stored setting (one three-value setting), the scope, the treatment of an unknown power source, Keep Awake following the setting and the duration ranges were delegated to Claude; the author may revisit them.
- **Date:** 2026-10-17
- **Deciders:** Project author
- **Related requirements:** **BAT-02**, **HOLD-01**, **HOLD-11**, **HOLD-12**, **HOLD-16**, **HOLD-19**, **LID-01**, **LID-02**, **NET-01**, **APP-03**, **APP-19**, **OPS-03**, **OPS-05**, **OPS-09**
- **Related ADRs:** [0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md), [0003](0003-opt-in-root-helper-smappservice-daemon.md), [0009](0009-helper-release-sequence.md), [0011](0011-helper-battery-floor.md), [0014](0014-lock-screen-on-lid-close.md), [0020](0020-verify-by-observed-sleep.md), [0024](0024-configurable-battery-and-temperature-protection.md)

## Context

The author asked for two ways to narrow the lid-closed half of Overtime: not keeping the Mac awake with the lid closed while it runs on battery, and keeping only the lid-open behaviour so that closing the lid puts the Mac to sleep as usual. The author also asked for the timed choices of the panel's Pause and Keep Awake menus to be editable. The binding rule: a user who never opens Settings sees no change.

- **Today the clamshell hold does not wait for the lid.** It engages whenever keep-awake is wanted, before the lid closes, on any power source (HOLD-02), so that closing the lid finds the selector already set (ADR [0001](0001-keep-awake-mechanism-rootless-clamshell-selector.md)).
- **What exists only for a held closed lid.** The clamshell selector (HOLD-01), the opt-in helper and its `SleepDisabled` (HOLD-16, ADR [0003](0003-opt-in-root-helper-smappservice-daemon.md)), the display-off lock at lid close and its re-sleep (LID-01, LID-02, ADR [0014](0014-lock-screen-on-lid-close.md)), hotspot failover (NET-01), and HOLD-12's check that the Mac really sleeps after the hold's release (ADR [0020](0020-verify-by-observed-sleep.md)). The lid-open idle hold (HOLD-11) and the display option (HOLD-10) do not depend on the lid.
- **BAT-02 was reserved.** The requirements already listed BAT-02, "Keep awake with the lid closed only on AC", off by default, as a v2 item. Requirement IDs are never reused, so this decision moves BAT-02 to v1 rather than minting a duplicate.

## Decision

- **One setting with three values (HOLD-19).** `lidClosedKeepAwake`: `always` (the default, 1.0.1's behaviour), `onPowerAdapter` (BAT-02) or `never`, shown as one picker in Settings > General, "Keep awake with the lid closed: Always / Only on power adapter / Never". Two switches were rejected: two Booleans have a combination (hold off, power adapter only on) that means nothing but still has to be stored, decoded, disabled in the UI and explained. One enum makes it unrepresentable, gives the reducer one gate and the log one vocabulary. macOS's own power settings use a three-value picker of the same shape for automatic restart.
- **Scope: the lid-closed hold only.** The setting governs the clamshell selector, the helper, the display-off lock and its 60 s re-sleep, hotspot failover and HOLD-12's check after the hold's own release. The lid-open idle hold, the display option, Want, Pause, Keep Awake, and battery and temperature protection are unchanged. Gating all of keep-awake on battery would also drop the lid-open hold, which nobody asked for.
- **What "on power adapter" means.** A reading of the power adapter (any charge, known or not) and a Mac with no battery allow the hold; battery (any charge) and no reading yet do not: an unknown source counts as battery, because when the state is unclear, never stuck awake wins. An unreadable reading after a known one keeps the last known source, because the engine drops unreadable readings for every machine (the BAT-01 rule). If the power adapter was the last known source, Only on power adapter behaves like Always until a readable sample arrives, which is 1.0.1's shipped behaviour.
- **Keep Awake follows the setting.** Under Never, and under Only on power adapter on battery, Keep Awake keeps only the lid-open hold. A manual override that quietly re-enabled lid-closed hold would be the one path where Never does not mean never, and the safe side of the tie-break is to let the Mac sleep. The panel's detail line says so.
- **Only engaging is gated.** The gate is `Hold.lidCloseDesired = wanted && Hold.lidClosedAllowed`, used only where the code decides to engage or keep the hold. Every clear keeps its trigger: the release from the hold's step (held or acquiring and not desired, failed and not desired), the late-write follow-up clear, the stale clear at launch, the clear after a lost watchdog (only the re-engage after it is gated), stop, the self-test's own clear, the emergency reset and every helper release.
- **The helper is handled app-side.** `HelperIntent.desired` requires the gate, so on the power event that ends the hold the app sends the helper's clear first (the existing ordering), then its own clamshell clear, and the helper runs its unchanged release sequence (ADR [0009](0009-helper-release-sequence.md)). The new release reason `lidClosedHoldOff` is an app log word, never sent over XPC. The XPC interface, the helper's state machine, helper version 2 and `Pinned/helper/v2` stay as they are: no re-approval.
- **The launch self-test is unchanged under every value (OPS-09).** It writes the selector on and off once with the lid open, as today. It checks the mechanism for when the user switches back, it never holds a closed lid, and changing a safety-relevant machine for a few milliseconds of write would cost more than it saves.
- **The decision log (OPS-03).** `HOLD lidClosed allowed=<true|false> setting=<always|onPowerAdapter|never> power=<ac|battery|noBattery|unknown>`, written only when the answer changes, so the default never writes it. The helper's release logs `HOLD helper release reason=lidClosedHoldOff`. The existing `SETTINGS applied keys=...` line names the five new keys when they change.
- **A change applies at once.** Applying new settings re-steps the last power reading when `lidClosedKeepAwake` changes, as it does for the battery thresholds; with no reading yet, the next 2 s tick applies it.
- **Expected sleeps are not unexpected.** A sleep counts as unexpected only while the lid-closed hold is allowed, so closing the lid under Never, or on battery under Only on power adapter, adds no "slept unexpectedly" line to the lid-closed summary.
- **The panel says what closing the lid does.** The lid-closed holding state shows only while the hold is allowed. While keep-awake is wanted, the lid is open and the hold is off, one detail line explains it ("Closing the lid lets the Mac sleep.", "On battery, closing the lid lets the Mac sleep." or "Until Overtime can read the power source, closing the lid lets the Mac sleep."). The unplug protection hint is hidden while the hold is off and names only display changes under Only on power adapter. Settings > Unplug Protection shows a note for the two non-default values.
- **Placement: Settings > General.** A Lid section between Startup and Display holds the picker; a Pause and Keep Awake section between Display and Notifications holds the four durations. General is the keep-awake behaviour itself, beside "Keep display on while Claude works"; Never has nothing to do with the battery, and the Battery pane is for protection limits.
- **Durations: four settings in minutes (APP-19).** `pauseFirstMinutes` 15, `pauseSecondMinutes` 60, `keepAwakeFirstMinutes` 30 and `keepAwakeSecondMinutes` 120, each from 1 to 1440 minutes, stepper step 5. The menus show the two values of each menu sorted ascending, a duplicate once, so there is no coupled validation. Labels are generated: under an hour "1 Minute" or "N Minutes", whole hours "1 Hour" or "H Hours", otherwise both joined by a space ("1 Hour 30 Minutes"); 1440 gives "24 Hours". What a click sends is carried by the choice itself, so a menu built from an older snapshot still sends exactly what it showed. Until Tomorrow, Until Resumed and Until Stopped stay, and the keyboard shortcuts are unchanged.
- **A bad value in the settings file.** An unknown `lidClosedKeepAwake` string or a wrong type makes the file invalid, like every other key, so the defaults are used, which is Always. An out-of-range duration is clamped on load and recorded as an adjustment; the editor rejects it with "Enter a whole number of minutes from 1 to 1440."

## Consequences

- **No change for a user who never opens Settings.** A settings file without the new keys decodes to Always and today's four durations, no lid-closed line is logged, and the menus are 15 Minutes, 1 Hour, Until Tomorrow, Until Resumed and 30 Minutes, 2 Hours, Until Stopped.
- **Under Only on power adapter, unplugging with the lid closed sleeps the Mac even with unplug protection.** The helper then covers connecting or disconnecting a display only.
- **Under Never the display-off lock is not used**, because the Mac sleeps and locks as it goes to sleep (with the lock delay LID-04 checks).
- **The General README image changes.** The panel, Battery and Unplug Protection images render as before, apart from the version number in the panel footer.
- **No helper change.** Helper version 2 and its pin stay current.

## Alternatives considered

- **Two switches.** A meaningless stored combination to disable and explain; the enum can be shown as two switches later without touching the core.
- **Gating all keep-awake on battery.** Drops the lid-open hold too.
- **A switch in the panel.** The panel is for the session at hand; this is a standing preference.
- **An unknown power source counting as on power.** It would hold a closed lid before Overtime knows it may.
- **Skipping the self-test under Never.** A change to a safety-relevant machine for a write that never holds a closed lid.
- **One list of durations.** A list needs a length rule and does not fit the existing numeric settings rows.
- **Validating the two durations in order.** Sorting the menu makes the order irrelevant and needs no coupled rule.

## Not verified

- No hardware run: unplugging the charger with the lid closed under Only on power adapter, with and without the helper; closing the lid under Never; an external display in clamshell use under Never.
- macOS 14 and 15.
- VoiceOver on the picker and the duration rows.

## Evidence

- **The core:** `LidClosedKeepAwakeTests` (the three values against every power reading, the gate, the lid-closed line, the clears under every value, the helper released first on an unplug), `LidClosedSideEffectsTests` (the display-off lock, failover, HOLD-12's check and the unexpected-sleep count, each with an Always control), and `SettingsTests` (defaults, missing keys, round trips, unknown values, clamps).
- **The runtime:** `EngineLidSettingTests` (the change applies at once and is published), the R-L1 rows of `ControlMappingTests`, and the panel, hint, copy and diagnostics suites.
- **The app:** the hosted `GeneralPaneTests`.
- **The default equals 1.0.1:** the frozen scenario, hold, lid, verification, failover, launch, stop and helper suites passed byte-unchanged on every commit, and the README's Battery and Unplug Protection images rendered byte-identical.
