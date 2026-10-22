# Changelog

All notable changes to Overtime are listed here, in the Keep a Changelog format, and versions follow Semantic Versioning.

## [1.1.0]

### Added

- Keep awake with the lid closed, in Settings > General: Always, as before, Only on power adapter, or Never. With Only on power adapter, the Mac sleeps when you close the lid on battery or unplug the charger with the lid closed. With Never, closing the lid always lets the Mac sleep, and Overtime still prevents idle sleep with the lid open.
- You can change the two timed choices of the panel's Pause and Keep Awake menus in Settings > General, from 1 minute to 24 hours. They stay 15 Minutes and 1 Hour, and 30 Minutes and 2 Hours, until you change them.
- Keep Awake from scripts and scheduled jobs: `open -g "overtime://keep-awake?minutes=90"`, `?until=05:30`, no parameter for until stopped, and `overtime://stop-keep-awake`. A link works like the Keep Awake control in the panel, with the same battery and lid-closed limits, and opens no window. See Automation in the README.

## [1.0.2] - 2026-10-17

### Fixed

- The iPhone hotspot setup step no longer cuts off its last line.
- The setup guide's window is taller, so every step shows all of its content without scrolling, including the four notes of Unplug protection and the "Sleep is turned off system-wide" row of Recommended macOS settings.

## [1.0.1] - 2026-10-17

### Added

- A Keep display on switch in the menu bar panel. It is the same setting as "Keep display on while Claude works" in Settings > General, and a change in either place shows in the other.
- Battery protection can be turned off in Settings > Battery. Unplug protection keeps its own floor, which you can now set from 5% to 50%.
- Temperature protection, off by default: once you turn it on in Settings > Battery, Overtime lets the Mac sleep when the battery reaches a temperature you choose (45°C by default) and holds again 5°C below it. Unplug protection also stops at that temperature, or at 60°C with temperature protection off.
- A Battery temperature notification, which you can turn off in Settings > General.

### Changed

- The unplug protection helper changed (helper version 2). After the update, macOS asks once to allow it again under Allow in the Background.
- A clearer setup guide. Its last step, Setup complete, says there is nothing left to do. The Location step became iPhone hotspot (optional): it asks for Location only after you choose your hotspot, and says what Location is used for and what it is never used for. Check your setup is now Recommended macOS settings.
- The Homebrew cask now lives in Overtime's own repository: `brew tap ivanhernandez-dev/overtime https://github.com/ivanhernandez-dev/overtime`, then `brew install --cask ivanhernandez-dev/overtime/overtime`. If you installed from the previous tap, run `brew untap ivanhernandez-dev/tap`; Overtime keeps updating itself either way.

### Fixed

- Claude Code sessions started through a wrapper, such as a terminal app's shim, are recognised. Before, a session that Overtime first saw while its wrapper was still starting was never counted as a working terminal session.
- Claude Code's own `caffeinate`, and the ones its commands start, no longer show as another tool managing sleep.

## [1.0.0] - 2026-10-15

### Added

- Keeps your Mac awake while Claude Code works, with the lid open or closed, and lets it sleep when the work stops.
- A menu bar panel that shows what Overtime is doing and why, with pause, keep awake and sleep now.
- Settings for detection, battery limits, notifications, network failover and diagnostics.
- Optional unplug protection, set up with one administrator approval.
- Network failover to your iPhone hotspot while the lid is closed.
- A guided first run.
- Automatic updates, checked once a day.
- Uninstall from Settings > About, with an option to remove settings, state and logs.
