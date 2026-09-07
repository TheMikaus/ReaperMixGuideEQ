"""Test harness for MixGuideEQ.

Same seam as MixDeck: mixguideeq.lua is a script that ends in ui.init(app, fns),
so stubbing ui.lua captures both tables and lets tests drive the real code.
"""
import os
import pathlib

import pytest
from lupa import lua54

PROJECT_DIR = pathlib.Path(__file__).resolve().parent.parent
TESTS_DIR = PROJECT_DIR / "tests"


def _lua_path(p):
    return str(p).replace("\\", "/")


class MixGuideEQ:
    def __init__(self, lua, app, fns, rmock, resource_path, tmp_path):
        self.lua = lua
        self.app = app
        self.fns = fns
        self.rmock = rmock
        self.resource_path = pathlib.Path(resource_path)
        self.tmp_path = pathlib.Path(tmp_path)

    def add_track(self, name, folder_depth=0, items=1, vol=1.0, pan=0.0,
                  partials=None, duration=4.0, channels=1, gaps=False):
        """Append a track. `partials` is a list of (freq_hz, amplitude) pairs
        describing the audio on that track."""
        lua_partials = self.lua.table_from([
            self.lua.table_from({"freq": f, "amp": a}) for f, a in (partials or [])
        ])
        spec = self.lua.table_from({
            "name": name, "folder_depth": folder_depth, "items": items,
            "vol": vol, "pan": pan, "partials": lua_partials, "duration": duration,
            "channels": channels, "gaps": gaps,
        })
        return self.rmock.add_track(spec)

    def roles_file(self, name="Song"):
        return self.tmp_path / ("%s.mixguideeq.roles" % name)

    def role_of(self, track_name):
        # Roles are assigned lazily by the column scan, so trigger it first.
        self.fns.list_role_columns()
        for track in self.rmock["tracks"].values():
            if track["name"] == track_name:
                return self.app["track_roles"][track["guid"]]
        raise KeyError(track_name)

    def columns(self):
        """{role: [display_name, ...]} as the UI would render it."""
        cols = self.fns.list_role_columns()
        out = {}
        for role in ("drums", "guitar", "bass", "vocals"):
            out[role] = [t["name"] for t in cols[role].values()]
        return out


@pytest.fixture
def mixguideeq(tmp_path):
    resource_path = tmp_path / "reaper_resource"
    os.makedirs(resource_path, exist_ok=True)

    lua = lua54.LuaRuntime(unpack_returned_tuples=True)

    def mkdir(path):
        try:
            os.makedirs(str(path).replace("\\", "/"), exist_ok=True)
        except OSError:
            return 0
        return 1

    lua.globals()["__host_mkdir"] = mkdir
    lua.execute('RMOCK = dofile("%s")' % _lua_path(TESTS_DIR / "reaper_mock.lua"))
    rmock = lua.globals()["RMOCK"]
    rmock["resource_path"] = _lua_path(resource_path)
    rmock.set_project(_lua_path(tmp_path / "Song.rpp"))

    lua.execute(
        """
        _CAPTURED = {}
        local real_dofile = dofile
        _G.dofile = function(path)
          if tostring(path):match("ui%.lua$") then
            return {
              init = function(app, fns) _CAPTURED.app = app; _CAPTURED.fns = fns end,
              loop = function() return false end,
            }
          end
          return real_dofile(path)
        end
        """
    )
    lua.execute('dofile("%s")' % _lua_path(PROJECT_DIR / "mixguideeq.lua"))

    captured = lua.globals()["_CAPTURED"]
    return MixGuideEQ(lua, captured["app"], captured["fns"], rmock,
                      resource_path, tmp_path)


@pytest.fixture
def lua_plain():
    lua = lua54.LuaRuntime(unpack_returned_tuples=True)
    lua.execute(
        "package.path = package.path .. ';%s'" % _lua_path(PROJECT_DIR / "?.lua")
    )
    return lua


@pytest.fixture
def eq_rules(lua_plain):
    """eq_rules.lua on its own — the band-target math needs no Reaper at all."""
    lua_plain.execute(
        'eq_rules = dofile("%s")' % _lua_path(PROJECT_DIR / "eq_rules.lua")
    )
    return lua_plain
