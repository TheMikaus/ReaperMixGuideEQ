# MixGuideEQ v0.35.4

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
19. Fixed ReaEQ named config key indexing (BANDTYPE/BANDENABLED now target correct band numbers)
20. Added fallback for ReaEQ variants that reject named band config: recreate default ReaEQ and apply by default slot layout
21. Added per-track Include/Exclude control; excluded tracks are ignored by suggestion counts and Auto EQ apply
22. Added drum-subtype heuristics (kick, snare, toms, overheads, room) for per-track drum EQ decisions
23. Hardened apply lifecycle so Undo begin/end always close cleanly even on runtime errors
24. Added report-only Frequency Analysis panel with per-track metrics and recommendation hints (no auto-write)
25. Fixed Analyze Frequency UI crash by hardening SameLine calls across compatibility paths
26. Redesigned Frequency Analysis output into role cards with per-track metrics and concise recommendations
27. Enforced Analyze-first workflow: Generate Suggestions is gated until analysis is run
28. Added tabbed Results view (Analysis/Suggestions) to keep panel size stable
29. Added ImGui context validation guard to reduce collapse/minimize-related UI crashes
30. Moved Analyze and Generate buttons into their respective Results tabs (Analyze tab and Suggestions tab)
31. Increased analysis and suggestion card heights for better readability in the existing panel size
32. Expanded drum detection and analysis gating sensitivity so hi-hats/crashes are less likely to be skipped
33. Suggestions now incorporate frequency-analysis recommendations when analysis data is available
34. Frequency analysis now runs incrementally with visible progress so UI does not appear frozen
35. Results header now uses true tab controls where supported for clearer Analysis/Suggestions navigation
36. Drum suggestion rendering in Suggestions tab is now per track (kick/snare/toms/hat/cymbal style tracks)
37. Analysis-informed suggestions now state which metric threshold triggered the recommendation
38. Hovering a suggestion card now shows an analysis-evidence tooltip with metrics and trigger context
39. Suggestions cards now show only actionable EQ changes; analysis details moved to hover tooltips
40. Drum suggestion tooltip evidence now resolves per track (GUID-first) instead of role-wide
41. Added Levels tab with profile-based volume analysis (Even, Pop, Rock, EDM)
42. Added hierarchical level recommendations: child-track relative trims inside each root, then root-node trims across roles
43. Added Apply Level Balance action to write static track/root volume trims with safety clamps and exclusion respect
44. Suggestions now render per track for all roles (not just drums) in multi-track sessions
45. Balance profile buttons now show hover tooltips describing each profile goal
46. Changing balance profile no longer clears existing suggestion/level cards; card headers show the profile used for generation
47. Profile tooltips are wider for easier readability of profile intent text
48. Suggestions now meaningfully use profile by adjusting per-role suggestion strength and adding per-track profile level intent hints
49. Profile tooltips now use fixed landscape size constraints to avoid tall-open resize behavior
50. Level analysis now includes pan-aware profile relief so wider-panned tracks can receive profile-specific loudness allowance
51. Levels report now displays pan position and pan-relief contribution per track
52. Added Apply Preview summary showing top predicted boosts/cuts and root moves before level write
53. Hardened profile tooltip rendering against transient invalid ImGui context during hover updates
54. Increased default main window height for better card visibility
55. Levels role cards now include per-column preview highlights (top boost/cut and root move) for tracks in that role
56. Levels per-track output now uses compact wrapped formatting to reduce required window width
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
