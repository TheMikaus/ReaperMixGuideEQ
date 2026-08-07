local M = {}

local ctx = nil
local md_ref = nil
local fns = nil

local strength_pct = 100
local install_source_buf = ""
local status_msg = ""
local status_expiry = 0

local suggestion_data = nil
local suggestions_generated = false
local apply_report = "Run Generate Suggestions to enable apply."

local selected_track_guid = nil
local selected_track_role = nil
local request_open_update_popup = false
local show_update_panel_inline = false
local should_close_window = false

local HAS_POPUP_MODAL_API = reaper.APIExists("ImGui_BeginPopupModal") and reaper.APIExists("ImGui_OpenPopup")
local HAS_SETCURSOR_API = reaper.APIExists("ImGui_SetCursorPosX") and reaper.APIExists("ImGui_SetCursorPosY")

local function set_status(msg)
  status_msg = msg
  status_expiry = reaper.time_precise() + 3.0
end

local function title_role(role)
  if role == "drums" then return "Drums" end
  if role == "guitar" then return "Guitar" end
  if role == "bass" then return "Bass" end
  return "Vox"
end

local function get_roles()
  if fns and fns.get_roles_order then
    return fns.get_roles_order()
  end
  return { "drums", "guitar", "bass", "vocals" }
end

local function load_columns()
  if fns and fns.list_role_columns then
    return fns.list_role_columns()
  end
  return { drums = {}, guitar = {}, bass = {}, vocals = {} }
end

local function child_border_flag()
  if reaper.ImGui_ChildFlags_Borders then
    return reaper.ImGui_ChildFlags_Borders()
  end
  if reaper.ImGui_ChildFlags_Border then
    return reaper.ImGui_ChildFlags_Border()
  end
  return 1
end

local function begin_child_any(label, width, height)
  local attempts = {
    function()
      return reaper.ImGui_BeginChild(ctx, label, width, height, child_border_flag())
    end,
    function()
      return reaper.ImGui_BeginChild(ctx, label, width, height, true)
    end,
    function()
      return reaper.ImGui_BeginChild(ctx, label, width, height, true, child_border_flag())
    end,
  }

  for _, fn in ipairs(attempts) do
    local ok, opened = pcall(fn)
    if ok then
      return true, opened
    end
  end

  return false, false
end

local function safe_draw_child(label, width, height, draw_fn)
  local started, opened = begin_child_any(label, width, height)
  if not started then
    reaper.ImGui_Text(ctx, "Unable to render column")
    return
  end

  if opened then
    local ok = pcall(draw_fn)
    if not ok then
      reaper.ImGui_Text(ctx, "Column render error")
    end
  end

  pcall(function()
    reaper.ImGui_EndChild(ctx)
  end)
end

local function refresh_suggestions()
  if fns and fns.build_suggestions then
    suggestion_data = fns.build_suggestions(strength_pct)
    suggestions_generated = true
    set_status("Suggestions generated")
  else
    suggestion_data = nil
    suggestions_generated = false
  end
end

