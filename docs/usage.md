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
21. Analyze Frequency generates a read-only per-track report (metrics + suggested moves) and does not change EQ
22. Frequency report is shown as role-based analysis cards (not a raw linear list)
23. Analyze Frequency UI path now uses guarded layout calls for better ImGui compatibility stability
24. Generate Suggestions is available only after Analyze Frequency has run
25. Results area is tabbed (Analysis first, Suggestions second) to avoid panel overgrowth
26. Analyze button is on the Analysis tab; Generate Suggestions button is on the Suggestions tab
27. Frequency and suggestion cards are taller for easier per-track review
28. Suggestions prefer analysis-informed recommendation lines when frequency analysis data exists
29. Analyze Frequency now shows in-progress state and percent complete while it runs
30. Results tab headers use real tab controls where available for clearer mode switching
31. Drum suggestions are presented per track in the Suggestions tab
32. Analysis-informed suggestions now explain which metric triggered each recommendation
33. Hover a Suggestions card to view analysis evidence tooltip (metrics + recommendation trigger context)
34. Suggestions card body now lists only proposed EQ changes (analysis evidence moved to hover tooltips)
35. Drum suggestion tooltip evidence is shown per track (hover drum track label)
36. Levels tab adds profile-based volume analysis (Even, Pop, Rock, EDM)
37. Volume analysis is hierarchical: track-relative balancing inside each root group, then root-node balancing across roles
38. Apply Level Balance writes static child/root trims with safeguards and skips excluded roots/tracks
39. Suggestions render per track for all roles when multiple tracks exist in a role column
40. Hover any balance profile button to see what that profile is trying to emphasize
41. Changing balance profile keeps current cards visible; suggestion card headers show the profile used to generate them
42. Profile tooltips use a wider wrap width for clearer explanation text
43. Suggestions now adapt to the selected profile via per-role suggestion strength scaling and profile level-intent hints
44. Profile tooltips now open with a fixed landscape shape (no tall-first resize jump)
45. Level balancing is pan-aware by profile; wider-panned tracks can receive profile-specific relief
46. Levels cards now show per-track pan value and pan-relief amount used in the recommendation
47. Levels tab now shows an Apply Preview block (largest predicted boosts/cuts and root moves) before applying
48. Profile hover tooltip rendering is now guarded against invalid-context hover edge cases
49. Default window first-open height is taller for improved multi-card visibility
50. Each Levels role card now includes preview highlights for that role (top boost/cut and root move)
51. Levels result lines are now compact/wrapped to reduce horizontal space needs
52. Revert Last Level Apply restores pre-apply track volumes from a captured snapshot
53. Levels tab displays snapshot availability/status so you can confirm revert readiness
54. Recommended calibration loop: Analyze Levels -> Apply Level Balance -> listen -> Revert -> tweak profile -> repeat

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
