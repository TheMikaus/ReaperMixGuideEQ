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
local freq_report = nil
local volume_report = nil
local volume_profile = "Even"
local level_apply_report = "Run Analyze Levels to preview level balance."
local active_results_tab = "analysis"
local analyze_in_progress = false
local analyze_progress_pct = 0
local operation_done_msg = ""

local selected_track_guid = nil
local selected_track_role = nil
local request_open_update_popup = false
local show_update_panel_inline = false
local should_close_window = false

local HAS_POPUP_MODAL_API = reaper.APIExists("ImGui_BeginPopupModal") and reaper.APIExists("ImGui_OpenPopup")
local HAS_SETCURSOR_API = reaper.APIExists("ImGui_SetCursorPosX") and reaper.APIExists("ImGui_SetCursorPosY")
local HAS_TABBAR_API = reaper.APIExists("ImGui_BeginTabBar") and reaper.APIExists("ImGui_BeginTabItem")

local function set_status(msg)
  status_msg = msg
  status_expiry = reaper.time_precise() + 3.0
end

local function has_valid_ctx()
  if not ctx then
    return false
  end
  if reaper.ImGui_ValidatePtr then
    local ok, valid = pcall(function()
      return reaper.ImGui_ValidatePtr(ctx, "ImGui_Context*")
    end)
    if ok then
      return valid == true
    end
  end
  return true
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

local function get_volume_profiles()
  if fns and fns.get_volume_profiles then
    local profiles = fns.get_volume_profiles()
    if profiles and #profiles > 0 then
      return profiles
    end
  end
  return { "Even", "Pop", "Rock", "EDM" }
end

local function fmt_db(v)
  return string.format("%+.2f dB", tonumber(v) or 0)
end

local PROFILE_DESCRIPTIONS = {
  Even = {
    "Balanced stems with moderate role separation.",
    "Use when you want neutral, steady role balance.",
    "Pan-aware level relief is subtle.",
  },
  Pop = {
    "Vocals forward, controlled low-end and guitars.",
    "Use when lead clarity and lyric focus are priority.",
    "Pan-aware relief stays conservative to keep center focus.",
  },
  Rock = {
    "Punchy drums and guitars, vocals slightly tucked.",
    "Use when rhythm energy should feel more aggressive.",
    "Pan-aware relief is stronger for wider guitar/drum placement.",
  },
  EDM = {
    "Low-end and vocal focus with lean mids.",
    "Use when kick/bass impact should carry the mix.",
    "Pan-aware relief supports wide side elements.",
  },
}

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

local function safe_same_line()
  if not has_valid_ctx() then
    return false
  end
  local ok = pcall(function()
    reaper.ImGui_SameLine(ctx)
  end)
  return ok
end

local function begin_tooltip_any()
  if not has_valid_ctx() then return false end
  if not reaper.APIExists("ImGui_BeginTooltip") then return false end
  local ok, opened = pcall(function()
    return reaper.ImGui_BeginTooltip(ctx)
  end)
  return ok and opened
end

local function end_tooltip_any()
  if not has_valid_ctx() then return end
  if not reaper.APIExists("ImGui_EndTooltip") then return end
  pcall(function()
    reaper.ImGui_EndTooltip(ctx)
  end)
end

local function is_last_item_hovered()
  if not has_valid_ctx() then return false end
  if not reaper.APIExists("ImGui_IsItemHovered") then return false end
  local ok, hovered = pcall(function()
    return reaper.ImGui_IsItemHovered(ctx)
  end)
  return ok and hovered == true
end
local function begin_profile_tooltip()
  if not has_valid_ctx() then return false end
  if reaper.APIExists("ImGui_SetNextWindowSizeConstraints") then
    pcall(function()
      reaper.ImGui_SetNextWindowSizeConstraints(ctx, 420, 110, 540, 170)
    end)
  end
  return begin_tooltip_any()
end

local function draw_profile_tooltip(profile)
  if not is_last_item_hovered() then return end
  if not begin_profile_tooltip() then return end
  reaper.ImGui_Text(ctx, tostring(profile) .. " profile")
  reaper.ImGui_Separator(ctx)
  local lines = PROFILE_DESCRIPTIONS[profile]
  if type(lines) == "table" then
    for _, line in ipairs(lines) do
      reaper.ImGui_Text(ctx, tostring(line))
    end
  else
    reaper.ImGui_Text(ctx, "Profile balance mode.")
  end
  end_tooltip_any()
