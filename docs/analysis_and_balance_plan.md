# Frequency Analysis and Auto-Balance Plan

## Goal
Add two optional, data-driven workflows on top of role presets:
1. Frequency-analysis EQ recommendations
2. Automatic track volume balancing

## Scope Boundaries
- Keep current role-based preset flow as default and fast path.
- New workflows must be opt-in, explainable, and reversible.
- Never touch excluded tracks.

## 1) Frequency-Analysis EQ Workflow

### Signal Collection
- For each included track with audio items, render analysis windows across the audible timeline.
- Prefer fixed-size FFT windows with overlap (for example 4096-point with 50% overlap).
- Use energy averaging in log-frequency bins (roughly octave or 1/3-octave style buckets).
- Skip near-silence windows via RMS gate.

### Per-Track Spectral Profile
- Compute per-track median spectrum (more robust than mean for transients).
- Store:
  - low-band energy (20-120 Hz)
  - low-mid energy (120-500 Hz)
  - presence energy (2-5 kHz)
  - air energy (8-14 kHz)
  - spectral centroid

### Role Target Curves
- For each role, define target profile ranges, not single values.
- Compare measured profile to role range and derive deltas.
- Convert deltas to at most 3 moves (+ HPF) with safety clamps:
  - gain clamp: +/-4 dB
  - Q clamp: 0.7 to 2.0
  - frequency snap to musically stable ranges

### Overlap Guardrails
- Detect masking between pairs (for example guitar vs vocals around 2-4 kHz).
- If two tracks occupy same hot zone, split corrective action conservatively:
  - small cut on masker
  - optional small boost on target
- Cap cumulative EQ change per track.

### UX
- Add an "Analyze" action before "Apply".
- Show "why" lines per move:
  - measured value
  - target range
  - chosen correction
- Keep manual strength slider as multiplier on computed deltas.

## 2) Auto-Volume Balance Workflow

### Loudness Metrics
- For each included track, compute short-term loudness proxy and peak statistics.
- Baseline option: RMS/LUFS-like approximation per active window.
- Aggregate to representative track loudness using median of active windows.

### Role-Based Balance Targets
- Define target offsets by role relative to a reference stem mix point.
- Example concept:
  - vocals near reference
  - bass slightly below vocals
  - guitars variable by density
  - drums role-dependent

### Gain Recommendation Engine
- Compute required trim in dB from current median loudness to target offset.
- Clamp adjustment range (for example +/-8 dB absolute, +/-3 dB per pass).
- Preserve headroom by checking projected master sum peaks.

### Safety and Stability
- Multi-pass strategy:
  - pass 1: coarse alignment
  - pass 2: optional refinement
- Never automate faders directly by default; write static trim values first.
- Offer dry-run report and apply confirmation.

### UX
- Add "Analyze Levels" and "Apply Level Balance".
- Report per-track:
  - current loudness
  - target
  - proposed gain delta
- Respect exclusions and no-audio tracks exactly like EQ flow.

## Data Model Additions
- Persist exclusion flags (already implemented).
- Add optional cached analysis snapshot keyed by project hash + track GUID + item edits.
- Invalidate cache when media items, item gain, or FX chain changes.

## Implementation Phases
1. Analysis scaffolding and data model
2. Frequency analysis report-only mode
3. Frequency EQ recommendation apply mode
4. Loudness analysis report-only mode
5. Auto-balance apply mode
6. Integrated review panel and one-click apply pipeline

## Testing Plan
- Unit tests for mapping metrics to moves and gain deltas.
- Regression tests for exclusion handling in all flows.
- Golden-case sessions: sparse acoustic, dense rock, dialog-heavy mix.
- Verify deterministic output for unchanged sessions.

## Logging
- Add separate log file for analysis decisions:
  - measured metrics
  - target bounds
  - selected actions
- Keep apply log focused on final writes/readbacks.
