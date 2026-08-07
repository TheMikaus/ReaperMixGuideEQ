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


def test_prefers_saved_source_dir_for_updates_when_available():
    lua = load_lua_runtime()
    lua.execute(textwrap.dedent(f"""
    local installer_utils = require('installer_utils')
    local current_dir = '{PROJECT_DIR}'.gsub('\\\\', '/')
    if current_dir:sub(-1) ~= '/' then
      current_dir = current_dir .. '/'
    end
        local saved_dir = '{PROJECT_DIR}'.gsub('\\\\', '/')
        if saved_dir:sub(-1) ~= '/' then
            saved_dir = saved_dir .. '/'
        end
        local resolved_dir, resolved_path = installer_utils.resolve_installer_path(current_dir, saved_dir)
        assert(resolved_dir == saved_dir)
        assert(resolved_path == saved_dir .. 'install.lua')
    """).strip())


if __name__ == '__main__':
    test_prefers_saved_source_dir_for_updates_when_available()
    print('installer path resolution test passed')
