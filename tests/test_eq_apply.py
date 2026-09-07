"""Auto EQ inserts and configures ReaEQ. Builds differ in FX naming and in
whether named band config works, so the apply path has to survive both."""
import pytest


@pytest.fixture
def project(mixguideeq):
    mixguideeq.add_track("Kick", partials=[(60, 0.8)])
    mixguideeq.add_track("Lead Vox", partials=[(500, 0.7)])
    mixguideeq.fns.list_role_columns()
    return mixguideeq


def apply(project, strength=100):
    """Apply follows Generate Suggestions, which is how the UI drives it."""
    project.fns.build_suggestions(strength, "Rock")
    return project.fns.apply_mapped_roles(strength, "Rock")


def fx_count(project, track_name):
    return len(list(project.rmock.track_by_name(track_name)["fx"].values()))


def test_inserts_reaeq_on_a_track_that_has_none(project):
    """Every AddByName call used a query-only instantiate, so a track without a
    pre-existing ReaEQ got nothing inserted and the apply failed."""
    assert fx_count(project, "Kick") == 0
    ok, summary, _errors = apply(project)
    assert ok is True, summary
    assert fx_count(project, "Kick") == 1, "no ReaEQ was inserted"


def test_reuses_an_existing_reaeq_instead_of_stacking(project):
    apply(project)
    apply(project)
    assert fx_count(project, "Kick") == 1, "a second ReaEQ was stacked on the track"


def test_writes_parameters(project):
    apply(project)
    params = project.rmock.track_by_name("Kick")["fx"][1]["params"]
    assert len(list(params.values())) > 0, "no EQ parameters were written"


def test_probe_does_not_leave_band_one_modified(project):
    """The named-config probe used to write BANDTYPE1 as a side effect."""
    apply(project)
    config = project.rmock.track_by_name("Kick")["fx"][1]["config"]
    # Band 1 is the HPF slot; the probe must not have left it as a bell.
    assert config["BANDTYPE1"] != "0", "probe left band 1 converted to a bell filter"


def test_falls_back_when_named_config_is_unsupported(project):
    """Older ReaEQ builds reject named band config entirely."""
    project.rmock["fx_named_config_supported"] = False
    ok, summary, _errors = apply(project)
    assert ok is True, summary
    params = project.rmock.track_by_name("Kick")["fx"][1]["params"]
    assert len(list(params.values())) > 0, "fallback path wrote no parameters"


def test_excluded_tracks_are_skipped(project):
    kick = project.rmock.track_by_name("Kick")
    project.fns.set_track_excluded(kick["guid"], True)
    apply(project)
    assert fx_count(project, "Kick") == 0, "an excluded track was given an EQ"


def test_apply_is_undo_balanced(project):
    apply(project)
    assert project.rmock["undo_depth"] == 0, "undo block left unbalanced"


# ── frequency lands where it was asked to ───────────────────────────────────

def test_high_pass_lands_at_the_requested_frequency(project):
    """The old code assumed ReaEQ's frequency parameter is a log map over
    20 Hz-24 kHz. On a plugin with any other curve a 70 Hz high-pass lands
    somewhere else entirely - around 4 kHz on a linear scale - which removes
    almost everything a guitar, vocal or snare has."""
    apply(project)

    # Band 1 is the high-pass slot; param 0 is its frequency. A kick's subtype
    # rule asks for 25 Hz. Under the old log assumption this same request wrote
    # 0.057, which on the mock's linear scale is about 1.4 kHz.
    hz = project.rmock.param_hz("Kick", 0, 0)
    assert hz is not None
    assert hz == pytest.approx(25.0, abs=1.0), (
        "kick high-pass landed at %.0f Hz instead of 25 Hz" % hz
    )


def test_a_vocal_high_pass_does_not_land_in_the_midrange(project):
    apply(project)
    hz = project.rmock.param_hz("Lead Vox", 0, 0)
    assert hz < 200, "vocal high-pass landed at %.0f Hz" % hz


