# MixGuideEQ v0.19.0

Rule-driven Auto EQ assistant for Reaper.

## Included in This Pass (11 features)

1. Installer and update flow modeled after MixDeck
2. Rule profile engine with ReaEQ insertion workflow
3. Hierarchical track mapper for root instrument tracks and child parts
4. Four-column role assignment workflow (Drums, Guitar, Bass, Vox) with move-between-columns controls
5. Suggestions/apply workflow that excludes tracks without audio items from counts and apply targets
6. Per-project persistence for role-column assignments with save/reload controls
7. ReaImGui compatibility fallbacks and updater source-priority fix
8. Single-panel UI with audio-only columns, suggestions below columns, and Generate-gated Apply
9. Fixed duplicate track rendering by drawing track columns once and suggestion panels separately per role
10. Window/layout improvements: +100px height, project-map controls bottom-left, updater closes old window after launch
11. Apply now writes concrete role-based ReaEQ band settings (HPF + frequency/gain/Q moves)
12. Fixed normalized parameter mapping so frequency/gain/Q values apply reliably on 0..1 plugin parameter ranges
13. Added strict and fallback ReaEQ param targeting (band+name, loose match, nth-kind fallback) for better cross-build value writes
14. Suggestions now show the exact HPF + move set that Apply writes (one-to-one alignment)
15. Apply now resolves EQ parameter targets by deterministic per-band mapping, removing loose fallback mismatches
16. Added detailed apply debug logging (param map, writes, readbacks) with log path in result summary
17. Log-guided fix for ReaEQ parameter layouts with non-Band naming (positional fallback for first 15 params)
18. Fixed BANDTYPE writes to use numeric ReaEQ type codes (HP/Band/HighShelf now map correctly)
11. Layout refinement: +300px height, bottom row alignment for Save/Reload/Install, and taller suggestion panels

## Requirements

- Reaper 6+
- ReaPack
- ReaImGui 0.8+

## Install

1. Open Reaper
2. Actions > Load ReaScript
3. Run MixGuideEQ/install.lua
4. The installer copies files to {Reaper resource path}/Scripts/MixGuideEQ and registers the action

## Update

- Click Install/Update (bottom-right in the main window) to rerun install.lua from the saved installer source folder.
- If your source folder moved, update Installer source folder in the UI and click Save Source.

## Current Behavior

- Single-panel layout (no tabs): mapping, suggestions, and apply in one flow
- Columns show all mapped tracks once (no duplicate A-Z/A-Z listing)
- Child tracks are displayed as Parent-Child in columns
- Suggestions are displayed below their matching role columns
- Apply Auto EQ appears only after Generate Suggestions is run
- Install/Update button is always visible in the bottom-right of the main window
- Role assignments persist per saved Reaper project in {project folder}/{project name}.mixguideeq.roles
- Update prioritizes the saved installer source path before fallback locations

## Planned Next

- Direct, deterministic band parameter writes for ReaEQ across all supported builds
- FFT-based content analysis for rule biasing
- Per-role editable templates and save/load presets
