local M = {}

local ctx = nil
local md_ref = nil
local fns = nil

local selected_track_idx = 0
local selected_role_idx = 0
local strength_pct = 100
local install_source_buf = ""
local status_msg = ""
local status_expiry = 0
local analysis_summary = "Choose a track and role, then click Analyze."

local function set_status(msg)
  status_msg = msg
  status_expiry = reaper.time_precise() + 3.0
end

local function build_items(values)
  local out = ""
  for _, v in ipairs(values) do
    out = out .. v .. "\0"
  end
  return out
end

local function get_roles()
  if fns and fns.get_roles then
    return fns.get_roles()
  end
  return { "vocals", "bass", "drums", "guitar" }
end

local function get_tracks()
  if fns and fns.get_track_names then
    return fns.get_track_names()
  end
  return {}
end

function M.init(md, functions)
  md_ref = md
  fns = functions
  install_source_buf = (md_ref and md_ref.install_source_dir) or ""
  ctx = reaper.ImGui_CreateContext("MixGuideEQ")
end

function M.loop()
  if not ctx then return false end
  local title = "MixGuideEQ v" .. tostring(md_ref.version or "")
  local visible, open = reaper.ImGui_Begin(ctx, title, true)

  if visible then
    reaper.ImGui_TextWrapped(ctx, "Rule-based Auto EQ helper: picks starting moves and inserts ReaEQ on demand.")
    reaper.ImGui_Separator(ctx)

    local tracks = get_tracks()
    if #tracks == 0 then
      reaper.ImGui_Text(ctx, "No tracks found in current project.")
    else
      if selected_track_idx > (#tracks - 1) then
        selected_track_idx = 0
      end

      reaper.ImGui_Text(ctx, "Track")
      local track_items = build_items(tracks)
      local changed_track, new_track_idx = reaper.ImGui_Combo(ctx, "##track_combo", selected_track_idx, track_items)
      if changed_track then
        selected_track_idx = new_track_idx
      end

      local roles = get_roles()
      if selected_role_idx > (#roles - 1) then
        selected_role_idx = 0
      end

      reaper.ImGui_Text(ctx, "Role")
      local role_items = build_items(roles)
      local changed_role, new_role_idx = reaper.ImGui_Combo(ctx, "##role_combo", selected_role_idx, role_items)
      if changed_role then
        selected_role_idx = new_role_idx
      end

      local changed_strength, new_strength = reaper.ImGui_SliderInt(ctx, "Strength %", strength_pct, 0, 150)
      if changed_strength then
        strength_pct = new_strength
      end

      if reaper.ImGui_Button(ctx, "Analyze", 110, 0) then
        local role_name = roles[selected_role_idx + 1]
        local ok, summary = fns.analyze_track(selected_track_idx, role_name, strength_pct)
        if ok then
          analysis_summary = summary
          set_status("Analysis updated")
        else
          set_status(summary or "Analysis failed")
        end
      end

      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Apply Auto EQ", 130, 0) then
        local role_name = roles[selected_role_idx + 1]
        local ok, message = fns.apply_role_to_track(selected_track_idx, role_name, strength_pct)
        if ok then
          set_status(message or "Applied")
        else
          set_status(message or "Apply failed")
        end
      end
    end

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_TextWrapped(ctx, analysis_summary)

    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, "Installer source folder")
    local source_changed, source_value = reaper.ImGui_InputText(ctx, "##install_source", install_source_buf)
    if source_changed then
      install_source_buf = source_value
    end

    if reaper.ImGui_Button(ctx, "Save Source", 100, 0) then
      if install_source_buf ~= "" and fns and fns.set_install_source_dir then
        local saved = fns.set_install_source_dir(install_source_buf)
        if saved then
          md_ref.install_source_dir = fns.get_install_source_dir()
          install_source_buf = md_ref.install_source_dir or install_source_buf
          set_status("Installer source saved")
        else
          set_status("Failed to save installer source")
        end
      else
        set_status("Enter an installer source folder first")
      end
    end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Update", 90, 0) then
      local launched = fns.run_installer()
      if launched then
        set_status("Installer finished. Relaunch MixGuideEQ from Actions.")
      else
        set_status("Installer failed. Check Reaper console.")
      end
    end

    if status_msg ~= "" and reaper.time_precise() < status_expiry then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Text(ctx, status_msg)
    end
  end

  reaper.ImGui_End(ctx)

  if not open then
    return false
  end
  return true
end

return M
