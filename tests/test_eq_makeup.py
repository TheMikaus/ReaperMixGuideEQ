"""The EQ stage shapes a track; it does not set its level.

Band shares are normalised by total energy, so the *decisions* never depended on
how loud a track was. The *result* did: filters remove energy, so every apply
left the mix quieter and only a balance pass got it back. The apply already
measures the track either side of the write, so it hands the difference back on
the fader and snapshots what it moved.
"""
import math

import pytest


def db(linear):
    return 20.0 * math.log10(linear)


@pytest.fixture
def project(mixguideeq):
    mixguideeq.add_track("Kick", partials=[(60, 0.8)])
    mixguideeq.add_track("Lead Vox", partials=[(500, 0.7)])
    mixguideeq.fns.list_role_columns()
    return mixguideeq


def costs_level(project, track_name, lost_db):
    """Make this track's EQ remove level, the way a real filter does."""
    project.rmock["eq_level_factor"][track_name] = 10.0 ** (-abs(lost_db) / 20.0)


def apply(project, strength=100):
    project.fns.build_suggestions(strength, "Rock")
    return project.fns.apply_mapped_roles(strength, "Rock")


def fader_db(project, track_name):
    return db(project.rmock.track_by_name(track_name)["vol"])


def test_the_level_a_filter_costs_comes_back(project):
    costs_level(project, "Kick", 6.0)
    apply(project)
    assert fader_db(project, "Kick") == pytest.approx(6.0, abs=1.0), (
        "kick came out %.2f dB down after its EQ" % fader_db(project, "Kick")
    )


def test_a_track_the_eq_does_not_cost_is_left_alone(project):
    costs_level(project, "Kick", 6.0)
    apply(project)
    assert fader_db(project, "Lead Vox") == pytest.approx(0.0, abs=0.3)


def test_the_makeup_is_bounded(project):
    """A track losing this much did not lose it to shaping, and compensating
    all of it would hide a filter landing in the wrong place."""
    costs_level(project, "Kick", 24.0)
    apply(project)
    assert fader_db(project, "Kick") <= 9.5


def test_a_large_loss_is_still_reported(project):
    costs_level(project, "Kick", 12.0)
    _ok, _summary, errors = apply(project)
    joined = " ".join(list(errors.values()))
    assert "Kick" in joined and "lost" in joined, (
        "a 12 dB loss was silently compensated: %r" % joined
    )


def test_the_summary_says_what_it_returned(project):
    costs_level(project, "Kick", 6.0)
    _ok, summary, _errors = apply(project)
    assert "Returned the level" in summary, summary


# -- undo ---------------------------------------------------------------------

def test_the_makeup_is_snapshotted(project):
    costs_level(project, "Kick", 6.0)
    apply(project)
    snapshot = project.fns.get_last_eq_makeup_snapshot()
    assert snapshot is not None
    assert len(list(snapshot["tracks"].values())) == 1


def test_reverting_puts_the_faders_back(project):
    costs_level(project, "Kick", 6.0)
    apply(project)
    project.fns.revert_last_eq_makeup()

    assert fader_db(project, "Kick") == pytest.approx(0.0, abs=0.01)
    assert project.fns.get_last_eq_makeup_snapshot() is None


def test_the_snapshot_survives_a_reload(project):
    costs_level(project, "Kick", 6.0)
    apply(project)
    project.fns.load_eq_makeup_snapshot()
    assert project.fns.get_last_eq_makeup_snapshot() is not None


def test_revert_with_nothing_to_revert_says_so(project):
    ok, message = project.fns.revert_last_eq_makeup()
    assert ok is False
    assert "No EQ makeup" in message


def test_analyzing_for_eq_takes_the_makeup_off(project):
    """Analysis measures the mix as it stands. Measuring one that already
    carries this stage's own compensation builds the next plan on it."""
    costs_level(project, "Kick", 6.0)
    apply(project)

    ok, message, undone = project.fns.revert_before_analysis("eq")
    assert ok is True, message
    assert "EQ makeup gain" in list(undone.values())
    assert fader_db(project, "Kick") == pytest.approx(0.0, abs=0.01)


def test_a_second_apply_does_not_stack_makeup(project):
    """The fader the second run snapshots would otherwise already carry the
    first run's correction, making it unrecoverable."""
    costs_level(project, "Kick", 6.0)
    apply(project)
    apply(project)

    assert fader_db(project, "Kick") == pytest.approx(6.0, abs=1.0), (
        "makeup stacked to %.2f dB" % fader_db(project, "Kick")
    )
    snapshot = project.fns.get_last_eq_makeup_snapshot()
    original = list(snapshot["tracks"].values())[0]["vol"]
    assert db(original) == pytest.approx(0.0, abs=0.01), (
        "the snapshot captured a fader that already carried makeup"
    )
