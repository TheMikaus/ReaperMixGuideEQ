local M = {}

local ROLE_ALIASES = {
  vox = "vocals",
  vocal = "vocals",
  voice = "vocals",
  drum = "drums",
  gtr = "guitar",
}

local ROLE_RULES = {
  vocals = {
    summary = "HPF around 80Hz and presence lift around 3kHz.",
    hpf_hz = 80,
    low_cut_db = -2.0,
    low_cut_hz = 250,
    presence_boost_db = 2.5,
    presence_hz = 3000,
    air_boost_db = 1.5,
    air_hz = 10000,
  },
  bass = {
    summary = "Focus 40-250Hz and clean sub rumble.",
    hpf_hz = 20,
    low_shelf_boost_db = 2.0,
    low_shelf_hz = 80,
    mud_cut_db = -1.5,
    mud_cut_hz = 250,
    definition_boost_db = 1.0,
    definition_hz = 1200,
  },
  drums = {
    summary = "Punch near 200Hz and air near 10kHz.",
    hpf_hz = 30,
    punch_boost_db = 2.5,
    punch_hz = 200,
    boxy_cut_db = -2.0,
    boxy_hz = 500,
    air_boost_db = 2.0,
    air_hz = 10000,
  },
  guitar = {
    summary = "Reduce mud at 200Hz and lift cut-through at 3kHz.",
    hpf_hz = 70,
    mud_cut_db = -2.5,
    mud_cut_hz = 200,
    presence_boost_db = 2.0,
    presence_hz = 3200,
    fizz_cut_db = -1.0,
    fizz_hz = 7000,
  },
}

local DRUM_SUBTYPE_RULES = {
  kick = {
    summary = "Kick: preserve thump and click, reduce boxiness.",
    hpf_hz = 25,
    low_shelf_boost_db = 2.5,
    low_shelf_hz = 70,
    boxy_cut_db = -2.5,
    boxy_hz = 350,
    definition_boost_db = 1.5,
    definition_hz = 3000,
  },
  snare = {
    summary = "Snare: body in low mids, crack in upper mids.",
    hpf_hz = 80,
    punch_boost_db = 2.0,
    punch_hz = 200,
    boxy_cut_db = -2.0,
    boxy_hz = 650,
    presence_boost_db = 2.0,
    presence_hz = 3500,
  },
  toms = {
    summary = "Toms: keep weight, reduce mud, add attack.",
    hpf_hz = 50,
    punch_boost_db = 2.0,
    punch_hz = 120,
    mud_cut_db = -1.5,
    mud_cut_hz = 300,
    presence_boost_db = 1.5,
    presence_hz = 4500,
  },
  overheads = {
    summary = "Overheads: clean lows and shape cymbal brightness.",
    hpf_hz = 180,
    mud_cut_db = -1.5,
    mud_cut_hz = 350,
    air_boost_db = 1.5,
    air_hz = 11000,
    fizz_cut_db = -1.0,
    fizz_hz = 8000,
  },
  room = {
    summary = "Room: tighten low boom and control harsh cymbal wash.",
    hpf_hz = 100,
    mud_cut_db = -2.0,
    mud_cut_hz = 250,
    air_boost_db = 1.0,
    air_hz = 10000,
    fizz_cut_db = -1.5,
    fizz_hz = 7000,
  },
}

local function clamp(v, min_v, max_v)
  if v < min_v then return min_v end
  if v > max_v then return max_v end
  return v
end

local function scale_db(v, strength)
  return v * strength
end

function M.get_role_names()
  return { "vocals", "bass", "drums", "guitar" }
end

function M.normalize_role(role)
  local normalized = (role or ""):lower()
  if ROLE_ALIASES[normalized] then
    return ROLE_ALIASES[normalized]
  end
  return normalized
end

function M.detect_drum_subtype(track_name)
  local n = (track_name or ""):lower()
  if n:find("kick", 1, true) or n:find("bd", 1, true) or n:find("kik", 1, true) then return "kick" end
  if n:find("snare", 1, true) or n:find("sd", 1, true) then return "snare" end
  if n:find("tom", 1, true) then return "toms" end
  if n:find("hihat", 1, true)
    or n:find("hi-hat", 1, true)
    or n:find("hat", 1, true)
    or n:find("crash", 1, true)
    or n:find("ride", 1, true)
    or n:find("cym", 1, true)
  then
    return "overheads"
  end
  if n:find("overhead", 1, true) or n:find("oh", 1, true) then return "overheads" end
  if n:find("room", 1, true) then return "room" end
  return nil
end

local function merge_rule(base, overrides)
  local merged = {}
  for k, v in pairs(base) do
    merged[k] = v
  end
  if overrides then
    for k, v in pairs(overrides) do
      merged[k] = v
    end
  end
  return merged
