# Changelog

All notable changes to Overtime are listed here, in the Keep a Changelog format, and versions follow Semantic Versioning.

## [Unreleased]

### Added

- A Keep display on switch in the menu bar panel. It is the same setting as "Keep display on while Claude works" in Settings > General, and a change in either place shows in the other.
- Battery protection can be turned off in Settings > Battery. Unplug protection keeps its own floor, which you can now set from 5% to 50%.
- Temperature protection, off by default: once you turn it on in Settings > Battery, Overtime lets the Mac sleep when the battery reaches a temperature you choose (45°C by default) and holds again 5°C below it. Unplug protection also stops at that temperature, or at 60°C with temperature protection off.
- A Battery temperature notification, which you can turn off in Settings > General.

### Changed

- The unplug protection helper changed (helper version 2). After the update, macOS asks once to allow it again under Allow in the Background.

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
