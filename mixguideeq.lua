-- MixGuideEQ: Rule-driven Auto EQ assistant for Reaper
-- @author ReaperAutomation
-- @version 0.46.4

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
  version = "0.46.4",
  install_source_dir = "",
  track_roles = {},
  track_excluded = {},
  last_frequency_report = nil,
  last_volume_report = nil,
  last_volume_apply_snapshot = nil,
  last_eq_makeup_snapshot = nil,
  frequency_analysis_job = nil,
  -- Bar the Preview control plays from. Per project, like the rest of the
  -- panel state -- you audition the same chorus over and over.
  preview_measure = "1",
}

-- Forward declarations. These are defined further down but are called by the
-- EQ apply, which sits above them. Without this the calls resolve to nil
-- globals and fail at runtime inside a pcall -- silently.
local alog_begin, alog, alogf, alog_end
local measure_track_levels

-- Plugin parameter calibration, keyed by fx name + parameter + kind + target.
-- Emptied when an apply run starts, in case the user swapped the plugin.
local calibration_cache = {}

local MAX_RULE_MOVES = 3
local MIN_TRACK_VOL = 1e-5
local MAX_TRACK_VOL = 4.0
local MIN_APPLY_DELTA_DB = 0.05
local MAX_CHILD_DELTA_DB = 3.0
local MAX_ROOT_DELTA_DB = 6.0
-- ~-80 dBFS. Windows quieter than this are bleed or noise floor.
local RMS_SILENCE_GATE = 1e-4
-- Headroom the level plan leaves below full scale.
local PEAK_CEILING_DB = -1.0
-- An EQ that costs a track more than this much level is doing something other
-- than shaping it. Makeup gain hides the symptom, so the threshold is low
-- enough to still name the track in the summary.
local EQ_LEVEL_LOSS_WARN_DB = 3.0
-- The EQ stage does not set levels. What the filters cost a track is measured
-- either side of the write and handed straight back, so the stage is level
-- neutral in fact and not only in principle. Bounded: a track needing more than
-- this did not lose its level to shaping, and that wants fixing rather than
-- compensating.
local MAX_EQ_MAKEUP_DB = 9.0
-- Below this the correction is inaudible and not worth a fader write or a
-- row in the revert snapshot.
local MIN_EQ_MAKEUP_DB = 0.25
-- A genre is described on two independent axes:
--
--   role_offsets  -- how loud each role sits, in dB relative to the vocal
--                    reference. Used by the Levels stage.
--   band_targets  -- what shape each role should have, as dB offsets on top of
--                    eq_rules.ROLE_BAND_REFERENCE. Used by the EQ stage.
--   pan_targets   -- where each category sits in the stereo image. Used by the
--                    Levels stage alongside the volume trims.
--
-- These are deliberately separate. EQ intensity used to be derived from
-- role_offsets by a single multiplier, which cannot work: tucking a role means
-- smaller boosts and *deeper* cuts, and one scalar moves both the same way.
-- The result was Rock carving more mud out of guitars than EDM did.
--
-- Level offsets are spread wide enough to be audible. Anything under about half
-- a dB is not worth writing.
local VOLUME_PROFILES = {
  even = {
    name = "Even",
    description = "Balanced stems with moderate role separation.",
    -- The lead vocal is what the listener follows; it sits at the top and
    -- everything else is placed under it.
    role_offsets = { drums = -0.5, guitar = -2.0, bass = -1.5, vocals = 1.5 },
    pan_relief_max_db = { drums = 0.5, guitar = 0.8, bass = 0.0, vocals = 0.0 },
    -- Neutral by definition: the reference shape, unmodified.
    band_targets = {
      drums  = {},
      guitar = {},
      bass   = {},
      vocals = {},
    },
    pan_targets = {
      -- Toms 15-30% and hats around 30% follow standard practice; they are kit
      -- detail, not the walls of the image. Overheads and doubled guitars are
      -- what actually set the width.
      guitar = 0.75, overheads = 0.80, bgv = 0.60, toms = 0.22, room = 0.85,
      hat = 0.28, cymbal = 0.45, percussion = 0.45,
    },
  },
  pop = {
    name = "Pop",
    description = "Vocals forward and bright, tight low end, guitars out of the way.",
    role_offsets = { drums = -1.5, guitar = -3.5, bass = -1.5, vocals = 3.0 },
    pan_relief_max_db = { drums = 0.5, guitar = 0.6, bass = 0.0, vocals = 0.0 },
    band_targets = {
      -- Vocal is the record: presence and air pushed, mud pulled.
      vocals = { low_mid = -1.0, presence = 1.5, high = 1.5 },
      -- "Controlled" low end means tight, not quiet: keep weight, lose mud.
      bass   = { low = 0.5, low_mid = -1.5 },
      -- Guitars are accompaniment; clear the vocal's range.
      guitar = { low_mid = -2.0, presence = -1.5 },
      drums  = { low = -0.5, high = 1.0 },
    },
    pan_targets = {
      guitar = 0.70, overheads = 0.75, bgv = 0.65, toms = 0.18, room = 0.80,
      hat = 0.25, cymbal = 0.40, percussion = 0.40,
    },
  },
  rock = {
    name = "Rock",
    description = "Punchy drums, big midrange guitars, vocals in the band.",
    -- Rock tucks the vocal into the band, but tucked is not buried: it
    -- still sits above the kit and the guitars.
    role_offsets = { drums = -0.5, guitar = -1.0, bass = -2.0, vocals = 1.0 },
    pan_relief_max_db = { drums = 0.8, guitar = 1.5, bass = 0.0, vocals = 0.5 },
    band_targets = {
      -- Guitars carry the track, so they are allowed the midrange.
      guitar = { low_mid = 1.5, presence = 1.0 },
      drums  = { low = 1.0, presence = 0.5 },
      bass   = { low_mid = 0.5 },
      vocals = { low_mid = -0.5, presence = 0.5 },
    },
    pan_targets = {
      -- Doubled rhythm guitars hard against each other is the sound.
      guitar = 1.00, overheads = 0.95, bgv = 0.70, toms = 0.28, room = 0.95,
      hat = 0.30, cymbal = 0.55, percussion = 0.50,
    },
  },
  edm = {
    name = "EDM",
    description = "Kick and sub dominant, scooped mids, bright vocals.",
    -- Kick is usually the loudest element in the mix, above the vocal.
    -- Kick and sub carry an EDM mix, but the vocal still has to be heard.
    role_offsets = { drums = 1.0, guitar = -4.5, bass = 0.5, vocals = 1.5 },
    pan_relief_max_db = { drums = 0.5, guitar = 1.0, bass = 0.0, vocals = 0.5 },
    band_targets = {
      bass   = { low = 2.5, low_mid = -1.5 },
      drums  = { low = 1.0, high = 1.0 },
      -- Guitars are incidental here: carve them, do not just turn them down.
      guitar = { low_mid = -3.0, presence = -1.5 },
      vocals = { low_mid = -1.0, presence = 1.5, high = 1.5 },
    },
    pan_targets = {
      -- Mono sources stay near the middle; width comes from stereo synths.
      guitar = 0.80, overheads = 0.60, bgv = 0.50, toms = 0.15, room = 0.70,
      hat = 0.20, cymbal = 0.35, percussion = 0.35,
    },
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
  calibration_cache = {}
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

-- Apply snapshots live next to the project so a revert survives closing the
-- window. `kind` is the file suffix: "levels" for volume trims, "pans" for
-- stereo placement. Each row is one track's pre-apply value.
local function get_project_snapshot_path(kind)
  local folder, name = get_project_folder_and_name()
  if not folder or not name then
    return nil
  end
  return folder .. name .. ".mixguideeq." .. kind
end

local function save_snapshot(kind, field, snapshot)
  local path = get_project_snapshot_path(kind)
  if not path then return false end

  if not snapshot then
    os.remove(path)
    return true
  end

  local file = io.open(path, "w")
  if not file then return false end
  file:write("# MixGuideEQ " .. kind .. " snapshot\n")
  file:write("profile\t" .. tostring(snapshot.profile or "") .. "\n")
  file:write("timestamp\t" .. tostring(snapshot.timestamp or 0) .. "\n")
  for _, row in ipairs(snapshot.tracks or {}) do
    file:write("track\t" .. tostring(row.guid) .. "\t" .. tostring(row[field])
      .. "\t" .. tostring(row.label or "") .. "\n")
  end
  file:close()
  return true
end

local function load_snapshot(kind, field)
  local path = get_project_snapshot_path(kind)
  if not path then return nil end

  local file = io.open(path, "r")
  if not file then return nil end

  local snapshot = { profile = "", timestamp = 0, tracks = {} }
  for line in file:lines() do
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local key, rest = line:match("^([^\t]+)\t(.*)$")
      if key == "profile" then
        snapshot.profile = rest
      elseif key == "timestamp" then
        snapshot.timestamp = tonumber(rest) or 0
      elseif key == "track" then
        local guid, value, label = rest:match("^([^\t]*)\t([^\t]*)\t?(.*)$")
        if guid and guid ~= "" and tonumber(value) then
          local row = { guid = guid, label = (label ~= "" and label) or guid }
          row[field] = tonumber(value)
          snapshot.tracks[#snapshot.tracks + 1] = row
        end
      end
    end
  end
  file:close()

  if #snapshot.tracks == 0 then return nil end
  return snapshot
end

-- Whether EQ has been applied since the last balance, kept next to the project.
--
-- It was memory-only, so closing the window lost the fact that EQ had shifted
-- the levels and the stage strip forgot to ask for a re-balance. Every path that
-- changes the flag writes the file, including revert.
-- The state file is tab separated and line based, so a value carrying either
-- would come back as a different key on the next load.
local function sanitize_state_value(value)
  return tostring(value or ""):gsub("[\t\r\n]", " ")
end

local function get_project_state_path()
  local folder, name = get_project_folder_and_name()
  if not folder or not name then return nil end
  return folder .. name .. ".mixguideeq.state"
end

local function save_project_state()
  local path = get_project_state_path()
  if not path then return false end
  local file = io.open(path, "w")
  if not file then return false end
  file:write("# MixGuideEQ panel state\n")
  file:write("eq_applied_since_balance\t"
    .. tostring(app.eq_applied_since_balance == true) .. "\n")
  file:write("preview_measure\t" .. sanitize_state_value(app.preview_measure) .. "\n")
  file:close()
  return true
end

local function load_project_state()
  app.eq_applied_since_balance = false
  app.preview_measure = "1"
  local path = get_project_state_path()
  if not path then return false end
  local file = io.open(path, "r")
  if not file then return false end
  for line in file:lines() do
    local key, value = line:match("^([^\t]+)\t(.*)$")
    if key == "eq_applied_since_balance" then
      app.eq_applied_since_balance = (value == "true")
    elseif key == "preview_measure" and value ~= "" then
      app.preview_measure = value
    end
  end
  file:close()
  return true
end

local function set_eq_applied(applied)
  app.eq_applied_since_balance = applied == true
  save_project_state()
end

local function save_volume_snapshot()
  return save_snapshot("levels", "vol", app.last_volume_apply_snapshot)
end

local function load_volume_snapshot()
  app.last_volume_apply_snapshot = load_snapshot("levels", "vol")
  return app.last_volume_apply_snapshot ~= nil
end

local function save_eq_makeup_snapshot()
  return save_snapshot("eqmakeup", "vol", app.last_eq_makeup_snapshot)
end

local function load_eq_makeup_snapshot()
  app.last_eq_makeup_snapshot = load_snapshot("eqmakeup", "vol")
  return app.last_eq_makeup_snapshot ~= nil
end

local function save_pan_snapshot()
  return save_snapshot("pans", "pan", app.last_pan_apply_snapshot)
end

local function load_pan_snapshot()
  app.last_pan_apply_snapshot = load_snapshot("pans", "pan")
  return app.last_pan_apply_snapshot ~= nil
end

-- Write the current role map to an explicit path. GUIDs are sorted so the file
-- is byte-stable between saves instead of reshuffling with whatever order
-- pairs() happens to hand back.
local function write_roles_file(path)
  if not path or path == "" then return false end

  local file = io.open(path, "w")
  if not file then return false end

  local guids = {}
  for guid in pairs(app.track_roles) do
    guids[#guids + 1] = guid
  end
  table.sort(guids)

  file:write("# MixGuideEQ role map\n")
  for _, guid in ipairs(guids) do
    local excluded = app.track_excluded[guid] == true and "1" or "0"
    file:write(tostring(guid) .. "\t" .. tostring(app.track_roles[guid]) .. "\t" .. excluded .. "\n")
  end
  file:close()
  return true
end

local function save_project_roles()
  local path = get_project_role_map_path()
  if not path then
    return false, "Project must be saved before role assignments can persist."
  end
  if not write_roles_file(path) then
    return false, "Could not write role map file."
  end
  app.loaded_roles_path = path
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
  app.loaded_roles_path = path
  return true, path
end

-- Reaper can switch project tabs underneath a running script. The role map is
-- per project, so noticing the switch matters: without it the column scan
-- prunes every GUID it cannot see and the next save writes that empty map back.
local function refresh_project_context()
  local path = get_project_role_map_path()
  if path == app.loaded_roles_path then
    return false
  end

  -- Flush the outgoing project's roles before adopting the new one, so work
  -- done before the switch is not silently dropped.
  local previous_path = app.loaded_roles_path
  if previous_path and previous_path ~= "" and next(app.track_roles) ~= nil then
    write_roles_file(previous_path)
  end

  app.track_roles = {}
  app.track_excluded = {}
  app.last_frequency_report = nil
  app.last_volume_report = nil
  app.last_volume_apply_snapshot = nil
  app.last_eq_makeup_snapshot = nil
  app.last_pan_apply_snapshot = nil
  app.last_pan_report = nil
  app.suggestions_ready = false
  app.frequency_analysis_job = nil
  app.loaded_roles_path = path

  if path then
    load_project_roles()
    load_volume_snapshot()
    load_pan_snapshot()
    load_eq_makeup_snapshot()
    load_project_state()
  end
  return true
end

local function get_track_name(track, fallback)
  local ok, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if ok and name and name ~= "" then
    return name
  end
  return fallback
end

-- Keyword sets per role, matched on whole words only. Plain substring matching
-- pulled in every "Custom", "Bathroom" and "That" as a drum track.
local ROLE_KEYWORDS = {
  drums  = { "drum", "drums", "kick", "bd", "snare", "sn", "tom", "toms", "hat",
             "hats", "hihat", "hh", "crash", "ride", "cym", "cymbal", "cymbals",
             "overhead", "overheads", "oh", "room",
             -- Percussion belongs with the kit for both role and placement.
             "perc", "percussion", "tamb", "tambourine", "shaker", "cowbell",
             "conga", "congas", "bongo", "bongos", "clap", "claps" },
  guitar = { "gtr", "gtrs", "guitar", "guitars", "rhythm", "riff" },
  bass   = { "bass", "bs", "sub", "di" },
  vocals = { "vox", "vocal", "vocals", "voice", "bgv", "bvs", "lead" },
}

-- Drums wins ties: "Bass Drum" and "Kick Bass" are drums, not bass. "lead" is
-- weak (Lead Gtr / Lead Vox), so it only decides when nothing stronger matched.
local ROLE_PRIORITY = { "drums", "guitar", "bass", "vocals" }

local function name_words(name)
  local words = {}
  for word in tostring(name or ""):lower():gmatch("[%a%d]+") do
    words[#words + 1] = word
  end
  return words
end

local function guess_role_from_name(name)
  local words = name_words(name)
  if #words == 0 then return "ignore" end

  local word_set = {}
  for _, word in ipairs(words) do
    word_set[word] = true
  end

  for _, role in ipairs(ROLE_PRIORITY) do
    for _, keyword in ipairs(ROLE_KEYWORDS[role]) do
      if word_set[keyword] then
        return role
      end
    end
  end
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

-- Channels of the widest source on the track.
--
-- NOT I_NCHAN: that is the track's channel width, which is 2 on essentially
-- every Reaper track whatever the media is, so using it reported nearly
-- everything as stereo and skipped it. What matters for panning is whether the
-- *source* is mono -- D_PAN places a mono source but only balances a stereo one.
--
-- Returns 0 when it cannot tell, which callers treat as mono/pannable: the
-- common case is a mono source, and pan apply is revertable.
local function track_source_channels(track)
  if not track then return 0 end
  if not reaper.GetTrackMediaItem or not reaper.GetMediaSourceNumChannels then
    return 0
  end

  local widest = 0
  local count = reaper.CountTrackMediaItems(track)
  for i = 0, count - 1 do
    local ok, channels = pcall(function()
      local item = reaper.GetTrackMediaItem(track, i)
      local take = item and reaper.GetActiveTake(item)
      local source = take and reaper.GetMediaItemTake_Source(take)
      if not source then return 0 end
      return reaper.GetMediaSourceNumChannels(source) or 0
    end)
    if ok and channels and channels > widest then
      widest = channels
    end
  end
  return widest
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

-- The full definition of a genre: level offsets for the balance stage, band
-- targets for the EQ stage.
local function get_volume_profile_definition(profile_name)
  return VOLUME_PROFILES[normalize_volume_profile_name(profile_name)]
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

-- Single-bin DFT magnitude at `freq`.
--
-- Only valid below Nyquist: for a real signal the bins at k and n-k are
-- conjugates, so probing above sample_rate/2 silently returns the energy of a
-- mirrored lower frequency instead. Callers must sample fast enough for the
-- frequencies they care about; this guard stops a wrong answer from looking
-- like a real measurement.
local function goertzel_power(samples, freq, sample_rate)
  local n = #samples
  if n == 0 then return 0.0 end
  if freq >= (sample_rate / 2) then return 0.0 end

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
  local power = s_prev2 * s_prev2 + s_prev * s_prev - coeff * s_prev * s_prev2
  if power < 0 then power = 0 end
  -- Normalise by window length so the value does not depend on window size.
  return power / (n * n)
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

  -- 44.1 kHz so the 7 kHz and 10 kHz probes sit well below Nyquist. At the old
  -- 11.025 kHz those two probes were above it and reported mirrored low-mid
  -- energy as "air", while genuine high content was filtered out entirely by
  -- the resampler. 2048 samples keeps the bin width (~21 Hz) that the low
  -- probes need.
  local sr = 44100
  local window_samples = 2048
  local max_windows = 100
  local tone_freqs = { 80, 200, 500, 1200, 3000, 7000, 10000 }
  local tone_sums = {}
  for _, f in ipairs(tone_freqs) do
    tone_sums[f] = 0.0
  end

  -- Hann window, precomputed once. Without it the rectangular window smears
  -- loud low-frequency energy across every probe.
  local hann = {}
  for i = 1, window_samples do
    hann[i] = 0.5 * (1.0 - math.cos((2.0 * math.pi * (i - 1)) / (window_samples - 1)))
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

      -- Gate on the raw signal, before windowing. RMS_SILENCE_GATE is about
      -- -80 dBFS: below that a track is bleed or noise, not material to
      -- recommend EQ moves from.
      local rms = math.sqrt(safe_div(e, #samples))
      if rms > RMS_SILENCE_GATE then
        windows = windows + 1
        rms_sum = rms_sum + rms

        local windowed = {}
        for i = 1, #samples do
          windowed[i] = samples[i] * hann[i]
        end
        for _, f in ipairs(tone_freqs) do
          tone_sums[f] = tone_sums[f] + goertzel_power(windowed, f, sr)
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
      channels = math.floor(reaper.GetMediaTrackInfo_Value(track, "I_NCHAN") or 2),
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
  -- Runs every frame, so this is where a project-tab switch gets noticed.
  refresh_project_context()

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
      channels = entry.channels,
      excluded = app.track_excluded[entry.guid] == true,
    }
  end

  return columns
end

local REAEQ_NAMES = {
  "VST: ReaEQ (Cockos)",
  "ReaEQ (Cockos)",
  "VST3: ReaEQ (Cockos)",
  "ReaEQ",
}

-- Find an existing ReaEQ on the track, or insert one.
--
-- The `instantiate` argument decides query-vs-create, and builds disagree about
-- the sign convention, so creation is attempted both ways rather than assuming.
-- Querying every name first means an existing ReaEQ is always reused instead of
-- stacking a second one.
local function ensure_reaeq(track)
  if not track then return -1 end

  for _, name in ipairs(REAEQ_NAMES) do
    local fx = reaper.TrackFX_AddByName(track, name, false, 0)
    if fx and fx >= 0 then return fx end
  end

  for _, instantiate in ipairs({ -1, 1 }) do
    for _, name in ipairs(REAEQ_NAMES) do
      local fx = reaper.TrackFX_AddByName(track, name, false, instantiate)
      if fx and fx >= 0 then
        log_apply("inserted ReaEQ via '" .. name .. "' instantiate=" .. tostring(instantiate))
        return fx
      end
    end
  end

  return -1
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

-- Whether this ReaEQ build accepts named band config keys.
--
-- Prefer asking (a read), because the old probe answered by writing BANDTYPE1
-- and left the user's band 1 converted to a bell filter whether or not the
-- apply went ahead. If only the write path is available, put the old value back.
local function supports_named_band_config(track, fx_idx)
  if reaper.TrackFX_GetNamedConfigParm then
    local ok, value = reaper.TrackFX_GetNamedConfigParm(track, fx_idx, "BANDTYPE1")
    if ok and value ~= nil and value ~= "" then
      return true
    end
  end

  if not reaper.TrackFX_SetNamedConfigParm then return false end

  local previous = nil
  if reaper.TrackFX_GetNamedConfigParm then
    local ok, value = reaper.TrackFX_GetNamedConfigParm(track, fx_idx, "BANDTYPE1")
    if ok then previous = value end
  end

  local supported = try_set_named_param(track, fx_idx, "BANDTYPE1", BAND_TYPE_CODE.Band)
  if supported and previous ~= nil and previous ~= "" then
    try_set_named_param(track, fx_idx, "BANDTYPE1", previous)
  end
  return supported
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

-- Every parameter written by the plugin's own scale, not an assumed one.
--
-- ReaEQ exposes each band as a numeric parameter, but what a given value means
-- -- which frequency, how many dB -- depends on the plugin's internal curve,
-- and on what range it reports. Guessing either silently puts a filter
-- somewhere other than where it was asked for.
--
-- This started as frequency-only, which was not enough. Gain still went
-- through an assumed -24..+24 dB linear map and every write was clamped to
-- 0..1, so a -4 dB corrective cut landed at whatever -4 dB happens to be on the
-- real curve. Three of those per track is the difference between shaping a
-- guitar and burying it.
--
-- The formatted readout is the ground truth for the value; TrackFX_GetParamEx
-- is the ground truth for the range. Bisect one inside the other.
local CALIBRATION_STEPS = 32

local function parse_hz(text)
  local number, suffix = tostring(text or ""):match("(-?[%d%.]+)%s*([kK]?)")
  local hz = tonumber(number)
  if not hz then return nil end
  if suffix == "k" or suffix == "K" then
    hz = hz * 1000.0
  end
  return hz
end

local function parse_db(text)
  -- Only a reading that actually says dB: a bare number here would be some
  -- other unit and calibrating against it would drive the parameter to a rail.
  local number = tostring(text or ""):match("(-?%d*%.?%d+)%s*[dD][bB]")
  return tonumber(number)
end

local function parse_plain_number(text)
  return tonumber(tostring(text or ""):match("(-?%d*%.?%d+)"))
end

-- calibrate: bisect against the plugin's readout. Q is read back and logged but
-- not calibrated -- its readout carries no unit, so there is nothing to confirm
-- the number means what we think, and a wrong Q costs bandwidth rather than
-- making a track disappear.
local PARAM_SPEC = {
  frequency = {
    parse = parse_hz, unit = "Hz", calibrate = true,
    tolerance = function(target) return math.max(1.0, math.abs(target) * 0.01) end,
  },
  gain = {
    parse = parse_db, unit = "dB", calibrate = true,
    tolerance = function() return 0.05 end,
  },
  q = { parse = parse_plain_number, unit = "", calibrate = false },
}

-- The plugin's own parameter range. Assuming 0..1 is another guess: a plugin
-- that reports its parameters in real units gets every write clamped into the
-- bottom of its range.
local function param_range(track, fx_idx, param_idx)
  if reaper.TrackFX_GetParamEx then
    local ok, _cur, min_val, max_val = reaper.TrackFX_GetParamEx(track, fx_idx, param_idx)
    min_val, max_val = tonumber(min_val), tonumber(max_val)
    if ok and min_val and max_val and max_val > min_val then
      return min_val, max_val
    end
  end
  return 0.0, 1.0
end

local function read_param_formatted(track, fx_idx, param_idx)
  if not reaper.TrackFX_GetFormattedParamValue then return nil end
  local ok, text = pcall(function()
    local _, formatted = reaper.TrackFX_GetFormattedParamValue(track, fx_idx, param_idx, "")
    return formatted
  end)
  if not ok then return nil end
  return text
end

local function read_param_as(track, fx_idx, param_idx, parse)
  local text = read_param_formatted(track, fx_idx, param_idx)
  if text == nil then return nil end
  return parse(text)
end

-- Returns the parameter value that puts this control at target, or nil when the
-- plugin does not report something we can read.
local function calibrate_param(track, fx_idx, param_idx, kind, target)
  local spec = PARAM_SPEC[kind]
  if not spec or not spec.calibrate then return nil end

  local fx_name = ""
  if reaper.TrackFX_GetFXName then
    local _, name = reaper.TrackFX_GetFXName(track, fx_idx, "")
    fx_name = tostring(name or "")
  end
  -- The mapping belongs to the plugin, not the track, and a session asks for
  -- the same handful of values on every track. Without this the calibration
  -- alone is hundreds of parameter round trips per track.
  local cache_key = string.format("%s|%d|%s|%.6f", fx_name, param_idx, kind, target)
  local cached = calibration_cache[cache_key]
  if cached then return cached.value, cached.error, true end

  local original = reaper.TrackFX_GetParam(track, fx_idx, param_idx)
  local min_val, max_val = param_range(track, fx_idx, param_idx)

  local function probe(raw)
    reaper.TrackFX_SetParam(track, fx_idx, param_idx, raw)
    return read_param_as(track, fx_idx, param_idx, spec.parse)
  end

  local function give_up()
    reaper.TrackFX_SetParam(track, fx_idx, param_idx, original)
    return nil
  end

  local low_reading = probe(min_val)
  local high_reading = probe(max_val)
  if not low_reading or not high_reading then return give_up() end

  local best, best_error = nil, nil
  local function consider(raw, reading)
    local err = math.abs(reading - target)
    if not best_error or err < best_error then
      best, best_error = raw, err
    end
  end

  -- Considering both ends first means a target outside the plugin's range
  -- settles on the nearest rail instead of an arbitrary interior point.
  consider(min_val, low_reading)
  consider(max_val, high_reading)

  -- The curve may run either way; bisection only needs it monotonic.
  local ascending = high_reading >= low_reading
  local low, high = min_val, max_val
  local tolerance = spec.tolerance(target)

  for _ = 1, CALIBRATION_STEPS do
    if best_error and best_error <= tolerance then break end
    local mid = (low + high) / 2.0
    local reading = probe(mid)
    if not reading then return give_up() end
    consider(mid, reading)
    if (reading < target) == ascending then low = mid else high = mid end
  end

  reaper.TrackFX_SetParam(track, fx_idx, param_idx, original)
  calibration_cache[cache_key] = { value = best, error = best_error }
  return best, best_error, false
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
  local spec = PARAM_SPEC[kind]
  local target = value
  local normalized = false
  local calibrated_error = nil
  local from_cache = false

  if spec and spec.calibrate then
    local found, err, cached = calibrate_param(track, fx_idx, param_idx, kind, value)
    if found then
      target, normalized, calibrated_error, from_cache = found, true, err, cached == true
    else
      target = normalize_param_value(kind, value)
      normalized = true
      log_apply(string.format(
        "%s calibration unavailable for param %d; falling back to the assumed "
        .. "scale for %.2f %s", tostring(kind), param_idx, tonumber(value) or 0,
        tostring(spec.unit)))
    end
  elseif kind == "gain" or kind == "q" then
    target = normalize_param_value(kind, value)
    normalized = true
  end

  local min_val, max_val = param_range(track, fx_idx, param_idx)
  if not (spec and spec.calibrate and normalized and calibrated_error) then
    -- An uncalibrated value came out of the assumed 0..1 map, so place it
    -- inside whatever range the plugin actually reports.
    target = min_val + (target * (max_val - min_val))
  end

  local clamped = math.max(min_val, math.min(max_val, target))
  local set_ok = reaper.TrackFX_SetParam(track, fx_idx, param_idx, clamped)
  local read_back = reaper.TrackFX_GetParam(track, fx_idx, param_idx)
  log_apply(string.format(
    "set_param_value kind=%s param=%d raw=%.5f normalized=%s range=[%.5f,%.5f] "
    .. "target=%.5f write=%s readback=%.5f calibration_error=%s cached=%s",
    tostring(kind),
    param_idx,
    tonumber(value) or -9999,
    tostring(normalized),
    min_val, max_val,
    tonumber(clamped) or -9999,
    tostring(set_ok),
    tonumber(read_back) or -9999,
    calibrated_error and string.format("%.3f", calibrated_error) or "n/a",
    tostring(from_cache)
  ))

  -- Where it actually ended up, for every kind. The one that is not calibrated
  -- is the one most worth watching.
  if spec then
    local landed = read_param_as(track, fx_idx, param_idx, spec.parse)
    alogf("  wrote %-9s wanted %8.2f %-2s landed %s", tostring(kind),
      tonumber(value) or 0, tostring(spec.unit),
      landed and string.format("%.2f %s", landed, spec.unit) or "unknown")
  end
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

-- Per-track metrics from the last analysis pass, keyed by track GUID.
local function get_analysis_metrics(guid)
  local report = app.last_frequency_report
  if not report or not report.rows or not guid then return nil end
  for _, role_row in ipairs(report.rows) do
    for _, entry in ipairs(role_row.tracks or {}) do
      if tostring(entry.guid or "") == tostring(guid) and entry.metrics then
        return entry.metrics
      end
    end
  end
  return nil
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

-- The one place an EQ decision is made for a track.
--
-- Both the Suggestions cards and Apply Auto EQ call this, so what is displayed
-- is exactly what gets written. They used to diverge: with analysis present the
-- cards showed analysis text while apply still wrote the static role curve.
--
-- With measurements available the moves come from the genre's band targets.
-- Without them it falls back to the fixed role curve, which is the best that
-- can be done without knowing what the track actually sounds like.
local function build_track_eq_plan(role, profile, metrics, context, strength_pct)
  local rule = eq_rules.build_rule_set(role, strength_pct, context)
  local band_targets = profile and profile.band_targets and profile.band_targets[role]
  local moves = eq_rules.build_band_moves(role, band_targets, metrics, strength_pct, MAX_RULE_MOVES)

  if #moves > 0 then
    return {
      source = "analysis",
      hpf_hz = rule.hpf_hz or 80,
      moves = moves,
      rule = rule,
    }
  end

  return {
    source = metrics and "analysis-neutral" or "role-default",
    hpf_hz = rule.hpf_hz or 80,
    moves = collect_rule_moves(rule),
    rule = rule,
  }
end

local function render_plan_lines(plan, profile_name)
  local lines = { "HPF: " .. tostring(plan.hpf_hz) .. " Hz" }

  if plan.source == "analysis-neutral" then
    lines[#lines + 1] = "Measured shape already matches the "
      .. tostring(profile_name) .. " target; no corrective moves."
    return lines
  end

  for i, move in ipairs(plan.moves) do
    lines[#lines + 1] = string.format("Move %d: %+.1f dB @ %d Hz (Q %.2f)",
      i, move.gain, move.freq, move.q or 1.0)
    if move.reason then
      lines[#lines + 1] = "   why: " .. move.reason
    end
  end

  if plan.source == "role-default" then
    lines[#lines + 1] = "No analysis for this track — using the default "
      .. tostring(plan.rule.role) .. " curve."
  end

  return lines
end

local function apply_rule_curve(track, fx_idx, plan)
  local writes = 0

  if set_band_enabled(track, fx_idx, 1, true) then writes = writes + 1 end
  if set_band_type(track, fx_idx, 1, "HP") then writes = writes + 1 end
  if set_band_param_by_name(track, fx_idx, 1, { "frequency" }, plan.hpf_hz or 80) then writes = writes + 1 end
  if set_band_param_by_name(track, fx_idx, 1, { "q" }, 0.707) then writes = writes + 1 end

  local moves = plan.moves or {}
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

local function apply_rule_curve_default_layout(track, fx_idx, plan)
  local writes = 0

  -- Default ReaEQ layout slots:
  -- band 2/3: bell-like moves, band 4: high shelf, band 5: high-pass.
  if set_band_param_by_name(track, fx_idx, 5, { "frequency" }, plan.hpf_hz or 80) then writes = writes + 1 end
  if set_band_param_by_name(track, fx_idx, 5, { "q" }, 0.707) then writes = writes + 1 end

  local moves = plan.moves or {}
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

-- What the makeup did, in one line, largest correction first.
local function describe_makeup(rows)
  local biggest, biggest_label = 0.0, nil
  for _, row in ipairs(rows or {}) do
    local db = tonumber(row.returned_db) or 0.0
    if math.abs(db) > math.abs(biggest) then
      biggest, biggest_label = db, row.label
    end
  end
  if not biggest_label then
    return "No level correction was needed."
  end
  return string.format(
    "Returned the level the filters cost on %d track(s); largest %+.1f dB (%s).",
    #rows, biggest, tostring(biggest_label))
end

local function apply_rule_to_track(track, role, strength_pct, track_label, profile, guid)
  if not track then
    return false, "Invalid track selection"
  end

  local _, track_name = reaper.GetTrackName(track)
  -- Same plan the Suggestions card showed for this track.
  local plan = build_track_eq_plan(role, profile, get_analysis_metrics(guid), {
    track_name = track_name,
    track_label = track_label,
  }, strength_pct)

  -- What is about to be written, in full, so a bad filter is identifiable from
  -- the log rather than by ear.
  alogf("PLAN     %-28s source=%s hpf=%s Hz", tostring(track_name),
    tostring(plan.source), tostring(plan.hpf_hz))
  for i, move in ipairs(plan.moves or {}) do
    alogf("  move %d: %-9s %+6.2f dB @ %6d Hz  Q %.2f  (%s)", i,
      tostring(move.band_type), tonumber(move.gain) or 0,
      tonumber(move.freq) or 0, tonumber(move.q) or 0,
      tostring(move.reason or move.band or ""))
  end

  local rule = plan.rule
  log_apply("apply_rule_to_track role=" .. tostring(role) .. " strength=" .. tostring(strength_pct)
    .. " source=" .. tostring(plan.source) .. " moves=" .. tostring(#plan.moves)
    .. " track=" .. tostring(track_name))
  local fx_idx = ensure_reaeq(track)
  if not fx_idx or fx_idx < 0 then
    log_apply("ensure_reaeq failed for track=" .. tostring(track_name))
    return false, "Could not insert or find ReaEQ"
  end
  log_apply("ensure_reaeq fx_idx=" .. tostring(fx_idx) .. " track=" .. tostring(track_name))
  dump_fx_params(track, fx_idx)

  -- What this track sounds like without our EQ. Measured with the plugin
  -- bypassed rather than merely before writing to it: on a second pass the
  -- filters from the first are already in place, so "before writing" is
  -- already the reduced level and the loss reads as zero. Only our own ReaEQ
  -- is bypassed; the rest of the chain stays in.
  --
  -- A quick check, not an analysis: a coarse reading is enough.
  local can_bypass = reaper.TrackFX_SetEnabled ~= nil
  if can_bypass then reaper.TrackFX_SetEnabled(track, fx_idx, false) end
  local before_db = measure_track_levels(track, LEVEL_VERIFY_BLOCKS)
  before_db = before_db and before_db.avg_db or nil
  if can_bypass then reaper.TrackFX_SetEnabled(track, fx_idx, true) end
  if not can_bypass then
    log_apply("TrackFX_SetEnabled unavailable; the before reading includes any "
      .. "EQ already on this track")
  end

  local applied = 0
  if supports_named_band_config(track, fx_idx) then
    log_apply("named band config supported; using band type/enable path")
    applied = apply_named_profile(track, fx_idx)
    applied = applied + apply_rule_curve(track, fx_idx, plan)
  else
    log_apply("named band config unsupported; recreating ReaEQ and using default-layout path")
    fx_idx = recreate_reaeq(track, fx_idx)
    if not fx_idx or fx_idx < 0 then
      log_apply("recreate_reaeq failed for track=" .. tostring(track_name))
      return false, "Could not recreate ReaEQ for fallback apply"
    end
    log_apply("fallback ensure_reaeq fx_idx=" .. tostring(fx_idx) .. " track=" .. tostring(track_name))
    dump_fx_params(track, fx_idx)
    applied = apply_rule_curve_default_layout(track, fx_idx, plan)
  end
  log_apply("apply_rule_to_track writes=" .. tostring(applied) .. " track=" .. tostring(track_name))

  -- Did the EQ cost this track its level?
  local after = measure_track_levels(track, LEVEL_VERIFY_BLOCKS)
  local after_db = after and after.avg_db or nil
  local lost_db = nil
  if before_db and after_db then
    lost_db = before_db - after_db
    alogf("LEVEL    %-28s before %.2f dB, after %.2f dB, lost %.2f dB",
      tostring(track_name), before_db, after_db, lost_db)
  end

  -- Give back exactly what the filters took. The caller snapshots the original
  -- fader so this is undone with the rest of the EQ stage.
  local makeup = nil
  if lost_db and math.abs(lost_db) >= MIN_EQ_MAKEUP_DB then
    local track_guid = guid or reaper.GetTrackGUID(track)
    local original_vol = tonumber(reaper.GetMediaTrackInfo_Value(track, "D_VOL")) or 1.0
    local returned_db = math.max(-MAX_EQ_MAKEUP_DB, math.min(MAX_EQ_MAKEUP_DB, lost_db))
    local new_vol = original_vol * (10.0 ^ (returned_db / 20.0))
    new_vol = math.max(MIN_TRACK_VOL, math.min(MAX_TRACK_VOL, new_vol))
    reaper.SetMediaTrackInfo_Value(track, "D_VOL", new_vol)
    makeup = {
      guid = track_guid,
      label = tostring(track_label or track_name),
      vol = original_vol,
      returned_db = returned_db,
    }
    alogf("MAKEUP   %-28s returned %+.2f dB (fader %.4f -> %.4f)",
      tostring(track_name), returned_db, original_vol, new_vol)
  end

  local msg_out = "Inserted/updated ReaEQ for " .. tostring(role) .. "."
  if applied == 0 then
    msg_out = msg_out .. " Rule summary generated; parameter writes were not accepted on this Reaper build."
  end

  -- Still say so even though the level came back: a filter costing this much is
  -- in the wrong place, and makeup gain would otherwise hide it.
  if lost_db and lost_db > EQ_LEVEL_LOSS_WARN_DB then
    local warning = string.format(
      "%s lost %.1f dB to its EQ (returned as makeup gain) - check where its "
      .. "filters landed in the apply debug log.",
      tostring(track_label or track_name), lost_db)
    alogf("WARNING  %s", warning)
    log_apply("LEVEL LOSS " .. warning)
    return true, msg_out, warning, makeup
  end

  return true, msg_out, nil, makeup
end

local function build_suggestions(strength_pct, profile_name)
  local columns = build_role_columns()
  app.last_suggestion_profile = profile_name
  -- Arms Apply. Cleared once applied, so a second Apply cannot run against
  -- suggestions that no longer describe the audio.
  app.suggestions_ready = true
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
    -- Suggestion strength is the user's slider, nothing else. The genre's
    -- influence on EQ comes from its band targets, not from its level offsets.
    local role_strength_pct = tonumber(strength_pct) or 100

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
        local plan = build_track_eq_plan(role, profile, get_analysis_metrics(item.guid), {
          track_name = item.name,
          track_label = item.display_name,
        }, role_strength_pct)
        local lines_for_track = render_plan_lines(plan, profile.name)

        if math.abs(role_profile_offset) >= 0.25 then
          lines_for_track[#lines_for_track + 1] = string.format(
            "Level stage will target %+.1f dB for %s.", role_profile_offset, role)
        end

        track_suggestions[#track_suggestions + 1] = {
          guid = item.guid,
          name = item.display_name,
          lines = lines_for_track,
          source = plan.source,
          moves = plan.moves,
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

-- Average RMS of a track's audio, in dB. Cheaper than the full spectral
-- analysis: no per-frequency probes, just level.
--
-- This is what the balance stage compares. Fader positions say nothing about
-- how loud a track actually is, which is why balancing them against each other
-- never settled on anything musical.
local LOUDNESS_WINDOWS = 40
local LOUDNESS_WINDOW_SAMPLES = 2048
local LOUDNESS_SAMPLE_RATE = 44100

local function measure_track_loudness_db(track)
  if not reaper.CreateTrackAudioAccessor then return nil end
  local accessor = reaper.CreateTrackAudioAccessor(track)
  if not accessor then return nil end

  local start_t = reaper.GetAudioAccessorStartTime(accessor)
  local end_t = reaper.GetAudioAccessorEndTime(accessor)
  local duration = (end_t or 0) - (start_t or 0)
  local window_len = LOUDNESS_WINDOW_SAMPLES / LOUDNESS_SAMPLE_RATE
  if duration <= window_len then
    reaper.DestroyAudioAccessor(accessor)
    return nil
  end

  local buf = reaper.new_array(LOUDNESS_WINDOW_SAMPLES)
  local span = math.max(0.0, duration - window_len)
  local sum = 0.0
  local counted = 0

  for w = 0, LOUDNESS_WINDOWS - 1 do
    local ratio = (LOUDNESS_WINDOWS > 1) and (w / (LOUDNESS_WINDOWS - 1)) or 0.0
    local t = start_t + (span * ratio)
    if reaper.GetAudioAccessorSamples(accessor, LOUDNESS_SAMPLE_RATE, 1, t,
        LOUDNESS_WINDOW_SAMPLES, buf) then
      local samples = buf.table(1, LOUDNESS_WINDOW_SAMPLES)
      local energy = 0.0
      for i = 1, #samples do
        energy = energy + (samples[i] * samples[i])
      end
      local rms = math.sqrt(safe_div(energy, #samples))
      -- Same gate as the spectral analyser: below this is bleed, not material.
      if rms > RMS_SILENCE_GATE then
        sum = sum + rms
        counted = counted + 1
      end
    end
  end

  reaper.DestroyAudioAccessor(accessor)
  if counted == 0 then return nil end
  return vol_to_db(sum / counted)
end

-- Balance on measured loudness against a fixed anchor.
--
-- The anchor is the vocals' measured level. It comes from the audio, not from
-- the faders, so it does not move when a trim is applied -- which is what made
-- the old fader-relative version run away, cutting guitar and bass further on
-- every pass.
--
-- Trims are written to the audio tracks themselves. Folder roots are left
-- alone: writing both a per-track trim and a root trim meant every track got
-- moved twice, and a folder has no audio to measure anyway.
-- Does the audio accessor read before or after the track fader?
--
-- It matters: if the reading already includes the fader, subtracting it gives
-- the source level; if not, the reading *is* the source level. Getting it wrong
-- makes the balance either compound or oscillate. Rather than assume, nudge one
-- track by a known amount and see whether the reading follows.
--
-- Cached for the session -- it is a property of the build, not the project.
local analysis_log_depth = 0
local accessor_fader_mode = nil

local function accessor_includes_fader(track)
  if accessor_fader_mode ~= nil then return accessor_fader_mode end
  if not track then return false end

  local base = measure_track_loudness_db(track)
  if not base then return false end

  local original = reaper.GetMediaTrackInfo_Value(track, "D_VOL") or 1.0
  local probe_db = 6.0
  reaper.SetMediaTrackInfo_Value(track, "D_VOL", original * db_to_vol(probe_db))
  local raised = measure_track_loudness_db(track)
  reaper.SetMediaTrackInfo_Value(track, "D_VOL", original)

  if not raised then return false end
  -- Half the nudge is plenty of margin either way.
  accessor_fader_mode = (raised - base) > (probe_db * 0.5)
  return accessor_fader_mode
end

-- ── analysis log ────────────────────────────────────────────────────────────
--
-- What each stage measured and why it decided what it did, written where it can
-- be read from outside Reaper. Rewritten per analysis so the file is always the
-- most recent run rather than an ever-growing history.
local analysis_log_lines = nil

function alog_begin(title)
  -- An operation that runs an analysis inside itself gets one log, not three
  -- that each overwrite the last. Only the outermost section writes the file.
  if analysis_log_lines and analysis_log_depth > 0 then
    analysis_log_depth = analysis_log_depth + 1
    analysis_log_lines[#analysis_log_lines + 1] = ""
    analysis_log_lines[#analysis_log_lines + 1] = "=== " .. tostring(title) .. " ==="
    return
  end
  analysis_log_depth = 1
  analysis_log_lines = {
    "MixGuideEQ analysis log",
    "written: " .. os.date("%Y-%m-%d %H:%M:%S"),
    "stage:   " .. tostring(title),
    string.rep("-", 78),
  }
end

function alog(text)
  if not analysis_log_lines then return end
  analysis_log_lines[#analysis_log_lines + 1] = tostring(text)
end

function alogf(fmt, ...)
  if not analysis_log_lines then return end
  local ok, line = pcall(string.format, fmt, ...)
  analysis_log_lines[#analysis_log_lines + 1] = ok and line or tostring(fmt)
end

function alog_end()
  if not analysis_log_lines then return end
  analysis_log_depth = analysis_log_depth - 1
  if analysis_log_depth > 0 then return end
  local lines = analysis_log_lines
  analysis_log_lines = nil
  pcall(function()
    local dir = reaper.GetResourcePath() .. "/Scripts/MixGuideEQ"
    reaper.RecursiveCreateDirectory(dir, 0)
    local file = io.open(dir .. "/mixguideeq_analysis.log", "w")
    if not file then return end
    for _, line in ipairs(lines) do
      file:write(line .. "\n")
    end
    file:close()
  end)
end

-- ── gated loudness measurement ──────────────────────────────────────────────
--
-- Per EBU R128: block the audio, drop blocks below an absolute floor, average
-- the rest, then re-average keeping only blocks within RELATIVE_GATE_DB of that
-- first result. Quiet passages and gaps stop dragging a track's average down,
-- which is the whole point -- a sparse lead vocal and a wall-to-wall rhythm
-- guitar become comparable.
--
-- RMS rather than K-weighted LUFS: every track goes through the same
-- measurement and only their differences are used, so the weighting curve
-- cancels. Swap in K-weighting if absolute LUFS numbers are ever wanted.
local LEVEL_BLOCK_SAMPLES = 4096
local LEVEL_BLOCK_COUNT = 100
local LEVEL_SAMPLE_RATE = 44100
local ABSOLUTE_GATE_DB = -70.0
-- Blocks used for the post-apply sanity check, which only has to spot a large
-- level loss rather than measure precisely.
local LEVEL_VERIFY_BLOCKS = 16
local RELATIVE_GATE_DB = 10.0

local function mean_db(block_dbs)
  if #block_dbs == 0 then return nil end
  -- Average in the power domain, not in dB.
  local sum = 0.0
  for _, db in ipairs(block_dbs) do
    sum = sum + (10.0 ^ (db / 10.0))
  end
  return 10.0 * (math.log(sum / #block_dbs) / math.log(10.0))
end

-- Returns { avg_db, max_db, blocks } or nil when the track has nothing to hear.
-- Stereo sources are asked for a single channel, so everything is compared as
-- mono.
function measure_track_levels(track, block_count)
  local blocks_wanted = math.max(4, math.floor(tonumber(block_count) or LEVEL_BLOCK_COUNT))
  if not reaper.CreateTrackAudioAccessor then return nil end
  local accessor = reaper.CreateTrackAudioAccessor(track)
  if not accessor then return nil end

  local start_t = reaper.GetAudioAccessorStartTime(accessor)
  local end_t = reaper.GetAudioAccessorEndTime(accessor)
  local duration = (end_t or 0) - (start_t or 0)
  local block_len = LEVEL_BLOCK_SAMPLES / LEVEL_SAMPLE_RATE
  if duration <= block_len then
    reaper.DestroyAudioAccessor(accessor)
    return nil
  end

  local buf = reaper.new_array(LEVEL_BLOCK_SAMPLES)
  local span = math.max(0.0, duration - block_len)
  local block_dbs = {}
  local peak = 0.0

  for b = 0, blocks_wanted - 1 do
    local ratio = (blocks_wanted > 1) and (b / (blocks_wanted - 1)) or 0.0
    local t = start_t + (span * ratio)
    if reaper.GetAudioAccessorSamples(accessor, LEVEL_SAMPLE_RATE, 1, t,
        LEVEL_BLOCK_SAMPLES, buf) then
      local samples = buf.table(1, LEVEL_BLOCK_SAMPLES)
      local energy = 0.0
      for i = 1, #samples do
        local x = samples[i]
        energy = energy + (x * x)
        local a = math.abs(x)
        if a > peak then peak = a end
      end
      local rms = math.sqrt(safe_div(energy, #samples))
      if rms > 0 then
        block_dbs[#block_dbs + 1] = vol_to_db(rms)
      end
    end
  end

  reaper.DestroyAudioAccessor(accessor)

  -- Stage 1: absolute gate.
  local above_absolute = {}
  for _, db in ipairs(block_dbs) do
    if db > ABSOLUTE_GATE_DB then
      above_absolute[#above_absolute + 1] = db
    end
  end
  local ungated = mean_db(above_absolute)
  if not ungated then return nil end

  -- Stage 2: relative gate, 10 dB below that.
  local threshold = ungated - RELATIVE_GATE_DB
  local above_relative = {}
  for _, db in ipairs(above_absolute) do
    if db > threshold then
      above_relative[#above_relative + 1] = db
    end
  end

  local avg_db = mean_db(above_relative) or ungated
  local max_db = ABSOLUTE_GATE_DB
  for _, db in ipairs(above_absolute) do
    if db > max_db then max_db = db end
  end

  return {
    avg_db = avg_db,
    max_db = max_db,
    peak_db = (peak > 0) and vol_to_db(peak) or ABSOLUTE_GATE_DB,
    blocks = #above_relative,
  }
end

-- Rank every track by measured loudness, then work out which need to move up or
-- down that ranking to match the profile.
--
-- The moves are zero-meaned before they are returned. Without that the plan only
-- ever cuts -- the reference was the quietest element, so everything louder got
-- pulled down to it and the whole mix lost level. Balancing means some tracks go
-- up and some go down.
local function analyze_volume_report(profile_name)
  local profile = get_volume_profile(profile_name)
  local columns = build_role_columns()
  alog_begin("Analyze Levels (" .. tostring(profile.name) .. ")")
  alogf("gate: absolute %.1f dB, relative %.1f dB, %d blocks of %d samples at %d Hz",
    ABSOLUTE_GATE_DB, RELATIVE_GATE_DB, LEVEL_BLOCK_COUNT, LEVEL_BLOCK_SAMPLES,
    LEVEL_SAMPLE_RATE)

  local function inherited_gain_db(item)
    if not item.root_guid or item.root_guid == item.guid then return 0.0 end
    local root_track = get_track_by_guid(item.root_guid)
    if not root_track then return 0.0 end
    return vol_to_db(reaper.GetMediaTrackInfo_Value(root_track, "D_VOL") or 1.0)
  end

  local measured = {}
  local excluded_count, skipped_count = 0, 0

  for _, role in ipairs(get_roles_order()) do
    for _, item in ipairs(columns[role]) do
      if item.excluded then
        excluded_count = excluded_count + 1
      elseif not item.has_audio then
        skipped_count = skipped_count + 1
      else
        local track = get_track_by_guid(item.guid)
        local levels = track and measure_track_levels(track)
        if not track or not levels then
          skipped_count = skipped_count + 1
          alogf("SKIPPED  %-28s role=%-7s reason=%s", tostring(item.display_name),
            tostring(role), track and "no audio above the gate" or "track not found")
        else
          local fader_db = vol_to_db(reaper.GetMediaTrackInfo_Value(track, "D_VOL") or 1.0)
          local pan = tonumber(reaper.GetMediaTrackInfo_Value(track, "D_PAN") or 0.0) or 0.0
          local child_offset, reason = get_child_balance_offset(role, item.name)
          local role_offset = (profile.role_offsets and profile.role_offsets[role]) or 0.0

          measured[#measured + 1] = {
            guid = item.guid,
            name = item.display_name,
            base_name = item.name,
            role = role,
            avg_db = levels.avg_db,
            max_db = levels.max_db,
            peak_db = levels.peak_db,
            blocks = levels.blocks,
            current_db = fader_db,
            pan = pan,
            pan_relief_db = get_pan_relief_db(profile, role, pan),
            inherited_db = inherited_gain_db(item),
            -- Where the profile says this track should sit relative to the rest.
            target_rel_db = role_offset + child_offset,
            child_reason = reason,
          }
        end
      end
    end
  end

  if #measured == 0 then
    alog("no measurable tracks; nothing to balance")
    alog_end()
    return nil
  end

  -- Loudest first. This ordering is the report.
  table.sort(measured, function(a, b) return a.avg_db > b.avg_db end)
  local loudest_db = measured[1].avg_db

  -- ── role sums ─────────────────────────────────────────────────────────────
  --
  -- What competes with a lead vocal is the whole kit, not one drum mic. Working
  -- track by track is count-weighted: eight drum tracks pull the balance eight
  -- times while the vocal pulls once, and the vocal ends up quiet no matter
  -- what the profile says. So roles are placed by their combined energy first.
  local role_members = {}
  local role_order = {}
  for _, row in ipairs(measured) do
    local heard = row.avg_db + row.inherited_db
    row.heard_db = heard
    if not role_members[row.role] then
      role_members[row.role] = {}
      role_order[#role_order + 1] = row.role
    end
    local bucket = role_members[row.role]
    bucket[#bucket + 1] = row
  end

  -- Combined level of each role, summed in the power domain.
  local role_sum_db, role_heard_mean = {}, {}
  for _, role in ipairs(role_order) do
    local power, heard_total = 0.0, 0.0
    for _, row in ipairs(role_members[role]) do
      power = power + (10.0 ^ (row.heard_db / 10.0))
      heard_total = heard_total + row.heard_db
    end
    role_sum_db[role] = 10.0 * (math.log(power) / math.log(10.0))
    role_heard_mean[role] = heard_total / #role_members[role]
  end

  -- Role offsets, zero-meaned across the roles actually present, so the mix
  -- keeps its overall level and only the relationship between roles changes.
  local offset_total, sum_total = 0.0, 0.0
  for _, role in ipairs(role_order) do
    offset_total = offset_total + ((profile.role_offsets and profile.role_offsets[role]) or 0.0)
    sum_total = sum_total + role_sum_db[role]
  end
  local offset_mean = offset_total / #role_order
  local sum_mean = sum_total / #role_order

  local role_delta = {}
  for _, role in ipairs(role_order) do
    local offset = (profile.role_offsets and profile.role_offsets[role]) or 0.0
    role_delta[role] = (sum_mean + (offset - offset_mean)) - role_sum_db[role]
    alogf("ROLE     %-8s combined %.2f dB, offset %+.2f, move %+.2f (%d track(s))",
      tostring(role), role_sum_db[role], offset - offset_mean, role_delta[role],
      #role_members[role])
  end

  -- Within a role, the child offsets say how its own tracks sit against each
  -- other. Zero-meaned inside the role so this does not disturb the role sum
  -- that was just placed.
  local within_mean = {}
  for _, role in ipairs(role_order) do
    local want_total = 0.0
    for _, row in ipairs(role_members[role]) do
      want_total = want_total + row.target_rel_db + (row.pan_relief_db or 0.0)
    end
    within_mean[role] = want_total / #role_members[role]
  end

  local total_nonzero = 0
  local track_adjustments = {}

  for rank, row in ipairs(measured) do
    row.rank = rank
    row.rel_avg_db = row.avg_db - loudest_db
    row.rel_max_db = row.max_db - loudest_db

    local heard = row.heard_db
    local want = row.target_rel_db + (row.pan_relief_db or 0.0)
    local within = (want - within_mean[row.role]) - (heard - role_heard_mean[row.role])

    local delta_db = clamp(role_delta[row.role] + within,
      -MAX_ROOT_DELTA_DB, MAX_ROOT_DELTA_DB)
    if math.abs(delta_db) < MIN_APPLY_DELTA_DB then
      delta_db = 0.0
    end

    row.delta_db = delta_db
    row.target_db = row.avg_db + delta_db
    if delta_db ~= 0.0 then
      total_nonzero = total_nonzero + 1
    end

    track_adjustments[#track_adjustments + 1] = {
      role = row.role,
      guid = row.guid,
      name = row.name,
      current_db = row.current_db,
      avg_db = row.avg_db,
      max_db = row.max_db,
      target_db = row.target_db,
      delta_db = delta_db,
      child_delta_db = delta_db,
      final_preview_delta_db = delta_db,
      child_reason = row.child_reason,
      pan = row.pan,
      pan_relief_db = row.pan_relief_db,
    }
  end

  -- Hold the overall level. Placing role sums can bias every move the same
  -- way; a uniform shift takes that out without touching the balance.
  local move_total = 0.0
  for _, row in ipairs(measured) do move_total = move_total + row.delta_db end
  local move_mean = move_total / #measured
  if math.abs(move_mean) >= MIN_APPLY_DELTA_DB then
    for _, row in ipairs(measured) do
      row.delta_db = row.delta_db - move_mean
      row.target_db = row.avg_db + row.delta_db
    end
    for _, action in ipairs(track_adjustments) do
      action.delta_db = action.delta_db - move_mean
      action.child_delta_db = action.delta_db
      action.final_preview_delta_db = action.delta_db
      action.target_db = action.target_db - move_mean
    end
    alogf("levelled the plan by %+.2f dB so the mix keeps its overall level", -move_mean)
  end

  -- Clip guard.
  --
  -- Only the track that would actually cross the ceiling is trimmed back to
  -- it. This used to take the excess off *every* move on the grounds that the
  -- balance is a set of relative positions, so shifting them together is free.
  -- It is not free: it undoes the levelling immediately above and leaves the
  -- whole mix quieter, which is the "everything got quieter" complaint in
  -- mechanical form. A real pass lost 2.93 dB across the board to one drum
  -- track running hot.
  --
  -- A track only clips itself, and a track being cut cannot clip at all. If a
  -- whole folder is running hot, the folder's own fader is the place to fix
  -- that -- so the guard names the inherited gain rather than quietly paying
  -- for it on every other track in the project.
  local predicted_peak = -math.huge
  for _, row in ipairs(measured) do
    local peak = (row.peak_db or row.max_db) + row.delta_db + row.inherited_db
    if peak > predicted_peak then predicted_peak = peak end
  end

  local clip_trims = {}
  local clip_trim_db = 0.0
  for _, row in ipairs(measured) do
    local peak = (row.peak_db or row.max_db) + row.delta_db + row.inherited_db
    if peak > PEAK_CEILING_DB then
      local trim = PEAK_CEILING_DB - peak
      row.delta_db = row.delta_db + trim
      row.target_db = row.avg_db + row.delta_db
      clip_trims[tostring(row.guid)] = trim
      -- The deepest single trim, for the report.
      if trim < clip_trim_db then clip_trim_db = trim end
      alogf("CLIP GUARD %-26s would peak %+.2f dB (inherited %+.2f dB from its "
        .. "folder); trimmed %.2f dB", tostring(row.name), peak,
        row.inherited_db, trim)
    end
  end

  if next(clip_trims) ~= nil then
    for _, action in ipairs(track_adjustments) do
      local trim = clip_trims[tostring(action.guid)]
      if trim then
        action.delta_db = action.delta_db + trim
        action.child_delta_db = action.delta_db
        action.final_preview_delta_db = action.delta_db
        action.target_db = action.target_db + trim
      end
    end
  else
    alogf("clip guard: loudest predicted peak %.2f dB, ceiling %.2f dB, no trim needed",
      predicted_peak, PEAK_CEILING_DB)
  end

  -- Where each track *should* rank, so the report can show what needs to move.
  local by_target = {}
  for i, row in ipairs(measured) do by_target[i] = row end
  table.sort(by_target, function(a, b) return a.target_db > b.target_db end)
  for target_rank, row in ipairs(by_target) do
    row.target_rank = target_rank
  end

  alogf("%-28s %8s %8s %8s %8s %8s", "TRACK", "avg", "max", "peak", "fader", "move")
  for _, row in ipairs(measured) do
    alogf("%-28s %8.2f %8.2f %8.2f %8.2f %8.2f  %s",
      tostring(row.name), row.avg_db, row.max_db, row.peak_db or 0,
      row.current_db, row.delta_db, tostring(row.child_reason or ""))
  end
  alogf("mean move %.3f dB (zero means the mix level is preserved)",
    (function()
      local sum = 0.0
      for _, row in ipairs(measured) do sum = sum + row.delta_db end
      return sum / #measured
    end)())
  alog_end()

  return {
    profile = profile.name,
    loudest_db = loudest_db,
    clip_trim_db = clip_trim_db,
    predicted_peak_db = predicted_peak,
    ranked = measured,
    track_adjustments = track_adjustments,
    root_adjustments = {},
    rows = {},
    total_nonzero = total_nonzero,
    excluded_track_count = excluded_count,
    skipped_track_count = skipped_count,
    summary = string.format(
      "Levels (%s): %d track(s) measured, %d move(s). Loudest %.1f dB.",
      profile.name, #measured, total_nonzero, loudest_db
    ),
  }
end

-- ============================================================================
-- PAN PLACEMENT
-- ============================================================================

-- A pan this far from centre counts as a deliberate choice by the user.
local PAN_SET_THRESHOLD = 0.02
-- Smaller than this is not worth writing.
local MIN_PAN_DELTA = 0.02

-- Group a role's tracks into named pairs ("Rhythm L" + "Rhythm R"), so the two
-- halves can be placed against each other. A base name with anything other than
-- exactly one L and one R is not a pair.
local function find_pan_pairs(entries)
  local by_base = {}
  for _, entry in ipairs(entries) do
    local base, side = eq_rules.split_pan_pair_name(entry.name)
    if base then
      by_base[base] = by_base[base] or {}
      local bucket = by_base[base]
      bucket[side] = bucket[side] or {}
      bucket[side][#bucket[side] + 1] = entry
    end
  end

  local sides = {}
  for _, bucket in pairs(by_base) do
    if bucket.L and bucket.R and #bucket.L == 1 and #bucket.R == 1 then
      sides[bucket.L[1].guid] = -1
      sides[bucket.R[1].guid] = 1
    end
  end
  return sides
end

-- Toms are spread across the image rather than paired off, so they are placed
-- by position in the list: low tom left, floor tom right, and so on.
local function tom_offsets(count)
  local offsets = {}
  if count <= 0 then return offsets end
  if count == 1 then
    offsets[1] = 0.0
    return offsets
  end
  for i = 1, count do
    offsets[i] = -1.0 + (2.0 * (i - 1) / (count - 1))
  end
  return offsets
end

-- Where every track should sit, and why. Reports rather than writes, so the UI
-- can show the move and the reason before anything changes.
local function analyze_pan_report(profile_name)
  local profile = get_volume_profile(profile_name)
  local pan_targets = profile.pan_targets or {}
  local columns = build_role_columns()
  local rows = {}
  local adjustments = {}
  local held = 0

  for _, role in ipairs(get_roles_order()) do
    local entries = {}
    for _, item in ipairs(columns[role]) do
      if not item.excluded and item.has_audio then
        local track = get_track_by_guid(item.guid)
        if track then
          entries[#entries + 1] = {
            guid = item.guid,
            name = item.name,
            display_name = item.display_name,
            track = track,
            channels = track_source_channels(track),
            category = eq_rules.pan_category(role, item.name),
            current_pan = tonumber(reaper.GetMediaTrackInfo_Value(track, "D_PAN")) or 0.0,
          }
        end
      end
    end

    local pair_sides = find_pan_pairs(entries)

    -- Collect toms first so they can be spread across the available width.
    local toms = {}
    for _, entry in ipairs(entries) do
      if entry.category == "toms" then toms[#toms + 1] = entry end
    end
    local spread = tom_offsets(#toms)
    local tom_index = {}
    for i, entry in ipairs(toms) do tom_index[entry.guid] = i end

    local row = { role = role, tracks = {} }

    for _, entry in ipairs(entries) do
      local category = entry.category
      local target, reason

      if category == "center" then
        target, reason = 0.0, "centre: never panned"
      elseif category == "toms" then
        local width = tonumber(pan_targets.toms) or 0.5
        target = (spread[tom_index[entry.guid]] or 0.0) * width
        reason = "toms spread across the kit"
      elseif eq_rules.SINGLE_SIDED_CATEGORIES[category] then
        -- One mic, so it is placed on a side rather than against a partner.
        local width = tonumber(pan_targets[category]) or 0.3
        target = eq_rules.SINGLE_SIDED_CATEGORIES[category] * width
        reason = category .. " spot mic, placed "
          .. ((target < 0) and "left" or "right")
      elseif category == "none" then
        target, reason = nil, "no pan rule for this source"
      else
        local width = tonumber(pan_targets[category]) or 0.6
        local side = pair_sides[entry.guid]
        if side then
          target = side * width
          reason = string.format("paired %s, placed %s",
            category, side < 0 and "left" or "right")
        else
          target, reason = nil, "unpaired " .. category .. ": left as-is"
        end
      end

      local track_row = {
        guid = entry.guid,
        name = entry.display_name,
        base_name = entry.name,
        category = category,
        channels = entry.channels,
        current_pan = entry.current_pan,
        target_pan = target,
        reason = reason,
        -- D_PAN on a stereo source is a balance control, not a placement
        -- one, so those are reported rather than nudged around. 0 means "could
        -- not tell", which is treated as mono.
        is_stereo = (entry.channels or 0) > 1,
        already_set = math.abs(entry.current_pan) > PAN_SET_THRESHOLD,
      }

      if target ~= nil and math.abs(target - entry.current_pan) >= MIN_PAN_DELTA then
        track_row.delta = target - entry.current_pan
        adjustments[#adjustments + 1] = track_row
        if track_row.already_set then held = held + 1 end
      end

      row.tracks[#row.tracks + 1] = track_row
    end

    rows[#rows + 1] = row
  end

  local report = {
    profile = profile.name,
    rows = rows,
    adjustments = adjustments,
    already_panned_count = held,
    summary = string.format(
      "Pan plan (%s): %d track(s) to move, %d already panned by hand.",
      profile.name, #adjustments, held
    ),
  }
  app.last_pan_report = report
  return report
end

local function get_last_pan_apply_snapshot()
  local snap = app.last_pan_apply_snapshot
  if not snap then
    return { available = false, track_count = 0 }
  end
  return {
    available = true,
    track_count = #(snap.tracks or {}),
    profile = snap.profile,
    timestamp = snap.timestamp,
  }
end

-- override_existing: when false, a track the user has already panned keeps its
-- position. When true, the plan wins everywhere.
local function apply_pan_balance(profile_name, override_existing)
  local report = analyze_pan_report(profile_name)
  if not report then
    return false, "No pan report available.", {}
  end

  local existing = app.last_pan_apply_snapshot
  if existing and existing.tracks and #existing.tracks > 0 then
    return false,
      "A previous pan apply (" .. tostring(existing.profile)
        .. ") has not been reverted. Revert it first so the original positions "
        .. "are not lost.",
      {}
  end

  local errors = {}
  local applied = 0
  local skipped_existing = 0
  local skipped_stereo = 0
  local snapshot = {}

  reaper.Undo_BeginBlock()
  local ok, err = pcall(function()
    for _, action in ipairs(report.adjustments) do
      local track = get_track_by_guid(action.guid)
      if not track then
        errors[#errors + 1] = tostring(action.name) .. ": track not found"
      elseif action.already_set and not override_existing then
        skipped_existing = skipped_existing + 1
      elseif action.is_stereo then
        -- Panning a stereo track is a balance change, which is not what the
        -- placement rules mean. Report it instead of doing the wrong thing.
        skipped_stereo = skipped_stereo + 1
      else
        snapshot[#snapshot + 1] = {
          guid = action.guid,
          label = action.name,
          pan = action.current_pan,
        }
        reaper.SetMediaTrackInfo_Value(track, "D_PAN", clamp(action.target_pan, -1.0, 1.0))
        applied = applied + 1
      end
    end
  end)
  reaper.Undo_EndBlock("MixGuideEQ: Apply pan placement (" .. tostring(report.profile) .. ")", -1)

  if not ok then
    errors[#errors + 1] = "Runtime pan apply error: " .. tostring(err)
  end

  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  if #snapshot > 0 then
    app.last_pan_apply_snapshot = {
      profile = report.profile,
      timestamp = os.time(),
      tracks = snapshot,
    }
    save_pan_snapshot()
  end

  local summary = string.format("Applied pan placement (%s): %d track(s) moved.",
    tostring(report.profile), applied)
  if skipped_existing > 0 then
    summary = summary .. string.format(
      " %d kept their existing pan (tick Override existing pans to move them).",
      skipped_existing)
  end
  if skipped_stereo > 0 then
    summary = summary .. string.format(
      " %d stereo track(s) skipped: pan on a stereo track is a balance control,"
      .. " set width by hand.", skipped_stereo)
  end
  if #errors > 0 then
    summary = summary .. " " .. tostring(#errors) .. " issue(s)."
  end

  return true, summary, errors, analyze_pan_report(profile_name)
end

local function revert_last_pan_balance()
  local snap = app.last_pan_apply_snapshot
  if not snap or not snap.tracks or #snap.tracks == 0 then
    return false, "No pan-apply snapshot available to revert.", {}
  end

  local restored = 0
  local errors = {}

  reaper.Undo_BeginBlock()
  local ok, err = pcall(function()
    for _, row in ipairs(snap.tracks) do
      local track = get_track_by_guid(row.guid)
      if track then
        reaper.SetMediaTrackInfo_Value(track, "D_PAN", clamp(tonumber(row.pan) or 0.0, -1.0, 1.0))
        restored = restored + 1
      else
        errors[#errors + 1] = tostring(row.label or row.guid) .. ": track not found during revert"
      end
    end
  end)
  reaper.Undo_EndBlock("MixGuideEQ: Revert last pan placement", -1)

  if not ok then
    errors[#errors + 1] = "Runtime pan revert error: " .. tostring(err)
  end

  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  app.last_pan_report = nil
  app.last_pan_apply_snapshot = nil
  save_pan_snapshot()

  local summary = "Reverted pan placement on " .. tostring(restored) .. " track(s)."
  if #errors > 0 then
    summary = summary .. " " .. tostring(#errors) .. " issue(s)."
  end
  return true, summary, errors
end

local function apply_volume_balance(profile_name)
  alog_begin("Apply Level Balance")
  local report = analyze_volume_report(profile_name)
  if not report then
    alog("no volume report; nothing applied")
    alog_end()
    return false, "No volume report available.", {}
  end

  -- Trims are multiplicative and stack. Replacing an unreverted snapshot would
  -- strand the earlier apply with no way back, so refuse instead.
  local existing = app.last_volume_apply_snapshot
  if existing and existing.tracks and #existing.tracks > 0 then
    alogf("refused: an unreverted %s snapshot covering %d track(s) is still in place",
      tostring(existing.profile), #existing.tracks)
    alog_end()
    return false,
      "A previous level apply (" .. tostring(existing.profile)
        .. ") has not been reverted. Revert it first, or the two trims stack "
        .. "and the first one cannot be undone.",
      {}
  end

  local errors = {}
  local applied_track_adjustments = 0
  local applied_root_adjustments = 0
  local snapshot_map = {}

  local function capture_snapshot(guid, label)
    if not guid or guid == "" then return end
    if snapshot_map[guid] then return end
    local tr = get_track_by_guid(guid)
    if tr then
      snapshot_map[guid] = {
        guid = guid,
        label = tostring(label or guid),
        vol = reaper.GetMediaTrackInfo_Value(tr, "D_VOL") or 1.0,
      }
    end
  end

  for _, action in ipairs(report.track_adjustments or {}) do
    if math.abs(action.delta_db or 0) >= MIN_APPLY_DELTA_DB then
      capture_snapshot(action.guid, action.name)
    end
  end

  -- What the plan asked for against what the fader could actually take. A
  -- clamped write is the difference between "the plan was wrong" and "the plan
  -- was right and only half of it landed", and those need opposite fixes.
  alog("")
  alogf("writes (anything under %.2f dB is left alone)", MIN_APPLY_DELTA_DB)
  alogf("%-28s %8s %9s %9s %8s  %s",
    "TRACK", "want", "fader in", "fader out", "got", "note")

  local function log_write(label, wanted_db, before_vol, after_vol)
    local got_db = vol_to_db(after_vol) - vol_to_db(before_vol)
    local note = ""
    if math.abs(got_db - wanted_db) > 0.05 then
      note = string.format("CLAMPED, %.2f dB short", wanted_db - got_db)
    end
    alogf("%-28s %+8.2f %+9.2f %+9.2f %+8.2f  %s",
      tostring(label), wanted_db, vol_to_db(before_vol), vol_to_db(after_vol),
      got_db, note)
  end

  reaper.Undo_BeginBlock()
  local apply_ok, apply_err = pcall(function()
    for _, action in ipairs(report.track_adjustments or {}) do
      if math.abs(action.delta_db or 0) >= MIN_APPLY_DELTA_DB then
        local track = get_track_by_guid(action.guid)
        if track then
          local current_vol = reaper.GetMediaTrackInfo_Value(track, "D_VOL") or 1.0
          local next_vol = clamp(current_vol * db_to_vol(action.delta_db), MIN_TRACK_VOL, MAX_TRACK_VOL)
          reaper.SetMediaTrackInfo_Value(track, "D_VOL", next_vol)
          log_write(action.name, action.delta_db, current_vol, next_vol)
          applied_track_adjustments = applied_track_adjustments + 1
        else
          errors[#errors + 1] = tostring(action.name) .. ": track not found for child adjustment"
          alogf("%-28s SKIPPED, track not found", tostring(action.name))
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
            log_write("[root] " .. tostring(action.root_name), action.delta_db, current_vol, next_vol)
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

  local snapshot_list = {}
  for _, row in pairs(snapshot_map) do
    snapshot_list[#snapshot_list + 1] = row
  end
  table.sort(snapshot_list, function(a, b)
    return tostring(a.label) < tostring(b.label)
  end)

  app.last_volume_apply_snapshot = {
    profile = report.profile,
    timestamp = os.time(),
    tracks = snapshot_list,
  }
  set_eq_applied(false)
  save_volume_snapshot()

  summary = summary .. " Snapshot captured for " .. tostring(#snapshot_list) .. " track(s)."

  for _, err in ipairs(errors) do
    alogf("ISSUE    %s", tostring(err))
  end
  alogf("summary: %s", summary)

  -- Re-measured so the panel shows where the mix landed, not where it started.
  -- Nested, so this does not overwrite the plan that produced the writes.
  local refreshed_report = analyze_volume_report(report.profile)
  alog_end()
  return true, summary, errors, refreshed_report
end

local function get_last_volume_apply_snapshot()
  local snap = app.last_volume_apply_snapshot
  if not snap then
    return { available = false, track_count = 0 }
  end
  return {
    available = true,
    track_count = #(snap.tracks or {}),
    profile = snap.profile,
    timestamp = snap.timestamp,
  }
end

local function revert_last_volume_balance()
  local snap = app.last_volume_apply_snapshot
  if not snap or not snap.tracks or #snap.tracks == 0 then
    return false, "No level-apply snapshot available to revert.", {}
  end

  local restored = 0
  local errors = {}

  reaper.Undo_BeginBlock()
  local ok, err = pcall(function()
    for _, row in ipairs(snap.tracks) do
      local tr = get_track_by_guid(row.guid)
      if tr then
        reaper.SetMediaTrackInfo_Value(tr, "D_VOL", clamp(tonumber(row.vol) or 1.0, MIN_TRACK_VOL, MAX_TRACK_VOL))
        restored = restored + 1
      else
        errors[#errors + 1] = tostring(row.label or row.guid) .. ": track not found during revert"
      end
    end
  end)
  reaper.Undo_EndBlock("MixGuideEQ: Revert last level balance", -1)

  if not ok then
    errors[#errors + 1] = "Runtime revert error: " .. tostring(err)
  end

  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()

  app.last_volume_report = nil
  app.last_volume_apply_snapshot = nil
  save_volume_snapshot()  -- clears the sidecar

  local summary = "Reverted level balance on " .. tostring(restored) .. " track(s)."
  if #errors > 0 then
    summary = summary .. " " .. tostring(#errors) .. " issue(s)."
  end
  return true, summary, errors
end

-- Analyze measures the mix as it stands, so anything this panel already applied
-- has to come off first. Otherwise the second analysis measures its own output
-- and the plan is computed against the wrong starting point.
-- Move the edit cursor to the start of a bar and play from there.
--
-- TimeMap2_beatsToTime with a measure index and zero beats gives the bar's
-- start; measures are 1-based in the UI and 0-based in the API.
local function preview_from_measure(measure_text)
  local measure = math.floor(tonumber(measure_text) or 0)
  if measure < 1 then
    return false, "Enter a bar number of 1 or more"
  end
  if not reaper.TimeMap2_beatsToTime then
    return false, "Bar lookup unavailable on this Reaper build"
  end

  local ok, position = pcall(reaper.TimeMap2_beatsToTime, 0, 0.0, measure - 1)
  if not ok or not position then
    return false, "Could not resolve bar " .. tostring(measure)
  end

  reaper.SetEditCurPos(position, true, false)
  -- 1007 = Transport: Play
  reaper.Main_OnCommand(1007, 0)
  return true, measure
end

-- Written through rather than left in the UI, so the bar survives a panel
-- close, a hot reload, and a project tab switch.
local function set_preview_measure(measure_text)
  app.preview_measure = tostring(measure_text or "")
  save_project_state()
  return app.preview_measure
end

local function stop_preview()
  -- 1016 = Transport: Stop
  reaper.Main_OnCommand(1016, 0)
  return true
end

-- Analyze measures the mix as it stands, so anything this panel already applied
-- has to come off first -- including every stage *after* the one being
-- measured. Stage order is Map -> EQ -> Pan -> Balance, so measuring for EQ has
-- to undo the pan and the balance too, or the plan is built against a mix the
-- later stages have already moved.
--
-- Later stages come off first, in reverse order of application.
-- Put the faders back where they were before the EQ stage compensated itself.
local function revert_last_eq_makeup()
  local snapshot = app.last_eq_makeup_snapshot
  if not snapshot or #(snapshot.tracks or {}) == 0 then
    return false, "No EQ makeup gain to undo"
  end

  local restored = 0
  reaper.Undo_BeginBlock()
  for _, row in ipairs(snapshot.tracks or {}) do
    local track = get_track_by_guid(row.guid)
    local vol = tonumber(row.vol)
    if track and vol then
      reaper.SetMediaTrackInfo_Value(track, "D_VOL", vol)
      restored = restored + 1
    end
  end
  reaper.Undo_EndBlock("MixGuideEQ: Undo EQ makeup gain", -1)

  app.last_eq_makeup_snapshot = nil
  save_eq_makeup_snapshot()
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
  return true, "Restored pre-EQ levels on " .. tostring(restored) .. " track(s)"
end

local function get_last_eq_makeup_snapshot()
  return app.last_eq_makeup_snapshot
end

local function revert_before_analysis(kind)
  local undone = {}

  if kind == "eq" or kind == "pans" or kind == "levels" then
    if app.last_volume_apply_snapshot then
      revert_last_volume_balance()
      undone[#undone + 1] = "levels"
    end
  end
  if kind == "eq" or kind == "pans" then
    if app.last_pan_apply_snapshot then
      revert_last_pan_balance()
      undone[#undone + 1] = "pan"
    end
  end
  -- The makeup gain belongs to the EQ stage, so it comes off when the EQ stage
  -- is being re-measured.
  if kind == "eq" then
    if app.last_eq_makeup_snapshot then
      revert_last_eq_makeup()
      undone[#undone + 1] = "EQ makeup gain"
    end
  end

  if #undone == 0 then
    return false, "nothing to undo", {}
  end
  return true, "undid " .. table.concat(undone, " and "), undone
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

  alog_begin("Analyze Frequency")
  alogf("queued %d track(s), excluded %d, skipped %d (no audio items)",
    #targets, total_excluded, total_skipped)
  for _, t in ipairs(targets) do
    alogf("QUEUED   %-28s role=%s", tostring(t.display_name), tostring(t.role))
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
      if metrics then
        alogf("MEASURED %-28s rms=%.5f low=%.4g low_mid=%.4g presence=%.4g high=%.4g",
          tostring(target.display_name), metrics.avg_rms or 0, metrics.low or 0,
          metrics.low_mid or 0, metrics.presence or 0, metrics.high or 0)
      else
        alogf("DROPPED  %-28s role=%-7s reason=%s", tostring(target.display_name),
          tostring(target.role), tostring(err or "analysis failed"))
      end
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
            low = metrics.low,
            low_mid = metrics.low_mid,
            presence = metrics.presence,
            high = metrics.high,
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
    alogf("done: %d analysed, %d excluded, %d skipped",
      total_analyzed, job.total_excluded, job.total_skipped)
    alog_end()
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

-- Apply, split across frames.
--
-- start_eq_apply builds the target list and opens the undo block;
-- step_eq_apply processes a few tracks per call and closes the block when it
-- runs out. Doing the whole thing in one call froze the UI for seconds on a
-- full kit, with no sign it was working.
local function start_eq_apply(strength_pct, profile_name)
  clear_apply_log()
  alog_begin("Apply Auto EQ")

  if not app.suggestions_ready then
    return false,
      "Generate Suggestions first. Applying EQ changes the audio, so the "
      .. "previous analysis no longer describes it: re-run Analyze Frequency "
      .. "and Generate Suggestions before applying again."
  end

  local profile = get_volume_profile(profile_name or app.last_suggestion_profile)
  local columns = build_role_columns()
  local targets = {}
  local excluded_audio_tracks = 0
  local role_track_counts = { drums = 0, guitar = 0, bass = 0, vocals = 0 }

  for _, role in ipairs(get_roles_order()) do
    for _, item in ipairs(columns[role]) do
      if item.excluded and item.has_audio then
        excluded_audio_tracks = excluded_audio_tracks + 1
      elseif item.has_audio then
        local track = get_track_by_guid(item.guid)
        if track then
          targets[#targets + 1] = {
            track = track, role = role, label = item.display_name, guid = item.guid,
          }
          role_track_counts[role] = role_track_counts[role] + 1
        end
      end
    end
  end

  if #targets == 0 then
    alog("no mapped tracks with audio")
    alog_end()
    return false, "No mapped tracks with audio items were found."
  end

  -- A previous run's makeup is measured into this one otherwise, and its
  -- snapshot would be overwritten with faders that already carry it.
  if app.last_eq_makeup_snapshot then
    revert_last_eq_makeup()
  end

  reaper.Undo_BeginBlock()
  app.eq_apply_job = {
    strength_pct = strength_pct,
    profile = profile,
    targets = targets,
    idx = 1,
    applied = 0,
    errors = {},
    makeup = {},
    excluded_audio_tracks = excluded_audio_tracks,
    role_track_counts = role_track_counts,
    done = false,
  }
  return true, { queued = #targets, excluded = excluded_audio_tracks }
end

local function step_eq_apply(max_tracks_per_step)
  local job = app.eq_apply_job
  if not job then
    return false, "No EQ apply in progress"
  end
  if job.done then
    return true, { done = true, progress = 1.0, summary = job.summary, errors = job.errors }
  end

  local budget = math.max(1, math.floor(tonumber(max_tracks_per_step) or 1))
  local processed = 0

  while processed < budget and job.idx <= #job.targets do
    local target = job.targets[job.idx]
    -- pcall shifts the returns along by one: ok, then what the call returned.
    local ok, applied_ok, message, warning, makeup = pcall(apply_rule_to_track,
      target.track, target.role, job.strength_pct, target.label,
      job.profile, target.guid)

    if not ok then
      job.errors[#job.errors + 1] = tostring(target.label) .. ": " .. tostring(applied_ok)
    else
      if makeup then
        job.makeup[#job.makeup + 1] = makeup
      end
      if warning then
        job.errors[#job.errors + 1] = warning
      end
      if applied_ok then
        job.applied = job.applied + 1
      else
        job.errors[#job.errors + 1] = tostring(target.label) .. ": " .. tostring(message)
      end
    end

    job.idx = job.idx + 1
    processed = processed + 1
  end

  local total = #job.targets
  local progress = (total > 0) and math.min(1.0, (job.idx - 1) / total) or 1.0

  if job.idx > total then
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
    reaper.Undo_EndBlock("MixGuideEQ: Apply mapped Auto EQ", -1)

    local summary = "Applied Auto EQ to " .. tostring(job.applied) .. " track(s) with audio."
    if job.excluded_audio_tracks > 0 then
      summary = summary .. " Excluded: " .. tostring(job.excluded_audio_tracks) .. "."
    end
    summary = summary
      .. " D:" .. tostring(job.role_track_counts.drums)
      .. " G:" .. tostring(job.role_track_counts.guitar)
      .. " B:" .. tostring(job.role_track_counts.bass)
      .. " V:" .. tostring(job.role_track_counts.vocals)
    if #job.errors > 0 then
      summary = summary .. " " .. tostring(#job.errors) .. " issue(s)."
    end

    if #job.makeup > 0 then
      app.last_eq_makeup_snapshot = {
        profile = job.profile and job.profile.name or "",
        timestamp = os.time(),
        tracks = job.makeup,
      }
      save_eq_makeup_snapshot()
      summary = summary .. " " .. describe_makeup(job.makeup)
    end

    if job.applied > 0 then
      app.last_frequency_report = nil
      app.frequency_analysis_job = nil
      app.last_volume_report = nil
      app.suggestions_ready = false
      set_eq_applied(true)
      summary = summary .. " Levels were held, but re-run Analyze Levels to balance."
    end

    summary = summary .. " Debug log: " .. get_debug_log_path()
    alogf("summary: %s", summary)
    alog_end()

    job.summary = summary
    job.done = true
    app.eq_apply_job = nil
    return true, { done = true, progress = 1.0, summary = summary, errors = job.errors }
  end

  return true, {
    done = false,
    progress = progress,
    processed = job.idx - 1,
    total = total,
  }
end

local function apply_mapped_roles(strength_pct, profile_name)
  clear_apply_log()
  alog_begin("Apply Auto EQ")
  -- Default to whatever profile the visible suggestions were built with, so
  -- Apply always writes what the cards showed.
  if not app.suggestions_ready then
    return false,
      "Generate Suggestions first. Applying EQ changes the audio, so the "
      .. "previous analysis no longer describes it: re-run Analyze Frequency "
      .. "and Generate Suggestions before applying again.",
      {}
  end

  local profile = get_volume_profile(profile_name or app.last_suggestion_profile)
  log_apply("apply_mapped_roles begin strength=" .. tostring(strength_pct)
    .. " profile=" .. tostring(profile.name))
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
          targets[#targets + 1] = {
            track = track, role = role, label = item.display_name, guid = item.guid,
          }
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
  local makeup_rows = {}

  if app.last_eq_makeup_snapshot then
    revert_last_eq_makeup()
  end

  reaper.Undo_BeginBlock()
  local apply_ok, apply_err = pcall(function()
    for _, target in ipairs(targets) do
      log_apply("target begin role=" .. tostring(target.role) .. " label=" .. tostring(target.label))
      local ok, err, warning, makeup = apply_rule_to_track(target.track, target.role, strength_pct,
        target.label, profile, target.guid)
      if makeup then
        makeup_rows[#makeup_rows + 1] = makeup
      end
      if warning then
        errors[#errors + 1] = warning
      end
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

  if #makeup_rows > 0 then
    app.last_eq_makeup_snapshot = {
      profile = profile.name,
      timestamp = os.time(),
      tracks = makeup_rows,
    }
    save_eq_makeup_snapshot()
    summary = summary .. " " .. describe_makeup(makeup_rows)
  end

  if applied_tracks > 0 then
    -- The tracks no longer sound like what was measured, and EQ moves change a
    -- track's overall level, so both reports are now stale.
    app.last_frequency_report = nil
    app.frequency_analysis_job = nil
    app.last_volume_report = nil
    app.suggestions_ready = false
    set_eq_applied(true)
    summary = summary
      .. " Levels were held through the EQ, but the balance between tracks"
      .. " has moved: re-run Analyze Levels and Apply Level Balance."
  end

  summary = summary .. " Debug log: " .. get_debug_log_path()
  log_apply("apply_mapped_roles done summary=" .. summary)
  alogf("summary: %s", summary)
  alog_end()

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
  load_volume_snapshot()
  load_pan_snapshot()
  load_eq_makeup_snapshot()
  load_project_state()
  build_role_columns()
end

local fns = {
  get_roles_order = get_roles_order,
  get_volume_profiles = get_volume_profiles,
  get_volume_profile_definition = get_volume_profile_definition,
  list_role_columns = build_role_columns,
  move_track_to_role = move_track_to_role,
  set_track_excluded = set_track_excluded,
  build_suggestions = build_suggestions,
  apply_mapped_roles = apply_mapped_roles,
  start_eq_apply = start_eq_apply,
  step_eq_apply = step_eq_apply,
  analyze_frequency_report = analyze_frequency_report,
  analyze_volume_report = analyze_volume_report,
  apply_volume_balance = apply_volume_balance,
  analyze_pan_report = analyze_pan_report,
  apply_pan_balance = apply_pan_balance,
  revert_last_pan_balance = revert_last_pan_balance,
  get_last_pan_apply_snapshot = get_last_pan_apply_snapshot,
  get_last_volume_apply_snapshot = get_last_volume_apply_snapshot,
  revert_last_volume_balance = revert_last_volume_balance,
  revert_before_analysis = revert_before_analysis,
  revert_last_eq_makeup = revert_last_eq_makeup,
  get_last_eq_makeup_snapshot = get_last_eq_makeup_snapshot,
  preview_from_measure = preview_from_measure,
  set_preview_measure = set_preview_measure,
  stop_preview = stop_preview,
  load_project_state = load_project_state,
  start_frequency_analysis = start_frequency_analysis,
  step_frequency_analysis = step_frequency_analysis,
  save_project_roles = save_project_roles,
  load_project_roles = load_project_roles,
  load_volume_snapshot = load_volume_snapshot,
  load_pan_snapshot = load_pan_snapshot,
  load_eq_makeup_snapshot = load_eq_makeup_snapshot,
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
