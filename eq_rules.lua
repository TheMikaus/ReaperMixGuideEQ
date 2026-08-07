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

function M.build_rule_set(role, strength_pct)
  local normalized_role = M.normalize_role(role)
  local base = ROLE_RULES[normalized_role] or ROLE_RULES.vocals
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

return M