end

local function get_analysis_row(role)
  if not freq_report or not freq_report.rows then return nil end
  for _, row in ipairs(freq_report.rows) do
    if row.role == role then
      return row
    end
  end
  return nil
end

local function draw_analysis_tooltip_for_role(role)
  local row = get_analysis_row(role)
  if not row then return end
  if not begin_tooltip_any() then return end

  reaper.ImGui_Text(ctx, title_role(role) .. " analysis evidence")
  reaper.ImGui_Separator(ctx)
  reaper.ImGui_TextDisabled(ctx,
    "Analyzed " .. tostring(row.analyzed_track_count or 0)
    .. " | Excluded " .. tostring(row.excluded_track_count or 0)
    .. " | Skipped " .. tostring(row.skipped_track_count or 0)
  )

  local shown = 0
  for _, tr in ipairs(row.tracks or {}) do
    if shown >= 3 then break end
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_Text(ctx, tostring(tr.name or "Track"))
    if tr.metrics then
      reaper.ImGui_TextDisabled(ctx, string.format(
        "RMS %.4f | Mud %.2f | Presence %.2f | Brightness %.2f",
        tonumber(tr.metrics.avg_rms) or 0,
        tonumber(tr.metrics.mud_ratio) or 0,
        tonumber(tr.metrics.presence_ratio) or 0,
        tonumber(tr.metrics.brightness_ratio) or 0
      ))
    else
      reaper.ImGui_TextDisabled(ctx, tostring(tr.summary or "No metrics"))
    end
    local rec = (tr.recommendations and tr.recommendations[1]) or ""
    if rec ~= "" then
      reaper.ImGui_TextDisabled(ctx, "- " .. tostring(rec))
    end
    shown = shown + 1
  end

  if (row.tracks and #row.tracks or 0) > shown then
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_TextDisabled(ctx, "...hovering card shows first " .. tostring(shown) .. " tracks")
  end

  end_tooltip_any()
end

local function draw_analysis_tooltip_for_track(role, track_name, track_guid)
  local row = get_analysis_row(role)
  if not row or not row.tracks then return end
  local target = nil
  for _, tr in ipairs(row.tracks) do
    if track_guid and track_guid ~= "" and tostring(tr.guid or "") == tostring(track_guid) then
      target = tr
      break
    end
    if tostring(tr.name or "") == tostring(track_name or "") then
      target = tr
      break
    end
  end
  if not target then return end
  if not begin_tooltip_any() then return end

  reaper.ImGui_Text(ctx, tostring(target.name or "Track") .. " analysis evidence")
  reaper.ImGui_Separator(ctx)
  if target.metrics then
    reaper.ImGui_TextDisabled(ctx, string.format(
      "RMS %.4f | Mud %.2f | Presence %.2f | Brightness %.2f",
      tonumber(target.metrics.avg_rms) or 0,
      tonumber(target.metrics.mud_ratio) or 0,
      tonumber(target.metrics.presence_ratio) or 0,
      tonumber(target.metrics.brightness_ratio) or 0
    ))
  else
    reaper.ImGui_TextDisabled(ctx, tostring(target.summary or "No metrics"))
  end

  local rec_shown = 0
  for _, rec in ipairs(target.recommendations or {}) do
    if rec_shown >= 2 then break end
    reaper.ImGui_TextDisabled(ctx, "- " .. tostring(rec))
    rec_shown = rec_shown + 1
  end

  end_tooltip_any()
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
  if not freq_report then
    suggestions_generated = false
    set_status("Run Analyze Frequency before generating suggestions")
    return
  end

  if fns and fns.build_suggestions then
    suggestion_data = fns.build_suggestions(strength_pct, volume_profile)
    suggestions_generated = true
    active_results_tab = "suggestions"
    set_status("Suggestions generated")
  else
    suggestion_data = nil
    suggestions_generated = false
  end
end

local function refresh_frequency_report()
  if fns and fns.start_frequency_analysis then
    local ok = fns.start_frequency_analysis(strength_pct)
    if ok then
      freq_report = nil
      analyze_in_progress = true
      analyze_progress_pct = 0
      suggestions_generated = false
      active_results_tab = "analysis"
      set_status("Frequency analysis started")
    else
      freq_report = nil
      analyze_in_progress = false
      analyze_progress_pct = 0
      set_status("Frequency analysis failed")
    end
  else
    freq_report = nil
    analyze_in_progress = false
    analyze_progress_pct = 0
    set_status("Frequency analysis unavailable")
  end
end

local function refresh_volume_report()
  if not (fns and fns.analyze_volume_report) then
    volume_report = nil
    set_status("Volume analysis unavailable")
    return
  end

  local report = fns.analyze_volume_report(volume_profile)
  if report then
    volume_report = report
    active_results_tab = "levels"
    set_status("Volume analysis complete")
  else
    volume_report = nil
    set_status("Volume analysis failed")
  end
end

local function step_frequency_analysis_job()
  if not analyze_in_progress then return end
  if not (fns and fns.step_frequency_analysis) then
    analyze_in_progress = false
    set_status("Frequency analysis unavailable")
    return
  end

  local ok, result = fns.step_frequency_analysis(1)
  if not ok then
    analyze_in_progress = false
    set_status("Frequency analysis failed")
    return
  end

  analyze_progress_pct = math.max(0, math.min(100, math.floor(((result.progress or 0) * 100) + 0.5)))
  if result.done then
    analyze_in_progress = false
    freq_report = result.report
    set_status("Frequency analysis complete")
  end
end

local function draw_results_tabs()
  if HAS_TABBAR_API and reaper.ImGui_BeginTabBar(ctx, "##results_tabs") then
    if reaper.ImGui_BeginTabItem(ctx, "Analysis") then
      active_results_tab = "analysis"
      reaper.ImGui_EndTabItem(ctx)
    end

    local sugg_label = freq_report and "Suggestions" or "Suggestions (Analyze first)"
    if reaper.ImGui_BeginTabItem(ctx, sugg_label) then
      active_results_tab = "suggestions"
      reaper.ImGui_EndTabItem(ctx)
    end

    if reaper.ImGui_BeginTabItem(ctx, "Levels") then
      active_results_tab = "levels"
      reaper.ImGui_EndTabItem(ctx)
    end

    reaper.ImGui_EndTabBar(ctx)
    return
  end

  if reaper.ImGui_Button(ctx, "Analysis", 100, 0) then
    active_results_tab = "analysis"
  end
  safe_same_line()
  if reaper.ImGui_Button(ctx, "Suggestions", 110, 0) then
    active_results_tab = "suggestions"
  end
  safe_same_line()
  if reaper.ImGui_Button(ctx, "Levels", 90, 0) then
    active_results_tab = "levels"
  end
end

local function draw_profile_selector()
  reaper.ImGui_TextDisabled(ctx, "Balance profile:")
  safe_same_line()
  local profiles = get_volume_profiles()
  for i, profile in ipairs(profiles) do
    local label = (profile == volume_profile and "[" .. profile .. "]") or profile
    if reaper.ImGui_Button(ctx, label .. "##profile_" .. profile, 86, 0) then
      volume_profile = profile
      set_status("Profile set to " .. profile .. " (existing cards kept; regenerate to refresh)")
    end
    draw_profile_tooltip(profile)
    if i < #profiles then
      safe_same_line()
    end
  end
end

local function draw_track_column(role, items, width, height)
  safe_draw_child(role .. "##track_column", width, height, function()
    reaper.ImGui_Text(ctx, title_role(role) .. "  (" .. tostring(#items) .. ")")
    reaper.ImGui_Separator(ctx)

    for _, item in ipairs(items) do
      local suffix = item.has_audio and "" or " [no audio]"
      if item.excluded then
        suffix = suffix .. " [excluded]"
      end
      local label = item.display_name .. suffix .. "##" .. item.guid
      local is_selected = selected_track_guid == item.guid
      if reaper.APIExists("ImGui_Selectable") then
        if reaper.ImGui_Selectable(ctx, label, is_selected) then
          selected_track_guid = item.guid
          selected_track_role = role
          suggestions_generated = false
          volume_report = nil
        end
      else
        reaper.ImGui_Text(ctx, item.display_name .. suffix)
      end
    end
  end)
end

local function find_selected_item(columns)
  if not selected_track_guid then return nil end
  local roles = get_roles()
  for _, role in ipairs(roles) do
    for _, item in ipairs(columns[role] or {}) do
      if item.guid == selected_track_guid then
        return item
      end
    end
  end
  return nil
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
      safe_same_line()
    end
  end
end

local function draw_suggestion_column(role, width, height)
  safe_draw_child(role .. "##suggest_column", width, height, function()
    if not suggestions_generated or not suggestion_data then
      reaper.ImGui_Text(ctx, title_role(role))
      reaper.ImGui_Separator(ctx)
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
      reaper.ImGui_Text(ctx, title_role(role))
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextDisabled(ctx, "No suggestion data")
      return
    end

    local profile_used = tostring(row_data.profile or suggestion_data.profile or "Even")
    reaper.ImGui_Text(ctx, title_role(role) .. " (" .. profile_used .. ")")
    reaper.ImGui_Separator(ctx)

    if row_data.track_suggestions and #row_data.track_suggestions > 0 then
      for _, track_block in ipairs(row_data.track_suggestions) do
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Text(ctx, tostring(track_block.name or "Track"))
        if is_last_item_hovered() then
          draw_analysis_tooltip_for_track(role, track_block.name, track_block.guid)
        end
        for i = 1, math.min(4, #(track_block.lines or {})) do
          reaper.ImGui_TextDisabled(ctx, "- " .. tostring(track_block.lines[i]))
        end
      end
      return
    end

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
  local height = math.max(280, math.min(460, math.floor(avail_y * 0.68)))

  for idx, role in ipairs(roles) do
    draw_suggestion_column(role, width, height)
    if idx < #roles then
      safe_same_line()
    end
  end
end

local function draw_frequency_report()
  if analyze_in_progress then
    reaper.ImGui_Separator(ctx)
    reaper.ImGui_Text(ctx, "Frequency Analysis")
    reaper.ImGui_TextDisabled(ctx, "Analyzing... " .. tostring(analyze_progress_pct) .. "%")
    return
  end

  if not freq_report then return end

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, "Frequency Analysis Report (read-only)")
  reaper.ImGui_TextWrapped(ctx, tostring(freq_report.summary or ""))
  reaper.ImGui_Spacing(ctx)

  local roles = get_roles()
  local row_by_role = {}
  for _, role_row in ipairs(freq_report.rows or {}) do
    row_by_role[role_row.role] = role_row
  end

  local avail_x, avail_y = reaper.ImGui_GetContentRegionAvail(ctx)
  local spacing = 8
  local total_spacing = spacing * (#roles - 1)
  local width = (avail_x - total_spacing) / #roles
  if width < 180 then width = 180 end
  local height = math.max(260, math.min(420, math.floor(avail_y * 0.62)))

  for idx, role in ipairs(roles) do
    local role_row = row_by_role[role] or {
      role = role,
      analyzed_track_count = 0,
      excluded_track_count = 0,
      skipped_track_count = 0,
      tracks = {},
    }

    safe_draw_child(role .. "##freq_column", width, height, function()
      reaper.ImGui_Text(ctx, title_role(role) .. " Analysis")
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextDisabled(ctx,
        "Analyzed " .. tostring(role_row.analyzed_track_count or 0)
        .. " | Excluded " .. tostring(role_row.excluded_track_count or 0)
        .. " | Skipped " .. tostring(role_row.skipped_track_count or 0)
      )

      if not role_row.tracks or #role_row.tracks == 0 then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextDisabled(ctx, "No analyzed tracks in this role")
        return
      end

      for _, t in ipairs(role_row.tracks) do
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Text(ctx, tostring(t.name or "Track"))

        if t.metrics then
          reaper.ImGui_TextDisabled(ctx, string.format(
            "RMS %.4f | Mud %.2f | Presence %.2f | Brightness %.2f",
            tonumber(t.metrics.avg_rms) or 0,
            tonumber(t.metrics.mud_ratio) or 0,
            tonumber(t.metrics.presence_ratio) or 0,
            tonumber(t.metrics.brightness_ratio) or 0
          ))
        else
          reaper.ImGui_TextDisabled(ctx, tostring(t.summary or "No metrics"))
        end

        local rec_shown = 0
        for _, rec in ipairs(t.recommendations or {}) do
          if rec_shown >= 2 then break end
          reaper.ImGui_TextDisabled(ctx, "- " .. tostring(rec))
          rec_shown = rec_shown + 1
        end
      end
    end)

    if idx < #roles then
      safe_same_line()
    end
  end
end

local function draw_volume_report()
  if not volume_report then
    reaper.ImGui_TextDisabled(ctx, "Run Analyze Levels to generate a report.")
    return
  end

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, "Volume Analysis Report (profile: " .. tostring(volume_report.profile or volume_profile) .. ")")
  reaper.ImGui_TextWrapped(ctx, tostring(volume_report.summary or ""))
  if volume_report.profile_description and volume_report.profile_description ~= "" then
    reaper.ImGui_TextDisabled(ctx, tostring(volume_report.profile_description))
  end
  reaper.ImGui_TextDisabled(ctx, "Reference loudness anchor: " .. fmt_db(volume_report.reference_db))
  reaper.ImGui_Spacing(ctx)

  local roles = get_roles()
  local row_by_role = {}
  for _, role_row in ipairs(volume_report.rows or {}) do
    row_by_role[role_row.role] = role_row
  end

  local avail_x, avail_y = reaper.ImGui_GetContentRegionAvail(ctx)
  local spacing = 8
  local total_spacing = spacing * (#roles - 1)
  local width = (avail_x - total_spacing) / #roles
  if width < 200 then width = 200 end
  local height = math.max(260, math.min(440, math.floor(avail_y * 0.58)))

  for idx, role in ipairs(roles) do
    local role_row = row_by_role[role] or {
      role = role,
      analyzed_track_count = 0,
      excluded_track_count = 0,
      skipped_track_count = 0,
      groups = {},
    }

    safe_draw_child(role .. "##level_column", width, height, function()
      reaper.ImGui_Text(ctx, title_role(role) .. " Levels")
      reaper.ImGui_Separator(ctx)
      reaper.ImGui_TextDisabled(ctx,
        "Analyzed " .. tostring(role_row.analyzed_track_count or 0)
        .. " | Excluded " .. tostring(role_row.excluded_track_count or 0)
        .. " | Skipped " .. tostring(role_row.skipped_track_count or 0)
      )
      reaper.ImGui_TextDisabled(ctx, tostring(role_row.profile_note or ""))
      reaper.ImGui_TextDisabled(ctx, "Role target: " .. fmt_db(role_row.target_role_db))

      if not role_row.groups or #role_row.groups == 0 then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextDisabled(ctx, "No analyzed groups")
        return
      end

      for _, g in ipairs(role_row.groups) do
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Text(ctx, tostring(g.root_name or "Root"))
        reaper.ImGui_TextDisabled(ctx,
          "Root shift " .. fmt_db(g.group_delta_db) .. " (" .. fmt_db(g.current_db) .. " -> " .. fmt_db(g.target_db) .. ")"
        )
        if g.can_apply_root == false then
          reaper.ImGui_TextDisabled(ctx, "Root excluded: global root shift will be skipped on apply")
        end

        for i = 1, math.min(6, #(g.entries or {})) do
          local t = g.entries[i]
          reaper.ImGui_TextDisabled(ctx,
            "- " .. tostring(t.name or "Track")
            .. string.format(" | pan %.2f", tonumber(t.pan) or 0)
            .. " | pan relief " .. fmt_db(t.pan_relief_db)
            .. " | child " .. fmt_db(t.child_delta_db)
            .. " (" .. tostring(t.child_reason or "relative balance") .. ")"
            .. " | final " .. fmt_db(t.final_preview_delta_db)
          )
        end

        if (g.entries and #g.entries or 0) > 6 then
          reaper.ImGui_TextDisabled(ctx, "..." .. tostring(#g.entries - 6) .. " more track(s)")
        end
      end
    end)

    if idx < #roles then
      safe_same_line()
    end
  end
end

local function draw_level_preview_summary()
  if not volume_report then return end

  local tracks = {}
  for _, action in ipairs(volume_report.track_adjustments or {}) do
    tracks[#tracks + 1] = action
  end

  local roots = {}
  for _, action in ipairs(volume_report.root_adjustments or {}) do
    roots[#roots + 1] = action
  end

  table.sort(tracks, function(a, b)
    return (tonumber(a.final_preview_delta_db) or 0) > (tonumber(b.final_preview_delta_db) or 0)
  end)
  table.sort(roots, function(a, b)
    return math.abs(tonumber(a.delta_db) or 0) > math.abs(tonumber(b.delta_db) or 0)
  end)

  reaper.ImGui_Separator(ctx)
  reaper.ImGui_Text(ctx, "Apply Preview")
  reaper.ImGui_TextDisabled(ctx, "Largest predicted level moves before writing:")

  local boost_count = 0
  for _, t in ipairs(tracks) do
    local d = tonumber(t.final_preview_delta_db) or 0
    if d > 0.05 then
      reaper.ImGui_TextDisabled(ctx, "+ " .. tostring(t.name or "Track") .. " " .. fmt_db(d))
      boost_count = boost_count + 1
      if boost_count >= 3 then break end
    end
  end
  if boost_count == 0 then
    reaper.ImGui_TextDisabled(ctx, "+ No significant boosts")
  end

  local cut_count = 0
  for i = #tracks, 1, -1 do
    local t = tracks[i]
    local d = tonumber(t.final_preview_delta_db) or 0
    if d < -0.05 then
      reaper.ImGui_TextDisabled(ctx, "- " .. tostring(t.name or "Track") .. " " .. fmt_db(d))
      cut_count = cut_count + 1
      if cut_count >= 3 then break end
    end
  end
  if cut_count == 0 then
    reaper.ImGui_TextDisabled(ctx, "- No significant cuts")
  end

  local root_count = 0
  for _, r in ipairs(roots) do
    local d = tonumber(r.delta_db) or 0
    if math.abs(d) >= 0.05 then
      reaper.ImGui_TextDisabled(ctx,
        "Root " .. tostring(r.root_name or "Root") .. " " .. fmt_db(d)
      )
      root_count = root_count + 1
      if root_count >= 4 then break end
    end
  end
  if root_count == 0 then
    reaper.ImGui_TextDisabled(ctx, "Root moves: none")
  end
end

local function draw_move_controls(columns)
  if not selected_track_guid then
    reaper.ImGui_TextDisabled(ctx, "Select a track in any column to move it.")
    return
  end

  local selected_item = find_selected_item(columns)

  reaper.ImGui_Text(ctx, "Move selected track to:")
  local roles = get_roles()
  for _, role in ipairs(roles) do
    if role ~= selected_track_role then
      if reaper.ImGui_Button(ctx, title_role(role) .. "##move_" .. role, 100, 0) then
        local moved, move_msg = fns and fns.move_track_to_role and fns.move_track_to_role(selected_track_guid, role)
        if moved then
          selected_track_role = role
          suggestions_generated = false
          volume_report = nil
          set_status(move_msg or ("Track moved to " .. title_role(role)))
        else
          set_status(move_msg or "Could not move track")
        end
      end
      safe_same_line()
    end
  end
  reaper.ImGui_NewLine(ctx)

  local is_excluded = selected_item and selected_item.excluded == true
  local toggle_label = is_excluded and "Include In EQ" or "Exclude From EQ"
  if reaper.ImGui_Button(ctx, toggle_label, 140, 0) then
    if fns and fns.set_track_excluded then
      local ok, msg = fns.set_track_excluded(selected_track_guid, not is_excluded)
      if ok then
        suggestions_generated = false
        volume_report = nil
      end
      set_status(msg or "Track exclusion updated")
    end
  end

  if selected_item then
    safe_same_line()
    if is_excluded then
      reaper.ImGui_TextDisabled(ctx, "This track is excluded from suggestions and apply")
    else
      reaper.ImGui_TextDisabled(ctx, "This track is included in suggestions and apply")
    end
  end
end

local function draw_bottom_row_controls()
  if not HAS_SETCURSOR_API then
    if reaper.ImGui_Button(ctx, "Save Project Map", 140, 0) then
      local ok, info = fns and fns.save_project_roles and fns.save_project_roles()
      if ok then set_status("Project map saved") else set_status(info or "Could not save project map") end
    end
    safe_same_line()
    if reaper.ImGui_Button(ctx, "Reload Project Map", 145, 0) then
      local ok = fns and fns.load_project_roles and fns.load_project_roles()
      if ok then
        suggestions_generated = false
        set_status("Project map reloaded")
      else
        set_status("No saved project map found")
      end
    end

    safe_same_line()
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

  safe_same_line()
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

    safe_same_line()
    if reaper.ImGui_Button(ctx, "Update##inline", 90, 0) then
      local launched = fns and fns.run_installer and fns.run_installer()
      if launched then
        set_status("Installer finished. Closing this window.")
        should_close_window = true
      else
        set_status("Installer failed. Check Reaper console.")
      end
    end

    safe_same_line()
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

  safe_same_line()
  if reaper.ImGui_Button(ctx, "Update", 90, 0) then
    local launched = fns and fns.run_installer and fns.run_installer()
    if launched then
      set_status("Installer finished. Closing this window.")
      should_close_window = true
    else
      set_status("Installer failed. Check Reaper console.")
    end
  end

  safe_same_line()
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
  if not has_valid_ctx() then return false end

  step_frequency_analysis_job()

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
      freq_report = nil
      analyze_in_progress = false
      analyze_progress_pct = 0
      suggestions_generated = false
      active_results_tab = "analysis"
    end

    reaper.ImGui_TextDisabled(ctx, "Use Results tabs below: Analyze first, then Suggestions.")

    reaper.ImGui_Spacing(ctx)
    local columns = load_columns()
    draw_track_columns(columns)

    reaper.ImGui_Spacing(ctx)
    draw_move_controls(columns)

    reaper.ImGui_Separator(ctx)
    reaper.ImGui_TextWrapped(ctx, "Results")
    draw_results_tabs()
    draw_profile_selector()
    reaper.ImGui_Spacing(ctx)

    if active_results_tab == "analysis" then
      if analyze_in_progress then
        reaper.ImGui_TextDisabled(ctx, "Analyze in progress...")
      elseif reaper.ImGui_Button(ctx, "Analyze Frequency", 150, 0) then
        refresh_frequency_report()
      end
      reaper.ImGui_Spacing(ctx)
      draw_frequency_report()
    else
      if active_results_tab == "suggestions" and analyze_in_progress then
        reaper.ImGui_TextDisabled(ctx, "Wait for analysis to complete before generating suggestions.")
      elseif active_results_tab == "suggestions" and freq_report then
        if reaper.ImGui_Button(ctx, "Generate Suggestions", 160, 0) then
          refresh_suggestions()
        end
      elseif active_results_tab == "suggestions" then
        reaper.ImGui_TextDisabled(ctx, "Analyze Frequency first to enable suggestions.")
      end

      if active_results_tab == "suggestions" then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextWrapped(ctx, "Suggestions by role (displayed below matching columns).")
        reaper.ImGui_TextDisabled(ctx, "Profile emphasis: " .. tostring(volume_profile))
        reaper.ImGui_Spacing(ctx)
        draw_suggestion_columns()
      else
        if reaper.ImGui_Button(ctx, "Analyze Levels", 140, 0) then
          refresh_volume_report()
        end
        safe_same_line()
        if volume_report and reaper.ImGui_Button(ctx, "Apply Level Balance", 170, 0) then
          if fns and fns.apply_volume_balance then
            local ok, summary, errors, refreshed_report = fns.apply_volume_balance(volume_profile)
            level_apply_report = summary or "Level balance applied"
            if errors and #errors > 0 then
              level_apply_report = level_apply_report .. "\n" .. table.concat(errors, "\n")
            end
            if refreshed_report then
              volume_report = refreshed_report
            else
              refresh_volume_report()
            end
            if ok then
              set_status("Level balance applied")
              operation_done_msg = "Operation done: " .. os.date("%H:%M:%S")
            else
              set_status(summary or "Level balance failed")
              operation_done_msg = "Operation finished with issues: " .. os.date("%H:%M:%S")
            end
          end
        end
        reaper.ImGui_Spacing(ctx)
        draw_level_preview_summary()
        reaper.ImGui_Spacing(ctx)
        draw_volume_report()
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextWrapped(ctx, level_apply_report)
      end
    end

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
            operation_done_msg = "Operation done: " .. os.date("%H:%M:%S")
          else
            set_status(summary or "Apply failed")
            operation_done_msg = "Operation finished with issues: " .. os.date("%H:%M:%S")
          end
        end
      end
    else
      reaper.ImGui_Spacing(ctx)
      if freq_report then
        reaper.ImGui_TextDisabled(ctx, "Run Generate Suggestions to enable Apply.")
      else
        reaper.ImGui_TextDisabled(ctx, "Analyze Frequency first, then Generate Suggestions.")
      end
    end

    if operation_done_msg ~= "" then
      reaper.ImGui_Spacing(ctx)
      reaper.ImGui_Text(ctx, operation_done_msg)
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
