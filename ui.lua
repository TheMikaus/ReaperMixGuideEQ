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
local pan_report = nil
local pan_apply_report = "Run Analyze Pan to preview stereo placement."
local pan_override_existing = false
local pan_snapshot_status = ""
local preview_measure_buf = "1"
-- What the state file last said, so a project switch refreshes the box
-- without fighting the keystrokes going into it.
local preview_measure_last_seen = nil
local eq_apply_in_progress = false
local eq_apply_progress_pct = 0
local level_snapshot_status = ""
local analyze_in_progress = false
local analyze_progress_pct = 0
local operation_done_msg = ""

local selected_track_guid = nil
local selected_track_role = nil
local request_open_update_popup = false
local show_update_panel_inline = false
local should_close_window = false

local HAS_POPUP_MODAL_API = reaper.APIExists("ImGui_BeginPopupModal") and reaper.APIExists("ImGui_OpenPopup")

local function set_status(msg)
  status_msg = msg
  status_expiry = reaper.time_precise() + 3.0
end

-- ── debug log ───────────────────────────────────────────────────────────────
--
-- Ring buffer in memory, flushed to disk the first time something throws. The
-- interesting part is the sequence of Begin/End calls immediately before the
-- failure, not the thousands of healthy frames before that.
-- Set false to silence the per-call trace. Errors still write a log with the
-- environment header, which is usually enough to say which build is running.
local DEBUG_ENABLED = true
local DEBUG_RING_MAX = 900
local debug_ring = {}
local debug_seq = 0
local debug_frame = 0
local debug_flushed = false