local function draw_track_column(role, items, width, height)
  safe_draw_child(role .. "##track_column", width, height, function()
    reaper.ImGui_Text(ctx, title_role(role) .. "  (" .. tostring(#items) .. ")")
    reaper.ImGui_Separator(ctx)

    for _, item in ipairs(items) do
      local suffix = item.has_audio and "" or " [no audio]"
      local label = item.display_name .. suffix .. "##" .. item.guid
      local is_selected = selected_track_guid == item.guid
      if reaper.APIExists("ImGui_Selectable") then
        if reaper.ImGui_Selectable(ctx, label, is_selected) then
          selected_track_guid = item.guid
          selected_track_role = role
          suggestions_generated = false
        end
      else
        reaper.ImGui_Text(ctx, item.display_name .. suffix)
      end
    end
  end)
end

local function draw_track_columns(columns)
  local roles = get_roles()
  local avail_x, avail_y = reaper.ImGui_GetContentRegionAvail(ctx)
  local spacing = 8
  local total_spacing = spacing * (#roles - 1)
  local width = (avail_x - total_spacing) / #roles
  if width < 180 then width = 180 end
  local height = math.max(120, math.min(170, math.floor(avail_y * 0.28)))

  for idx, role in ipairs(roles) do
    draw_track_column(role, columns[role] or {}, width, height)
    if idx < #roles then
      reaper.ImGui_SameLine(ctx)
    end
  end
end

local function draw_suggestion_column(role, width, height)
  safe_draw_child(role .. "##suggest_column", width, height, function()
    reaper.ImGui_Text(ctx, title_role(role))
    reaper.ImGui_Separator(ctx)

    if not suggestions_generated or not suggestion_data then
      reaper.ImGui_TextDisabled(ctx, "Generate suggestions")
      return
    end

    local row_data = nil
    for _, row in ipairs(suggestion_data.rows or {}) do
      if row.role == role then
        row_data = row
        break
      end
    end

    if not row_data then
      reaper.ImGui_TextDisabled(ctx, "No suggestion data")
      return
    end

    reaper.ImGui_Text(ctx, tostring(row_data.audio_track_count) .. " audio track(s)")
    reaper.ImGui_TextWrapped(ctx, row_data.summary)
    for _, line in ipairs(row_data.lines or {}) do
      reaper.ImGui_TextDisabled(ctx, "- " .. line)
    end
  end)
end

local function draw_suggestion_columns()
  local roles = get_roles()
  local avail_x, avail_y = reaper.ImGui_GetContentRegionAvail(ctx)
  local spacing = 8
  local total_spacing = spacing * (#roles - 1)
  local width = (avail_x - total_spacing) / #roles
  if width < 180 then width = 180 end
  local height = math.max(220, math.min(380, math.floor(avail_y * 0.55)))

  for idx, role in ipairs(roles) do
    draw_suggestion_column(role, width, height)
    if idx < #roles then
      reaper.ImGui_SameLine(ctx)
    end
  end
end

local function draw_move_controls()
  if not selected_track_guid then
    reaper.ImGui_TextDisabled(ctx, "Select a track in any column to move it.")
    return
  end

  reaper.ImGui_Text(ctx, "Move selected track to:")
  local roles = get_roles()
  for _, role in ipairs(roles) do
    if role ~= selected_track_role then
      if reaper.ImGui_Button(ctx, title_role(role) .. "##move_" .. role, 100, 0) then
        local moved, move_msg = fns and fns.move_track_to_role and fns.move_track_to_role(selected_track_guid, role)
        if moved then
          selected_track_role = role
          suggestions_generated = false
          set_status(move_msg or ("Track moved to " .. title_role(role)))
        else
          set_status(move_msg or "Could not move track")
        end
      end
      reaper.ImGui_SameLine(ctx)
    end
  end
  reaper.ImGui_NewLine(ctx)
end

local function draw_bottom_row_controls()
  if not HAS_SETCURSOR_API then
    if reaper.ImGui_Button(ctx, "Save Project Map", 140, 0) then
      local ok, info = fns and fns.save_project_roles and fns.save_project_roles()
      if ok then set_status("Project map saved") else set_status(info or "Could not save project map") end
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Reload Project Map", 145, 0) then
      local ok = fns and fns.load_project_roles and fns.load_project_roles()
      if ok then
        suggestions_generated = false
        set_status("Project map reloaded")
      else
        set_status("No saved project map found")
      end
    end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Install/Update", 120, 0) then
      if HAS_POPUP_MODAL_API then
        request_open_update_popup = true
      else
        show_update_panel_inline = not show_update_panel_inline
      end
    end
    return
  end

  local cur_y = reaper.ImGui_GetCursorPosY(ctx)
  local _, avail_y = reaper.ImGui_GetContentRegionAvail(ctx)
  local y = cur_y + math.max(0, avail_y - 24)

  reaper.ImGui_SetCursorPosX(ctx, 8)
  reaper.ImGui_SetCursorPosY(ctx, y)

  if reaper.ImGui_Button(ctx, "Save Project Map", 140, 0) then
    local ok, info = fns and fns.save_project_roles and fns.save_project_roles()
    if ok then set_status("Project map saved") else set_status(info or "Could not save project map") end
  end

  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Reload Project Map", 145, 0) then
    local ok = fns and fns.load_project_roles and fns.load_project_roles()
    if ok then
      suggestions_generated = false
      set_status("Project map reloaded")
    else
      set_status("No saved project map found")
    end
  end
  local avail_x, _ = reaper.ImGui_GetContentRegionAvail(ctx)
  local left_width = 140 + 145 + 8
  local x = math.max(8 + left_width + 16, 8 + math.max(0, avail_x - 120))
  reaper.ImGui_SetCursorPosX(ctx, x)
  reaper.ImGui_SetCursorPosY(ctx, y)

  if reaper.ImGui_Button(ctx, "Install/Update", 120, 0) then
    if HAS_POPUP_MODAL_API then
      request_open_update_popup = true
    else
      show_update_panel_inline = not show_update_panel_inline
    end
  end
end

local function draw_update_popup()
  if not HAS_POPUP_MODAL_API then
    if not show_update_panel_inline then return end

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, "Install/Update")
    reaper.ImGui_Text(ctx, "Installer source folder")
    local src_changed, src_value = reaper.ImGui_InputText(ctx, "##install_source_inline", install_source_buf)
    if src_changed then install_source_buf = src_value end

    if reaper.ImGui_Button(ctx, "Save Source##inline", 110, 0) then
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
    if reaper.ImGui_Button(ctx, "Update##inline", 90, 0) then
      local launched = fns and fns.run_installer and fns.run_installer()
      if launched then
        set_status("Installer finished. Closing this window.")
        should_close_window = true
      else
        set_status("Installer failed. Check Reaper console.")
      end
    end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Hide##inline", 90, 0) then
      show_update_panel_inline = false
    end
    return
  end

  if request_open_update_popup then
    reaper.ImGui_OpenPopup(ctx, "Install/Update##popup")
    request_open_update_popup = false
  end

  local visible = reaper.ImGui_BeginPopupModal(ctx, "Install/Update##popup", true)
  if not visible then return end

  reaper.ImGui_Text(ctx, "Installer source folder")
  local source_changed, source_value = reaper.ImGui_InputText(ctx, "##install_source", install_source_buf)
  if source_changed then install_source_buf = source_value end

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
    local launched = fns and fns.run_installer and fns.run_installer()
    if launched then
      set_status("Installer finished. Closing this window.")
      should_close_window = true
    else
      set_status("Installer failed. Check Reaper console.")
    end
  end

  reaper.ImGui_SameLine(ctx)
  if reaper.ImGui_Button(ctx, "Close", 90, 0) then
    reaper.ImGui_CloseCurrentPopup(ctx)
  end

  reaper.ImGui_EndPopup(ctx)
end

function M.init(md, functions)
  md_ref = md
  fns = functions
  install_source_buf = (md_ref and md_ref.install_source_dir) or ""
  ctx = reaper.ImGui_CreateContext("MixGuideEQ")
end

function M.loop()
  if not ctx then return false end

  if reaper.ImGui_SetNextWindowSize then
    local cond = reaper.ImGui_Cond_FirstUseEver and reaper.ImGui_Cond_FirstUseEver() or 0
    reaper.ImGui_SetNextWindowSize(ctx, 1600, 800, cond)
  end

  local title = "MixGuideEQ v" .. tostring(md_ref.version or "")
  local visible, open = reaper.ImGui_Begin(ctx, title, true)

  if visible then
    reaper.ImGui_TextWrapped(ctx, "Single-panel workflow: map tracks, generate suggestions, then apply.")
    reaper.ImGui_Separator(ctx)

    local changed_strength, new_strength = reaper.ImGui_SliderInt(ctx, "Suggestion Strength %", strength_pct, 0, 150)
    if changed_strength then
      strength_pct = new_strength
      suggestions_generated = false
    end

    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Generate Suggestions", 160, 0) then
      refresh_suggestions()
    end

    reaper.ImGui_Spacing(ctx)
    local columns = load_columns()
    draw_track_columns(columns)

    reaper.ImGui_Spacing(ctx)
    draw_move_controls()

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_TextWrapped(ctx, "Suggestions by role (displayed below matching columns).")
    reaper.ImGui_Spacing(ctx)
    draw_suggestion_columns()

    if suggestions_generated and suggestion_data then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Text(ctx, "Audio tracks used for suggestions: " .. tostring(suggestion_data.total_audio_tracks or 0))
      reaper.ImGui_TextWrapped(ctx, apply_report)
      reaper.ImGui_Spacing(ctx)
      if reaper.ImGui_Button(ctx, "Apply Auto EQ", 140, 0) then
        if fns and fns.apply_mapped_roles then
          local ok, summary, errors = fns.apply_mapped_roles(strength_pct)
          apply_report = summary or "Apply completed"
          if errors and #errors > 0 then
            apply_report = apply_report .. "\n" .. table.concat(errors, "\n")
          end
          if ok then
            set_status("Auto EQ applied")
          else
            set_status(summary or "Apply failed")
          end
        end
      end
    else
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_TextDisabled(ctx, "Run Generate Suggestions to enable Apply.")
    end

    draw_bottom_row_controls()
    draw_update_popup()

    if status_msg ~= "" and reaper.time_precise() < status_expiry then
      reaper.ImGui_Text(ctx, status_msg)
    end
  end

  reaper.ImGui_End(ctx)

  if should_close_window then
    should_close_window = false
    return false
  end

  if not open then
    return false
  end

  return true
end

return M
