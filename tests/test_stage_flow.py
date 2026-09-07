"""Stage ordering: balance, then EQ, then re-balance.

EQ changes a track's overall level, so applying it invalidates a balance that
was already set. Band shares are normalised, so the reverse is not true — a
fader move does not change any EQ decision.
"""
import pytest

from test_frequency_analysis import analyze
from test_band_targets import MATERIAL


@pytest.fixture
def project(mixguideeq):
    for name, partials in MATERIAL.items():
        mixguideeq.add_track(name, partials=partials)
    mixguideeq.fns.list_role_columns()
    analyze(mixguideeq)
    return mixguideeq


def test_applying_eq_marks_the_balance_stale(project):
    project.fns.apply_volume_balance("Rock")
    assert project.app["eq_applied_since_balance"] is False

    project.fns.build_suggestions(100, "Rock")
    ok, summary, _errors = project.fns.apply_mapped_roles(100, "Rock")

    assert ok is True
    assert project.app["eq_applied_since_balance"] is True
    assert "Analyze Levels" in summary, summary


def test_applying_eq_invalidates_the_analysis(project):
    """The tracks no longer sound like what was measured."""
    assert project.app["last_frequency_report"] is not None
    project.fns.build_suggestions(100, "Rock")
    project.fns.apply_mapped_roles(100, "Rock")
    assert project.app["last_frequency_report"] is None


def test_rebalancing_clears_the_stale_flag(project):
    project.fns.build_suggestions(100, "Rock")
    project.fns.apply_mapped_roles(100, "Rock")
    assert project.app["eq_applied_since_balance"] is True

    project.fns.revert_last_volume_balance()  # no snapshot yet; harmless
    analyze(project)
    project.fns.apply_volume_balance("Rock")
    assert project.app["eq_applied_since_balance"] is False


def test_balancing_does_not_invalidate_the_analysis(project):
    """Levels first is safe: normalised band shares are level-independent, so a
    balance pass never forces a re-analysis."""
    before = project.app["last_frequency_report"]
    assert before is not None
    project.fns.apply_volume_balance("Rock")
    assert project.app["last_frequency_report"] is not None


def test_apply_uses_the_profile_the_suggestions_were_built_with(project):
    """Apply must write what the cards showed, even if the caller passes no
    profile of its own."""
    project.fns.build_suggestions(100, "EDM")
    assert project.app["last_suggestion_profile"] == "EDM"

    ok, summary, _errors = project.fns.apply_mapped_roles(100)
    assert ok is True, summary


def test_apply_without_analysis_falls_back_to_role_defaults(mixguideeq):
    """No measurements means no band targets; the static role curve is the
    honest fallback rather than nothing at all."""
    mixguideeq.add_track("Kick", partials=[(80, 0.8)])
    mixguideeq.fns.list_role_columns()

    report = mixguideeq.fns.build_suggestions(100, "Rock")
    for row in report["rows"].values():
        for suggestion in row["track_suggestions"].values():
            assert suggestion["source"] == "role-default"
            assert any("default" in line for line in suggestion["lines"].values())

    ok, _summary, _errors = mixguideeq.fns.apply_mapped_roles(100, "Rock")
    assert ok is True


# ── the apply gate ──────────────────────────────────────────────────────────

def test_apply_requires_suggestions(project):
    ok, summary, _errors = project.fns.apply_mapped_roles(100, "Rock")
    assert ok is False
    assert "Generate Suggestions first" in summary, summary


def test_second_apply_without_regenerating_is_refused(project):
    """Applying EQ changes the audio, so the analysis behind those suggestions
    no longer describes it. Re-applying used to silently fall back to the
    generic role curve and overwrite the analysis-driven EQ."""
    project.fns.build_suggestions(100, "Rock")
    ok, _summary, _errors = project.fns.apply_mapped_roles(100, "Rock")
    assert ok is True

    ok, summary, _errors = project.fns.apply_mapped_roles(100, "Rock")
    assert ok is False, "a second apply ran against stale suggestions"
    assert "Generate Suggestions first" in summary


def test_reanalyzing_re_arms_apply(project):
    project.fns.build_suggestions(100, "Rock")
    project.fns.apply_mapped_roles(100, "Rock")

    analyze(project)
    project.fns.build_suggestions(100, "Rock")
    ok, summary, _errors = project.fns.apply_mapped_roles(100, "Rock")
    assert ok is True, summary


# ── preview transport ───────────────────────────────────────────────────────

def test_preview_jumps_to_the_bar_and_plays(mixguideeq):
    ok, info = mixguideeq.fns.preview_from_measure("5")
    assert ok is True
    assert info == 5
    # Bar 5 starts after four bars; the mock runs 4/4 at 120 bpm.
    assert mixguideeq.rmock["edit_cursor"] == pytest.approx(8.0)
    assert 1007 in list(mixguideeq.rmock["commands"].values())


def test_preview_rejects_a_bad_bar(mixguideeq):
    ok, info = mixguideeq.fns.preview_from_measure("nonsense")
    assert ok is False
    assert "bar" in str(info).lower()


def test_stop_preview_sends_the_stop_command(mixguideeq):
    mixguideeq.fns.stop_preview()
    assert 1016 in list(mixguideeq.rmock["commands"].values())


# ── applied-state file ──────────────────────────────────────────────────────

def test_eq_applied_flag_survives_a_reload(project):
    project.fns.build_suggestions(100, "Rock")
    project.fns.apply_mapped_roles(100, "Rock")
    assert project.app["eq_applied_since_balance"] is True

    project.app["eq_applied_since_balance"] = False
    project.fns.load_project_state()
    assert project.app["eq_applied_since_balance"] is True


def test_balancing_clears_the_flag_on_disk(project):
    project.fns.build_suggestions(100, "Rock")
    project.fns.apply_mapped_roles(100, "Rock")
    analyze(project)
    project.fns.apply_volume_balance("Rock")

    project.app["eq_applied_since_balance"] = True
    project.fns.load_project_state()
    assert project.app["eq_applied_since_balance"] is False


# ── analyze reverts the previous apply ──────────────────────────────────────

def test_analyze_reverts_a_previous_level_apply(project):
    before = dict(project.rmock.volumes())
    project.fns.apply_volume_balance("Rock")
    assert project.rmock.volumes() != before

    project.fns.revert_before_analysis("levels")
    for name, vol in before.items():
        assert project.rmock.volumes()[name] == pytest.approx(vol), name


def test_analyze_reverts_a_previous_pan_apply(project):
    before = dict(project.rmock.pans())
    project.fns.apply_pan_balance("Rock", True)

    project.fns.revert_before_analysis("pans")
    for name, pan in before.items():
        assert project.rmock.pans()[name] == pytest.approx(pan), name
