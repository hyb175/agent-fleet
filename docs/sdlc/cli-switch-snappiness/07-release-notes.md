---
feature: cli-switch-snappiness
phase: release
status: draft
date: 2026-11-05
---
# CLI switch snappiness — Release notes

## Highlights
- Switching into another workspace no longer waits on agents to repaint. Windows you are not looking at are resized to your terminal in the background, so a switch resizes nothing and Claude's late repaint (up to about 1 s) happens off screen.
- `agent-fleet goto` is about twice as fast: median 29 ms, down from 56 ms (Linux; more on macOS, where each skipped process costs more).

## Changes
### Added
- `scripts/presize.sh`: on `client-attached` and `client-resized`, sizes every window no other client is viewing to the client's size, and sets tmux's `default-size` so agents spawned into other workspaces are created at that size. Bursts of resizes (dragging the terminal edge) are coalesced into one pass. Runs in the background; never delays the client.

### Changed
- `agent-fleet goto` and the focus hook only run the done-acknowledgement (`status.sh clear-done`) when the agent is actually done. Agents detected by screen scraping are acknowledged in the background, after the switch.

### Fixed
- Intermittent lag of up to about a second when switching into a workspace last viewed by a differently sized terminal.

## Upgrade notes
- Run `agent-fleet reload` to register the new hooks.
- The fleet now owns tmux's global `default-size`: it follows the most recent client's size. A hand-set `default-size` is overwritten on the next attach or resize.
- With two differently sized terminals attached at once, each still keeps the other's workspaces at their own size (unchanged from before).

## Internal
- Tests: `tests/t-presize.sh` (unit and the conf-driven attach/resize/switch scenario, including 20 switches with no window resized), `tests/t-presize-clients.sh` (two clients, a nested client, background spawns), `tests/t-goto-fast.sh` (goto skips the done-check unless done; scraped ack under 1 s), a presize case in `tests/t-bash32.sh`.
- Review: 20 findings, 17 fixed, 3 accepted (06-review.md).
- Not yet run: the bash 3.2 case (macOS CI only).
