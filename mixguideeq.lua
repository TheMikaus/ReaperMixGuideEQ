-- MixGuideEQ: Rule-driven Auto EQ assistant for Reaper
-- @author ReaperAutomation
-- @version 0.3.0

local function get_script_dir()
  local src = debug.getinfo(1).source
  if src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  local dir = src:match("(.*[/\\])")
  return dir or ""
end

local eq_rules = dofile(get_script_dir() .. "eq_rules.lua")
local installer_utils = dofile(get_script_dir() .. "installer_utils.lua")
local ui = dofile(get_script_dir() .. "ui.lua")

local app = {
  name = "MixGuideEQ",
  version = "0.3.0",
  install_source_dir = "",
}

local function msg(text)
  reaper.ShowConsoleMsg("[MixGuideEQ] " .. tostring(text) .. "\n")
end

local function normalize_install_dir(dir)
  return installer_utils.normalize_install_dir(dir)
end

local function get_global_data_dir()
  local dir = reaper.GetResourcePath() .. "/Scripts/MixGuideEQ"
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir
end

local function get_install_source_state_path()
  return get_global_data_dir() .. "/mixguideeq_install_source.txt"
end

local function load_install_source_dir()
  local path = get_install_source_state_path()
  local file = io.open(path, "r")
  if not file then return "" end
  local dir = file:read("*l") or ""
  file:close()
  if dir ~= "" then
    app.install_source_dir = normalize_install_dir(dir)
  end
  return app.install_source_dir or ""
end

local function save_install_source_dir(dir)
  local normalized = normalize_install_dir(dir)
  if normalized == "" then return false end
  local path = get_install_source_state_path()
  local file = io.open(path, "w")
  if not file then return false end
  file:write(normalized)
  file:close()
  app.install_source_dir = normalized
  return true
end

local function get_track_name(track, fallback)
  local ok, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if ok and name and name ~= "" then
    return name
  end
  return fallback
end

local function get_track_names()
  local out = {}
  local count = reaper.CountTracks(0)
  for i = 0, count - 1 do
    local track = reaper.GetTrack(0, i)
    out[#out + 1] = get_track_name(track, "Track " .. tostring(i + 1))
  end
  return out
end

local function ensure_reaeq(track)
  local fx = reaper.TrackFX_AddByName(track, "VST: ReaEQ (Cockos)", false, 0)
  if fx and fx >= 0 then return fx end

  fx = reaper.TrackFX_AddByName(track, "ReaEQ (Cockos)", false, 0)
  if fx and fx >= 0 then return fx end

  fx = reaper.TrackFX_AddByName(track, "VST3: ReaEQ (Cockos)", false, 0)
  if fx and fx >= 0 then return fx end

  return reaper.TrackFX_AddByName(track, "ReaEQ", false, 1)
end

local function try_set_named_param(track, fx_idx, key, value)
  if not reaper.TrackFX_SetNamedConfigParm then return false end
  local ok = reaper.TrackFX_SetNamedConfigParm(track, fx_idx, key, tostring(value))
  return ok == true
end

local function apply_named_profile(track, fx_idx, rule)
  local applied = 0

  -- ReaEQ parameter keys vary by build; try common aliases.
  local attempts = {
    { "BANDTYPE0", "HP" },
    { "BANDENABLED0", 1 },
    { "BANDTYPE1", "Band" },
    { "BANDENABLED1", 1 },
    { "BANDTYPE2", "Band" },
    { "BANDENABLED2", 1 },
    { "BANDTYPE3", "Band" },
    { "BANDENABLED3", 1 },
  }

  for _, entry in ipairs(attempts) do
    if try_set_named_param(track, fx_idx, entry[1], entry[2]) then
      applied = applied + 1
    end
  end

  return applied
end

local function analyze_track(track_idx, role, strength_pct)
  local track = reaper.GetTrack(0, track_idx)
  if not track then
    return false, "Invalid track selection"
  end

  local count = reaper.CountTrackMediaItems(track)
  local rule = eq_rules.build_rule_set(role, strength_pct)
  local lines = {
    "Track items: " .. tostring(count),
    eq_rules.render_summary(rule),
    "Note: spectral FFT analysis will be added in a future pass.",
  }
  return true, table.concat(lines, "\n")
end

local function apply_role_to_track(track_idx, role, strength_pct)
  local track = reaper.GetTrack(0, track_idx)
  if not track then
    return false, "Invalid track selection"
  end

  local rule = eq_rules.build_rule_set(role, strength_pct)
  local fx_idx = ensure_reaeq(track)
  if not fx_idx or fx_idx < 0 then
    return false, "Could not insert or find ReaEQ"
  end

  local applied = apply_named_profile(track, fx_idx, rule)
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  local msg_out = "Inserted/updated ReaEQ for " .. tostring(role) .. "."
  if applied == 0 then
    msg_out = msg_out .. " Rule summary generated; direct band parameter writes are limited on this Reaper build."
  end
  return true, msg_out
end

local function run_installer()
  local current_dir = normalize_install_dir(get_script_dir())
  local saved_dir = normalize_install_dir(app.install_source_dir)
  local resolved_dir, installer_path = installer_utils.resolve_installer_path(current_dir, saved_dir)

  local f = io.open(installer_path, "r")
  if not f then
    msg("Installer not found at: " .. tostring(installer_path))
    return false
  end
  f:close()

  save_install_source_dir(resolved_dir)

  local ok, err = pcall(function()
    dofile(installer_path)
  end)
  if not ok then
    msg("Failed to run installer: " .. tostring(err))
    return false
  end

  return true
end

local function init()
  load_install_source_dir()
  if app.install_source_dir == "" then
    app.install_source_dir = normalize_install_dir(get_script_dir())
    save_install_source_dir(app.install_source_dir)
  end
end

local fns = {
  get_roles = eq_rules.get_role_names,
  get_track_names = get_track_names,
  analyze_track = analyze_track,
  apply_role_to_track = apply_role_to_track,
  run_installer = run_installer,
  get_install_source_dir = load_install_source_dir,
  set_install_source_dir = save_install_source_dir,
}

local function loop()
  if ui.loop() then
    reaper.defer(loop)
  end
end

init()
ui.init(app, fns)
loop()
