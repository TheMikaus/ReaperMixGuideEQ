local M = {}

local function normalize_install_dir(dir)
  if not dir or dir == "" then return "" end
  dir = dir:gsub("\\", "/")
  if dir:sub(-1) ~= "/" then
    dir = dir .. "/"
  end
  return dir
end

M.normalize_install_dir = normalize_install_dir

function M.resolve_installer_path(current_dir, saved_dir)
  local candidates = {}
  local normalized_current = normalize_install_dir(current_dir)
  local normalized_saved = normalize_install_dir(saved_dir)

  if normalized_current ~= "" then
    table.insert(candidates, normalized_current)
  end
  if normalized_saved ~= "" then
    table.insert(candidates, normalized_saved)
  end

  local seen = {}
  for _, dir in ipairs(candidates) do
    if not seen[dir] then
      seen[dir] = true
      local path = dir .. "install.lua"
      local f = io.open(path, "r")
      if f then
        f:close()
        return dir, path
      end
    end
  end

  if normalized_current ~= "" then
    return normalized_current, normalized_current .. "install.lua"
  end
  return normalized_saved, normalized_saved .. "install.lua"
end

return M
