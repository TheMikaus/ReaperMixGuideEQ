"""Update flow: which install.lua does the in-app Install/Update button run?

Paths are passed in as Lua globals rather than interpolated into the source —
a Windows path like W:\\ToolDev is not a valid Lua string literal.
"""
import pathlib

PROJECT_DIR = pathlib.Path(__file__).resolve().parent.parent


def _load(lua_plain):
    lua_plain.execute(
        'installer_utils = dofile("%s")'
        % (PROJECT_DIR / "installer_utils.lua").as_posix()
    )
    return lua_plain.globals()["installer_utils"]


def test_normalizes_separators_and_trailing_slash(lua_plain):
    utils = _load(lua_plain)
    assert utils.normalize_install_dir("W:\\ToolDev\\MixGuideEQ") == "W:/ToolDev/MixGuideEQ/"
    assert utils.normalize_install_dir("W:/ToolDev/MixGuideEQ/") == "W:/ToolDev/MixGuideEQ/"
    assert utils.normalize_install_dir("") == ""
    assert utils.normalize_install_dir(None) == ""


def test_prefers_saved_source_dir_when_it_has_an_installer(lua_plain):
    utils = _load(lua_plain)
    current = PROJECT_DIR.as_posix() + "/"
    saved = PROJECT_DIR.as_posix() + "/"
    resolved_dir, resolved_path = utils.resolve_installer_path(current, saved)
    assert resolved_dir == saved
    assert resolved_path == saved + "install.lua"


def test_falls_back_to_current_dir_when_saved_dir_is_stale(lua_plain):
    utils = _load(lua_plain)
    current = PROJECT_DIR.as_posix() + "/"
    stale = (PROJECT_DIR / "tests").as_posix() + "/"  # no install.lua here
    resolved_dir, resolved_path = utils.resolve_installer_path(current, stale)
    assert resolved_dir == current
    assert resolved_path == current + "install.lua"


def test_returns_a_usable_path_when_nothing_exists(lua_plain, tmp_path):
    utils = _load(lua_plain)
    missing = tmp_path.as_posix() + "/"
    resolved_dir, resolved_path = utils.resolve_installer_path(missing, "")
    assert resolved_dir == missing
    assert resolved_path == missing + "install.lua"
