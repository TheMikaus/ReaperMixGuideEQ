"""Pan placement: centre column, paired sources against each other, spread toms.

The failure that matters most is panning a double-tracked pair to the *same*
side — worse than leaving both centred — so pairing is tested hardest.
"""
import pytest


@pytest.fixture
def band(mixguideeq):
    """A conventional rock kit and band, all mono, all centred."""
    mixguideeq.add_track("Drums", folder_depth=1, items=0)
    mixguideeq.add_track("Kick")
    mixguideeq.add_track("Snare")
    mixguideeq.add_track("Tom 1")
    mixguideeq.add_track("Tom 2")
    mixguideeq.add_track("OH L")
    mixguideeq.add_track("OH R", folder_depth=-1)
    mixguideeq.add_track("Bass DI")
    mixguideeq.add_track("Rhythm Gtr L")
    mixguideeq.add_track("Rhythm Gtr R")
    mixguideeq.add_track("Lead Vox")
    mixguideeq.add_track("BGV L")
    mixguideeq.add_track("BGV R")
    mixguideeq.fns.list_role_columns()
    return mixguideeq


def plan(mixguideeq, genre="Rock"):
    report = mixguideeq.fns.analyze_pan_report(genre)
    out = {}
    for row in report["rows"].values():
        for track in row["tracks"].values():
            out[track["base_name"]] = track
    return out


# ── placement rules ─────────────────────────────────────────────────────────

@pytest.mark.parametrize("name", ["Kick", "Snare", "Bass DI", "Lead Vox"])
def test_centre_column_stays_centred(band, name):
    assert plan(band)[name]["target_pan"] == 0.0


def test_doubled_guitars_go_to_opposite_sides(band):
    p = plan(band)
    left = p["Rhythm Gtr L"]["target_pan"]
    right = p["Rhythm Gtr R"]["target_pan"]
    assert left < 0 < right, "doubled guitars did not end up on opposite sides"
    assert left == pytest.approx(-right), "pair is not symmetric"


def test_overheads_go_to_opposite_sides(band):
    p = plan(band)
    assert p["OH L"]["target_pan"] < 0 < p["OH R"]["target_pan"]


def test_backing_vocals_go_to_opposite_sides(band):
    p = plan(band)
    assert p["BGV L"]["target_pan"] < 0 < p["BGV R"]["target_pan"]


def test_toms_are_spread_not_paired(band):
    p = plan(band)
    assert p["Tom 1"]["target_pan"] < 0 < p["Tom 2"]["target_pan"]


def test_unpaired_guitar_is_left_alone(mixguideeq):
    """A lone rhythm guitar has no partner to sit against; hard-panning it is a
    creative choice the tool should not make on its own."""
    mixguideeq.add_track("Rhythm Gtr")
    mixguideeq.fns.list_role_columns()
    entry = plan(mixguideeq)["Rhythm Gtr"]
    assert entry["target_pan"] is None
    assert "unpaired" in entry["reason"]


def test_numbered_pairs_are_detected(mixguideeq):
    mixguideeq.add_track("Gtr 1")
    mixguideeq.add_track("Gtr 2")
    mixguideeq.fns.list_role_columns()
    p = plan(mixguideeq)
    assert p["Gtr 1"]["target_pan"] < 0 < p["Gtr 2"]["target_pan"]


def test_three_of_a_kind_is_not_a_pair(mixguideeq):
    """Two lefts and a right is not a pair; guessing would be worse than
    leaving them alone."""
    for name in ("Gtr L", "Gtr R", "Gtr 1"):
        mixguideeq.add_track(name)
    mixguideeq.fns.list_role_columns()
    p = plan(mixguideeq)
    # "Gtr L"/"Gtr R" still pair; "Gtr 1" has no partner named "Gtr 2".
    assert p["Gtr 1"]["target_pan"] is None


# ── genre differences ───────────────────────────────────────────────────────

def test_rock_spreads_guitars_wider_than_pop(band):
    rock = plan(band, "Rock")["Rhythm Gtr R"]["target_pan"]
    pop = plan(band, "Pop")["Rhythm Gtr R"]["target_pan"]
    assert rock > pop


def test_edm_keeps_toms_narrower_than_rock(band):
    rock = plan(band, "Rock")["Tom 2"]["target_pan"]
    edm = plan(band, "EDM")["Tom 2"]["target_pan"]
    assert edm < rock


# ── the override toggle ─────────────────────────────────────────────────────

def test_existing_pans_are_kept_by_default(band):
    """Someone already placed this guitar; without the override it stays."""
    band.rmock.track_by_name("Rhythm Gtr L")["pan"] = -0.35

    ok, summary, _errors, _report = band.fns.apply_pan_balance("Rock", False)
    assert ok is True
    assert band.rmock.pans()["Rhythm Gtr L"] == pytest.approx(-0.35)
    assert "kept their existing pan" in summary, summary


def test_override_moves_already_panned_tracks(band):
    band.rmock.track_by_name("Rhythm Gtr L")["pan"] = -0.35

    ok, _summary, _errors, _report = band.fns.apply_pan_balance("Rock", True)
    assert ok is True
    assert band.rmock.pans()["Rhythm Gtr L"] == pytest.approx(-1.0)


def test_centred_tracks_move_regardless_of_the_toggle(band):
    """Only *deliberately placed* tracks are protected; a centred track is not
    a choice worth preserving."""
    band.fns.apply_pan_balance("Rock", False)
    assert band.rmock.pans()["Rhythm Gtr L"] == pytest.approx(-1.0)


def test_report_counts_tracks_held_back(band):
    band.rmock.track_by_name("Rhythm Gtr L")["pan"] = -0.35
    band.rmock.track_by_name("BGV R")["pan"] = 0.9
    report = band.fns.analyze_pan_report("Rock")
    assert report["already_panned_count"] == 2


