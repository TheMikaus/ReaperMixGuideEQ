# MixGuideEQ Usage

## Launch

1. Install with install.lua
2. Open Actions list in Reaper
3. Search for MixGuideEQ
4. Run the action

## UI Workflow

1. Single panel layout (no tabs): columns at top, suggestions below
2. Review four columns (Drums, Guitar, Bass, Vox)
3. Select a track in a column and move it to another column
4. Child tracks are displayed as Parent-Child
5. Set Suggestion Strength % and click Generate Suggestions
6. Suggestions are displayed below the matching role column
7. Apply Auto EQ appears after suggestions are generated
8. After apply completes, the window shows an "Operation done" status line
9. Apply writes role-based EQ values with normalized parameter mapping for ReaEQ builds that expose 0..1 params
10. Apply now uses fallback param targeting when exact band-name lookups differ between ReaEQ builds
11. Suggestion lines now mirror the exact moves that Apply writes to ReaEQ
12. Apply targets band parameters using deterministic per-band mapping to avoid cross-band value mismatches
13. Apply summary now includes the debug log file path for parameter-write diagnostics
14. ReaEQ layouts without explicit "Band N" labels now use positional fallback mapping for Freq/Gain/BW triplets
15. ReaEQ band filter types now write via numeric BANDTYPE codes for reliable HP/Bell/Shelf assignment
16. ReaEQ BANDTYPE/BANDENABLED named config writes now use 1-based band key indexing
17. If named band config writes are unsupported, Apply rebuilds ReaEQ and writes to default slot layout (band5 HPF, band2/3/4 moves)
18. Selected tracks can be toggled Include/Exclude from EQ; excluded tracks are ignored by suggestions and apply
19. Drum tracks now use subtype-aware heuristics (kick/snare/toms/overheads/room) when names match subtype keywords
20. Apply execution now protects Undo begin/end lifecycle with guaranteed close behavior

## Audio Item Rule

- Tracks are shown once in the role columns; no duplicate list rendering.
- Tracks without audio are still excluded from suggestion/apply target counts.

## Install/Update

- Use the always-visible Install/Update button in the bottom-right of the main window.
- After clicking Update, the current MixGuideEQ window closes so the newly launched script instance can take over.

## Project Role Map Persistence

- Track-to-column assignments are saved per project in:
	- {project folder}/{project name}.mixguideeq.roles
- Exclude/include state is saved in the same role map file
- Move operations auto-save when the project is saved.
- Use Save Project Map and Reload Project Map on the bottom-left of the window for manual control.

## Installer Source

- Installer source folder controls where Update looks for install.lua.
- Use Save Source after changing it.
