"""A muted track is not in the mix, and one track can be most of a role.

Roles are placed by their combined energy, which is what the mix bus does. That
only holds while every track in a role is a separate contribution. A muted
track is not a contribution at all, and a stem of the same source is the same
contribution counted twice - either one makes its role read louder than it
sounds, and the whole role gets cut for it.
"""
import pytest


@pytest.fixture
def kit(mixguideeq):
    """A drums folder of individual mics, plus bass and a vocal."""
    mixguideeq.add_track("Drums", folder_depth=1, items=0)
    mixguideeq.add_track("Kick", partials=[(60, 0.5)])
    mixguideeq.add_track("Snare", partials=[(200, 0.5)])
    mixguideeq.add_track("Tom1", partials=[(120, 0.5)])
    mixguideeq.add_track("Tom2", folder_depth=-1, partials=[(150, 0.5)])
    mixguideeq.add_track("Bass DI", partials=[(80, 0.5)])
    mixguideeq.add_track("Lead Vox", partials=[(500, 0.5)])
    mixguideeq.fns.list_role_columns()
    return mixguideeq


def measured_names(report):
    """Display names carry the folder prefix, so match on the bare name."""
    return [r["name"] for r in report["ranked"].values()]


def named(report, bare):
    for row in report["ranked"].values():
        if bare in row["name"]:
            return row
    return None


def notes(report):
    return " ".join(list(report["stem_notes"].values()))


# -- mute --------------------------------------------------------------------

def test_a_muted_track_is_not_measured(kit):
    kit.rmock.track_by_name("Kick")["mute"] = 1
    assert named(kit.fns.analyze_volume_report("Even"), "Kick") is None


def test_a_muted_track_is_not_written(kit):
    kit.rmock.track_by_name("Kick")["mute"] = 1
    before = dict(kit.rmock.volumes())
    kit.fns.apply_volume_balance("Even")
    after = dict(kit.rmock.volumes())
    assert after["Kick"] == pytest.approx(before["Kick"]), (
        "a muted track got a fader trim"
    )


def test_a_muted_track_does_not_inflate_its_role(kit):
    """It is not in the mix, so it must not push its role's combined level up
    and get the audible tracks cut for it."""
    heard = named(kit.fns.analyze_volume_report("Even"), "Snare")["delta_db"]

    kit.rmock.track_by_name("Kick")["mute"] = 1
    muted = named(kit.fns.analyze_volume_report("Even"), "Snare")["delta_db"]

    assert muted > heard, (
        "muting a sibling left the drums no better off (%.2f -> %.2f dB)"
        % (heard, muted)
    )


def test_children_of_a_muted_folder_are_skipped(kit):
    kit.rmock.track_by_name("Drums")["mute"] = 1
    report = kit.fns.analyze_volume_report("Even")
    for bare in ("Kick", "Snare", "Tom1", "Tom2"):
        assert named(report, bare) is None, "%s survived a muted folder" % bare


def test_the_skip_reason_reaches_the_count(kit):
    kit.rmock.track_by_name("Kick")["mute"] = 1
    assert kit.fns.analyze_volume_report("Even")["skipped_track_count"] >= 1


# -- one track holding most of a role ----------------------------------------

@pytest.fixture
def kit_with_stem(mixguideeq):
    """The real shape: a whole-kit mix living inside the drums folder next to
    the individual mics, so it inherits the drums role."""
    mixguideeq.add_track("Drums", folder_depth=1, items=0)
    mixguideeq.add_track("Kick", partials=[(60, 0.5)])
    mixguideeq.add_track("Snare", partials=[(200, 0.5)])
    mixguideeq.add_track("Tom1", partials=[(120, 0.5)])
    mixguideeq.add_track("Master",
                         partials=[(60, 0.9), (120, 0.9), (200, 0.9), (150, 0.9)])
    mixguideeq.add_track("Tom2", folder_depth=-1, partials=[(150, 0.5)])
    mixguideeq.add_track("Bass DI", partials=[(80, 0.5)])
    mixguideeq.add_track("Lead Vox", partials=[(500, 0.5)])
    mixguideeq.fns.list_role_columns()
    return mixguideeq


def test_a_track_holding_most_of_its_role_is_called_out(kit_with_stem):
    report = kit_with_stem.fns.analyze_volume_report("Even")
    assert "Master" in notes(report), (
        "the double count went unmentioned: %r" % notes(report)
    )
    assert "double count" in report["summary"].lower()


def test_an_ordinary_multi_mic_kit_is_not_called_out(kit):
    """Every drum track here is one mic on one part of the kit. None of them
    should be accused of duplicating the others."""
    report = kit.fns.analyze_volume_report("Even")
    assert notes(report) == "", "flagged a plain multi-mic kit: %r" % notes(report)


def test_a_merely_loud_track_is_not_called_out(kit):
    """A kick sitting well above the rest of the kit is normal. The threshold
    is a share of the whole role, not just being the loudest."""
    kit.rmock.track_by_name("Kick")["partials"][1]["amp"] = 0.8
    report = kit.fns.analyze_volume_report("Even")
    assert "Kick" not in notes(report), notes(report)


def test_the_call_out_does_not_change_the_plan(kit_with_stem):
    """It is a question for the user, not a decision the tool makes."""
    report = kit_with_stem.fns.analyze_volume_report("Even")
    assert named(report, "Master") is not None, (
        "the tool excluded the track on its own instead of asking"
    )