end

function M.build_rule_set(role, strength_pct, context)
  local normalized_role = M.normalize_role(role)
  local base = ROLE_RULES[normalized_role] or ROLE_RULES.vocals
  local drum_subtype = nil

  if normalized_role == "drums" then
    local track_name = context and (context.track_name or context.track_label)
    drum_subtype = M.detect_drum_subtype(track_name)
    if drum_subtype and DRUM_SUBTYPE_RULES[drum_subtype] then
      base = merge_rule(base, DRUM_SUBTYPE_RULES[drum_subtype])
    end
  end

  local pct = clamp(tonumber(strength_pct) or 100, 0, 150)
  local strength = pct / 100

  local out = {
    role = normalized_role,
    summary = base.summary,
    hpf_hz = base.hpf_hz,
  }

  for k, v in pairs(base) do
    if type(v) == "number" and k:match("_db$") then
      out[k] = scale_db(v, strength)
    elseif out[k] == nil then
      out[k] = v
    end
  end

  if drum_subtype then
    out.drum_subtype = drum_subtype
    out.summary = tostring(out.summary or "") .. " Drum subtype: " .. drum_subtype .. "."
  end

  out.strength_pct = pct
  return out
end

function M.to_lines(rule)
  if not rule then return {} end

  local out = {
    "HPF: " .. tostring(rule.hpf_hz) .. " Hz",
  }

  local pairs_out = {
    { "low_cut_db", "low_cut_hz", "Low cut" },
    { "mud_cut_db", "mud_cut_hz", "Mud cut" },
    { "presence_boost_db", "presence_hz", "Presence boost" },
    { "air_boost_db", "air_hz", "Air boost" },
    { "punch_boost_db", "punch_hz", "Punch boost" },
    { "boxy_cut_db", "boxy_hz", "Boxy cut" },
    { "low_shelf_boost_db", "low_shelf_hz", "Low shelf" },
    { "definition_boost_db", "definition_hz", "Definition boost" },
    { "fizz_cut_db", "fizz_hz", "Fizz cut" },
  }

  for _, entry in ipairs(pairs_out) do
    local gain_key, freq_key, label = entry[1], entry[2], entry[3]
    local gain = rule[gain_key]
    local freq = rule[freq_key]
    if type(gain) == "number" and type(freq) == "number" then
      out[#out + 1] = string.format("%s: %.1f dB @ %d Hz", label, gain, freq)
    end
  end

  return out
end

function M.render_summary(rule)
  if not rule then return "No rule selected" end

  local lines = {
    "Role: " .. tostring(rule.role),
    "Strength: " .. tostring(rule.strength_pct) .. "%",
    "HPF: " .. tostring(rule.hpf_hz) .. " Hz",
    tostring(rule.summary or ""),
  }

  return table.concat(lines, "\n")
end

-- ============================================================================
-- BAND TARGETS
-- ============================================================================
--
-- The static ROLE_RULES above are a fixed curve per role. Band targets are the
-- analysis-driven alternative: measure how a track's energy is distributed
-- across four bands, compare that to where a track of this role should sit in
-- this genre, and correct the difference.
--
-- This is what the genre profile is for. Level offsets say how loud a role
-- should be; band targets say what shape it should have. Deriving one from the
-- other cannot work, because "tuck this role" means smaller boosts AND deeper
-- cuts -- opposite directions that a single scalar gets half right at best.

M.BAND_ORDER = { "low", "low_mid", "presence", "high" }

-- Where each band's correction is written, matched to the analyzer's probe
-- frequencies (low = 86/194 Hz, low_mid = 495/1206, presence = 2993,
-- high = 6998/9991).
M.BAND_LAYOUT = {
  low      = { hz = 100,  band_type = "LowShelf",  q = 0.90, label = "low" },
  low_mid  = { hz = 600,  band_type = "Band",      q = 1.00, label = "low-mid" },
  presence = { hz = 3000, band_type = "Band",      q = 1.00, label = "presence" },
  high     = { hz = 9000, band_type = "HighShelf", q = 0.90, label = "high" },
}

-- The spectral signature of a neutral, well-balanced track of each role, given
-- as each band's share of that track's total measured energy in dB.
--
-- These are a starting calibration, not measured truth: they encode that bass
-- is low-dominant, vocals and guitars are mid-dominant, and drums are the most
-- broadband of the four. Tune them against real material -- every correction is
-- clamped to MAX_BAND_MOVE_DB, so a mis-calibrated reference makes suggestions
-- less useful but cannot produce a wild EQ move.
M.ROLE_BAND_REFERENCE = {
  bass   = { low =  -1.0, low_mid =  -9.0, presence = -20.0, high = -28.0 },
  drums  = { low =  -4.0, low_mid =  -8.0, presence = -12.0, high = -12.0 },
  guitar = { low =  -8.0, low_mid =  -3.5, presence = -10.0, high = -16.0 },
  vocals = { low = -10.0, low_mid =  -3.0, presence =  -8.0, high = -14.0 },
}

-- Correction limits, per docs/analysis_and_balance_plan.md.
M.MAX_BAND_MOVE_DB = 4.0
-- Below this a move is not worth writing: level differences under about half a
-- dB in a dense mix are not audible.
M.MIN_BAND_MOVE_DB = 0.5

-- Renormalise a set of per-band dB values so they describe a valid share
-- distribution -- that is, so the linear shares sum to 1.
--
-- This matters twice. The reference tables are written by hand and will not sum
-- to unity, which would otherwise apply a constant bias to every correction.
-- And genre offsets can ask for more of everything at once, which is not a
-- meaningful shape: renormalising turns "boost all four bands" into "no change",
-- which is what it actually means when you are describing relative emphasis.
function M.normalize_shape_db(shape_db)
  local total = 0.0
  local linear = {}
  for _, band in ipairs(M.BAND_ORDER) do
    local value = 10.0 ^ ((shape_db[band] or 0.0) / 10.0)
    linear[band] = value
    total = total + value
  end
  if total <= 0 then return shape_db end

  local out = {}
  for _, band in ipairs(M.BAND_ORDER) do
    local ratio = math.max(linear[band] / total, 1e-9)
    out[band] = 10.0 * (math.log(ratio) / math.log(10.0))
  end
  return out
end

-- Each band's share of the track's total measured energy, in dB. Normalising by
-- the total makes this a shape, independent of how loud the track is -- level is
-- the balance stage's job, not the EQ stage's.
function M.band_shares_db(metrics)
  if not metrics then return nil end

  local total = 0.0
  for _, band in ipairs(M.BAND_ORDER) do
    local value = tonumber(metrics[band])
    if not value or value < 0 then return nil end
    total = total + value
  end
  if total <= 0 then return nil end

  local shares = {}
  for _, band in ipairs(M.BAND_ORDER) do
    local value = tonumber(metrics[band]) or 0.0
    -- Floor the ratio so an empty band reports "very quiet" rather than -inf.
    local ratio = math.max(value / total, 1e-9)
    shares[band] = 10.0 * (math.log(ratio) / math.log(10.0))
  end
  return shares
end

-- Compare a track's measured shape against the target for its role in this
-- genre and return the EQ moves that close the gap.
--
-- band_targets is the per-role table from the genre profile: a dB offset per
-- band applied on top of ROLE_BAND_REFERENCE. Returns moves sorted by size,
-- largest first, capped at max_moves.
-- The correction each band wants, before thresholding or ranking: one entry per
-- band, always. Separated out so callers that need the full picture (genre
-- comparisons, a "why" panel) are not looking at a list that has already had
-- small moves dropped and been truncated to the three available ReaEQ slots.
function M.band_deltas_db(role, band_targets, metrics, strength_pct)
  local normalized_role = M.normalize_role(role)
  local reference = M.ROLE_BAND_REFERENCE[normalized_role] or M.ROLE_BAND_REFERENCE.vocals
  local shares = M.band_shares_db(metrics)
  if not shares then return nil end

  local strength = clamp(tonumber(strength_pct) or 100, 0, 150) / 100
  band_targets = band_targets or {}

  -- Reference plus genre emphasis, renormalised so it is a valid shape and
  -- directly comparable with the measured shares.
  local target_shape = {}
  for _, band in ipairs(M.BAND_ORDER) do
    target_shape[band] = (reference[band] or 0.0) + (tonumber(band_targets[band]) or 0.0)
  end
  target_shape = M.normalize_shape_db(target_shape)

  local deltas = {}
  for _, band in ipairs(M.BAND_ORDER) do
    local measured_db = shares[band]
    local target_db = target_shape[band]
    deltas[band] = {
      band = band,
      measured_db = measured_db,
      target_db = target_db,
      gain = clamp((target_db - measured_db) * strength,
        -M.MAX_BAND_MOVE_DB, M.MAX_BAND_MOVE_DB),
    }
  end
  return deltas
end

function M.build_band_moves(role, band_targets, metrics, strength_pct, max_moves)
  local normalized_role = M.normalize_role(role)
  local deltas = M.band_deltas_db(role, band_targets, metrics, strength_pct)
  if not deltas then return {} end

  max_moves = max_moves or 3

  local candidates = {}
  for _, band in ipairs(M.BAND_ORDER) do
    local layout = M.BAND_LAYOUT[band]
    local delta = deltas[band]

    if math.abs(delta.gain) >= M.MIN_BAND_MOVE_DB then
      candidates[#candidates + 1] = {
        band = band,
        label = layout.label,
        freq = layout.hz,
        q = layout.q,
        band_type = layout.band_type,
        gain = delta.gain,
        measured_db = delta.measured_db,
        target_db = delta.target_db,
        reason = string.format(
          "%s measured %.1f dB vs %.1f dB target for %s",
          layout.label, delta.measured_db, delta.target_db, normalized_role
        ),
      }
    end
  end

  -- Biggest problems first, so the three ReaEQ slots go to what matters most.
  table.sort(candidates, function(a, b)
    if math.abs(a.gain) == math.abs(b.gain) then
      return a.band < b.band
    end
    return math.abs(a.gain) > math.abs(b.gain)
  end)

  local moves = {}
  for i = 1, math.min(max_moves, #candidates) do
    moves[i] = candidates[i]
  end
  return moves
end

-- ============================================================================
-- PAN PLACEMENT
-- ============================================================================
--
-- Panning is more categorical than level or EQ: a handful of sources belong in
-- the centre and everything else is placed relative to a partner. The two hard
-- parts are deciding which category a track is in, and finding its partner --
-- panning a double-tracked pair to the same side is worse than leaving both
-- centred, so pairing has to be right before anything is written.

-- Trailing tokens that mark one half of a pair. Numbers cover the "Gtr 1 / Gtr 2"
-- convention as well as explicit left/right.
local PAN_SIDE_TOKENS = {
  l = "L", left = "L", ["1"] = "L",
  r = "R", right = "R", ["2"] = "R",
}

-- Split "Rhythm Gtr L" into ("rhythm gtr", "L"). Returns nil when the name does
-- not end in a side marker, which means the track is not half of a named pair.
function M.split_pan_pair_name(name)
  local words = {}
  for word in tostring(name or ""):lower():gmatch("[%a%d]+") do
    words[#words + 1] = word
  end
  if #words < 2 then return nil, nil end

  local side = PAN_SIDE_TOKENS[words[#words]]
  if not side then return nil, nil end

  table.remove(words)
  return table.concat(words, " "), side
end

local function has_word(name, wanted)
  for word in tostring(name or ""):lower():gmatch("[%a%d]+") do
    if word == wanted then return true end
  end
  return false
end

local function has_any_word(name, wanted)
  for _, word in ipairs(wanted) do
    if has_word(name, word) then return true end
  end
  return false
end

-- Which pan rule applies to a track.
--
--   center     -- kick, snare, bass, lead vocal. Never panned: low frequency
--                 content panned off centre wastes headroom and collapses in mono,
--                 and the lead vocal is the anchor of the image.
--   guitar     -- placed against its partner
--   overheads  -- placed against its partner (hats, cymbals, OH)
--   toms       -- spread across the image rather than paired
--   room       -- widest of the drum sources
--   bgv        -- backing vocals and harmonies, spread
--   none       -- no opinion; left where the user put it
function M.pan_category(role, name)
  local normalized_role = M.normalize_role(role)

  if normalized_role == "bass" then
    return "center"
  end

  if normalized_role == "drums" then
    -- Hats and single cymbal spots are their own thing: they are one mic, so
    -- they are placed on a side rather than paired against a partner. Lumping
    -- them in with overheads meant they waited for a pair that never came and
    -- ended up centred.
    if has_any_word(name, { "hat", "hats", "hihat", "hh" }) then return "hat" end
    if has_any_word(name, { "crash", "ride", "cym", "cymbal", "cymbals" }) then
      return "cymbal"
    end
    if has_any_word(name, { "perc", "percussion", "tamb", "tambourine",
                            "shaker", "cowbell", "conga", "bongo" }) then
      return "percussion"
    end

    local subtype = M.detect_drum_subtype(name)
    if subtype == "kick" or subtype == "snare" then return "center" end
    if subtype == "toms" then return "toms" end
    if subtype == "room" then return "room" end
    if subtype == "overheads" then return "overheads" end
    return "none"
  end

  if normalized_role == "vocals" then
    if has_any_word(name, { "bgv", "bvs", "bv", "back", "backing", "harm", "harmony",
                            "harmonies", "dbl", "double", "stack" }) then
      return "bgv"
    end
    return "center"
  end

  if normalized_role == "guitar" then
    return "guitar"
  end

  return "none"
end

-- Categories whose pan target is fixed rather than taken from the profile.
function M.pan_category_is_centered(category)
  return category == "center"
end

-- Categories placed on one side because they are a single spot mic, rather than
-- being set against a partner. Hats sit left, viewed from behind the kit; a
-- second cymbal spot goes the other way so they do not stack up.
M.SINGLE_SIDED_CATEGORIES = {
  hat = -1,
  cymbal = 1,
  percussion = 1,
}

return M