local function dbg(text)
  if not DEBUG_ENABLED then return end
  debug_seq = debug_seq + 1
  debug_ring[#debug_ring + 1] = string.format("%06d f%05d %s", debug_seq, debug_frame, tostring(text))
  if #debug_ring > DEBUG_RING_MAX then
    table.remove(debug_ring, 1)
  end
end

local function debug_log_path()
  local dir = reaper.GetResourcePath() .. "/Scripts/MixGuideEQ"
  pcall(function() reaper.RecursiveCreateDirectory(dir, 0) end)
  return dir .. "/mixguideeq_ui_debug.log"
end

local function debug_environment()
  local lines = {}
  local ok, version = pcall(function()
    return reaper.ImGui_GetVersion and reaper.ImGui_GetVersion() or "unknown"
  end)
  lines[#lines + 1] = "reaimgui version: " .. tostring(ok and version or "unavailable")
  lines[#lines + 1] = "ImGui_ChildFlags_Borders: " .. tostring(reaper.ImGui_ChildFlags_Borders ~= nil)
  lines[#lines + 1] = "ImGui_ChildFlags_Border:  " .. tostring(reaper.ImGui_ChildFlags_Border ~= nil)
  lines[#lines + 1] = "ImGui_ValidatePtr:        " .. tostring(reaper.ImGui_ValidatePtr ~= nil)
  return table.concat(lines, "\n")
end

local function dbg_flush(reason)
  if debug_flushed then return end
  debug_flushed = true
  pcall(function()
    local file = io.open(debug_log_path(), "w")
    if not file then return end
    file:write("MixGuideEQ UI debug log\n")
    file:write("written: " .. os.date("%Y-%m-%d %H:%M:%S") .. "\n")
    file:write("reason:  " .. tostring(reason) .. "\n")
    file:write(debug_environment() .. "\n")
    file:write(string.rep("-", 60) .. "\n")
    for _, line in ipairs(debug_ring) do
      file:write(line .. "\n")
    end
    file:close()
  end)
end

-- Work deferred until after the ImGui frame closes.
--
-- Applying levels, pans or EQ calls TrackList_AdjustWindows and UpdateArrange,
-- which pump Reaper's own UI. Doing that between ImGui_Begin and ImGui_End
-- invalidates the context, and every ImGui call for the rest of the frame
-- throws. Button handlers queue their work here instead; M.loop runs it once
-- the frame has ended.
local pending_action = nil

local function queue_action(fn)
  pending_action = fn
end

local function run_pending_action()
  if not pending_action then return end
  local action = pending_action
  pending_action = nil
  pcall(action)
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

-- Text that gives up quietly rather than throwing. Minimise, collapse and
-- resize can invalidate the context part-way through a frame, and an error path
-- that calls ImGui itself just throws again from inside the handler.
local function safe_text(text, disabled)
  if not has_valid_ctx() then return end
  pcall(function()
    if disabled then
      reaper.ImGui_TextDisabled(ctx, tostring(text))
    else
      reaper.ImGui_Text(ctx, tostring(text))
    end
  end)
end

local function safe_spacing()
  if not has_valid_ctx() then return end
  pcall(function() reaper.ImGui_Spacing(ctx) end)
end

local function safe_separator()
  if not has_valid_ctx() then return end
  pcall(function() reaper.ImGui_Separator(ctx) end)
end

local function safe_text_wrapped(text)
  if not has_valid_ctx() then return end
  pcall(function() reaper.ImGui_TextWrapped(ctx, tostring(text)) end)
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

local function short_label(text, max_len)
  local s = tostring(text or "")
  local n = tonumber(max_len) or 26
  if #s <= n then
    return s
  end
  if n <= 3 then
    return s:sub(1, n)
  end
  return s:sub(1, n - 3) .. "..."
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

-- ReaImGui changed BeginChild's fifth argument: 0.9+ takes an integer
-- child_flags, older builds take a boolean border. Pick from API presence.
--
-- Do NOT go back to trying one signature and falling back to another on error.
-- A BeginChild that throws part-way can still have pushed a child window, so a
-- second attempt pushes a second one while only a single EndChild follows. The
-- unbalanced stack then shows up as an EndChild assertion and an invalidated
-- context several calls later, far from the cause.
local USES_CHILD_FLAGS =
  reaper.ImGui_ChildFlags_Borders ~= nil or reaper.ImGui_ChildFlags_Border ~= nil

local function begin_child_any(label, width, height)
  local ok, opened
  if USES_CHILD_FLAGS then
    ok, opened = pcall(reaper.ImGui_BeginChild, ctx, label, width, height, child_border_flag())
  else
    ok, opened = pcall(reaper.ImGui_BeginChild, ctx, label, width, height, true)
  end

  dbg(string.format("BeginChild '%s' w=%.0f h=%.0f -> ok=%s opened=%s",
    tostring(label), tonumber(width) or -1, tonumber(height) or -1,
    tostring(ok), tostring(opened)))

  if not ok then
    dbg("  BeginChild threw: " .. tostring(opened))
    return false, false
  end
  return true, opened
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
  dbg("BeginTooltip -> ok=" .. tostring(ok) .. " opened=" .. tostring(opened))
  return ok and opened
end

-- Deliberately NOT guarded by has_valid_ctx().
--
-- An End must never be skipped once its Begin succeeded. Bailing out here on a
-- context that merely *looks* invalid leaves the tooltip window pushed on
-- ImGui's stack, and the next EndChild then asserts against the tooltip
-- instead of the child column:
--
--   ImGui_EndChild: Assertion failed: child_window->Flags & ImGuiWindowFlags_ChildWindow
--
-- pcall is the only protection an End call gets.
local function end_tooltip_any()
  if not reaper.APIExists("ImGui_EndTooltip") then return end
  local ok, err = pcall(function()
    reaper.ImGui_EndTooltip(ctx)
  end)
  dbg("EndTooltip -> ok=" .. tostring(ok))
  if not ok then
    dbg("  EndTooltip THREW: " .. tostring(err))
    dbg_flush("EndTooltip threw")
  end
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
  local _ = pcall(function()
    if not has_valid_ctx() then return end
    safe_text(tostring(profile) .. " profile")
    safe_separator()
    local lines = PROFILE_DESCRIPTIONS[profile]
    if type(lines) == "table" then
      for _, line in ipairs(lines) do
        if not has_valid_ctx() then break end
        safe_text(tostring(line))
      end
    else
      safe_text("Profile balance mode.")
    end
  end)
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

  -- Body in a pcall so end_tooltip_any() always runs. See the note in
  -- draw_analysis_tooltip_for_track: a leaked tooltip window is what makes a
  -- later EndChild assert.
  pcall(function()
    safe_text(title_role(role) .. " analysis evidence")
    safe_separator()
    safe_text("Analyzed " .. tostring(row.analyzed_track_count or 0)
      .. " | Excluded " .. tostring(row.excluded_track_count or 0)
      .. " | Skipped " .. tostring(row.skipped_track_count or 0), true)

    local shown = 0
    for _, tr in ipairs(row.tracks or {}) do
      if shown >= 3 then break end
      safe_spacing()
      safe_text(tostring(tr.name or "Track"))
      if tr.metrics then
        safe_text(string.format(
          "RMS %.4f | Mud %.2f | Presence %.2f | Brightness %.2f",
          tonumber(tr.metrics.avg_rms) or 0,
          tonumber(tr.metrics.mud_ratio) or 0,
          tonumber(tr.metrics.presence_ratio) or 0,
          tonumber(tr.metrics.brightness_ratio) or 0
        ), true)
      else
        safe_text(tostring(tr.summary or "No metrics"), true)
      end
      local rec = (tr.recommendations and tr.recommendations[1]) or ""
      if rec ~= "" then
        safe_text("- " .. tostring(rec), true)
      end
      shown = shown + 1
    end

    if (row.tracks and #row.tracks or 0) > shown then
      safe_spacing()
      safe_text("...hovering card shows first " .. tostring(shown) .. " tracks", true)
    end
  end)

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

  -- Body in a pcall so end_tooltip_any() always runs. A throw here would leave
  -- the tooltip window pushed on ImGui's stack, and the next EndChild would
  -- then assert against the tooltip instead of the child column.
  pcall(function()
    safe_text(tostring(target.name or "Track") .. " analysis evidence")
    safe_separator()

    if target.metrics then
      safe_text(string.format(
        "RMS %.4f | Mud %.2f | Presence %.2f | Brightness %.2f",
        tonumber(target.metrics.avg_rms) or 0,
        tonumber(target.metrics.mud_ratio) or 0,
        tonumber(target.metrics.presence_ratio) or 0,
        tonumber(target.metrics.brightness_ratio) or 0
      ), true)
    else
      safe_text(tostring(target.summary or "No metrics"), true)
    end

    local rec_shown = 0
    for _, rec in ipairs(target.recommendations or {}) do
      if rec_shown >= 2 then break end
      safe_text("- " .. tostring(rec), true)
      rec_shown = rec_shown + 1
    end
  end)

  end_tooltip_any()
end

local function safe_draw_child(label, width, height, draw_fn)
  if not has_valid_ctx() then return end

  local started, opened = begin_child_any(label, width, height)
  if not started then
    safe_text("Unable to render column")
    return
  end

  -- EndChild ONLY when BeginChild actually opened the child.
  --
  -- Verified against ReaImGui 1.92.1 from mixguideeq_ui_debug.log: a child that
  -- is culled -- which is what happens when you scroll a column out of view --
  -- returns false without pushing a window, and EndChild then asserts with
  --
  --   ImGui_EndChild: Assertion failed: child_window->Flags & ImGuiWindowFlags_ChildWindow
  --
  -- taking the context down with it. Do not "fix" this back to an
  -- unconditional EndChild on the strength of the upstream Dear ImGui docs;
  -- this binding does not behave that way.
  if not opened then
    dbg("BeginChild '" .. tostring(label) .. "' culled; skipping EndChild")
    return
  end

  local ok = pcall(draw_fn)
  if not ok then
    safe_text("Column render error")
  end

  dbg("EndChild '" .. tostring(label) .. "' (opened=true)")
  local end_ok, end_err = pcall(function()
    reaper.ImGui_EndChild(ctx)
  end)
  if not end_ok then
    dbg("  EndChild THREW: " .. tostring(end_err))
    dbg_flush("EndChild threw for '" .. tostring(label) .. "'")
  end
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

local function refresh_pan_report()
  if not (fns and fns.analyze_pan_report) then
    pan_report = nil
    set_status("Pan analysis unavailable")
    return
  end

  local report = fns.analyze_pan_report(volume_profile)
  if report then
    pan_report = report
    set_status("Pan analysis complete")
  else
    pan_report = nil
    set_status("Pan analysis failed")
  end
end

local function refresh_pan_snapshot_status()
  if not (fns and fns.get_last_pan_apply_snapshot) then
    pan_snapshot_status = ""
    return
  end

  local snap = fns.get_last_pan_apply_snapshot()
  if not snap or snap.available ~= true then
    pan_snapshot_status = "Pan revert snapshot: none"
    return
  end

  local time_text = ""
  if snap.timestamp and tonumber(snap.timestamp) then
    time_text = os.date("%H:%M:%S", tonumber(snap.timestamp))
  end
  pan_snapshot_status = string.format(
    "Pan revert snapshot: %d track(s), %s profile, %s",
    tonumber(snap.track_count) or 0,
    tostring(snap.profile or "?"),
    time_text
  )
end

local function pan_position_text(pan)
  local value = tonumber(pan)
  if not value then return "-" end
  if math.abs(value) < 0.02 then return "C" end
  return string.format("%s%d", value < 0 and "L" or "R", math.floor(math.abs(value) * 100 + 0.5))
end

local function draw_pan_report()
  if not pan_report then
    safe_text("Run Analyze Pan to see the planned stereo placement.", true)
    return
  end

  safe_text_wrapped(tostring(pan_report.summary or ""))
  safe_spacing()

  for _, row in ipairs(pan_report.rows or {}) do
    local moves = {}
    for _, track in ipairs(row.tracks or {}) do
      if track.target_pan ~= nil then
        moves[#moves + 1] = track
      end
    end
    if #moves > 0 then
      safe_text(title_role(row.role))
      for _, track in ipairs(moves) do
        local line = string.format("  %s: %s -> %s",
          short_label(track.name, 28),
          pan_position_text(track.current_pan),
          pan_position_text(track.target_pan))
        if track.is_stereo then
          line = line .. "  [stereo: skipped]"
        elseif track.already_set then
          line = line .. "  [already panned]"
        end
        safe_text(line, true)
        if is_last_item_hovered() and begin_tooltip_any() then
          pcall(function()
            safe_text(tostring(track.reason or ""))
          end)
          end_tooltip_any()
        end
      end
      safe_spacing()
    end
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
    set_status("Volume analysis complete")
  else
    volume_report = nil
    set_status("Volume analysis failed")
  end
end

local function refresh_level_snapshot_status()
  if not (fns and fns.get_last_volume_apply_snapshot) then
    level_snapshot_status = ""
    return
  end

  local snap = fns.get_last_volume_apply_snapshot()
  if not snap or snap.available ~= true then
    level_snapshot_status = "Revert snapshot: none"
    return
  end

  local time_text = ""
  if snap.timestamp and tonumber(snap.timestamp) then
    time_text = os.date("%H:%M:%S", tonumber(snap.timestamp))
  end

  level_snapshot_status = "Revert snapshot: " .. tostring(snap.track_count or 0)
    .. " track(s)"
    .. (snap.profile and (", profile " .. tostring(snap.profile)) or "")
    .. (time_text ~= "" and (", " .. time_text) or "")
end

-- One slice of the EQ apply per frame. Calibrating a filter and measuring the
-- track either side of it is slow enough that doing every track in one call
-- locked the window for seconds with nothing on screen.
local EQ_APPLY_TRACKS_PER_FRAME = 1

local function step_eq_apply_job()
  if not eq_apply_in_progress then return end
  if not (fns and fns.step_eq_apply) then
    eq_apply_in_progress = false
    return
  end

  local ok, result = fns.step_eq_apply(EQ_APPLY_TRACKS_PER_FRAME)
  if not ok then
    eq_apply_in_progress = false
    return
  end

  eq_apply_progress_pct = math.max(0, math.min(100,
    math.floor(((result.progress or 0) * 100) + 0.5)))

  if result.done then
    eq_apply_in_progress = false
    eq_apply_progress_pct = 100
    apply_report = result.summary or "Apply completed"
    if result.errors and #result.errors > 0 then
      apply_report = apply_report .. "\n" .. table.concat(result.errors, "\n")
    end
    -- The tracks no longer sound like what was measured.
    suggestions_generated = false
    suggestion_data = nil
    freq_report = nil
    volume_report = nil
    set_status("Auto EQ applied")
    operation_done_msg = "Operation done: " .. os.date("%H:%M:%S")
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

local function draw_profile_selector()
  safe_text("Balance profile:", true)
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
    safe_text(title_role(role) .. "  (" .. tostring(#items) .. ")")
    safe_separator()

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
        safe_text(item.display_name .. suffix)
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
      safe_text(title_role(role))
      safe_separator()
      safe_text("Generate suggestions", true)
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
      safe_text(title_role(role))
      safe_separator()
      safe_text("No suggestion data", true)
      return
    end

    local profile_used = tostring(row_data.profile or suggestion_data.profile or "Even")
    safe_text(title_role(role) .. " (" .. profile_used .. ")")
    safe_separator()

    if row_data.track_suggestions and #row_data.track_suggestions > 0 then
      for _, track_block in ipairs(row_data.track_suggestions) do
        safe_spacing()
        safe_separator()
        safe_text(tostring(track_block.name or "Track"))
        if is_last_item_hovered() then
          draw_analysis_tooltip_for_track(role, track_block.name, track_block.guid)
        end
        for i = 1, math.min(4, #(track_block.lines or {})) do
          safe_text("- " .. tostring(track_block.lines[i]), true)
        end
      end
      return
    end

    for _, line in ipairs(row_data.lines or {}) do
      safe_text("- " .. line, true)
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
    safe_separator()
    safe_text("Frequency Analysis")
    safe_text("Analyzing... " .. tostring(analyze_progress_pct) .. "%", true)
    return
  end

  if not freq_report then return end

  safe_separator()
  safe_text("Frequency Analysis Report (read-only)")
  safe_text_wrapped(tostring(freq_report.summary or ""))
  safe_spacing()

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
      safe_text(title_role(role) .. " Analysis")
      safe_separator()
      safe_text("Analyzed " .. tostring(role_row.analyzed_track_count or 0)
        .. " | Excluded " .. tostring(role_row.excluded_track_count or 0)
        .. " | Skipped " .. tostring(role_row.skipped_track_count or 0), true)

      if not role_row.tracks or #role_row.tracks == 0 then
        safe_spacing()
        safe_text("No analyzed tracks in this role", true)
        return
      end

      for _, t in ipairs(role_row.tracks) do
        safe_spacing()
        safe_separator()
        safe_text(tostring(t.name or "Track"))

        if t.metrics then
          safe_text(string.format(
            "RMS %.4f | Mud %.2f | Presence %.2f | Brightness %.2f",
            tonumber(t.metrics.avg_rms) or 0,
            tonumber(t.metrics.mud_ratio) or 0,
            tonumber(t.metrics.presence_ratio) or 0,
            tonumber(t.metrics.brightness_ratio) or 0
          ), true)
        else
          safe_text(tostring(t.summary or "No metrics"), true)
        end

        local rec_shown = 0
        for _, rec in ipairs(t.recommendations or {}) do
          if rec_shown >= 2 then break end
          safe_text("- " .. tostring(rec), true)
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
    safe_text("Run Analyze Levels to measure every track and rank them.", true)
    return
  end

  safe_separator()
  safe_text("Levels (profile: " .. tostring(volume_report.profile or volume_profile) .. ")")
  safe_text_wrapped(tostring(volume_report.summary or ""))
  safe_text("Averages exclude silence (gated). Stereo measured as mono. "
    .. "Values are relative to the loudest track.", true)
  safe_spacing()

  safe_text(string.format("  %-24s %8s %8s %7s  %s",
    "TRACK", "avg", "max", "move", "rank"), true)
  safe_separator()

  for _, row in ipairs(volume_report.ranked or {}) do
    local move = tonumber(row.delta_db) or 0
    local rank_note = ""
    local target_rank = tonumber(row.target_rank)
    if target_rank and target_rank ~= row.rank then
      -- Which way it needs to travel in the ranking, which is the thing the
      -- list is for.
      local direction = (target_rank < row.rank) and "up" or "down"
      rank_note = string.format("%d -> %d (%s)", row.rank, target_rank, direction)
    else
      rank_note = string.format("%d", row.rank or 0)
    end

    local line = string.format("  %-24s %8s %8s %7s  %s",
      short_label(row.name, 24),
      fmt_db(row.rel_avg_db),
      fmt_db(row.rel_max_db),
      (move == 0) and "-" or fmt_db(move),
      rank_note)
    safe_text_wrapped(line)
  end

  if (volume_report.excluded_track_count or 0) > 0
    or (volume_report.skipped_track_count or 0) > 0 then
    safe_spacing()
    safe_text(string.format("Excluded %d, skipped %d (no audio or below the gate).",
      volume_report.excluded_track_count or 0,
      volume_report.skipped_track_count or 0), true)
  end
end

local function draw_move_controls(columns)
  if not selected_track_guid then
    safe_text("Select a track in any column to move it.", true)
    return
  end

  local selected_item = find_selected_item(columns)

  safe_text("Move selected track to:")
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
      safe_text("This track is excluded from suggestions and apply", true)
    else
      safe_text("This track is included in suggestions and apply", true)
    end
  end
end

-- Height reserved at the bottom of the window for the always-visible footer.
local FOOTER_HEIGHT = 62

-- Jump the edit cursor to a bar and start playback, so a change can be heard
-- without leaving the panel.
local function remember_preview_measure()
  if fns and fns.set_preview_measure then
    fns.set_preview_measure(preview_measure_buf)
  end
end

local function draw_preview_controls()
  -- Follow the project: the bar number is stored per project, so a tab switch
  -- reloads it underneath us.
  local stored = md_ref and md_ref.preview_measure
  if stored ~= nil and stored ~= preview_measure_last_seen then
    preview_measure_buf = tostring(stored)
    preview_measure_last_seen = preview_measure_buf
  end

  safe_text("Preview from bar", true)
  safe_same_line()
  reaper.ImGui_PushItemWidth(ctx, 60)
  local changed, value = reaper.ImGui_InputText(ctx, "##preview_measure", preview_measure_buf)
  reaper.ImGui_PopItemWidth(ctx)
  if changed then
    preview_measure_buf = value
    preview_measure_last_seen = value
    if md_ref then md_ref.preview_measure = value end
  end
  -- Save on the way out of the box rather than per keystroke.
  if reaper.APIExists("ImGui_IsItemDeactivatedAfterEdit")
    and reaper.ImGui_IsItemDeactivatedAfterEdit(ctx) then
    queue_action(remember_preview_measure)
  end

  safe_same_line()
  if reaper.ImGui_Button(ctx, "Play", 60, 0) then
    queue_action(function()
      remember_preview_measure()
      if fns and fns.preview_from_measure then
        local ok, info = fns.preview_from_measure(preview_measure_buf)
        set_status(ok and ("Playing from bar " .. tostring(info))
          or tostring(info or "Could not start playback"))
      end
    end)
  end

  safe_same_line()
  if reaper.ImGui_Button(ctx, "Stop", 60, 0) then
    queue_action(function()
      if fns and fns.stop_preview then fns.stop_preview() end
    end)
  end
end

local function draw_footer()
  safe_separator()

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
  draw_preview_controls()

  safe_same_line()
  if reaper.ImGui_Button(ctx, "Install/Update", 120, 0) then
    if HAS_POPUP_MODAL_API then
      request_open_update_popup = true
    else
      show_update_panel_inline = not show_update_panel_inline
    end
  end

  -- Status line. Always present so the row does not jump about as messages
  -- come and go.
  local line = ""
  if status_msg ~= "" and reaper.time_precise() < status_expiry then
    line = status_msg
  elseif operation_done_msg ~= "" then
    line = operation_done_msg
  end
  if line == "" then
    safe_text("Ready", true)
  else
    safe_text(line)
  end
end


local function draw_update_popup()
  if not HAS_POPUP_MODAL_API then
    if not show_update_panel_inline then return end

    safe_separator()
    safe_text("Install/Update")
    safe_text("Installer source folder")
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

  -- Body in a pcall so EndPopup always runs. A leaked popup window desyncs
  -- ImGui's stack exactly like a leaked tooltip does.
  local popup_ok, popup_err = pcall(function()

  safe_text("Installer source folder")
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

  end)
  if not popup_ok then
    set_status("Update panel error: " .. tostring(popup_err))
  end

  reaper.ImGui_EndPopup(ctx)
end

function M.init(md, functions)
  md_ref = md
  fns = functions
  install_source_buf = (md_ref and md_ref.install_source_dir) or ""
  preview_measure_buf = tostring((md_ref and md_ref.preview_measure) or "1")
  preview_measure_last_seen = preview_measure_buf
  ctx = reaper.ImGui_CreateContext("MixGuideEQ")
  dbg("init: context created, USES_CHILD_FLAGS=" .. tostring(USES_CHILD_FLAGS))
end

-- One ImGui frame.
--
-- Runs inside a pcall in M.loop below. Reaper can invalidate the context
-- part-way through a frame: an apply calls TrackList_AdjustWindows and
-- UpdateArrange, which pump Reaper's own UI, and every ImGui call after that
-- throws. ImGui_ValidatePtr does not reliably detect it -- it reported the
-- context as valid while ImGui_Spacing was rejecting the same pointer -- so
-- the frame is protected as a whole rather than call by call.
-- ── stages ──────────────────────────────────────────────────────────────────
--
-- The window is one stage at a time, in the order the work actually happens:
-- map the tracks, shape them, place them, then set levels.
--
-- EQ comes before Balance on purpose. EQ decisions here are level-independent
-- (band shares are normalised by total energy), but EQ *changes* level -- so
-- EQ-then-levels settles in one pass, where levels-then-EQ always needs a
-- re-balance afterwards. Pan sits between them because placement shifts
-- perceived level too, which leaves Balance to settle everything last.
--
-- Going back and re-applying EQ marks Balance "redo" rather than adding a fifth
-- stage, so the loop back is visible without pretending it is a new step.

local STAGE_ORDER = { "map", "eq", "pan", "balance" }
local STAGE_TITLES = {
  map = "1 Map", eq = "2 EQ", pan = "3 Pan", balance = "4 Balance",
}
local STAGE_BLURB = {
  map     = "Put each track in a role column and exclude anything that is not musical material.",
  eq      = "Measure each track and shape it towards the profile's targets. Done first because EQ changes level.",
  pan     = "Place tracks across the stereo image. Pairs go opposite each other.",
  balance = "Set how loud each track sits. Last, so it settles what EQ and pan have changed.",
}
local active_stage = "map"

local function snapshot_available(getter)
  if not getter then return false end
  local ok, snap = pcall(getter)
  return ok and snap ~= nil and snap.available == true
end

local function compute_stage_status(columns)
  local track_count = 0
  for _, role in ipairs(get_roles()) do
    track_count = track_count + #(columns[role] or {})
  end

  local levels_applied = snapshot_available(fns and fns.get_last_volume_apply_snapshot)
  local pans_applied = snapshot_available(fns and fns.get_last_pan_apply_snapshot)
  local eq_stale = md_ref and md_ref.eq_applied_since_balance == true

  local status = { track_count = track_count }

  status.map = track_count > 0
    and { state = "done", note = tostring(track_count) .. " track(s) mapped" }
    or { state = "now", note = "no tracks found in this project" }

  if track_count == 0 then
    status.balance = { state = "locked", note = "map tracks first" }
    status.pan = { state = "locked", note = "map tracks first" }
    status.eq = { state = "locked", note = "map tracks first" }
    return status
  end

  if eq_stale then
    status.balance = { state = "redo", note = "EQ changed levels - balance again" }
  elseif levels_applied then
    status.balance = { state = "done", note = "levels applied, revert available" }
  else
    status.balance = { state = "now", note = "not balanced yet" }
  end

  if pans_applied then
    status.pan = { state = "done", note = "pans applied, revert available" }
  else
    status.pan = { state = "now", note = "not placed yet" }
  end

  if suggestions_generated then
    status.eq = { state = "now", note = "review the cards, then apply" }
  elseif freq_report then
    status.eq = { state = "now", note = "analysed, generate suggestions" }
  else
    status.eq = { state = "now", note = "not analysed yet" }
  end

  return status
end

local function stage_next_hint(status)
  if active_stage == "map" then
    return "Next: 2 EQ"
  elseif active_stage == "eq" then
    if md_ref and md_ref.eq_applied_since_balance == true then
      return "Next: 3 Pan"
    end
    return "Analyze Frequency, Generate Suggestions, then Apply Auto EQ."
  elseif active_stage == "pan" then
    if status.pan.state == "done" then return "Next: 4 Balance" end
    return "Run Analyze Pan, review, then Apply."
  end
  if status.balance.state == "redo" then
    return "EQ was applied after the last balance - run Analyze Levels again."
  end
  if status.balance.state == "done" then
    return "Done. Listen, and use Preview to jump around."
  end
  return "Run Analyze Levels, review the ranking, then Apply."
end

local function draw_stage_strip(status)
  for i, stage in ipairs(STAGE_ORDER) do
    local st = status[stage] or { state = "now", note = "" }
    local marker = (active_stage == stage) and "> " or "  "
    local label = marker .. STAGE_TITLES[stage] .. "  [" .. st.state .. "]"
    if reaper.ImGui_Button(ctx, label .. "##stage_" .. stage, 165, 0) then
      active_stage = stage
    end
    if is_last_item_hovered() and begin_tooltip_any() then
      pcall(function()
        safe_text(STAGE_TITLES[stage])
        safe_text(STAGE_BLURB[stage] or "", true)
        safe_text(st.note or "", true)
      end)
      end_tooltip_any()
    end
    if i < #STAGE_ORDER then
      safe_same_line()
    end
  end
end

local function draw_profile_header()
  safe_text("Profile", true)
  safe_same_line()
  draw_profile_selector()
end

-- ── stage bodies ────────────────────────────────────────────────────────────

local function draw_stage_map(columns)
  safe_text_wrapped(STAGE_BLURB.map)
  safe_spacing()
  draw_track_columns(columns)
  safe_spacing()
  draw_move_controls(columns)
end

local function draw_stage_balance()
  safe_text_wrapped(STAGE_BLURB.balance)
  safe_spacing()

  if reaper.ImGui_Button(ctx, "Analyze Levels", 140, 0) then
    -- Take the previous apply off first: measuring the panel's own output would
    -- compute the next plan against the wrong starting point.
    queue_action(function()
      if fns.revert_before_analysis then
        fns.revert_before_analysis("levels")
      end
      refresh_volume_report()
      refresh_level_snapshot_status()
    end)
  end
  safe_same_line()
  if volume_report and reaper.ImGui_Button(ctx, "Apply Level Balance", 170, 0) then
    queue_action(function()
      local ok, summary, errors, refreshed = fns.apply_volume_balance(volume_profile)
      level_apply_report = summary or "Level balance applied"
      if errors and #errors > 0 then
        level_apply_report = level_apply_report .. "\n" .. table.concat(errors, "\n")
      end
      volume_report = refreshed or volume_report
      if ok then
        set_status("Level balance applied")
        operation_done_msg = "Operation done: " .. os.date("%H:%M:%S")
        refresh_level_snapshot_status()
      else
        set_status(summary or "Level balance failed")
      end
    end)
  end

  if snapshot_available(fns and fns.get_last_volume_apply_snapshot) then
    safe_same_line()
    if reaper.ImGui_Button(ctx, "Revert Last Level Apply", 190, 0) then
      queue_action(function()
        local ok, summary, errors = fns.revert_last_volume_balance()
        level_apply_report = summary or "Revert attempted"
        if errors and #errors > 0 then
          level_apply_report = level_apply_report .. "\n" .. table.concat(errors, "\n")
        end
        if ok then
          set_status("Last level apply reverted")
          operation_done_msg = "Operation done: " .. os.date("%H:%M:%S")
          refresh_level_snapshot_status()
          refresh_volume_report()
        else
          set_status(summary or "Revert failed")
        end
      end)
    end
  end

  if level_snapshot_status == "" then
    refresh_level_snapshot_status()
  end
  safe_spacing()
  safe_text(level_snapshot_status, true)
  safe_spacing()
  draw_volume_report()
  safe_spacing()
  safe_text_wrapped(level_apply_report)
end

local function draw_stage_pan()
  safe_text_wrapped(STAGE_BLURB.pan)
  safe_spacing()

  if reaper.ImGui_Button(ctx, "Analyze Pan", 140, 0) then
    queue_action(function()
      if fns.revert_before_analysis then
        fns.revert_before_analysis("pans")
      end
      refresh_pan_report()
      refresh_pan_snapshot_status()
    end)
  end
  safe_same_line()
  if pan_report and reaper.ImGui_Button(ctx, "Apply Pan Placement", 180, 0) then
    queue_action(function()
      local ok, summary, errors, refreshed = fns.apply_pan_balance(volume_profile, pan_override_existing)
      pan_apply_report = summary or "Pan placement applied"
      if errors and #errors > 0 then
        pan_apply_report = pan_apply_report .. "\n" .. table.concat(errors, "\n")
      end
      pan_report = refreshed or pan_report
      if ok then
        set_status("Pan placement applied")
        operation_done_msg = "Operation done: " .. os.date("%H:%M:%S")
        refresh_pan_snapshot_status()
      else
        set_status(summary or "Pan placement failed")
      end
    end)
  end

  if snapshot_available(fns and fns.get_last_pan_apply_snapshot) then
    safe_same_line()
    if reaper.ImGui_Button(ctx, "Revert Last Pan Apply", 190, 0) then
      queue_action(function()
        local ok, summary, errors = fns.revert_last_pan_balance()
        pan_apply_report = summary or "Revert attempted"
        if errors and #errors > 0 then
          pan_apply_report = pan_apply_report .. "\n" .. table.concat(errors, "\n")
        end
        if ok then
          set_status("Last pan apply reverted")
          operation_done_msg = "Operation done: " .. os.date("%H:%M:%S")
          refresh_pan_snapshot_status()
          refresh_pan_report()
        else
          set_status(summary or "Revert failed")
        end
      end)
    end
  end

  local changed, value = reaper.ImGui_Checkbox(ctx, "Override existing pans", pan_override_existing)
  if changed then
    pan_override_existing = value
  end
  if is_last_item_hovered() and begin_tooltip_any() then
    pcall(function()
      safe_text("Off: tracks you have already panned keep their position.")
      safe_text("On: every track is placed by the profile's rules.")
      safe_text("Revert Last Pan Apply restores the originals either way.", true)
    end)
    end_tooltip_any()
  end

  if pan_snapshot_status == "" then
    refresh_pan_snapshot_status()
  end
  safe_spacing()
  safe_text(pan_snapshot_status, true)
  safe_spacing()
  draw_pan_report()
  safe_spacing()
  safe_text_wrapped(pan_apply_report)
end

local function draw_stage_eq()
  safe_text_wrapped(STAGE_BLURB.eq)
  safe_spacing()

  local changed_strength, new_strength =
    reaper.ImGui_SliderInt(ctx, "Suggestion Strength %", strength_pct, 0, 150)
  if changed_strength then
    strength_pct = new_strength
    freq_report = nil
    analyze_in_progress = false
    analyze_progress_pct = 0
    suggestions_generated = false
  end

  safe_spacing()
  if analyze_in_progress then
    safe_text("Analyzing... " .. tostring(analyze_progress_pct) .. "%", true)
  elseif reaper.ImGui_Button(ctx, "Analyze Frequency", 150, 0) then
    -- Take every later stage off first, and this stage's own makeup gain with
    -- it: measuring a mix the panel has already moved computes the next plan
    -- against the wrong starting point. Queued, because reverting pumps
    -- Reaper's UI and that invalidates the ImGui context mid-frame.
    queue_action(function()
      if fns and fns.revert_before_analysis then
        fns.revert_before_analysis("eq")
      end
      refresh_frequency_report()
    end)
  end

  if not analyze_in_progress and freq_report then
    safe_same_line()
    if reaper.ImGui_Button(ctx, "Generate Suggestions", 160, 0) then
      refresh_suggestions()
    end
  end

  if eq_apply_in_progress then
    safe_same_line()
    safe_text("Applying... " .. tostring(eq_apply_progress_pct) .. "%", true)
  elseif suggestions_generated and suggestion_data then
    safe_same_line()
    if reaper.ImGui_Button(ctx, "Apply Auto EQ", 140, 0) then
      queue_action(function()
        local ok, info = fns.start_eq_apply(strength_pct, volume_profile)
        if ok then
          eq_apply_in_progress = true
          eq_apply_progress_pct = 0
          apply_report = "Applying EQ to " .. tostring(info.queued) .. " track(s)..."
          set_status("Applying Auto EQ")
        else
          set_status(tostring(info or "Apply failed"))
          apply_report = tostring(info or "Apply failed")
        end
      end)
    end
  end

  safe_spacing()
  if suggestions_generated and suggestion_data then
    safe_text("Audio tracks analysed: " .. tostring(suggestion_data.total_audio_tracks or 0), true)
    safe_spacing()
    draw_suggestion_columns()
  else
    draw_frequency_report()
  end

  safe_spacing()
  safe_text_wrapped(apply_report)
end


local function draw_frame()
  if reaper.ImGui_SetNextWindowSize then
    local cond = reaper.ImGui_Cond_FirstUseEver and reaper.ImGui_Cond_FirstUseEver() or 0
    reaper.ImGui_SetNextWindowSize(ctx, 1600, 920, cond)
  end

  local title = "MixGuideEQ v" .. tostring(md_ref.version or "")
  local visible, open = reaper.ImGui_Begin(ctx, title, true)

  if visible then
    -- Everything above the footer scrolls inside this region, so the footer
    -- below it stays pinned to the bottom of the window.
    local _, body_avail = reaper.ImGui_GetContentRegionAvail(ctx)
    local body_height = math.max(120, body_avail - FOOTER_HEIGHT)
    local body_started, body_opened = begin_child_any("##body", 0, body_height)
    local body_drawn = body_started and body_opened
    local columns = load_columns()
    local stage_status = compute_stage_status(columns)

    draw_profile_header()
    safe_spacing()
    draw_stage_strip(stage_status)
    safe_separator()
    safe_text(stage_next_hint(stage_status), true)
    safe_spacing()

    if active_stage == "map" then
      draw_stage_map(columns)
    elseif active_stage == "balance" then
      draw_stage_balance()
    elseif active_stage == "pan" then
      draw_stage_pan()
    else
      draw_stage_eq()
    end

    if operation_done_msg ~= "" then
      safe_spacing()
      safe_text(operation_done_msg)
    end

    draw_update_popup()

    -- Close the scrolling region before the footer. EndChild only when the
    -- child actually opened -- see the note in safe_draw_child.
    if body_drawn then
      pcall(function() reaper.ImGui_EndChild(ctx) end)
    end

    draw_footer()
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

-- Consecutive frames that threw. A context that cannot be rebuilt should close
-- the window rather than spin forever recreating itself.
local frame_errors = 0
local MAX_FRAME_ERRORS = 10

function M.loop()
  if not ctx then return false end

  -- Domain work, no ImGui: guarded separately so an analysis error does not
  -- get mistaken for a dead context.
  pcall(step_frequency_analysis_job)
  pcall(step_eq_apply_job)

  debug_frame = debug_frame + 1
  dbg("=== frame begin ===")

  -- xpcall so the traceback survives: knowing which call threw is the whole
  -- point of this log.
  local ok, keep_open = xpcall(draw_frame, function(err)
    return tostring(err) .. "\n" .. debug.traceback("", 2)
  end)
  dbg("=== frame end ok=" .. tostring(ok) .. " ===")

  -- Outside the frame: safe for Reaper to redraw its own windows now.
  run_pending_action()

  if ok then
    frame_errors = 0
    return keep_open
  end

  dbg("FRAME THREW: " .. tostring(keep_open))
  dbg_flush("draw_frame threw")

  -- Discard the half-drawn frame and rebuild. ImGui state is unbalanced at this
  -- point (Begin without End), and a fresh context is the only clean recovery.
  frame_errors = frame_errors + 1
  if frame_errors >= MAX_FRAME_ERRORS then
    return false
  end

  ctx = reaper.ImGui_CreateContext("MixGuideEQ")
  set_status("Window rebuilt after a graphics error (" .. tostring(keep_open) .. ")")
  return ctx ~= nil
end

return M
