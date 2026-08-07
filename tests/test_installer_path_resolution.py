import os
import textwrap

import lupa


ROOT = os.path.dirname(os.path.abspath(__file__))
PROJECT_DIR = os.path.abspath(os.path.join(ROOT, '..'))


def load_lua_runtime():
    lua = lupa.LuaRuntime(unpack_returned_tuples=True)
    lua_path = os.path.join(PROJECT_DIR, '?.lua').replace('\\', '/')
    lua.execute("package.path = package.path .. ';%s'" % lua_path)
    return lua


def test_prefers_current_script_dir_over_stale_saved_dir():
    lua = load_lua_runtime()
    lua.execute(textwrap.dedent(f"""
    local installer_utils = require('installer_utils')
    local current_dir = '{PROJECT_DIR}'.gsub('\\\\', '/')
    if current_dir:sub(-1) ~= '/' then
      current_dir = current_dir .. '/'
    end
    local stale_dir = '{PROJECT_DIR}/tests/'
    local resolved_dir, resolved_path = installer_utils.resolve_installer_path(current_dir, stale_dir)
    assert(resolved_dir == current_dir)
    assert(resolved_path == current_dir .. 'install.lua')
    """).strip())


if __name__ == '__main__':
    test_prefers_current_script_dir_over_stale_saved_dir()
    print('installer path resolution test passed')
