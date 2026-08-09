# MixGuideEQ v0.36.2

MixGuideEQ is a Reaper assistant that helps you:

- Map tracks into four practical mix roles (Drums, Guitar, Bass, Vox)
- Generate role-aware EQ suggestions before writing anything
- Analyze and apply profile-based level balancing (Even, Pop, Rock, EDM)
- Keep changes reversible with a one-click level-apply revert snapshot

## Install

1. Open Reaper.
2. Go to Actions > Load ReaScript.
3. Run MixGuideEQ/install.lua.
4. The installer copies files to {Reaper resource path}/Scripts/MixGuideEQ and registers the script action.

## Update

1. Open MixGuideEQ.
2. Click Install/Update (bottom-right).
3. If your source folder moved, set Installer source folder and click Save Source first.

## Flow / Use

1. Map tracks to roles using the four columns.
2. Exclude tracks that should not be processed.
3. Run Analyze Frequency.
4. Generate Suggestions and review per-track cards.
5. Apply Auto EQ when ready.
6. Open Levels tab, pick a balance profile, run Analyze Levels.
7. Review Volume Adjustment Preview at top of each role card.
8. Apply Level Balance, listen, then use Revert Last Level Apply for A/B if needed.

### Expected Project Layout

MixGuideEQ works best when your Reaper project follows a stem-style layout:

- Root folders (top-level tracks) represent major instrument groups.
- Child tracks under each root are parts/layers for that instrument group.
- Typical roots are drums, guitars, bass, and vocals.
- Audio-bearing tracks should be included; utility tracks (click, guides, refs) should usually be excluded.

Example structure:

- Drums (root)
	- Kick In
	- Kick Out
	- Snare Top
	- Overheads L/R
- Guitars (root)
	- Rhythm L
	- Rhythm R
	- Lead
- Bass (root)
	- DI
	- Amp
- Vocals (root)
	- Lead Vox
	- BGV Stack

### How Mapping Into Categories Works

MixGuideEQ maps each track into one of four categories: Drums, Guitar, Bass, Vox.

- Root-level inference:
	- Track/folder names are scanned for keywords.
	- Examples: kick/snare/tom/hat/cym/overhead/room -> Drums; guitar/gtr -> Guitar; bass -> Bass; vox/vocal -> Vox.
- Child inheritance:
	- Child tracks inherit their active root folder role when possible.
- Fallback behavior:
	- If a role cannot be inferred, it falls back to Vox (safe default).
- Manual override:
	- You can move any selected track between columns at any time.
- Exclusion control:
	- Excluded tracks are ignored by suggestion counts, EQ apply, and level apply.

Tip: Do one mapping pass first, then run analysis. If you remap many tracks, re-run Analyze for best results.

## What To Expect In Current Version

- Suggestions are analysis-first and per-track.
- Suggestion cards show the profile used when generated.
- Drum and non-drum tracks both provide track-level suggestion visibility.
- Levels are hierarchical:
	- Child tracks are balanced relative to their root group.
	- Root groups are then balanced against other role groups.
- Pan-aware profile relief affects level recommendations (not pan automation).
- Level apply captures a snapshot for one-click revert.
- Current output is optimized to fit narrower windows with compact wrapped lines.

## Known Scope

- This tool sets static EQ/volume values; it does not automate over time.
- Pan is considered for level recommendation context only.
- Best results come from running analysis after mapping/exclusion is final.

## Technical Details (Appendix)

### Requirements

- Reaper 6+
- ReaPack
- ReaImGui 0.8+

### Project Data

- Role assignments and exclusion flags are persisted per project in:
	- {project folder}/{project name}.mixguideeq.roles
- Installer source state is persisted for update flow resolution.

### Current Technical Feature Log

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
57. Added one-click Revert Last Level Apply with per-apply snapshot capture for A/B safety
58. Levels tab now shows snapshot status (track count, profile, time) to confirm revert availability
59. Added practical profile calibration workflow support through repeatable analyze/apply/revert loop
