"""Role inference, folder inheritance, and per-project persistence."""
import pytest

KEYWORDS = [
    ("Kick In", "drums"),
    ("Snare Top", "drums"),
    ("Overheads L", "drums"),
    ("Hi-Hat", "drums"),
    ("Rhythm Gtr", "guitar"),
    ("Guitar Lead", "guitar"),
    ("Bass DI", "bass"),
    ("Lead Vox", "vocals"),
    ("BGV Stack", "vocals"),
]


@pytest.mark.parametrize("name,expected", KEYWORDS)
def test_infers_role_from_name(mixguideeq, name, expected):
    mixguideeq.add_track(name)
    assert mixguideeq.role_of(name) == expected


WORD_BOUNDARY = [
    ("Custom Bus", "vocals"),      # contains "tom" but is not a tom
    ("Bathroom Verb", "vocals"),   # contains "room"
    ("That Take", "vocals"),       # contains "hat"
]


@pytest.mark.parametrize("name,expected", WORD_BOUNDARY)
def test_keyword_matching_respects_word_boundaries(mixguideeq, name, expected):
    """Unanchored substring matching pulled unrelated tracks into Drums."""
    mixguideeq.add_track(name)
    assert mixguideeq.role_of(name) == expected, (
        "%r was matched by a substring keyword" % name
    )


def test_bass_drum_is_drums_not_bass(mixguideeq):
    mixguideeq.add_track("Bass Drum")
    assert mixguideeq.role_of("Bass Drum") == "drums"


def test_children_inherit_the_root_folder_role(mixguideeq):
    mixguideeq.add_track("Drums", folder_depth=1)
    mixguideeq.add_track("Kick", folder_depth=0)
    mixguideeq.add_track("Ambience", folder_depth=-1)

    cols = mixguideeq.columns()
    assert set(cols["drums"]) == {"Drums", "Kick", "Ambience"}


def test_unrecognised_root_falls_back_to_vocals(mixguideeq):
    mixguideeq.add_track("Bus 7")
    assert mixguideeq.role_of("Bus 7") == "vocals"


def test_manual_move_overrides_inference(mixguideeq):
    track = mixguideeq.add_track("Kick")
    assert mixguideeq.role_of("Kick") == "drums"

    mixguideeq.fns.move_track_to_role(track["guid"], "guitar")
    assert mixguideeq.role_of("Kick") == "guitar"


def test_roles_persist_to_the_project_file(mixguideeq):
    track = mixguideeq.add_track("Kick")
    mixguideeq.fns.move_track_to_role(track["guid"], "guitar")
    mixguideeq.fns.set_track_excluded(track["guid"], True)

    ok, path = mixguideeq.fns.save_project_roles()
    assert ok is True
    assert mixguideeq.roles_file().exists()

    mixguideeq.app["track_roles"] = mixguideeq.lua.table_from({})
    mixguideeq.app["track_excluded"] = mixguideeq.lua.table_from({})
    mixguideeq.fns.load_project_roles()

    assert mixguideeq.app["track_roles"][track["guid"]] == "guitar"
    assert mixguideeq.app["track_excluded"][track["guid"]] is True


def test_roles_file_is_written_in_a_stable_order(mixguideeq):
    """Iterating a hash map made the file churn on every save."""
    for name in ("Kick", "Snare", "Bass DI", "Lead Vox", "Rhythm Gtr"):
        mixguideeq.add_track(name)
    mixguideeq.fns.list_role_columns()
    mixguideeq.fns.save_project_roles()

    body = [line for line in mixguideeq.roles_file().read_text(encoding="utf-8").splitlines()
            if line and not line.startswith("#")]
    guids = [line.split("\t")[0] for line in body]
    assert guids == sorted(guids), "role map rows are not in a deterministic order"


def test_switching_projects_does_not_wipe_saved_roles(mixguideeq):
    """build_role_columns prunes GUIDs it cannot see. With another project
    active that used to empty the map, and the next save wrote the empty map."""
    track = mixguideeq.add_track("Kick")
    mixguideeq.fns.move_track_to_role(track["guid"], "guitar")
    mixguideeq.fns.save_project_roles()
    original = mixguideeq.roles_file().read_text(encoding="utf-8")

    # Reaper switches to a different project tab: different path, no tracks.
    mixguideeq.rmock.set_project((mixguideeq.tmp_path / "Other.rpp").as_posix())
    mixguideeq.rmock["tracks"] = mixguideeq.lua.table_from({})
    mixguideeq.fns.list_role_columns()
    mixguideeq.fns.save_project_roles()

    assert mixguideeq.roles_file().read_text(encoding="utf-8") == original, (
        "the original project's role map was overwritten from another project"
    )


def test_switching_back_restores_the_original_roles(mixguideeq):
    """The map is per project, so it must follow the active project tab."""
    kick = mixguideeq.add_track("Kick")
    mixguideeq.fns.move_track_to_role(kick["guid"], "guitar")
    mixguideeq.fns.save_project_roles()

    mixguideeq.rmock.set_project((mixguideeq.tmp_path / "Other.rpp").as_posix())
    mixguideeq.rmock["tracks"] = mixguideeq.lua.table_from({})
    mixguideeq.fns.list_role_columns()
    assert mixguideeq.app["track_roles"][kick["guid"]] is None

    mixguideeq.rmock.set_project((mixguideeq.tmp_path / "Song.rpp").as_posix())
    mixguideeq.rmock["tracks"] = mixguideeq.lua.eval("function(t) return {t} end")(kick)
    mixguideeq.fns.list_role_columns()

    assert mixguideeq.app["track_roles"][kick["guid"]] == "guitar", (
        "role assignments were not reloaded when returning to the project"
    )


def test_unsaved_edits_are_flushed_when_the_project_switches(mixguideeq):
    kick = mixguideeq.add_track("Kick")
    mixguideeq.fns.list_role_columns()
    mixguideeq.fns.move_track_to_role(kick["guid"], "bass")   # not saved explicitly

    mixguideeq.rmock.set_project((mixguideeq.tmp_path / "Other.rpp").as_posix())
    mixguideeq.rmock["tracks"] = mixguideeq.lua.table_from({})
    mixguideeq.fns.list_role_columns()

    assert mixguideeq.roles_file().exists(), "roles were not flushed on project switch"
    assert "bass" in mixguideeq.roles_file().read_text(encoding="utf-8")
