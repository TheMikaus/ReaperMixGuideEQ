-- MixGuideEQ: Rule-driven Auto EQ assistant for Reaper
-- @author ReaperAutomation
-- @version 0.35.1

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
  version = "0.35.1",
  install_source_dir = "",
  track_roles = {},
  track_excluded = {},
  last_frequency_report = nil,
  last_volume_report = nil,
  frequency_analysis_job = nil,
}

local MAX_RULE_MOVES = 3
local MIN_TRACK_VOL = 1e-5
local MAX_TRACK_VOL = 4.0
local MIN_APPLY_DELTA_DB = 0.05
local MAX_CHILD_DELTA_DB = 3.0
local MAX_ROOT_DELTA_DB = 6.0
local VOLUME_PROFILES = {
  even = {
    name = "Even",
    description = "Balanced stems with moderate role separation.",
    role_offsets = { drums = -1.0, guitar = -1.5, bass = -1.0, vocals = 0.0 },
    pan_relief_max_db = { drums = 0.25, guitar = 0.35, bass = 0.05, vocals = 0.00 },
  },
  pop = {
    name = "Pop",
    description = "Vocals forward, controlled low-end and guitars.",
    role_offsets = { drums = -1.5, guitar = -2.0, bass = -2.0, vocals = 1.0 },
    pan_relief_max_db = { drums = 0.20, guitar = 0.20, bass = 0.00, vocals = 0.00 },
  },
  rock = {
    name = "Rock",
    description = "Punchy drums and guitars, vocals slightly tucked.",
    role_offsets = { drums = 0.0, guitar = -0.5, bass = -1.0, vocals = -0.5 },
    pan_relief_max_db = { drums = 0.35, guitar = 0.75, bass = 0.10, vocals = 0.15 },
  },
  edm = {
    name = "EDM",
    description = "Low-end and vocal focus with lean mids.",
    role_offsets = { drums = -0.5, guitar = -2.5, bass = 0.0, vocals = 0.5 },
    pan_relief_max_db = { drums = 0.25, guitar = 0.50, bass = 0.05, vocals = 0.10 },
  },
}
local BAND_TYPE_CODE = {
  Band = 0,
  LowShelf = 1,
  HighShelf = 2,
  LowPass = 3,
  HighPass = 4,
  AllPass = 5,
  Notch = 6,
  HP = 4,
  LP = 3,
}
local DEBUG_APPLY_LOG = true

local function get_debug_log_path()
  local dir = reaper.GetResourcePath() .. "/Scripts/MixGuideEQ"
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir .. "/mixguideeq_apply_debug.log"
end

local function append_log(line)
  local file = io.open(get_debug_log_path(), "a")
  if not file then return end
  file:write(line .. "\n")
  file:close()
end

local function clear_apply_log()
  local file = io.open(get_debug_log_path(), "w")
  if not file then return end
  file:write("=== MixGuideEQ Apply Debug Log ===\n")
  file:close()
end

local function log_apply(msg_text)
  if not DEBUG_APPLY_LOG then return end
  local line = "[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. tostring(msg_text)
  append_log(line)
end

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

local function get_project_folder_and_name()
  local _, proj_path = reaper.EnumProjects(-1)
  if not proj_path or proj_path == "" then
    return nil, nil
  end

  local folder = proj_path:match("^(.+[\\/])[^\\/]+$")
  local name = proj_path:match("^.+[\\/]([^\\/.]+)%.")
  if not folder or not name then
    return nil, nil
  end
  return folder, name
end

local function get_project_role_map_path()
  local folder, name = get_project_folder_and_name()
  if not folder or not name then
    return nil
  end
  return folder .. name .. ".mixguideeq.roles"
end

local function save_project_roles()
  local path = get_project_role_map_path()
  if not path then
    return false, "Project must be saved before role assignments can persist."
  end

  local file = io.open(path, "w")
  if not file then
    return false, "Could not write role map file."
  end

  file:write("# MixGuideEQ role map\n")
  for guid, role in pairs(app.track_roles) do
    local excluded = app.track_excluded[guid] == true and "1" or "0"
    file:write(tostring(guid) .. "\t" .. tostring(role) .. "\t" .. excluded .. "\n")
  end
  file:close()
  return true, path
end

local function load_project_roles()
  local path = get_project_role_map_path()
  if not path then
    return false, ""
  end

  local file = io.open(path, "r")
  if not file then
    return false, path
  end

  local loaded_roles = {}
  local loaded_excluded = {}
  for line in file:lines() do
    if line:sub(1, 1) ~= "#" and line ~= "" then
      local guid, role, excluded = line:match("^(.-)\t(.-)\t(.-)$")
      if not guid then
        guid, role = line:match("^(.-)\t(.-)$")
        excluded = "0"
      end
      if guid and role then
        local normalized = eq_rules.normalize_role(role)
        if normalized == "drums" or normalized == "guitar" or normalized == "bass" or normalized == "vocals" then
          loaded_roles[guid] = normalized
          loaded_excluded[guid] = (tostring(excluded) == "1" or tostring(excluded):lower() == "true")
        end
      end
    end
  end
  file:close()

  app.track_roles = loaded_roles
  app.track_excluded = loaded_excluded
  return true, path
end

local function get_track_name(track, fallback)
  local ok, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if ok and name and name ~= "" then
    return name
  end
  return fallback
end

local function guess_role_from_name(name)
  local n = (name or ""):lower()
  if n:find("vox", 1, true) or n:find("vocal", 1, true) then return "vocals" end
  if n:find("bass", 1, true) then return "bass" end
  if n:find("drum", 1, true)
    or n:find("kick", 1, true)
    or n:find("snare", 1, true)
    or n:find("tom", 1, true)
    or n:find("hat", 1, true)
    or n:find("hihat", 1, true)
    or n:find("hh", 1, true)
    or n:find("crash", 1, true)
    or n:find("ride", 1, true)
    or n:find("cym", 1, true)
    or n:find("overhead", 1, true)
    or n:find("room", 1, true)
  then
    return "drums"
  end
  if n:find("gtr", 1, true) or n:find("guitar", 1, true) then return "guitar" end
  return "ignore"
end

local function get_track_by_guid(guid)
  local count = reaper.CountTracks(0)
  for i = 0, count - 1 do
    local track = reaper.GetTrack(0, i)
    if reaper.GetTrackGUID(track) == guid then
      return track
    end
  end
  return nil
end

local function has_audio_items(track)
  return reaper.CountTrackMediaItems(track) > 0
end

local function safe_div(num, den)
  if not den or math.abs(den) < 1e-12 then
    return 0.0
  end
  return num / den
end

local function clamp(v, lo, hi)
  return math.max(lo, math.min(hi, v))
end

local function vol_to_db(vol)
  local v = tonumber(vol) or 0
  if v <= 0 then
    return -150.0
  end
  return 20.0 * (math.log(v) / math.log(10.0))
end

local function db_to_vol(db)
  return 10.0 ^ ((tonumber(db) or 0) / 20.0)
end

local function median(values)
  if not values or #values == 0 then return nil end
  local sorted = {}
  for i = 1, #values do
    sorted[i] = values[i]
  end
  table.sort(sorted)
  local n = #sorted
  if n % 2 == 1 then
    return sorted[(n + 1) / 2]
  end
  return (sorted[n / 2] + sorted[(n / 2) + 1]) * 0.5
end

local function normalize_volume_profile_name(profile_name)
  local key = tostring(profile_name or "even"):lower()
  if VOLUME_PROFILES[key] then
    return key
  end
  return "even"
end

local function get_volume_profile(profile_name)
  return VOLUME_PROFILES[normalize_volume_profile_name(profile_name)]
end

local function get_volume_profiles()
  return { "Even", "Pop", "Rock", "EDM" }
end