# -- gain lands where it was asked to -----------------------------------------
#
# The same class of bug as the frequency one, found the same way. Gain was
# written through an assumed -24..+24 dB linear map and then clamped to 0..1,
# so on a plugin whose gain parameter is in real dB units every corrective move
# landed at the bottom of the range. Three of those per track is a track you
# cannot hear.

def plan_moves(project, strength=100):
    """The moves the Suggestions card shows, which is what Apply writes."""
    rows = project.fns.build_suggestions(strength, "Rock")
    out = {}
    for role_row in rows["rows"].values():
        for suggestion in role_row["track_suggestions"].values():
            out[suggestion["name"]] = list((suggestion["moves"] or {}).values())
    return out


def written_gains(project, track_name):
    """Band 2..4 gain, in dB, read back from the plugin."""
    return [project.rmock.param_db(track_name, 0, band * 3 + 1) for band in (1, 2, 3)]


def test_a_corrective_move_lands_at_the_gain_it_asked_for(project):
    moves = plan_moves(project)["Kick"]
    if not moves:
        pytest.skip("no corrective move for this material")

    project.fns.apply_mapped_roles(100, "Rock")

    landed = written_gains(project, "Kick")
    # Only the first three fit: ReaEQ gets one high-pass and three moves.
    for i, move in enumerate(moves[:3]):
        assert landed[i] == pytest.approx(move["gain"], abs=0.2), (
            "move %d asked for %+.2f dB and landed at %+.2f dB"
            % (i + 1, move["gain"], landed[i])
        )


def test_no_band_is_driven_to_the_bottom_of_its_range(project):
    """Clamping a 0..1 value into a -18..+18 dB parameter pins every band at
    -18 dB, which is what silences a track."""
    apply(project)
    for name in ("Kick", "Lead Vox"):
        for gain in written_gains(project, name):
            assert gain > -12.0, "%s has a band at %.1f dB" % (name, gain)


def test_unused_bands_are_left_flat(project):
    """A band with no move must not be left holding a cut."""
    moves = plan_moves(project)["Kick"]
    apply(project)
    for band in range(min(len(moves), 3), 3):
        gain = project.rmock.param_db("Kick", 0, (band + 1) * 3 + 1)
        assert gain == pytest.approx(0.0, abs=0.2), (
            "unused band %d sits at %.2f dB" % (band + 2, gain)
        )


# ── the apply runs in slices ────────────────────────────────────────────────

def drive_apply(project, per_step=1, strength=100):
    """Run the incremental apply to completion, returning the progress trail."""
    project.fns.build_suggestions(strength, "Rock")
    ok, info = project.fns.start_eq_apply(strength, "Rock")
    assert ok is True, info

    trail = []
    for _ in range(200):
        ok, status = project.fns.step_eq_apply(per_step)
        assert ok is True, status
        trail.append(status["progress"])
        if status["done"]:
            return trail, status
    raise AssertionError("apply never finished")


def test_apply_completes_in_slices(project):
    trail, status = drive_apply(project)
    assert len(trail) > 1, "the whole apply ran in a single step"
    assert trail == sorted(trail), "progress went backwards: %s" % trail
    assert trail[-1] == 1.0
    assert "Applied Auto EQ" in status["summary"]


def test_sliced_apply_writes_the_same_parameters(project):
    drive_apply(project)
    params = project.rmock.track_by_name("Kick")["fx"][1]["params"]
    assert len(list(params.values())) > 0
    assert project.rmock.param_hz("Kick", 0, 0) == pytest.approx(25.0, abs=1.0)


def test_apply_refuses_without_suggestions(project):
    ok, info = project.fns.start_eq_apply(100, "Rock")
    assert ok is False
    assert "Generate Suggestions first" in info


def test_apply_clears_the_gate_when_it_finishes(project):
    drive_apply(project)
    assert project.app["suggestions_ready"] is False
    assert project.app["eq_applied_since_balance"] is True
