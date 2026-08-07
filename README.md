# MixGuideEQ v0.3.0

Rule-driven Auto EQ assistant for Reaper.

## Included in This Pass (3 features)

1. Installer and update flow modeled after MixDeck
2. ReaImGui UI scaffold for track, role, and strength controls
3. Rule profile engine with ReaEQ insertion workflow

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

- Click Update in the MixGuideEQ window to rerun install.lua from the saved installer source folder.
- If your source folder moved, update Installer source folder in the UI and click Save Source.

## Current Behavior

- Analyze: shows role-based starting EQ guidance
- Apply Auto EQ: inserts ReaEQ on the selected track and applies available profile flags supported by current Reaper build

## Planned Next

- Direct, deterministic band parameter writes for ReaEQ across all supported builds
- FFT-based content analysis for rule biasing
- Per-role editable templates and save/load presets
