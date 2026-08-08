-- MixGuideEQ: Rule-driven Auto EQ assistant for Reaper
-- @author ReaperAutomation
-- @version 0.27.0

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
  version = "0.27.0",
  install_source_dir = "",
  track_roles = {},
  track_excluded = {},
  last_frequency_report = nil,
}

local MAX_RULE_MOVES = 3
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

  if role == "guitar" then
    if metrics.mud_ratio > 1.30 then
      push(string.format("Cut mud: %.1f dB @ 250-350 Hz", 1.5 * strength))
    end
    if metrics.presence_ratio < 0.95 then
      push(string.format("Add presence: %.1f dB @ 2.5-3.5 kHz", 1.5 * strength))
    end
    if metrics.brightness_ratio > 1.70 then
      push(string.format("Tame fizz: %.1f dB @ 6-8 kHz", 1.0 * strength))
    end
  elseif role == "bass" then
    if metrics.low > (metrics.low_mid * 1.9) then
      push(string.format("Control boom: %.1f dB @ 80-120 Hz", 1.5 * strength))
    end
    if metrics.presence_ratio < 0.80 then
      push(string.format("Add note definition: %.1f dB @ 1-1.5 kHz", 1.0 * strength))
    end
  elseif role == "vocals" then
    if metrics.mud_ratio > 1.20 then
      push(string.format("Reduce mud: %.1f dB @ 200-350 Hz", 1.5 * strength))
    end
    if metrics.presence_ratio < 1.00 then
      push(string.format("Increase clarity: %.1f dB @ 2.5-4 kHz", 1.5 * strength))
    end
    if metrics.brightness_ratio < 0.80 then
      push(string.format("Add air: %.1f dB @ 10-12 kHz", 1.0 * strength))
    end
  elseif role == "drums" then
    local subtype = eq_rules.detect_drum_subtype and eq_rules.detect_drum_subtype(track_name)
    if subtype == "kick" then
      if metrics.presence_ratio < 0.85 then
        push(string.format("Kick click: %.1f dB @ 2.5-4 kHz", 1.0 * strength))
      end
      if metrics.mud_ratio > 1.20 then
        push(string.format("Kick boxiness cut: %.1f dB @ 250-400 Hz", 1.5 * strength))
      end
    elseif subtype == "snare" then
      if metrics.presence_ratio < 0.95 then
        push(string.format("Snare crack: %.1f dB @ 3-5 kHz", 1.5 * strength))
      end
      if metrics.mud_ratio > 1.20 then
        push(string.format("Snare ring/box cut: %.1f dB @ 500-800 Hz", 1.0 * strength))
      end
    elseif subtype == "overheads" or subtype == "room" then
      if metrics.brightness_ratio > 1.85 then
        push(string.format("Tame cymbal harshness: %.1f dB @ 7-9 kHz", 1.0 * strength))
      end
      if metrics.mud_ratio > 1.10 then
        push(string.format("Low cleanup: %.1f dB @ 200-350 Hz", 1.0 * strength))
      end
    else
      if metrics.presence_ratio < 0.90 then
        push(string.format("Add attack/presence: %.1f dB @ 3-4 kHz", 1.0 * strength))
      end
      if metrics.mud_ratio > 1.20 then
        push(string.format("Reduce boxiness: %.1f dB @ 350-600 Hz", 1.0 * strength))
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
      has_audio = has_audio_items(track),
    }

    depth = depth + folder_delta
    if depth <= 0 then
      depth = 0
      active_root_name = nil
      active_root_role = "ignore"
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

local function build_suggestions(strength_pct)
  local columns = build_role_columns()
  local roles = get_roles_order()
  local rows = {}
  local total_audio_tracks = 0

  local analysis_by_role = {}
  if app.last_frequency_report and app.last_frequency_report.rows then
    for _, role_row in ipairs(app.last_frequency_report.rows) do
      analysis_by_role[role_row.role] = role_row
    end
  end

  for _, role in ipairs(roles) do
    local audio_tracks = {}
    local excluded_tracks = {}
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

    local rule = eq_rules.build_rule_set(role, strength_pct)
    local summary = eq_rules.render_summary(rule)
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
    local analysis_role_row = analysis_by_role[role]
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

    rows[#rows + 1] = {
      role = role,
      audio_track_count = #audio_tracks,
      audio_tracks = audio_tracks,
      excluded_track_count = #excluded_tracks,
      excluded_tracks = excluded_tracks,
      summary = summary,
      lines = lines,
    }
  end

  return {
    columns = columns,
    rows = rows,
    total_audio_tracks = total_audio_tracks,
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
              name = item.display_name,
              summary = "Skipped: " .. tostring(err or "analysis failed"),
              recommendations = { "No recommendation (analysis unavailable)." },
            }
            skipped_count = skipped_count + 1
          else
            analyzed_count = analyzed_count + 1
            role_rows[#role_rows + 1] = {
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
  list_role_columns = build_role_columns,
  move_track_to_role = move_track_to_role,
  set_track_excluded = set_track_excluded,
  build_suggestions = build_suggestions,
  apply_mapped_roles = apply_mapped_roles,
  analyze_frequency_report = analyze_frequency_report,
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
