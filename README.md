# MixGuideEQ v0.46.3

> **Status: the EQ stage is not ready.** Mapping, pan and level balancing are in
> usable shape. Auto EQ is still producing mixes that come out too quiet, across
> several rounds of fixes, and the current apply should be treated as a work in
> progress rather than something to run on a mix you care about. What it writes
> is reversible, and every apply logs its plan and the level each track had
> before and after to `mixguideeq_analysis.log`.

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

The window is one stage at a time, in the order the work happens. A strip across
the top shows all four with their state, and you can click any of them to jump.

| Stage | What it does | State shown |
|---|---|---|
| 1 Map | Put each track in a role column, exclude non-musical tracks | `done` once tracks are found |
| 2 EQ | Analyse, review suggestions, apply | — |
| 3 Pan | Place tracks across the stereo image | `done` after apply |
| 4 Balance | Set how loud each track sits | `done` after apply, `redo` if EQ is applied again afterwards |

EQ comes before Balance deliberately. EQ decisions here are level-independent —
band shares are normalised by total energy — but EQ *changes* level. So
EQ-then-levels settles in one pass, where levels-then-EQ always needs a
re-balance afterwards. Pan sits between them because placement shifts perceived
level too, which leaves Balance to settle everything last.

The profile picker sits above the strip because it drives all three of Balance,
Pan and EQ. Each stage ends with a "Next:" line telling you where to go.

There is no fifth stage for a re-balance: going back and re-applying EQ marks
**4 Balance** as `redo` instead, which makes the loop back obvious.

1. Map tracks to roles using the four columns.
2. Exclude tracks that should not be processed.
3. Run Analyze Frequency.
4. Open the Levels tab, pick a profile, run Analyze Levels.
5. Review the Volume Adjustment Preview at the top of each role card.
6. Apply Level Balance, listen, then use Revert Last Level Apply for A/B if needed.
6a. Run Analyze Pan to see the planned stereo placement, then Apply Pan Placement.
    Leave "Override existing pans" off to keep positions you set yourself; tick it
    to let the profile place everything. Revert Last Pan Apply restores either way.
7. Back on the Suggestions tab, Generate Suggestions and review the per-track cards.
   Each move shows the band it corrects, the measured value, and the target.