# ── stereo sources ──────────────────────────────────────────────────────────

def test_stereo_tracks_are_not_panned(mixguideeq):
    """D_PAN on a stereo track is a balance control, not a placement control."""
    mixguideeq.add_track("OH L", channels=2)
    mixguideeq.add_track("OH R", channels=2)
    mixguideeq.fns.list_role_columns()

    ok, summary, _errors, _report = mixguideeq.fns.apply_pan_balance("Rock", True)
    assert ok is True
    assert mixguideeq.rmock.pans()["OH L"] == pytest.approx(0.0)
    assert "stereo" in summary.lower(), summary


# ── safety ──────────────────────────────────────────────────────────────────

def test_revert_restores_original_pans(band):
    band.rmock.track_by_name("Tom 1")["pan"] = -0.2
    before = dict(band.rmock.pans())

    band.fns.apply_pan_balance("Rock", True)
    assert band.rmock.pans() != before

    ok, _summary, _errors = band.fns.revert_last_pan_balance()
    assert ok is True
    for name, pan in before.items():
        assert band.rmock.pans()[name] == pytest.approx(pan), "%s not restored" % name


def test_snapshot_survives_a_reload(band):
    before = dict(band.rmock.pans())
    band.fns.apply_pan_balance("Rock", True)

    band.app["last_pan_apply_snapshot"] = None
    band.fns.load_pan_snapshot()
    assert band.fns.get_last_pan_apply_snapshot()["available"] is True

    band.fns.revert_last_pan_balance()
    for name, pan in before.items():
        assert band.rmock.pans()[name] == pytest.approx(pan)


def test_second_apply_is_refused_while_unreverted(band):
    band.fns.apply_pan_balance("Rock", True)
    ok, summary, _errors = band.fns.apply_pan_balance("Pop", True)
    assert ok is False
    assert "revert" in summary.lower()


def test_apply_is_undo_balanced(band):
    band.fns.apply_pan_balance("Rock", True)
    band.fns.revert_last_pan_balance()
    assert band.rmock["undo_depth"] == 0


def test_excluded_tracks_are_not_panned(band):
    guid = band.rmock.track_by_name("Rhythm Gtr L")["guid"]
    band.fns.set_track_excluded(guid, True)
    band.fns.apply_pan_balance("Rock", True)
    assert band.rmock.pans()["Rhythm Gtr L"] == pytest.approx(0.0)


def test_pans_stay_in_range(band):
    band.fns.apply_pan_balance("Rock", True)
    for name, pan in band.rmock.pans().items():
        assert -1.0 <= pan <= 1.0, "%s out of range at %.2f" % (name, pan)


def test_mono_sources_are_panned_despite_a_stereo_track_width(mixguideeq):
    """I_NCHAN is 2 on essentially every Reaper track whatever the media is.
    Using it to detect stereo skipped almost everything."""
    mixguideeq.add_track("Gtr L", channels=1)
    mixguideeq.add_track("Gtr R", channels=1)
    mixguideeq.fns.list_role_columns()

    ok, summary, _errors, _report = mixguideeq.fns.apply_pan_balance("Rock", True)
    assert ok is True
    assert mixguideeq.rmock.pans()["Gtr L"] < 0, summary
    assert "stereo" not in summary.lower(), summary


def test_unknown_source_channels_are_treated_as_mono(mixguideeq):
    """When the channel count cannot be read, pan rather than skip: the common
    case is a mono source, and pan apply is revertable either way."""
    mixguideeq.add_track("Gtr L", channels=0)
    mixguideeq.add_track("Gtr R", channels=0)
    mixguideeq.fns.list_role_columns()

    entry = plan(mixguideeq)["Gtr L"]
    assert entry["is_stereo"] is False
    assert entry["target_pan"] < 0


# ── single-source spot mics ─────────────────────────────────────────────────

def test_hi_hat_is_placed_even_though_it_has_no_pair(mixguideeq):
    """A hat is one mic. It used to be lumped in with overheads, which are
    placed as a pair, so it waited for a partner that never came and stayed
    centred."""
    mixguideeq.add_track("Hi-Hat")
    mixguideeq.fns.list_role_columns()
    entry = plan(mixguideeq)["Hi-Hat"]
    assert entry["target_pan"] is not None, entry["reason"]
    assert entry["target_pan"] < 0, "hat should sit to one side"
    assert abs(entry["target_pan"]) <= 0.35, "hat is kit detail, not a wall"


def test_toms_stay_within_conventional_width(mixguideeq):
    """Convention is 15-30%. They were being thrown out to 70%."""
    for name in ("Tom 1", "Tom 2", "Tom 3"):
        mixguideeq.add_track(name)
    mixguideeq.fns.list_role_columns()

    p = plan(mixguideeq, "Rock")
    for name in ("Tom 1", "Tom 3"):
        assert abs(p[name]["target_pan"]) <= 0.30, (
            "%s at %.2f is wider than a kit ever sits" % (name, p[name]["target_pan"])
        )


def test_overheads_stay_wide(mixguideeq):
    """The pair that actually sets the width should still go out to 75-100%."""
    mixguideeq.add_track("OH L")
    mixguideeq.add_track("OH R")
    mixguideeq.fns.list_role_columns()
    p = plan(mixguideeq, "Rock")
    assert abs(p["OH R"]["target_pan"]) >= 0.75


def test_percussion_is_placed_off_centre(mixguideeq):
    mixguideeq.add_track("Tambourine")
    mixguideeq.fns.list_role_columns()
    entry = plan(mixguideeq)["Tambourine"]
    assert entry["target_pan"] is not None
    assert abs(entry["target_pan"]) > 0.2
