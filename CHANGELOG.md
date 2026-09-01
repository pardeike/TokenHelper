# Changelog

## 1.0.5

- Restored reliable menu-item toggling, immediate window focus, and title-area dragging on current macOS betas.

## 1.0.4

- Added an optional multi-display blackout while `Screen on` is active, dismissed immediately by keyboard or mouse input.
- Added persistent popup-menu choices for turning blackout off or starting it after 1, 2, 5, 10, or 60 idle minutes.

## 1.0.3

- Made the menu bar icon toggle the panel on macOS 27 beta without leaving the status item highlighted.
- Kept the macOS 27 menu bar integration buildable with older Xcode Cloud SDKs.
- Built the project with Apple Swift 6.4.

## 1.0.2

- Fixed the menu bar icon on macOS 27 beta by using the new status item expanded interface path while keeping older macOS behavior unchanged.
- Reworked quota sample iCloud sync to use incremental CloudKit zone changes instead of full-table queries.
- Added CloudKit rate-limit backoff and a `sync paused` status so throttling is no longer reported as a generic sync failure.
- Added bounded remote cleanup for `QuotaSample` records older than the current weekly graph window, including a throttled bridge for records written by earlier builds.

## 0.1

- Added macOS menu bar app with compact power controls.
- Added no-sleep modes for keeping the Mac awake with optional display wake.
- Added automatic closed-lid sleep prevention while awake modes are active.
- Added Codex weekly and 5h usage display.
- Replaced the bundled Codex helper path with native ChatGPT/Codex sign-in and usage reads.
- Added 7-day forecast graph with day sections, deadline marker, and over-limit coloring.
- Added local quota sample history and burst-aware weekly projection.