8. Apply Auto EQ when ready.
9. EQ changes level, so re-run Analyze Levels and Apply Level Balance to settle
   the mix. The EQ decisions themselves are level-independent, so this second
   balance pass does not invalidate them.

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
60. Fixed frequency analysis sampling: probes at 7 kHz and 10 kHz were above the Nyquist limit of the 11.025 kHz analysis rate, so they reported mirrored low-mid energy as "air" while real high-frequency content was filtered out entirely; analysis now runs at 44.1 kHz
61. Added a Hann window to the analysis, replacing the rectangular window that smeared loud low-frequency energy across every probe
62. Raised the near-silence gate to about -80 dBFS so bleed and noise floor no longer generate EQ recommendations
63. Level-apply snapshots now persist to {project name}.mixguideeq.levels, so Revert survives closing and reopening the window
64. Apply Level Balance now refuses to run while an unreverted apply is outstanding, since trims stack multiplicatively and the earlier apply would become unrecoverable
65. Role keyword matching now uses whole words, so tracks like "Custom Bus", "Bathroom Verb" and "That Take" are no longer classified as drums
66. Drums now win keyword ties, so "Bass Drum" maps to Drums instead of Bass
67. Role assignments now follow the active project tab: switching projects flushes the outgoing role map and loads the incoming one instead of pruning the map to empty
68. Role map files are written in sorted order for stable diffs
69. ReaEQ insertion now attempts both instantiate conventions, so a track with no existing ReaEQ gets one inserted instead of failing the apply
70. The named-band-config probe no longer leaves band 1 converted to a bell filter as a side effect
71. Added a mock-Reaper test suite that runs the real Lua sources outside Reaper
72. Genre profiles now carry band targets: a per-role target spectral shape, separate from the level offsets, so a genre describes both how loud a role sits and what shape it has
73. EQ intensity is no longer derived from the level offset; that coupling inverted every corrective cut, so Rock carved more mud out of guitars than EDM did
74. EQ moves are now computed as measured-minus-target on the analyzer's own bands, with the reason for each move shown on the suggestion card
75. Suggestions and Apply now share one plan builder, restoring the guarantee that Apply writes exactly what the cards show (they had diverged whenever analysis data existed)
76. Band shares are normalised by total energy, so EQ decisions are independent of fader position and the level stage cannot perturb them
77. Reference and target shapes are renormalised, so hand-written tables cannot introduce a constant bias and "boost every band" correctly means "no change"
78. Applying Auto EQ now invalidates the frequency and level reports and prompts a re-balance, since EQ changes a track's overall level
79. Level offsets widened to audible ranges and sub-0.5 dB moves are no longer written
80. Added stereo placement: the Levels stage now plans and applies pan positions alongside volume trims
81. Pan rules follow the conventional centre column (kick, snare, bass, lead vocal never panned) with everything else placed against a partner
82. Double-tracked sources are detected by name ("Rhythm L"/"Rhythm R", "Gtr 1"/"Gtr 2") and placed on opposite sides; an unpaired source is left alone rather than guessed at
83. Toms are spread across the image by position instead of being paired
84. Each genre carries pan_targets, so Rock spreads doubled guitars hard while Pop and EDM keep a tighter image
85. Added an "Override existing pans" checkbox: off by default, so a track you have already placed keeps its position
86. Stereo tracks are reported and skipped rather than panned, since D_PAN on a stereo track is a balance control
87. Pan apply captures a snapshot to {project name}.mixguideeq.pans for one-click revert, and refuses to run twice without a revert
88. Fixed stereo detection: pan used I_NCHAN, which is 2 on essentially every Reaper track whatever the media is, so nearly everything was reported "stereo: skipped"; it now reads the source's channel count
89. Fixed non-convergent root level trims: the delta was computed from the children's faders but written to the root folder, whose own fader was never accounted for, so re-balancing after EQ added the whole role offset again and the mix got quieter every pass
90. Save/Reload/Install and the status line are now pinned to the bottom of the window instead of scrolling away
91. Revert buttons only appear when there is a snapshot to revert
92. Rebuilt the window around ordered stages (Map, Balance, Pan, EQ) with a state strip, replacing tabs named after content
93. Each stage now owns its own analyze/apply/revert, so Apply Auto EQ no longer sits outside the tab system
94. Added a UI debug log flushed on the first error, with a ReaImGui environment header
95. Level balance now works from measured loudness instead of fader positions; the old model compared faders against a reference that was itself the median of those faders, so every trim moved the reference and each pass cut guitar and bass further
96. The anchor is the vocals' measured source level, a property of the audio, so it is the same number on every pass regardless of what the balance has already done
97. Trims are written to the audio tracks only; folder roots are left alone, removing the double move that came from writing both a per-track and a root trim
98. The plan is an absolute target fader rather than a relative nudge, so applying it twice lands in the same place
99. Whether the audio accessor reads before or after the fader is now probed at runtime rather than assumed, since builds differ and guessing wrong makes the balance either compound or oscillate
100. Analyze Levels now measures gated average and max loudness per track, following EBU R128's two-stage gate so silence and gaps do not drag a sparse track's average down
101. Levels are reported as a ranked list, loudest at the top, with values relative to the loudest track and an indication of which tracks need to move up or down the ranking
102. Stereo sources are measured as mono, so tracks are compared on equal terms
103. Level moves are zero-meaned, so the stage balances tracks against each other instead of attenuating the whole mix toward its quietest element
104. Added an analysis log written to {Reaper resource path}/Scripts/MixGuideEQ/mixguideeq_analysis.log, recording what each stage measured and why it decided what it did
105. Added a clip guard: if the balanced mix is predicted to exceed -1 dBFS, the excess comes off every move equally so headroom is recovered without disturbing the balance
106. Analyze Levels and Analyze Pan now revert the previous application first, so a measurement is always taken of the untouched mix
107. Corrected tom panning from up to 70% to the conventional 15-30%
108. Hi-hats, single cymbal spots and percussion are now placed on a side; they were grouped with overheads, which are placed as a pair, so they waited for a partner that never came and stayed centred
109. Percussion names now map to the Drums role instead of falling through to Vox
110. Added a preview control: type a bar number and play from there
111. The EQ-applied flag now persists to {project name}.mixguideeq.state, so the re-balance prompt survives a restart
112. Apply Auto EQ now measures each track before and after and reports any track that loses more than 6 dB to its own EQ
113. Reordered the stages to Map, EQ, Pan, Balance. EQ decisions are level-independent but EQ changes level, so running it before the balance settles the mix in one pass instead of requiring a re-balance
114. Roles are now balanced by their combined level rather than track by track. Per-track balancing is count-weighted, so an eight-mic kit pulled the plan eight times while a lead vocal pulled once and the vocal ended up measured against a single drum mic instead of the kit that competes with it
115. Profile offsets now place the lead vocal at or near the top of the ranking in every genre; it was previously targeted below the drums
116. Analyzing a stage now undoes every stage after it, so a measurement is always taken of a mix the later stages have not moved: Analyze Frequency undoes pan and levels, Analyze Pan undoes levels
117. EQ frequencies are now calibrated against the plugin's own formatted readout instead of an assumed 20 Hz-24 kHz logarithmic scale. On a plugin with a different curve the old assumption put a 25 Hz high-pass near 1.4 kHz, which removed most of what a guitar, vocal or snare has - the reason those tracks became inaudible after an apply
118. Apply Auto EQ now runs across frames with a progress readout instead of blocking the window
119. The post-apply level check uses a coarse measurement, since it only has to notice a large loss
120. Every EQ parameter is now written through the plugin's own scale, not an assumed one: gain is calibrated against the formatted dB readout and each write is placed inside the range the plugin reports, instead of a -24..+24 dB guess clamped to 0..1
121. The EQ stage is level neutral. What the filters cost a track is measured either side of the write - with the EQ bypassed for the before reading, so a second pass still sees it - and handed straight back on the fader, bounded to 9 dB and undone with the rest of the EQ stage
122. A track losing more than 3 dB to its EQ is named in the apply summary even though the level came back, so makeup gain cannot hide a filter landing in the wrong place
123. The Preview bar number is remembered per project instead of resetting to 1 on every panel open
124. Analyze Frequency now actually performs the revert that feature 116 describes. The Levels and Pan buttons undid the stages after them; the EQ one never did, so a re-analysis measured a mix still carrying this panel's pan, level and makeup moves
125. Apply Level Balance logs every fader it writes - what the plan asked for, the fader before and after, what was actually achieved, and a CLAMPED marker when the write could not take the whole move. A track landing wrong can now be traced to the plan or to the write, which need opposite fixes
126. Analysis log sections nest, so one operation leaves one log. Apply Level Balance re-measures afterwards, and that pass used to overwrite the plan that produced the moves - leaving only the post-apply reading, the least useful of the three