local function get_profile_emphasis_for_role(profile_name, role)
  local profile = get_volume_profile(profile_name)
  local offset = (profile.role_offsets and profile.role_offsets[role]) or 0
  local pan_relief = (profile.pan_relief_max_db and profile.pan_relief_max_db[role]) or 0
  local base_msg = ""
  if offset >= 0.75 then
    base_msg = profile.name .. " profile: push " .. tostring(role) .. " forward."
  elseif offset <= -1.5 then
    base_msg = profile.name .. " profile: keep " .. tostring(role) .. " more tucked."
  else
    base_msg = profile.name .. " profile: keep " .. tostring(role) .. " near neutral."
  end
  if pan_relief > 0 then
    base_msg = base_msg .. string.format(" Pan-aware relief up to %.2f dB for wider panning.", pan_relief)
  end
  return base_msg
end

local function get_pan_relief_db(profile, role, pan)
  local max_relief = 0.0
  if profile and profile.pan_relief_max_db then
    max_relief = tonumber(profile.pan_relief_max_db[role]) or 0.0
  end
  local pan_amount = clamp(math.abs(tonumber(pan) or 0.0), 0.0, 1.0)
  return pan_amount * max_relief
end

local function get_child_balance_offset(role, track_name)
  local name = tostring(track_name or "")
  local lower = name:lower()

  if role == "drums" and eq_rules.detect_drum_subtype then
    local subtype = eq_rules.detect_drum_subtype(name)
    if subtype == "kick" then return 0.0, "kick anchor" end
    if subtype == "snare" then return -0.5, "snare slightly below kick" end
    if subtype == "toms" then return -1.0, "toms under kick/snare" end
    if subtype == "overheads" then return -1.5, "overheads as cymbal support" end
    if subtype == "room" then return -2.0, "room mic kept behind close mics" end
    return -0.8, "general drum support"
  end

  if role == "vocals" then
    if lower:find("back", 1, true) or lower:find("bg", 1, true) or lower:find("harm", 1, true) or lower:find("dbl", 1, true) then
      return -2.0, "backing vocal support"
    end
    return 0.0, "lead vocal anchor"
  end

  if role == "guitar" then
    if lower:find("lead", 1, true) or lower:find("solo", 1, true) then
      return 0.4, "lead guitar foreground"
    end
    if lower:find("rhythm", 1, true) then
      return -0.6, "rhythm guitar support"
    end
    return -0.3, "guitar layer balance"
  end

  if role == "bass" then
    return 0.0, "bass foundation"
  end

  return 0.0, "neutral"
end

local function goertzel_power(samples, freq, sample_rate)
  local n = #samples
  if n == 0 then return 0.0 end
  local k = math.floor(0.5 + ((n * freq) / sample_rate))
  local w = (2.0 * math.pi / n) * k
  local coeff = 2.0 * math.cos(w)
  local s_prev = 0.0
  local s_prev2 = 0.0
  for i = 1, n do
    local s = samples[i] + coeff * s_prev - s_prev2
    s_prev2 = s_prev
    s_prev = s
  end
  return s_prev2 * s_prev2 + s_prev * s_prev - coeff * s_prev * s_prev2
end

