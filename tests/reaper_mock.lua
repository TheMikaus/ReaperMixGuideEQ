-- reaper_mock.lua — a fake `reaper` API good enough to load and drive
-- mixguideeq.lua outside of Reaper.
--
-- The audio accessor is the interesting part. A track's audio is declared as a
-- list of {freq, amp} partials; GetAudioAccessorSamples renders them at the
-- sample rate the caller asks for and, like Reaper's resampler, drops anything
-- at or above that rate's Nyquist limit. Content above Nyquist must therefore be
-- invisible to the analyzer rather than folding down into a lower band.
--
-- The host (conftest.py) must provide __host_mkdir(path) before this is loaded.

local RMOCK = {
  resource_path = "",
  project_path = "",
  tracks = {},
  console = {},
  undo_names = {},
  undo_depth = 0,
  fx_named_config_supported = true,
  -- Whether the audio accessor reads after the track fader. Builds differ, and
  -- the balance stage probes for it at runtime, so both are worth testing.
  accessor_post_fader = false,
  fx_param_layout = "named",   -- "named" | "positional"
  -- Linear gain the accessor applies once a track has a ReaEQ on it, by track
  -- name. Filters remove energy, and the apply measures either side of the
  -- write to hand that back -- with no loss here the makeup path never runs.
  eq_level_factor = {},
}

function RMOCK.reset()
  RMOCK.project_path = ""
  RMOCK.eq_level_factor = {}
  RMOCK.tracks = {}
  RMOCK.console = {}
  RMOCK.undo_names = {}
  RMOCK.undo_depth = 0
end

function RMOCK.set_project(path)
  RMOCK.project_path = path or ""
end

