"""The plan has to see the faders that are already there.

accessor_includes_fader was written, documented, and never called, and the
heard level was the measurement plus the folder's fader and nothing else. On a
build whose accessor reads before the fader, every track was planned as if it
sat at 0 dB: a bass already at +6.5 dB measured 6.5 dB quieter than anyone
could hear it and was pushed to +12 for it, and re-measuring after an apply
produced the identical plan a second time.
"""
import math

import pytest


def db(linear):
    return 20.0 * math.log10(linear)


def moves(report):
    return {r["name"]: r["delta_db"] for r in report["ranked"].values()}


def ranked_names(report):
    return [r["name"] for r in report["ranked"].values()]


@pytest.fixture
def twins(mixguideeq):
    """Two vocals with identical audio; one fader sits 6 dB up."""
    mixguideeq.add_track("Vox A", partials=[(500, 0.3)])
    mixguideeq.add_track("Vox B", partials=[(500, 0.3)], vol=2.0)   # +6 dB
    mixguideeq.add_track("Kick", partials=[(60, 0.4)])
    mixguideeq.add_track("Bass DI", partials=[(80, 0.4)])
    mixguideeq.fns.list_role_columns()
    return mixguideeq


# -- accessor before the fader (the default mock, and this user's build) -----

def test_a_raised_fader_makes_a_track_heard_louder(twins):
    report = twins.fns.analyze_volume_report("Even")
    names = ranked_names(report)
    assert names.index("Vox B") < names.index("Vox A"), (
        "identical audio, but the one with the +6 dB fader is not ranked louder: %s" % names
    )


def test_the_raised_twin_is_planned_lower_than_the_other(twins):
    """Same source, one 6 dB louder as heard: the plan should bring them
    together, not treat them as equals."""
    m = moves(twins.fns.analyze_volume_report("Even"))
    assert m["Vox B"] < m["Vox A"] - 4.0, (
        "the +6 dB fader was ignored: Vox A %.2f, Vox B %.2f" % (m["Vox A"], m["Vox B"])
    )


def test_relative_levels_in_the_report_include_the_fader(twins):
    rows = {r["name"]: r for r in twins.fns.analyze_volume_report("Even")["ranked"].values()}
    assert rows["Vox B"]["rel_avg_db"] - rows["Vox A"]["rel_avg_db"] == pytest.approx(6.0, abs=0.3)


def test_the_plan_converges_after_one_apply(twins):
    """Apply, then measure again: the balance should now be where it was
    asked to be, so the second plan is close to no moves at all. The real log
    asked for the same 4-7 dB moves twice in a row."""
    ok, _summary, _errors, refreshed = twins.fns.apply_volume_balance("Even")
    assert ok is True
    for name, move in moves(refreshed).items():
        assert abs(move) < 0.6, (
            "%s still wants %+.2f dB after the apply landed" % (name, move)
        )


# -- accessor after the fader ------------------------------------------------

@pytest.fixture
def post_fader(twins):
    twins.rmock["accessor_post_fader"] = True
    return twins


def test_post_fader_reading_is_not_counted_twice(post_fader):
    """Here the measurement already carries the fader; adding it again would
    plan Vox B as 12 dB up instead of 6."""
    rows = {r["name"]: r for r in post_fader.fns.analyze_volume_report("Even")["ranked"].values()}
    assert rows["Vox B"]["rel_avg_db"] - rows["Vox A"]["rel_avg_db"] == pytest.approx(6.0, abs=0.3)


def test_post_fader_plan_also_converges(post_fader):
    ok, _summary, _errors, refreshed = post_fader.fns.apply_volume_balance("Even")
    assert ok is True
    for name, move in moves(refreshed).items():
        assert abs(move) < 0.6, (
            "%s still wants %+.2f dB after the apply landed" % (name, move)
        )


def test_the_probe_result_is_logged(twins):
    twins.fns.analyze_volume_report("Even")
    log = twins.resource_path / "Scripts" / "MixGuideEQ" / "mixguideeq_analysis.log"
    assert log.exists(), "analysis log was not written"
    text = log.read_text(encoding="utf-8")
    assert "accessor reads BEFORE the fader" in text or "accessor reads AFTER the fader" in text