local function analyze_track_frequency_profile(track)
  if not reaper.CreateTrackAudioAccessor then
    return nil, "Track audio accessor API unavailable"
  end

  local accessor = reaper.CreateTrackAudioAccessor(track)
  if not accessor then
    return nil, "Could not create track audio accessor"
  end

  local start_t = reaper.GetAudioAccessorStartTime(accessor)
  local end_t = reaper.GetAudioAccessorEndTime(accessor)
  local duration = (end_t or 0) - (start_t or 0)
  if duration <= 0 then
    reaper.DestroyAudioAccessor(accessor)
    return nil, "No readable audio time range"
  end

  local sr = 11025
  local window_samples = 512
  local max_windows = 120
  local tone_freqs = { 80, 200, 500, 1200, 3000, 7000, 10000 }
  local tone_sums = {}
  for _, f in ipairs(tone_freqs) do
    tone_sums[f] = 0.0
  end

  local sample_buf = reaper.new_array(window_samples)
  local windows = 0
  local rms_sum = 0.0

  local analysis_span = math.max(0.0, duration - (window_samples / sr))
  for w = 0, max_windows - 1 do
    local ratio = 0.0
    if max_windows > 1 then
      ratio = w / (max_windows - 1)
    end
    local t = start_t + (analysis_span * ratio)
    if t + (window_samples / sr) > end_t then
      t = end_t - (window_samples / sr)
    end
    if t < start_t then
      t = start_t
    end

    local ok = reaper.GetAudioAccessorSamples(accessor, sr, 1, t, window_samples, sample_buf)
    if ok then
      local samples = sample_buf.table(1, window_samples)
      local e = 0.0
      for i = 1, #samples do
        local x = samples[i]
        e = e + (x * x)
      end

      local rms = math.sqrt(safe_div(e, #samples))
      if rms > 1e-6 then
        windows = windows + 1
        rms_sum = rms_sum + rms
        for _, f in ipairs(tone_freqs) do
          tone_sums[f] = tone_sums[f] + goertzel_power(samples, f, sr)
        end
      end
    end
  end

  reaper.DestroyAudioAccessor(accessor)

  if windows == 0 then
    return nil, "No active audio windows (below gate)"
  end

  local avg = {}
  for _, f in ipairs(tone_freqs) do
    avg[f] = tone_sums[f] / windows
  end

  local low = avg[80] + avg[200]
  local low_mid = avg[500] + avg[1200]
  local presence = avg[3000]
  local high = avg[7000] + avg[10000]

  return {
    windows = windows,
    avg_rms = rms_sum / windows,
    low = low,
    low_mid = low_mid,
    presence = presence,
    high = high,
    mud_ratio = safe_div(low_mid, presence + 1e-9),
    brightness_ratio = safe_div(high, low + 1e-9),
    presence_ratio = safe_div(presence, low_mid + 1e-9),
  }, nil
end

local function build_frequency_recommendations(role, track_name, metrics, strength_pct)
  local recs = {}
  local strength = (tonumber(strength_pct) or 100) / 100

  local function push(line)
    recs[#recs + 1] = line
  end

  local function push_ratio_reason(label, amount_db, band_text, metric_name, observed, comparator, threshold)
    push(string.format(
      "%s: %.1f dB @ %s because %s %.2f %s %.2f",
      label,
      amount_db,
      band_text,
      metric_name,
      observed,
      comparator,
      threshold
    ))
  end

  local function push_balance_reason(label, amount_db, band_text, left_name, left_value, comparator, right_name, right_value)
    push(string.format(
      "%s: %.1f dB @ %s because %s %.2f %s %s %.2f",
      label,
      amount_db,
      band_text,
      left_name,
      left_value,
      comparator,
      right_name,
      right_value
    ))
  end

  if role == "guitar" then
    if metrics.mud_ratio > 1.30 then
      push_ratio_reason("Cut mud", 1.5 * strength, "250-350 Hz", "mud ratio", metrics.mud_ratio, ">", 1.30)
    end
    if metrics.presence_ratio < 0.95 then
      push_ratio_reason("Add presence", 1.5 * strength, "2.5-3.5 kHz", "presence ratio", metrics.presence_ratio, "<", 0.95)
    end
    if metrics.brightness_ratio > 1.70 then
      push_ratio_reason("Tame fizz", 1.0 * strength, "6-8 kHz", "brightness ratio", metrics.brightness_ratio, ">", 1.70)
    end
  elseif role == "bass" then
    if metrics.low > (metrics.low_mid * 1.9) then
      push_balance_reason("Control boom", 1.5 * strength, "80-120 Hz", "low energy", metrics.low, ">", "low-mid energy", metrics.low_mid * 1.9)
    end
    if metrics.presence_ratio < 0.80 then
      push_ratio_reason("Add note definition", 1.0 * strength, "1-1.5 kHz", "presence ratio", metrics.presence_ratio, "<", 0.80)
    end
  elseif role == "vocals" then
    if metrics.mud_ratio > 1.20 then
      push_ratio_reason("Reduce mud", 1.5 * strength, "200-350 Hz", "mud ratio", metrics.mud_ratio, ">", 1.20)
    end
    if metrics.presence_ratio < 1.00 then
      push_ratio_reason("Increase clarity", 1.5 * strength, "2.5-4 kHz", "presence ratio", metrics.presence_ratio, "<", 1.00)
    end
    if metrics.brightness_ratio < 0.80 then
      push_ratio_reason("Add air", 1.0 * strength, "10-12 kHz", "brightness ratio", metrics.brightness_ratio, "<", 0.80)
    end
  elseif role == "drums" then
    local subtype = eq_rules.detect_drum_subtype and eq_rules.detect_drum_subtype(track_name)
    if subtype == "kick" then
      if metrics.presence_ratio < 0.85 then
        push_ratio_reason("Kick click", 1.0 * strength, "2.5-4 kHz", "presence ratio", metrics.presence_ratio, "<", 0.85)
      end
      if metrics.mud_ratio > 1.20 then
        push_ratio_reason("Kick boxiness cut", 1.5 * strength, "250-400 Hz", "mud ratio", metrics.mud_ratio, ">", 1.20)
      end
    elseif subtype == "snare" then
      if metrics.presence_ratio < 0.95 then
        push_ratio_reason("Snare crack", 1.5 * strength, "3-5 kHz", "presence ratio", metrics.presence_ratio, "<", 0.95)
      end
      if metrics.mud_ratio > 1.20 then
        push_ratio_reason("Snare ring/box cut", 1.0 * strength, "500-800 Hz", "mud ratio", metrics.mud_ratio, ">", 1.20)
      end
    elseif subtype == "overheads" or subtype == "room" then
      if metrics.brightness_ratio > 1.85 then
        push_ratio_reason("Tame cymbal harshness", 1.0 * strength, "7-9 kHz", "brightness ratio", metrics.brightness_ratio, ">", 1.85)
      end
      if metrics.mud_ratio > 1.10 then
        push_ratio_reason("Low cleanup", 1.0 * strength, "200-350 Hz", "mud ratio", metrics.mud_ratio, ">", 1.10)
      end
    else
      if metrics.presence_ratio < 0.90 then
        push_ratio_reason("Add attack/presence", 1.0 * strength, "3-4 kHz", "presence ratio", metrics.presence_ratio, "<", 0.90)
      end
      if metrics.mud_ratio > 1.20 then
        push_ratio_reason("Reduce boxiness", 1.0 * strength, "350-600 Hz", "mud ratio", metrics.mud_ratio, ">", 1.20)
      end
    end
  end

  if #recs == 0 then
    push("No strong corrective move indicated by current analysis.")
  end

  return recs
end

local function scan_track_entries()
  local entries = {}
  local count = reaper.CountTracks(0)
  local depth = 0
  local active_root_name = nil
  local active_root_role = "ignore"
  local active_root_guid = nil

  for i = 0, count - 1 do
    local track = reaper.GetTrack(0, i)
    local guid = reaper.GetTrackGUID(track)
    local name = get_track_name(track, "Track " .. tostring(i + 1))
    local folder_delta = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_FOLDERDEPTH") or 0)
    local root_level = depth == 0

    local inferred = "ignore"
    local display = name

    if root_level then
      inferred = guess_role_from_name(name)
      active_root_name = name
      active_root_role = inferred
      active_root_guid = guid
    else
      display = (active_root_name or "Parent") .. "-" .. name
      if active_root_role ~= "ignore" then
        inferred = active_root_role
      else
        inferred = guess_role_from_name(name)
      end
    end

    if inferred == "ignore" then
      inferred = "vocals"
    end

    entries[#entries + 1] = {
      guid = guid,
      idx = i,
      name = name,
      display_name = display,
      inferred_role = inferred,
      root_guid = root_level and guid or active_root_guid,
      root_name = root_level and name or (active_root_name or name),
      is_root = root_level,
      has_audio = has_audio_items(track),
    }

    depth = depth + folder_delta
    if depth <= 0 then
      depth = 0
      active_root_name = nil
      active_root_role = "ignore"
      active_root_guid = nil
    end
  end

  return entries
end

local function ensure_track_role_defaults(entries)
  local seen = {}
  for _, entry in ipairs(entries) do
    seen[entry.guid] = true
    if not app.track_roles[entry.guid] then
      app.track_roles[entry.guid] = entry.inferred_role
    end
    if app.track_excluded[entry.guid] == nil then
      app.track_excluded[entry.guid] = false
    end
  end

  for guid, _ in pairs(app.track_roles) do
    if not seen[guid] then
      app.track_roles[guid] = nil
    end
  end

  for guid, _ in pairs(app.track_excluded) do
    if not seen[guid] then
      app.track_excluded[guid] = nil
    end
  end
end

local function get_roles_order()
  return { "drums", "guitar", "bass", "vocals" }
end

local function build_role_columns()
  local entries = scan_track_entries()
  ensure_track_role_defaults(entries)

  local columns = {
    drums = {},
    guitar = {},
    bass = {},
    vocals = {},
  }

  for _, entry in ipairs(entries) do
    local role = app.track_roles[entry.guid] or entry.inferred_role
    if columns[role] == nil then
      role = "vocals"
      app.track_roles[entry.guid] = role
    end

    columns[role][#columns[role] + 1] = {
      guid = entry.guid,
      idx = entry.idx,
      name = entry.name,
      display_name = entry.display_name,
      root_guid = entry.root_guid,
      root_name = entry.root_name,
      is_root = entry.is_root,
      has_audio = entry.has_audio,
      excluded = app.track_excluded[entry.guid] == true,
    }
  end

  return columns
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

local function recreate_reaeq(track, old_fx_idx)
  if old_fx_idx and old_fx_idx >= 0 then
    reaper.TrackFX_Delete(track, old_fx_idx)
  end
  return ensure_reaeq(track)
end

local function try_set_named_param(track, fx_idx, key, value)
  if not reaper.TrackFX_SetNamedConfigParm then return false end
  local ok = reaper.TrackFX_SetNamedConfigParm(track, fx_idx, key, tostring(value))
  return ok == true
end

local function supports_named_band_config(track, fx_idx)
  return try_set_named_param(track, fx_idx, "BANDTYPE1", BAND_TYPE_CODE.Band)
end

local function apply_named_profile(track, fx_idx)
  local applied = 0

  local attempts = {
    { "BANDTYPE1", BAND_TYPE_CODE.HP },
    { "BANDENABLED1", 1 },
    { "BANDTYPE2", BAND_TYPE_CODE.Band },
    { "BANDENABLED2", 1 },
    { "BANDTYPE3", BAND_TYPE_CODE.Band },
    { "BANDENABLED3", 1 },
    { "BANDTYPE4", BAND_TYPE_CODE.Band },
    { "BANDENABLED4", 1 },
  }

  for _, entry in ipairs(attempts) do
    if try_set_named_param(track, fx_idx, entry[1], entry[2]) then
      applied = applied + 1
    end
  end

  return applied
end

local function contains_all_words(haystack, words)
  local lower = (haystack or ""):lower()
  for _, w in ipairs(words) do
    if not lower:find(w:lower(), 1, true) then
      return false
    end
  end
  return true
end

local function contains_any_words(haystack, words)
  local lower = (haystack or ""):lower()
  for _, w in ipairs(words) do
    if lower:find(w:lower(), 1, true) then
      return true
    end
  end
  return false
end

local function find_param_index(track, fx_idx, words)
  local count = reaper.TrackFX_GetNumParams(track, fx_idx)
  for i = 0, count - 1 do
    local ok, name = reaper.TrackFX_GetParamName(track, fx_idx, i, "")
    if ok and contains_all_words(name, words) then
      return i
    end
  end
  return nil
end

local function parse_band_index_from_name(lower_name)
  local n = lower_name:match("band%s*(%d+)")
  if n then return tonumber(n) end
  n = lower_name:match("(%d+)%s*band")
  if n then return tonumber(n) end
  return nil
end

local function build_band_param_map(track, fx_idx)
  local count = reaper.TrackFX_GetNumParams(track, fx_idx)
  local out = {}
  log_apply("build_band_param_map param_count=" .. tostring(count))

  for i = 0, count - 1 do
    local ok, name = reaper.TrackFX_GetParamName(track, fx_idx, i, "")
    if ok and name then
      local lower = name:lower()
      local band = parse_band_index_from_name(lower)
      if band then
        out[band] = out[band] or {}

        if contains_any_words(lower, { "frequency", "freq" }) and out[band].frequency == nil then
          out[band].frequency = i
          log_apply(string.format("map band=%d frequency -> param %d (%s)", band, i, tostring(name)))
        elseif contains_any_words(lower, { "gain" }) and out[band].gain == nil then
          out[band].gain = i
          log_apply(string.format("map band=%d gain -> param %d (%s)", band, i, tostring(name)))
        elseif contains_any_words(lower, { "q", "bandwidth", "bw" }) and out[band].q == nil then
          out[band].q = i
          log_apply(string.format("map band=%d q -> param %d (%s)", band, i, tostring(name)))
        elseif contains_any_words(lower, { "enable", "enabled" }) and out[band].enable == nil then
          out[band].enable = i
          log_apply(string.format("map band=%d enable -> param %d (%s)", band, i, tostring(name)))
        elseif contains_any_words(lower, { "type" }) and out[band].type == nil then
          out[band].type = i
          log_apply(string.format("map band=%d type -> param %d (%s)", band, i, tostring(name)))
        end
      end
    end
  end

  -- Fallback for ReaEQ layouts where band names omit explicit "Band N" tokens.
  -- ReaEQ commonly exposes first 15 params as 5 bands x (Freq, Gain, BW).
  if count >= 15 then
    for band = 1, 5 do
      out[band] = out[band] or {}
      local base = (band - 1) * 3
      if out[band].frequency == nil then
        out[band].frequency = base
        log_apply(string.format("fallback map band=%d frequency -> param %d", band, base))
      end
      if out[band].gain == nil then
        out[band].gain = base + 1
        log_apply(string.format("fallback map band=%d gain -> param %d", band, base + 1))
      end
      if out[band].q == nil then
        out[band].q = base + 2
        log_apply(string.format("fallback map band=%d q -> param %d", band, base + 2))
      end
    end
  end

  return out
end

local function normalize_param_value(kind, value)
  if kind == "frequency" then
    local hz = math.max(20, math.min(24000, value))
    local min_hz = 20
    local max_hz = 24000
    return (math.log(hz) - math.log(min_hz)) / (math.log(max_hz) - math.log(min_hz))
  end
  if kind == "gain" then
    local db = math.max(-24, math.min(24, value))
    return (db + 24) / 48
  end
  if kind == "q" then
    local q = math.max(0.1, math.min(5.0, value))
    return (q - 0.1) / 4.9
  end
  return value
end

local function set_param_value(track, fx_idx, param_idx, kind, value)
  local target = value
  local normalized = false

  if kind == "frequency" or kind == "gain" or kind == "q" then
    target = normalize_param_value(kind, value)
    normalized = true
  end

  local clamped = math.max(0.0, math.min(1.0, target))
  local set_ok = reaper.TrackFX_SetParam(track, fx_idx, param_idx, clamped)
  local read_back = reaper.TrackFX_GetParam(track, fx_idx, param_idx)
  log_apply(string.format(
    "set_param_value kind=%s param=%d raw=%.5f normalized=%s target=%.5f write=%s readback=%.5f",
    tostring(kind),
    param_idx,
    tonumber(value) or -9999,
    tostring(normalized),
    tonumber(clamped) or -9999,
    tostring(set_ok),
    tonumber(read_back) or -9999
  ))
  return set_ok
end

local function set_band_param_by_name(track, fx_idx, band_idx, kind_words, value)
  local kind_key = kind_words[1]

  local band_map = build_band_param_map(track, fx_idx)
  local band_entry = band_map[band_idx]
  if band_entry and band_entry[kind_key] ~= nil then
    log_apply(string.format("set_band_param_by_name direct-map band=%d kind=%s param=%d value=%.5f", band_idx, kind_key, band_entry[kind_key], tonumber(value) or -9999))
    return set_param_value(track, fx_idx, band_entry[kind_key], kind_key, value)
  end

  local words = { "band", tostring(band_idx) }
  for _, w in ipairs(kind_words) do
    words[#words + 1] = w
  end

  local param_idx = find_param_index(track, fx_idx, words)
  if param_idx == nil then
    log_apply(string.format("set_band_param_by_name failed to resolve band=%d kind=%s", band_idx, kind_key))
    return false
  end
  log_apply(string.format("set_band_param_by_name strict-search band=%d kind=%s param=%d value=%.5f", band_idx, kind_key, param_idx, tonumber(value) or -9999))
  return set_param_value(track, fx_idx, param_idx, kind_key, value)
end

local function dump_fx_params(track, fx_idx)
  local count = reaper.TrackFX_GetNumParams(track, fx_idx)
  log_apply("dump_fx_params count=" .. tostring(count))
  for i = 0, count - 1 do
    local ok_name, name = reaper.TrackFX_GetParamName(track, fx_idx, i, "")
    local ok_ex, _, min_val, max_val = reaper.TrackFX_GetParamEx(track, fx_idx, i)
    local cur = reaper.TrackFX_GetParam(track, fx_idx, i)
    log_apply(string.format(
      "param[%d] name=%s ok_name=%s ok_ex=%s min=%.5f max=%.5f cur=%.5f",
      i,
      tostring(name),
      tostring(ok_name),
      tostring(ok_ex),
      tonumber(min_val) or -9999,
      tonumber(max_val) or -9999,
      tonumber(cur) or -9999
    ))
  end
end

local function set_band_enabled(track, fx_idx, band_idx, enabled)
  local key = string.format("BANDENABLED%d", band_idx)
  local val = enabled and 1 or 0
  if try_set_named_param(track, fx_idx, key, val) then
    return true
  end
  return set_band_param_by_name(track, fx_idx, band_idx, { "enable" }, val)
end

local function set_band_type(track, fx_idx, band_idx, band_type)
  local type_code = BAND_TYPE_CODE[band_type]
  if type_code == nil then
    log_apply(string.format("set_band_type unknown band_type=%s", tostring(band_type)))
    return false
  end

  local key = string.format("BANDTYPE%d", band_idx)
  if try_set_named_param(track, fx_idx, key, type_code) then
    return true
  end
  log_apply(string.format("set_band_type failed key=%s type=%s code=%d", key, tostring(band_type), type_code))
  return false
end

local function collect_rule_moves(rule)
  local moves = {}

  local function push_if_present(gain_key, freq_key, band_type)
    local gain = rule[gain_key]
    local freq = rule[freq_key]
    if type(gain) == "number" and type(freq) == "number" then
      moves[#moves + 1] = {
        gain = gain,
        freq = freq,
        q = 1.0,
        band_type = band_type or "Band",
      }
    end
  end

  push_if_present("low_shelf_boost_db", "low_shelf_hz", "LowShelf")
  push_if_present("low_cut_db", "low_cut_hz", "Band")
  push_if_present("mud_cut_db", "mud_cut_hz", "Band")
  push_if_present("punch_boost_db", "punch_hz", "Band")
  push_if_present("boxy_cut_db", "boxy_hz", "Band")
  push_if_present("presence_boost_db", "presence_hz", "Band")
  push_if_present("definition_boost_db", "definition_hz", "Band")
  push_if_present("air_boost_db", "air_hz", "HighShelf")
  push_if_present("fizz_cut_db", "fizz_hz", "Band")

  return moves
end

local function render_applied_rule_lines(rule)
  local out = {
    "HPF: " .. tostring(rule.hpf_hz or 80) .. " Hz",
  }

  local moves = collect_rule_moves(rule)
  local labels = {
    "Move 1",
    "Move 2",
    "Move 3",
  }

  for i = 1, MAX_RULE_MOVES do
    local move = moves[i]
    if move then
      out[#out + 1] = string.format("%s: %.1f dB @ %d Hz (Q %.2f)", labels[i], move.gain, move.freq, move.q or 1.0)
    end
  end

  return out
end

local function apply_rule_curve(track, fx_idx, rule)
  local writes = 0

  if set_band_enabled(track, fx_idx, 1, true) then writes = writes + 1 end
  if set_band_type(track, fx_idx, 1, "HP") then writes = writes + 1 end
  if set_band_param_by_name(track, fx_idx, 1, { "frequency" }, rule.hpf_hz or 80) then writes = writes + 1 end
  if set_band_param_by_name(track, fx_idx, 1, { "q" }, 0.707) then writes = writes + 1 end

  local moves = collect_rule_moves(rule)
  for i = 1, MAX_RULE_MOVES do
    local band_idx = i + 1
    local move = moves[i]
    if move then
      if set_band_enabled(track, fx_idx, band_idx, true) then writes = writes + 1 end
      if set_band_type(track, fx_idx, band_idx, move.band_type) then writes = writes + 1 end
      if set_band_param_by_name(track, fx_idx, band_idx, { "frequency" }, move.freq) then writes = writes + 1 end
      if set_band_param_by_name(track, fx_idx, band_idx, { "gain" }, move.gain) then writes = writes + 1 end
      if set_band_param_by_name(track, fx_idx, band_idx, { "q" }, move.q or 1.0) then writes = writes + 1 end
    else
      if set_band_enabled(track, fx_idx, band_idx, false) then writes = writes + 1 end
    end
  end

  return writes
end

local function apply_rule_curve_default_layout(track, fx_idx, rule)
  local writes = 0

  -- Default ReaEQ layout slots:
  -- band 2/3: bell-like moves, band 4: high shelf, band 5: high-pass.
  if set_band_param_by_name(track, fx_idx, 5, { "frequency" }, rule.hpf_hz or 80) then writes = writes + 1 end
  if set_band_param_by_name(track, fx_idx, 5, { "q" }, 0.707) then writes = writes + 1 end

  local moves = collect_rule_moves(rule)
  local move_bands = { 2, 3, 4 }
  for i = 1, MAX_RULE_MOVES do
    local move = moves[i]
    if move then
      local band_idx = move_bands[i]
      if set_band_param_by_name(track, fx_idx, band_idx, { "frequency" }, move.freq) then writes = writes + 1 end
      if set_band_param_by_name(track, fx_idx, band_idx, { "gain" }, move.gain) then writes = writes + 1 end
      if set_band_param_by_name(track, fx_idx, band_idx, { "q" }, move.q or 1.0) then writes = writes + 1 end
    end
  end

  return writes
end

local function apply_rule_to_track(track, role, strength_pct, track_label)
  if not track then
    return false, "Invalid track selection"
  end

  local _, track_name = reaper.GetTrackName(track)
  local rule = eq_rules.build_rule_set(role, strength_pct, {
    track_name = track_name,
    track_label = track_label,
  })
  log_apply("apply_rule_to_track role=" .. tostring(role) .. " strength=" .. tostring(strength_pct) .. " track=" .. tostring(track_name))
  local fx_idx = ensure_reaeq(track)
  if not fx_idx or fx_idx < 0 then
    log_apply("ensure_reaeq failed for track=" .. tostring(track_name))
    return false, "Could not insert or find ReaEQ"
  end
  log_apply("ensure_reaeq fx_idx=" .. tostring(fx_idx) .. " track=" .. tostring(track_name))
  dump_fx_params(track, fx_idx)

  local applied = 0
  if supports_named_band_config(track, fx_idx) then
    log_apply("named band config supported; using band type/enable path")
    applied = apply_named_profile(track, fx_idx)
    applied = applied + apply_rule_curve(track, fx_idx, rule)
  else
    log_apply("named band config unsupported; recreating ReaEQ and using default-layout path")
    fx_idx = recreate_reaeq(track, fx_idx)
    if not fx_idx or fx_idx < 0 then
      log_apply("recreate_reaeq failed for track=" .. tostring(track_name))
      return false, "Could not recreate ReaEQ for fallback apply"
    end
    log_apply("fallback ensure_reaeq fx_idx=" .. tostring(fx_idx) .. " track=" .. tostring(track_name))
    dump_fx_params(track, fx_idx)
    applied = apply_rule_curve_default_layout(track, fx_idx, rule)
  end
  log_apply("apply_rule_to_track writes=" .. tostring(applied) .. " track=" .. tostring(track_name))

  local msg_out = "Inserted/updated ReaEQ for " .. tostring(role) .. "."
  if applied == 0 then
    msg_out = msg_out .. " Rule summary generated; parameter writes were not accepted on this Reaper build."
  end
  return true, msg_out
end

local function build_suggestions(strength_pct, profile_name)
  local columns = build_role_columns()
  local roles = get_roles_order()
  local rows = {}
  local total_audio_tracks = 0
  local profile = get_volume_profile(profile_name)

  local analysis_by_role = {}
  if app.last_frequency_report and app.last_frequency_report.rows then
    for _, role_row in ipairs(app.last_frequency_report.rows) do
      analysis_by_role[role_row.role] = role_row
    end
  end

  for _, role in ipairs(roles) do
    local audio_tracks = {}
    local excluded_tracks = {}
    local track_suggestions = {}
    local drum_subtype_counts = {}
    for _, item in ipairs(columns[role]) do
      if item.excluded then
        excluded_tracks[#excluded_tracks + 1] = item.display_name
      elseif item.has_audio then
        audio_tracks[#audio_tracks + 1] = item.display_name
        if role == "drums" and eq_rules.detect_drum_subtype then
          local subtype = eq_rules.detect_drum_subtype(item.name or item.display_name)
          if subtype then
            drum_subtype_counts[subtype] = (drum_subtype_counts[subtype] or 0) + 1
          end
        end
      end
    end
    total_audio_tracks = total_audio_tracks + #audio_tracks

    local role_profile_offset = (profile.role_offsets and profile.role_offsets[role]) or 0.0
    local role_strength_scale = clamp(1.0 + (role_profile_offset * 0.12), 0.75, 1.30)
    local role_strength_pct = math.floor((tonumber(strength_pct) or 100) * role_strength_scale + 0.5)

    local rule = eq_rules.build_rule_set(role, role_strength_pct)
    local summary = eq_rules.render_summary(rule)
    local analysis_role_row = analysis_by_role[role]
    local analysis_track_by_guid = {}
    local analysis_track_by_name = {}
    if analysis_role_row and analysis_role_row.tracks then
      for _, tr in ipairs(analysis_role_row.tracks) do
        local guid_key = tostring(tr.guid or "")
        local name_key = tostring(tr.name or "")
        if guid_key ~= "" then
          analysis_track_by_guid[guid_key] = tr
        end
        if name_key ~= "" then
          analysis_track_by_name[name_key] = tr
        end
      end
    end

    for _, item in ipairs(columns[role]) do
      if item.has_audio and not item.excluded then
        local track_rule = eq_rules.build_rule_set(role, role_strength_pct, {
          track_name = item.name,
          track_label = item.display_name,
        })
        local lines_for_track = render_applied_rule_lines(track_rule)

        if math.abs(role_profile_offset) >= 0.25 then
          lines_for_track[#lines_for_track + 1] = string.format("Profile level intent: %+.1f dB", role_profile_offset)
        end

        local analysis_track = analysis_track_by_guid[tostring(item.guid)]
          or analysis_track_by_name[tostring(item.display_name)]
        if analysis_track and analysis_track.recommendations then
          local analysis_lines = {}
          for _, rec in ipairs(analysis_track.recommendations) do
            local rec_text = tostring(rec or "")
            if rec_text ~= ""
              and not rec_text:find("No strong corrective", 1, true)
              and not rec_text:find("No recommendation", 1, true)
            then
              analysis_lines[#analysis_lines + 1] = rec_text
            end
            if #analysis_lines >= MAX_RULE_MOVES then
              break
            end
          end
          if #analysis_lines > 0 then
            lines_for_track = {}
            for i = 1, #analysis_lines do
              lines_for_track[#lines_for_track + 1] = string.format("Analysis move %d: %s", i, analysis_lines[i])
            end
          end
        end

        track_suggestions[#track_suggestions + 1] = {
          guid = item.guid,
          name = item.display_name,
          lines = lines_for_track,
        }
      end
    end

    if #track_suggestions > 0 then
      summary = summary .. "\nPer-track suggestions enabled."
    end
    if role == "drums" then
      local parts = {}
      for _, subtype in ipairs({ "kick", "snare", "toms", "overheads", "room" }) do
        local count = drum_subtype_counts[subtype] or 0
        if count > 0 then
          parts[#parts + 1] = subtype .. ": " .. tostring(count)
        end
      end
      if #parts > 0 then
        summary = summary .. "\nDrum subtype tracks: " .. table.concat(parts, ", ")
      end
    end

    local lines = render_applied_rule_lines(rule)
    if analysis_role_row and analysis_role_row.tracks then
      local counts = {}
      for _, tr in ipairs(analysis_role_row.tracks) do
        for _, rec in ipairs(tr.recommendations or {}) do
          local rec_text = tostring(rec or "")
          if rec_text ~= ""
            and not rec_text:find("No strong corrective", 1, true)
            and not rec_text:find("No recommendation", 1, true)
          then
            counts[rec_text] = (counts[rec_text] or 0) + 1
          end
        end
      end

      local ranked = {}
      for rec_text, count in pairs(counts) do
        ranked[#ranked + 1] = { text = rec_text, count = count }
      end
      table.sort(ranked, function(a, b)
        if a.count == b.count then
          return a.text < b.text
        end
        return a.count > b.count
      end)

      if #ranked > 0 then
        lines = {}
        for i = 1, math.min(MAX_RULE_MOVES, #ranked) do
          lines[#lines + 1] = string.format("Analysis move %d: %s", i, ranked[i].text)
        end
        summary = summary .. "\nSuggestions are analysis-informed from current track spectra."
      end
    end

    summary = summary .. "\n" .. get_profile_emphasis_for_role(profile.name, role)
    summary = summary .. string.format("\nProfile suggestion strength scale: %.2fx", role_strength_scale)

    rows[#rows + 1] = {
      role = role,
      profile = profile.name,
      audio_track_count = #audio_tracks,
      audio_tracks = audio_tracks,
      excluded_track_count = #excluded_tracks,
      excluded_tracks = excluded_tracks,
      track_suggestions = track_suggestions,
      summary = summary,
      lines = lines,
    }
  end

  return {
    columns = columns,
    rows = rows,
    total_audio_tracks = total_audio_tracks,
    profile = profile.name,
  }
end

local function analyze_volume_report(profile_name)
  local profile = get_volume_profile(profile_name)
  local columns = build_role_columns()
  local roles = get_roles_order()
  local rows = {}
  local all_group_medians = {}

  for _, role in ipairs(roles) do
    local groups_by_root = {}
    local row = {
      role = role,
      profile_note = get_profile_emphasis_for_role(profile.name, role),
      analyzed_track_count = 0,
      excluded_track_count = 0,
      skipped_track_count = 0,
      groups = {},
    }

    for _, item in ipairs(columns[role]) do
      if item.excluded then
        row.excluded_track_count = row.excluded_track_count + 1
      elseif not item.has_audio then
        row.skipped_track_count = row.skipped_track_count + 1
      else
        local track = get_track_by_guid(item.guid)
        if not track then
          row.skipped_track_count = row.skipped_track_count + 1
        else
          row.analyzed_track_count = row.analyzed_track_count + 1
          local root_guid = item.root_guid or item.guid
          local group = groups_by_root[root_guid]
          if not group then
            group = {
              role = role,
              root_guid = root_guid,
              root_name = item.root_name or item.name or item.display_name,
              entries = {},
            }
            groups_by_root[root_guid] = group
          end

          local pan = tonumber(reaper.GetMediaTrackInfo_Value(track, "D_PAN") or 0.0) or 0.0
          local current_db = vol_to_db(reaper.GetMediaTrackInfo_Value(track, "D_VOL") or 1.0)
          local pan_relief_db = get_pan_relief_db(profile, role, pan)

          group.entries[#group.entries + 1] = {
            guid = item.guid,
            name = item.display_name,
            base_name = item.name,
            pan = pan,
            pan_relief_db = pan_relief_db,
            current_db = current_db,
            effective_db = current_db - pan_relief_db,
            is_root = item.is_root == true,
          }
        end
      end
    end

    for _, group in pairs(groups_by_root) do
      local values_raw = {}
      local values_effective = {}
      for _, entry in ipairs(group.entries) do
        values_raw[#values_raw + 1] = entry.current_db
        values_effective[#values_effective + 1] = entry.effective_db or entry.current_db
      end
      group.current_db = median(values_raw) or -18.0
      group.effective_db = median(values_effective) or group.current_db
      all_group_medians[#all_group_medians + 1] = { role = role, db = group.effective_db }
      row.groups[#row.groups + 1] = group
    end

    table.sort(row.groups, function(a, b)
      return tostring(a.root_name or "") < tostring(b.root_name or "")
    end)
    rows[#rows + 1] = row
  end

  local vocal_refs = {}
  for _, item in ipairs(all_group_medians) do
    if item.role == "vocals" then
      vocal_refs[#vocal_refs + 1] = item.db
    end
  end
  local reference_db = median(vocal_refs)
  if not reference_db then
    local all_refs = {}
    for _, item in ipairs(all_group_medians) do
      all_refs[#all_refs + 1] = item.db
    end
    reference_db = median(all_refs) or -18.0
  end

  local root_adjustments = {}
  local track_adjustments = {}
  local total_nonzero = 0

  for _, row in ipairs(rows) do
    local role_offset = (profile.role_offsets and profile.role_offsets[row.role]) or 0.0
    row.target_role_db = reference_db + role_offset

    for _, group in ipairs(row.groups) do
      group.group_delta_db = clamp(row.target_role_db - group.effective_db, -MAX_ROOT_DELTA_DB, MAX_ROOT_DELTA_DB)
      if math.abs(group.group_delta_db) < MIN_APPLY_DELTA_DB then
        group.group_delta_db = 0.0
      end
      group.target_db = group.current_db + group.group_delta_db
      group.can_apply_root = app.track_excluded[group.root_guid] ~= true

      root_adjustments[#root_adjustments + 1] = {
        role = row.role,
        root_guid = group.root_guid,
        root_name = group.root_name,
        current_db = group.current_db,
        target_db = group.target_db,
        delta_db = group.group_delta_db,
        can_apply = group.can_apply_root,
      }

      for _, track_row in ipairs(group.entries) do
        local child_offset, reason = get_child_balance_offset(row.role, track_row.base_name or track_row.name)
        local child_target_db = group.current_db + child_offset + (track_row.pan_relief_db or 0.0)
        local child_delta_db = clamp(child_target_db - track_row.current_db, -MAX_CHILD_DELTA_DB, MAX_CHILD_DELTA_DB)
        if math.abs(child_delta_db) < MIN_APPLY_DELTA_DB then
          child_delta_db = 0.0
        end

        track_row.child_reason = reason
        track_row.child_target_db = child_target_db
        track_row.child_delta_db = child_delta_db
        track_row.final_preview_delta_db = child_delta_db + group.group_delta_db
        track_row.final_target_db = track_row.current_db + track_row.final_preview_delta_db

        if math.abs(track_row.final_preview_delta_db) >= MIN_APPLY_DELTA_DB then
          total_nonzero = total_nonzero + 1
        end

        track_adjustments[#track_adjustments + 1] = {
          role = row.role,
          guid = track_row.guid,
          name = track_row.name,
          root_guid = group.root_guid,
          pan = track_row.pan,
          pan_relief_db = track_row.pan_relief_db,
          child_reason = reason,
          current_db = track_row.current_db,
          child_target_db = child_target_db,
          child_delta_db = child_delta_db,
          root_delta_db = group.group_delta_db,
          final_target_db = track_row.final_target_db,
          final_preview_delta_db = track_row.final_preview_delta_db,
        }
      end
    end
  end

  local summary = string.format(
    "Volume report (%s): reference %.2f dB, %d track adjustment(s), %d root adjustment(s).",
    profile.name,
    reference_db,
    #track_adjustments,
    #root_adjustments
  )

  local report = {
    profile = profile.name,
    profile_description = profile.description,
    reference_db = reference_db,
    summary = summary,
    rows = rows,
    track_adjustments = track_adjustments,
    root_adjustments = root_adjustments,
    nonzero_adjustments = total_nonzero,
  }
  app.last_volume_report = report
  return report
end

local function apply_volume_balance(profile_name)
  local report = analyze_volume_report(profile_name)
  if not report then
    return false, "No volume report available.", {}
  end

  local errors = {}
  local applied_track_adjustments = 0
  local applied_root_adjustments = 0

  reaper.Undo_BeginBlock()
  local apply_ok, apply_err = pcall(function()
    for _, action in ipairs(report.track_adjustments or {}) do
      if math.abs(action.child_delta_db or 0) >= MIN_APPLY_DELTA_DB then
        local track = get_track_by_guid(action.guid)
        if track then
          local current_vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL") or 1.0
          local next_vol = clamp(current_vol * db_to_vol(action.child_delta_db), MIN_TRACK_VOL, MAX_TRACK_VOL)
          reaper.SetMediaTrackInfo_Value(track, "D_VOL", next_vol)
          applied_track_adjustments = applied_track_adjustments + 1
        else
          errors[#errors + 1] = tostring(action.name) .. ": track not found for child adjustment"
        end
      end
    end

    for _, action in ipairs(report.root_adjustments or {}) do
      if math.abs(action.delta_db or 0) >= MIN_APPLY_DELTA_DB then
        if action.can_apply ~= true then
          errors[#errors + 1] = tostring(action.root_name) .. ": root adjustment skipped (root excluded)"
        else
          local root_track = get_track_by_guid(action.root_guid)
          if root_track then
            local current_vol = reaper.GetMediaTrackInfo_Value(root_track, "D_VOL") or 1.0
            local next_vol = clamp(current_vol * db_to_vol(action.delta_db), MIN_TRACK_VOL, MAX_TRACK_VOL)
            reaper.SetMediaTrackInfo_Value(root_track, "D_VOL", next_vol)
            applied_root_adjustments = applied_root_adjustments + 1
          else
            errors[#errors + 1] = tostring(action.root_name) .. ": root track not found"
          end
        end
      end
    end
  end)
  reaper.Undo_EndBlock("MixGuideEQ: Apply volume balance (" .. tostring(report.profile) .. ")", -1)

  if not apply_ok then
    errors[#errors + 1] = "Runtime apply error: " .. tostring(apply_err)
  end

  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  local summary = string.format(
    "Applied level balance (%s): %d child track trim(s), %d root trim(s).",
    tostring(report.profile),
    applied_track_adjustments,
    applied_root_adjustments
  )
  if #errors > 0 then
    summary = summary .. " " .. tostring(#errors) .. " issue(s)."
  end

  local refreshed_report = analyze_volume_report(report.profile)
  return true, summary, errors, refreshed_report
end

local function start_frequency_analysis(strength_pct)
  local columns = build_role_columns()
  local roles = get_roles_order()

  local role_rows = {
    drums = { role = "drums", analyzed_track_count = 0, excluded_track_count = 0, skipped_track_count = 0, tracks = {} },
    guitar = { role = "guitar", analyzed_track_count = 0, excluded_track_count = 0, skipped_track_count = 0, tracks = {} },
    bass = { role = "bass", analyzed_track_count = 0, excluded_track_count = 0, skipped_track_count = 0, tracks = {} },
    vocals = { role = "vocals", analyzed_track_count = 0, excluded_track_count = 0, skipped_track_count = 0, tracks = {} },
  }

  local targets = {}
  local total_excluded = 0
  local total_skipped = 0

  for _, role in ipairs(roles) do
    for _, item in ipairs(columns[role]) do
      if item.excluded then
        role_rows[role].excluded_track_count = role_rows[role].excluded_track_count + 1
        total_excluded = total_excluded + 1
      elseif not item.has_audio then
        role_rows[role].skipped_track_count = role_rows[role].skipped_track_count + 1
        total_skipped = total_skipped + 1
      else
        targets[#targets + 1] = {
          role = role,
          guid = item.guid,
          name = item.name,
          display_name = item.display_name,
        }
      end
    end
  end

  app.frequency_analysis_job = {
    strength_pct = strength_pct,
    targets = targets,
    idx = 1,
    role_rows = role_rows,
    total_excluded = total_excluded,
    total_skipped = total_skipped,
    done = false,
  }

  return true, {
    queued = #targets,
    excluded = total_excluded,
    skipped = total_skipped,
  }
end

local function step_frequency_analysis(max_tracks_per_step)
  local job = app.frequency_analysis_job
  if not job then
    return false, "No active analysis job"
  end

  if job.done then
    return true, {
      done = true,
      progress = 1.0,
      report = app.last_frequency_report,
    }
  end

  local step_n = math.max(1, tonumber(max_tracks_per_step) or 1)
  local processed = 0

  while processed < step_n and job.idx <= #job.targets do
    local target = job.targets[job.idx]
    local role_row = job.role_rows[target.role]
    local track = get_track_by_guid(target.guid)

    if not track then
      role_row.skipped_track_count = role_row.skipped_track_count + 1
      job.total_skipped = job.total_skipped + 1
    else
      local metrics, err = analyze_track_frequency_profile(track)
      if not metrics then
        role_row.tracks[#role_row.tracks + 1] = {
          guid = target.guid,
          name = target.display_name,
          summary = "Skipped: " .. tostring(err or "analysis failed"),
          recommendations = { "No recommendation (analysis unavailable)." },
        }
        role_row.skipped_track_count = role_row.skipped_track_count + 1
        job.total_skipped = job.total_skipped + 1
      else
        role_row.analyzed_track_count = role_row.analyzed_track_count + 1
        role_row.tracks[#role_row.tracks + 1] = {
          guid = target.guid,
          name = target.display_name,
          metrics = {
            windows = metrics.windows,
            avg_rms = metrics.avg_rms,
            mud_ratio = metrics.mud_ratio,
            presence_ratio = metrics.presence_ratio,
            brightness_ratio = metrics.brightness_ratio,
          },
          summary = string.format(
            "RMS %.4f | Mud %.2f | Presence %.2f | Brightness %.2f",
            metrics.avg_rms,
            metrics.mud_ratio,
            metrics.presence_ratio,
            metrics.brightness_ratio
          ),
          recommendations = build_frequency_recommendations(target.role, target.name or target.display_name, metrics, job.strength_pct),
        }
      end
    end

    job.idx = job.idx + 1
    processed = processed + 1
  end

  local processed_total = math.min(job.idx - 1, #job.targets)
  local progress = 1.0
  if #job.targets > 0 then
    progress = processed_total / #job.targets
  end

  if job.idx > #job.targets then
    local roles = get_roles_order()
    local rows = {}
    local total_analyzed = 0
    for _, role in ipairs(roles) do
      local r = job.role_rows[role]
      total_analyzed = total_analyzed + (r.analyzed_track_count or 0)
      rows[#rows + 1] = r
    end

    local summary = string.format(
      "Frequency report: analyzed %d track(s), excluded %d, skipped %d.",
      total_analyzed,
      job.total_excluded,
      job.total_skipped
    )

    local report = {
      summary = summary,
      rows = rows,
    }
    app.last_frequency_report = report
    job.done = true

    return true, {
      done = true,
      progress = 1.0,
      report = report,
    }
  end

  return true, {
    done = false,
    progress = progress,
    processed = processed_total,
    total = #job.targets,
  }
end

local function apply_mapped_roles(strength_pct)
  clear_apply_log()
  log_apply("apply_mapped_roles begin strength=" .. tostring(strength_pct))
  local columns = build_role_columns()
  local roles = get_roles_order()
  local role_track_counts = { drums = 0, guitar = 0, bass = 0, vocals = 0 }
  local targets = {}
  local excluded_audio_tracks = 0

  for _, role in ipairs(roles) do
    for _, item in ipairs(columns[role]) do
      if item.excluded and item.has_audio then
        excluded_audio_tracks = excluded_audio_tracks + 1
      elseif item.has_audio then
        local track = get_track_by_guid(item.guid)
        if track then
          targets[#targets + 1] = { track = track, role = role, label = item.display_name }
          role_track_counts[role] = role_track_counts[role] + 1
        end
      end
    end
  end

  if #targets == 0 then
    log_apply("apply_mapped_roles no targets with audio")
    return false, "No mapped tracks with audio items were found.", {}
  end

  local applied_tracks = 0
  local errors = {}

  reaper.Undo_BeginBlock()
  local apply_ok, apply_err = pcall(function()
    for _, target in ipairs(targets) do
      log_apply("target begin role=" .. tostring(target.role) .. " label=" .. tostring(target.label))
      local ok, err = apply_rule_to_track(target.track, target.role, strength_pct, target.label)
      if ok then
        applied_tracks = applied_tracks + 1
      else
        errors[#errors + 1] = target.label .. ": " .. tostring(err)
        log_apply("target error label=" .. tostring(target.label) .. " err=" .. tostring(err))
      end
    end
  end)
  reaper.Undo_EndBlock("MixGuideEQ: Apply mapped Auto EQ", -1)

  if not apply_ok then
    errors[#errors + 1] = "Runtime apply error: " .. tostring(apply_err)
    log_apply("apply runtime error: " .. tostring(apply_err))
  end

  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  local summary = "Applied Auto EQ to " .. tostring(applied_tracks) .. " track(s) with audio."
  if excluded_audio_tracks > 0 then
    summary = summary .. " Excluded: " .. tostring(excluded_audio_tracks) .. "."
  end
  summary = summary
    .. " D:" .. tostring(role_track_counts.drums)
    .. " G:" .. tostring(role_track_counts.guitar)
    .. " B:" .. tostring(role_track_counts.bass)
    .. " V:" .. tostring(role_track_counts.vocals)
  if #errors > 0 then
    summary = summary .. " " .. tostring(#errors) .. " error(s) occurred."
  end

  summary = summary .. " Debug log: " .. get_debug_log_path()
  log_apply("apply_mapped_roles done summary=" .. summary)

  return true, summary, errors
end

local function analyze_frequency_report(strength_pct)
  local columns = build_role_columns()
  local roles = get_roles_order()
  local rows = {}
  local total_analyzed = 0
  local total_excluded = 0
  local total_skipped = 0

  for _, role in ipairs(roles) do
    local role_rows = {}
    local analyzed_count = 0
    local excluded_count = 0
    local skipped_count = 0

    for _, item in ipairs(columns[role]) do
      if item.excluded then
        excluded_count = excluded_count + 1
      elseif not item.has_audio then
        skipped_count = skipped_count + 1
      else
        local track = get_track_by_guid(item.guid)
        if not track then
          skipped_count = skipped_count + 1
        else
          local metrics, err = analyze_track_frequency_profile(track)
          if not metrics then
            role_rows[#role_rows + 1] = {
              guid = item.guid,
              name = item.display_name,
              summary = "Skipped: " .. tostring(err or "analysis failed"),
              recommendations = { "No recommendation (analysis unavailable)." },
            }
            skipped_count = skipped_count + 1
          else
            analyzed_count = analyzed_count + 1
            role_rows[#role_rows + 1] = {
              guid = item.guid,
              name = item.display_name,
              metrics = {
                windows = metrics.windows,
                avg_rms = metrics.avg_rms,
                mud_ratio = metrics.mud_ratio,
                presence_ratio = metrics.presence_ratio,
                brightness_ratio = metrics.brightness_ratio,
              },
              summary = string.format(
                "RMS %.4f | Mud %.2f | Presence %.2f | Brightness %.2f",
                metrics.avg_rms,
                metrics.mud_ratio,
                metrics.presence_ratio,
                metrics.brightness_ratio
              ),
              recommendations = build_frequency_recommendations(role, item.name or item.display_name, metrics, strength_pct),
            }
          end
        end
      end
    end

    total_analyzed = total_analyzed + analyzed_count
    total_excluded = total_excluded + excluded_count
    total_skipped = total_skipped + skipped_count
    rows[#rows + 1] = {
      role = role,
      analyzed_track_count = analyzed_count,
      excluded_track_count = excluded_count,
      skipped_track_count = skipped_count,
      tracks = role_rows,
    }
  end

  local summary = string.format(
    "Frequency report: analyzed %d track(s), excluded %d, skipped %d.",
    total_analyzed,
    total_excluded,
    total_skipped
  )

  local report = {
    summary = summary,
    rows = rows,
  }
  app.last_frequency_report = report

  return true, report
end

local function move_track_to_role(track_guid, role)
  local normalized = eq_rules.normalize_role(role)
  local valid = {
    drums = true,
    guitar = true,
    bass = true,
    vocals = true,
  }

  if not valid[normalized] then
    return false, "Invalid role"
  end

  app.track_roles[track_guid] = normalized
  local saved, save_info = save_project_roles()
  if not saved then
    return true, "Track moved. " .. tostring(save_info)
  end
  return true, "Track moved and saved to project map."
end

local function set_track_excluded(track_guid, excluded)
  if not track_guid or track_guid == "" then
    return false, "Invalid track"
  end

  app.track_excluded[track_guid] = excluded == true
  local saved, save_info = save_project_roles()
  if not saved then
    return true, "Exclusion updated. " .. tostring(save_info)
  end

  if excluded then
    return true, "Track excluded from EQ calculations and apply."
  end
  return true, "Track included in EQ calculations and apply."
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
  load_project_roles()
  build_role_columns()
end

local fns = {
  get_roles_order = get_roles_order,
  get_volume_profiles = get_volume_profiles,
  list_role_columns = build_role_columns,
  move_track_to_role = move_track_to_role,
  set_track_excluded = set_track_excluded,
  build_suggestions = build_suggestions,
  apply_mapped_roles = apply_mapped_roles,
  analyze_frequency_report = analyze_frequency_report,
  analyze_volume_report = analyze_volume_report,
  apply_volume_balance = apply_volume_balance,
  start_frequency_analysis = start_frequency_analysis,
  step_frequency_analysis = step_frequency_analysis,
  save_project_roles = save_project_roles,
  load_project_roles = load_project_roles,
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