-- spec: {
--   name = "Kick", folder_depth = 1, items = 1, vol = 1.0, pan = 0.0,
--   partials = { {freq = 100, amp = 0.5}, ... },  -- the track's audio
--   duration = 4.0,
-- }
function RMOCK.add_track(spec)
  local track = {
    name         = spec.name or ("Track " .. tostring(#RMOCK.tracks + 1)),
    folder_depth = spec.folder_depth or 0,
    items        = spec.items or 0,
    vol          = spec.vol or 1.0,
    pan          = spec.pan or 0.0,
    mute         = spec.mute or 0,
    solo         = spec.solo or 0,
    guid         = spec.guid or ("{GUID-" .. tostring(#RMOCK.tracks + 1) .. "}"),
    partials     = spec.partials or {},
    duration     = spec.duration or 4.0,
    -- Silent for alternating stretches, to exercise the loudness gate.
    gaps         = spec.gaps == true,
    channels     = spec.channels or 1,
    fx           = {},
  }
  RMOCK.tracks[#RMOCK.tracks + 1] = track
  return track
end

function RMOCK.track_by_name(name)
  for _, t in ipairs(RMOCK.tracks) do
    if t.name == name then return t end
  end
  return nil
end

function RMOCK.pans()
  local out = {}
  for _, t in ipairs(RMOCK.tracks) do
    out[t.name] = t.pan
  end
  return out
end

function RMOCK.volumes()
  local out = {}
  for _, t in ipairs(RMOCK.tracks) do
    out[t.name] = t.vol
  end
  return out
end

local reaper = {}

function reaper.GetResourcePath() return RMOCK.resource_path end
function reaper.EnumProjects(_) return 0, RMOCK.project_path end
function reaper.RecursiveCreateDirectory(path, _) __host_mkdir(path); return 1 end
function reaper.CountTracks(_) return #RMOCK.tracks end
function reaper.GetTrack(_, i) return RMOCK.tracks[i + 1] end
function reaper.GetTrackGUID(track) return track and track.guid or "" end
function reaper.CountTrackMediaItems(track) return track and track.items or 0 end

-- Media items exist only far enough to report their source channel count,
-- which is what pan placement uses to tell mono from stereo.
function reaper.GetTrackMediaItem(track, idx)
  if not track or idx >= (track.items or 0) then return nil end
  return { track = track }
end

function reaper.GetActiveTake(item)
  if not item then return nil end
  return { item = item }
end

function reaper.GetMediaItemTake_Source(take)
  if not take or not take.item then return nil end
  return { channels = take.item.track.channels or 1 }
end

function reaper.GetMediaSourceNumChannels(source)
  return source and source.channels or 0
end
function reaper.UpdateArrange() end
function reaper.TrackList_AdjustWindows(_) end
function reaper.defer(_) end

function reaper.GetTrackName(track)
  if not track then return false, "" end
  return true, track.name
end

function reaper.GetSetMediaTrackInfo_String(track, key, value, is_set)
  if not track or key ~= "P_NAME" then return false, "" end
  if is_set then track.name = value; return true, value end
  return true, track.name
end

local TRACK_KEYS = { D_PAN = "pan", D_VOL = "vol", B_MUTE = "mute", I_SOLO = "solo" }

function reaper.GetMediaTrackInfo_Value(track, key)
  if not track then return 0 end
  if key == "I_FOLDERDEPTH" then return track.folder_depth end
  -- Real Reaper reports 2 for essentially every track regardless of what is on
  -- it, so the mock does too. Anything that needs to know mono from stereo must
  -- ask the source, not the track width.
  if key == "I_NCHAN" then return 2 end
  local field = TRACK_KEYS[key]
  return field and track[field] or 0
end

function reaper.SetMediaTrackInfo_Value(track, key, value)
  if not track then return false end
  local field = TRACK_KEYS[key]
  if not field then return false end
  track[field] = value
  return true
end

function reaper.ShowConsoleMsg(text)
  RMOCK.console[#RMOCK.console + 1] = text
end

function reaper.Undo_BeginBlock()
  RMOCK.undo_depth = RMOCK.undo_depth + 1
end

function reaper.Undo_EndBlock(name, _)
  RMOCK.undo_depth = RMOCK.undo_depth - 1
  RMOCK.undo_names[#RMOCK.undo_names + 1] = name
end

-- ── Audio accessor ──────────────────────────────────────────────────────────

function reaper.CreateTrackAudioAccessor(track)
  return { track = track }
end

function reaper.DestroyAudioAccessor(_) end
function reaper.GetAudioAccessorStartTime(_) return 0.0 end
function reaper.GetAudioAccessorEndTime(acc)
  return acc and acc.track and acc.track.duration or 0.0
end

function reaper.new_array(size)
  local arr = { _size = size }
  for i = 1, size do arr[i] = 0.0 end
  function arr.table(first, count)
    local out = {}
    for i = 0, count - 1 do
      out[i + 1] = arr[first + i] or 0.0
    end
    return out
  end
  function arr.get_size() return arr._size end
  return arr
end

-- What the track's EQ costs it, linear. Only once an EQ is actually on it.
function RMOCK.eq_gain_for(track)
  if not track then return 1.0 end
  local active = false
  for _, fx in ipairs(track.fx) do
    if fx.enabled ~= false then active = true end
  end
  if not active then return 1.0 end
  local factor = RMOCK.eq_level_factor[track.name]
  return tonumber(factor) or 1.0
end

function reaper.GetAudioAccessorSamples(acc, sample_rate, _, start_time, count, buf)
  if not acc or not acc.track then return 0 end
  local nyquist = sample_rate / 2
  for i = 0, count - 1 do
    local t = start_time + (i / sample_rate)
    local value = 0.0
    for _, partial in ipairs(acc.track.partials) do
      -- A real resampler lowpasses before decimating: content at or above
      -- Nyquist is removed, not folded back down into an audible band.
      if partial.freq < nyquist then
        value = value + partial.amp * math.sin(2 * math.pi * partial.freq * t)
      end
    end
    if acc.track.gaps and (math.floor(t) % 2 == 1) then
      value = 0.0
    end
    if RMOCK.accessor_post_fader then
      value = value * (acc.track.vol or 1.0)
    end
    value = value * RMOCK.eq_gain_for(acc.track)
    buf[i + 1] = value
  end
  return 1
end

-- ── FX ──────────────────────────────────────────────────────────────────────

function reaper.TrackFX_AddByName(track, name, _, instantiate)
  if not track then return -1 end
  for i, fx in ipairs(track.fx) do
    if fx.name:find("ReaEQ", 1, true) and name:find("ReaEQ", 1, true) then
      return i - 1
    end
  end
  -- Negative instantiate means "add it if missing"; 0/positive only query.
  if instantiate and instantiate < 0 then
    track.fx[#track.fx + 1] = { name = name, params = {}, config = {}, enabled = true }
    return #track.fx - 1
  end
  return -1
end

function reaper.TrackFX_SetEnabled(track, fx_idx, enabled)
  local fx = track and track.fx[fx_idx + 1]
  if not fx then return false end
  fx.enabled = enabled and true or false
  return true
end

function reaper.TrackFX_GetEnabled(track, fx_idx)
  local fx = track and track.fx[fx_idx + 1]
  return fx ~= nil and fx.enabled ~= false
end

function reaper.TrackFX_Delete(track, fx_idx)
  if track and track.fx[fx_idx + 1] then
    table.remove(track.fx, fx_idx + 1)
    return true
  end
  return false
end

local NAMED_PARAMS = {
  "Band 1 Freq", "Band 1 Gain", "Band 1 Q",
  "Band 2 Freq", "Band 2 Gain", "Band 2 Q",
  "Band 3 Freq", "Band 3 Gain", "Band 3 Q",
  "Band 4 Freq", "Band 4 Gain", "Band 4 Q",
  "Band 5 Freq", "Band 5 Gain", "Band 5 Q",
}

local function get_fx(track, fx_idx)
  return track and track.fx[fx_idx + 1] or nil
end

function reaper.TrackFX_SetNamedConfigParm(track, fx_idx, key, value)
  if not RMOCK.fx_named_config_supported then return false end
  local fx = get_fx(track, fx_idx)
  if not fx then return false end
  fx.config[key] = value
  return true
end


function reaper.TrackFX_GetNumParams(track, fx_idx)
  return get_fx(track, fx_idx) and #NAMED_PARAMS or 0
end

function reaper.TrackFX_GetParamName(track, fx_idx, idx, _)
  local name = NAMED_PARAMS[idx + 1]
  if not name then return false, "" end
  if RMOCK.fx_param_layout == "positional" then
    return true, "Param " .. tostring(idx + 1)
  end
  return true, name
end

function reaper.TrackFX_GetParam(track, fx_idx, idx)
  local fx = get_fx(track, fx_idx)
  return fx and (fx.params[idx] or 0.0) or 0.0
end

function reaper.TrackFX_GetParamEx(track, fx_idx, idx)
  local min_val, max_val = RMOCK.param_range(idx)
  return true, reaper.TrackFX_GetParam(track, fx_idx, idx), min_val, max_val
end

-- Frequency parameters run LINEARLY from 20 Hz to 24 kHz here, on purpose.
-- The code used to assume a logarithmic scale; under that assumption a 70 Hz
-- high-pass lands near 4 kHz on a linear plugin, which is what made whole
-- tracks vanish. Calibration must land on the right value without knowing the
-- curve.
local FREQ_MIN_HZ, FREQ_MAX_HZ = 20.0, 24000.0

-- Gain is deliberately NOT a 0..1 control and NOT the -24..+24 dB the code used
-- to assume: it runs in the plugin's own units over -18..+18 dB. Writing a
-- normalised 0..1 value into it lands 18 dB low, which is a track you cannot
-- hear -- the whole complaint.
local GAIN_MIN_DB, GAIN_MAX_DB = -18.0, 18.0

local function param_is_frequency(idx)
  local name = NAMED_PARAMS[idx + 1] or ""
  return name:find("Freq", 1, true) ~= nil
end

local function param_is_gain(idx)
  local name = NAMED_PARAMS[idx + 1] or ""
  return name:find("Gain", 1, true) ~= nil
end

function RMOCK.param_range(idx)
  if param_is_gain(idx) then return GAIN_MIN_DB, GAIN_MAX_DB end
  return 0.0, 1.0
end

-- Gain reads back in dB straight from the parameter.
function RMOCK.param_db(track_name, fx_idx, param_idx)
  local track = RMOCK.track_by_name(track_name)
  local fx = track and track.fx[fx_idx + 1]
  if not fx then return nil end
  return fx.params[param_idx] or 0.0
end

function RMOCK.param_hz(track_name, fx_idx, param_idx)
  local track = RMOCK.track_by_name(track_name)
  local fx = track and track.fx[fx_idx + 1]
  if not fx then return nil end
  local value = fx.params[param_idx] or 0.0
  return FREQ_MIN_HZ + value * (FREQ_MAX_HZ - FREQ_MIN_HZ)
end

function reaper.TrackFX_GetFormattedParamValue(track, fx_idx, idx, _)
  local fx = track and track.fx[fx_idx + 1]
  if not fx then return false, "" end
  local value = fx.params[idx] or 0.0

  if param_is_frequency(idx) then
    local hz = FREQ_MIN_HZ + value * (FREQ_MAX_HZ - FREQ_MIN_HZ)
    if hz >= 1000 then
      return true, string.format("%.2f kHz", hz / 1000.0)
    end
    return true, string.format("%.1f Hz", hz)
  end

  if param_is_gain(idx) then
    return true, string.format("%.2f dB", value)
  end

  -- Q carries no unit, which is exactly why it is not calibrated.
  return true, string.format("%.3f", value)
end

function reaper.TrackFX_SetParam(track, fx_idx, idx, value)
  local fx = get_fx(track, fx_idx)
  if not fx then return false end
  fx.params[idx] = value
  return true
end

-- Transport / timeline, for the preview control.
function reaper.TimeMap2_beatsToTime(_, beats, measure)
  -- 4/4 at 120 bpm: two seconds a bar.
  return ((measure or 0) * 2.0) + ((beats or 0) * 0.5)
end

function reaper.SetEditCurPos(pos, _, _)
  RMOCK.edit_cursor = pos
end

function reaper.Main_OnCommand(cmd, _)
  RMOCK.commands = RMOCK.commands or {}
  RMOCK.commands[#RMOCK.commands + 1] = cmd
end

function reaper.APIExists(name) return reaper[name] ~= nil end

_G.reaper = reaper
return RMOCK
