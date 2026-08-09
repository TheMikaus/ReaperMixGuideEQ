-- MixGuideEQ Installer
-- Run this script once in Reaper (Actions > Load ReaScript, run it)

local MIXGUIDEEQ_VERSION = "0.35.1"
local REAIMGUI_MIN = "0.8"

local function msg(text)
  reaper.ShowConsoleMsg(text .. "\n")
end

local function get_script_dir()
  local src = debug.getinfo(1).source
  if src:sub(1, 1) == "@" then
    src = src:sub(2)
  end
  local dir = src:match("(.*[/\\])")
  return dir or ""
end

local function copy_file(src, dst)
  local f_in = io.open(src, "rb")
  if not f_in then return false, "Cannot read: " .. src end
  local data = f_in:read("*all")
  f_in:close()

  local f_out = io.open(dst, "wb")
  if not f_out then return false, "Cannot write: " .. dst end
  f_out:write(data)
  f_out:close()
  return true
end

local function reaimgui_installed()
  return reaper.APIExists("ImGui_CreateContext")
end

local function reaimgui_version_ok()
  if not reaper.APIExists("ImGui_GetVersion") then return false end
  local ver = reaper.ImGui_GetVersion()
  local maj, min = ver:match("^(%d+)%.(%d+)")
  local req_maj, req_min = REAIMGUI_MIN:match("^(%d+)%.(%d+)")
  if not maj then return false end
  maj, min = tonumber(maj), tonumber(min)
  req_maj, req_min = tonumber(req_maj), tonumber(req_min)
  return (maj > req_maj) or (maj == req_maj and min >= req_min)
end

local function reappack_installed()
  return reaper.APIExists("ReaPack_GetOwner")
end

local function open_reapack_browser()
  local cmd_id = reaper.NamedCommandLookup("_REAPACK_BROWSE")
  if cmd_id and cmd_id ~= 0 then
    reaper.Main_OnCommand(cmd_id, 0)
    return true
  end
  return false
end

local function check_deps()
  msg("=== MixGuideEQ Installer v" .. MIXGUIDEEQ_VERSION .. " ===")
  msg("")

  if not reappack_installed() then
    msg("ReaPack not found.")
    msg("Install ReaPack from https://reapack.com/, restart Reaper, then run installer again.")
    return false
  end

  msg("ReaPack found")

  if not reaimgui_installed() then
    msg("ReaImGui not found.")
    if open_reapack_browser() then
      msg("ReaPack browser opened. Search for ReaImGui by cfillion and install it.")
    else
      msg("Open ReaPack browser manually and install ReaImGui by cfillion.")
    end
    return false
  end

  if not reaimgui_version_ok() then
    msg("ReaImGui is installed but appears older than " .. REAIMGUI_MIN)
    msg("Update ReaImGui via ReaPack, restart Reaper, and run installer again.")
    return false
  end

  msg("ReaImGui found (v" .. reaper.ImGui_GetVersion() .. ")")
  return true
end

local FILES = {
  "mixguideeq.lua",
  "ui.lua",
  "eq_rules.lua",
  "installer_utils.lua",
  "install.lua",
}

local function install_files()
  local src_dir = get_script_dir()
  local dst_dir = reaper.GetResourcePath() .. "/Scripts/MixGuideEQ"

  reaper.RecursiveCreateDirectory(dst_dir, 0)
  msg("Installing to: " .. dst_dir)

  local all_ok = true
  for _, fname in ipairs(FILES) do
    local src = src_dir .. fname
    local dst = dst_dir .. "/" .. fname
    local ok, err = copy_file(src, dst)
    if ok then
      msg("  OK  " .. fname)
    else
      msg("  FAIL " .. fname .. " - " .. tostring(err))
      all_ok = false
    end
  end

  local cfg_dir = dst_dir .. "/config"
  reaper.RecursiveCreateDirectory(cfg_dir, 0)
  local cfg_dst = cfg_dir .. "/default_config.json"
  local cfg_existing = io.open(cfg_dst, "r")
  if cfg_existing then
    cfg_existing:close()
    msg("  SKIP config/default_config.json (already exists)")
  else
    local ok_cfg = copy_file(src_dir .. "config/default_config.json", cfg_dst)
    if ok_cfg then
      msg("  OK   config/default_config.json")
    else
      msg("  FAIL config/default_config.json")
      all_ok = false
    end
  end

  local source_state_path = dst_dir .. "/mixguideeq_install_source.txt"
  local source_state = io.open(source_state_path, "w")
  if source_state then
    source_state:write(src_dir)
    source_state:close()
    msg("  OK   mixguideeq_install_source.txt")
  else
    msg("  FAIL mixguideeq_install_source.txt")
    all_ok = false
  end

  return all_ok, dst_dir
end

local function register_action(install_dir)
  local main_script = install_dir .. "/mixguideeq.lua"
  local cmd_id = reaper.AddRemoveReaScript(true, 0, main_script, true)
  if cmd_id and cmd_id > 0 then
    msg("Registered Reaper action (command ID: " .. cmd_id .. ")")
    reaper.Main_OnCommand(cmd_id, 0)
    return true
  end

  msg("Could not auto-register action. Load this script manually:")
  msg(main_script)
  return false
end

local function run()
  reaper.ClearConsole()
  if not check_deps() then return end

  local ok, install_dir = install_files()
  if ok then
    register_action(install_dir)
    msg("")
    msg("MixGuideEQ v" .. MIXGUIDEEQ_VERSION .. " installed successfully.")
  else
    msg("")
    msg("Install completed with errors; review lines above.")
  end
end

run()
