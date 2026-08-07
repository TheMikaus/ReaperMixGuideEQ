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

## Audio Item Rule

- Tracks are shown once in the role columns; no duplicate list rendering.
- Tracks without audio are still excluded from suggestion/apply target counts.

## Install/Update

- Use the always-visible Install/Update button in the bottom-right of the main window.
- After clicking Update, the current MixGuideEQ window closes so the newly launched script instance can take over.

## Project Role Map Persistence

- Track-to-column assignments are saved per project in:
	- {project folder}/{project name}.mixguideeq.roles
- Move operations auto-save when the project is saved.
- Use Save Project Map and Reload Project Map on the bottom-left of the window for manual control.

## Installer Source

- Installer source folder controls where Update looks for install.lua.
- Use Save Source after changing it.
