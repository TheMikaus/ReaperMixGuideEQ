"""Level balance writes static volume trims, so its revert path is the only
thing standing between a bad profile and a manually rebuilt mix."""
import pytest


@pytest.fixture
def band(mixguideeq):
    """A small stem-style project with audio on every child."""
    mixguideeq.add_track("Drums", folder_depth=1, items=0)
    mixguideeq.add_track("Kick", partials=[(60, 0.8), (3000, 0.2)])
    mixguideeq.add_track("Snare", partials=[(200, 0.6), (4000, 0.3)])
    mixguideeq.add_track("Overheads", folder_depth=-1, partials=[(8000, 0.4)])
    mixguideeq.add_track("Bass DI", partials=[(80, 0.9)])
    mixguideeq.add_track("Lead Vox", partials=[(500, 0.7), (3000, 0.5)])
    mixguideeq.fns.list_role_columns()
    return mixguideeq


def test_apply_changes_volumes(band):
    before = dict(band.rmock.volumes())
    ok, summary, _errors, _report = band.fns.apply_volume_balance("Even")
    assert ok is True
    assert band.rmock.volumes() != before, "apply made no change at all"


def test_revert_restores_exact_volumes(band):
    before = dict(band.rmock.volumes())
    band.fns.apply_volume_balance("Even")

    ok, summary, _errors = band.fns.revert_last_volume_balance()
    assert ok is True

    after = dict(band.rmock.volumes())
    for name, vol in before.items():
        assert after[name] == pytest.approx(vol), "%s not restored" % name


def test_revert_after_two_applies_returns_to_the_original(band):
    """Apply is multiplicative. A second apply used to overwrite the snapshot,
    leaving the first one permanently unrevertable."""
    before = dict(band.rmock.volumes())
    band.fns.apply_volume_balance("Even")
    band.fns.apply_volume_balance("Rock")

    band.fns.revert_last_volume_balance()

    after = dict(band.rmock.volumes())
    for name, vol in before.items():
        assert after[name] == pytest.approx(vol), (
            "%s ended at %.4f instead of its pre-apply %.4f" % (name, after[name], vol)
        )


def test_snapshot_survives_a_reload(band):
    """The snapshot lived only in memory, so closing the window silently
    removed the ability to undo an apply."""
    before = dict(band.rmock.volumes())
    band.fns.apply_volume_balance("Even")

    # Simulate the script being closed and relaunched.
    band.app["last_volume_apply_snapshot"] = None
    band.fns.load_project_roles()
    band.fns.load_volume_snapshot()

    status = band.fns.get_last_volume_apply_snapshot()
    assert status["available"] is True, "no snapshot available after a reload"

    band.fns.revert_last_volume_balance()
    after = dict(band.rmock.volumes())
    for name, vol in before.items():
        assert after[name] == pytest.approx(vol), "%s not restored after reload" % name


def test_revert_without_a_snapshot_is_reported(band):
    ok, summary, _errors = band.fns.revert_last_volume_balance()
    assert ok is False
    assert "snapshot" in summary.lower()


def test_excluded_tracks_are_not_touched(band):
    kick = band.rmock.track_by_name("Kick")
    band.fns.set_track_excluded(kick["guid"], True)
    before = kick["vol"]

    band.fns.apply_volume_balance("Even")
    assert kick["vol"] == pytest.approx(before), "an excluded track was re-levelled"


def test_apply_and_revert_are_undo_balanced(band):
    band.fns.apply_volume_balance("Even")
    band.fns.revert_last_volume_balance()
    assert band.rmock["undo_depth"] == 0, "undo block left unbalanced"


def test_trims_are_clamped(band):
    """Safety rails: no single apply should push a track to an absurd level."""
    band.fns.apply_volume_balance("EDM")
    for name, vol in band.rmock.volumes().items():
        assert 1e-5 <= vol <= 4.0, "%s left at %.5f" % (name, vol)


# ── convergence ─────────────────────────────────────────────────────────────

def test_rebalancing_does_not_stack_root_trims(band):
    """The documented flow balances, applies EQ, then balances again. The root
    delta was derived from the children's faders but written to the root, whose
    own fader was never accounted for -- so each pass added the whole role
    offset again and the mix got quieter every time."""
    band.fns.apply_volume_balance("Rock")
    after_first = dict(band.rmock.volumes())

    band.fns.revert_last_volume_balance()
    band.fns.apply_volume_balance("Rock")
    band.fns.revert_last_volume_balance()

    # Second balance from the already-balanced state must be a no-op.
    band.fns.apply_volume_balance("Rock")
    first = dict(band.rmock.volumes())
    band.fns.revert_last_volume_balance()

    for name, vol in after_first.items():
        assert first[name] == pytest.approx(vol, rel=0.01), (
            "%s drifted between identical balance passes: %.4f then %.4f"
            % (name, vol, first[name])
        )


def test_balance_converges_when_applied_from_its_own_result(band):
    """Applying the same profile to an already-balanced mix should ask for
    almost nothing."""
    band.fns.apply_volume_balance("Rock")
    balanced = dict(band.rmock.volumes())

    report = band.fns.analyze_volume_report("Rock")
    for action in report["root_adjustments"].values():
        assert abs(action["delta_db"]) < 1.0, (
            "%s still wants %.2f dB after being balanced"
            % (action["root_name"], action["delta_db"])
        )
    assert dict(band.rmock.volumes()) == balanced


# ── measured loudness, not fader positions ──────────────────────────────────

def test_a_loud_track_is_turned_down_more_than_a_quiet_one(mixguideeq):
    """The whole point: the plan has to reflect how loud things actually are.
    The old version compared fader positions and never looked at the audio."""
    mixguideeq.add_track("Lead Vox", partials=[(500, 0.5)])
    mixguideeq.add_track("Rhythm Gtr L", partials=[(500, 0.9)])   # loud
    mixguideeq.add_track("Rhythm Gtr R", partials=[(500, 0.1)])   # quiet
    mixguideeq.fns.list_role_columns()

    report = mixguideeq.fns.analyze_volume_report("Even")
    deltas = {a["name"]: a["delta_db"] for a in report["track_adjustments"].values()}

    assert deltas["Rhythm Gtr L"] < deltas["Rhythm Gtr R"], deltas


def test_ranked_list_is_loudest_first(mixguideeq):
    mixguideeq.add_track("Lead Vox", partials=[(500, 0.30)])
    mixguideeq.add_track("Bass DI", partials=[(80, 0.90)])
    mixguideeq.add_track("Rhythm Gtr L", partials=[(500, 0.60)])
    mixguideeq.fns.list_role_columns()

    ranked = list(mixguideeq.fns.analyze_volume_report("Even")["ranked"].values())
    names = [r["name"] for r in ranked]
    assert names == ["Bass DI", "Rhythm Gtr L", "Lead Vox"], names

    # Relative to the loudest, so the top row is 0 and the rest are below it.
    assert ranked[0]["rel_avg_db"] == pytest.approx(0.0, abs=0.01)
    for row in ranked[1:]:
        assert row["rel_avg_db"] < 0


def test_the_plan_moves_tracks_both_ways(mixguideeq):
    """It is a balance, not an attenuator. The old version only ever cut: the
    reference was the quietest track and everything louder was dragged to it."""
    mixguideeq.add_track("Lead Vox", partials=[(500, 0.20)])
    mixguideeq.add_track("Bass DI", partials=[(80, 0.90)])
    mixguideeq.add_track("Rhythm Gtr L", partials=[(500, 0.70)])
    mixguideeq.add_track("Kick", partials=[(80, 0.50)])
    mixguideeq.fns.list_role_columns()

    deltas = [a["delta_db"] for a
              in mixguideeq.fns.analyze_volume_report("Even")["track_adjustments"].values()]

    assert any(d > 0 for d in deltas), "nothing was turned up: %s" % deltas
    assert any(d < 0 for d in deltas), "nothing was turned down: %s" % deltas


def test_the_plan_holds_the_overall_level(mixguideeq):
    """Zero-meaned, so the mix does not quietly lose level every pass."""
    for name, amp in (("Lead Vox", 0.2), ("Bass DI", 0.9),
                      ("Rhythm Gtr L", 0.7), ("Kick", 0.5), ("Snare", 0.4)):
        mixguideeq.add_track(name, partials=[(500, amp)])
    mixguideeq.fns.list_role_columns()

    deltas = [a["delta_db"] for a
              in mixguideeq.fns.analyze_volume_report("Even")["track_adjustments"].values()]
    assert abs(sum(deltas) / len(deltas)) < 1.0, "average move is %.2f dB" % (
        sum(deltas) / len(deltas))


def test_silence_does_not_drag_the_average_down(mixguideeq):
    """A track that plays occasionally should measure by what it sounds like
    when it plays, not be averaged down by the gaps -- that is the gate."""
    mixguideeq.add_track("Steady", partials=[(500, 0.5)], duration=8.0)
    mixguideeq.add_track("Sparse", partials=[(500, 0.5)], duration=8.0, gaps=True)
    mixguideeq.fns.list_role_columns()

    ranked = {r["name"]: r for r
              in mixguideeq.fns.analyze_volume_report("Even")["ranked"].values()}
    assert ranked["Sparse"]["avg_db"] == pytest.approx(ranked["Steady"]["avg_db"], abs=1.5), (
        "sparse %.2f vs steady %.2f" % (ranked["Sparse"]["avg_db"], ranked["Steady"]["avg_db"])
    )


@pytest.mark.parametrize("post_fader", [False, True])
def test_applying_twice_lands_in_the_same_place(mixguideeq, post_fader):
    """Idempotent in both accessor modes: the plan is an absolute target fader,
    and the mode is probed rather than assumed."""
    mixguideeq.rmock["accessor_post_fader"] = post_fader
    mixguideeq.add_track("Lead Vox", partials=[(500, 0.5)])
    mixguideeq.add_track("Bass DI", partials=[(80, 0.9)])
    mixguideeq.add_track("Rhythm Gtr L", partials=[(500, 0.8)])
    mixguideeq.fns.list_role_columns()

    mixguideeq.fns.apply_volume_balance("Rock")
    after_first = dict(mixguideeq.rmock.volumes())

    mixguideeq.fns.revert_last_volume_balance()
    mixguideeq.fns.apply_volume_balance("Rock")
    mixguideeq.fns.revert_last_volume_balance()

    # Apply, then apply again on top without reverting.
    mixguideeq.fns.apply_volume_balance("Rock")
    mixguideeq.fns.revert_last_volume_balance()
    mixguideeq.fns.apply_volume_balance("Rock")
    after_second = dict(mixguideeq.rmock.volumes())

    for name, vol in after_first.items():
        assert after_second[name] == pytest.approx(vol, rel=0.02), (
            "%s drifted between passes (post_fader=%s): %.4f then %.4f"
            % (name, post_fader, vol, after_second[name])
        )


def test_no_root_folder_trims_are_written(mixguideeq):
    """Trims go to the audio tracks. Writing both a per-track and a root trim
    moved every track twice."""
    mixguideeq.add_track("Guitars", folder_depth=1, items=0)
    mixguideeq.add_track("Rhythm Gtr L", partials=[(500, 0.8)])
    mixguideeq.add_track("Rhythm Gtr R", partials=[(500, 0.8)], folder_depth=-1)
    mixguideeq.add_track("Lead Vox", partials=[(500, 0.5)])
    mixguideeq.fns.list_role_columns()

    mixguideeq.fns.apply_volume_balance("Rock")
    assert mixguideeq.rmock.volumes()["Guitars"] == pytest.approx(1.0)


# ── role sums, not track counts ─────────────────────────────────────────────

def test_a_lone_vocal_is_not_buried_by_a_multi_mic_kit(mixguideeq):
    """Per-track balancing is count-weighted: eight drum tracks pull the plan
    eight times and the lead vocal pulls once, so the vocal is measured against
    a single drum mic instead of the kit that actually competes with it."""
    for name in ("Kick", "Snare", "Tom 1", "Tom 2", "OH L", "OH R", "Hi-Hat", "Room"):
        mixguideeq.add_track(name, partials=[(200, 0.5)])
    mixguideeq.add_track("Lead Vox", partials=[(500, 0.5)])
    mixguideeq.fns.list_role_columns()

    adjustments = {a["name"]: a["delta_db"] for a
                   in mixguideeq.fns.analyze_volume_report("Rock")["track_adjustments"].values()}
    drum_moves = [v for k, v in adjustments.items() if k != "Lead Vox"]

    assert adjustments["Lead Vox"] > max(drum_moves), (
        "vocal move %.2f is not above every drum move %s"
        % (adjustments["Lead Vox"], sorted(drum_moves))
    )


@pytest.mark.parametrize("genre", ["Even", "Pop", "Rock", "EDM"])
def test_the_lead_vocal_targets_above_the_kit(mixguideeq, genre):
    """The vocal used to be targeted below the drums in every profile."""
    for name in ("Kick", "Snare", "OH L", "OH R"):
        mixguideeq.add_track(name, partials=[(200, 0.5)])
    mixguideeq.add_track("Lead Vox", partials=[(500, 0.5)])
    mixguideeq.fns.list_role_columns()

    ranked = {r["name"]: r for r
              in mixguideeq.fns.analyze_volume_report(genre)["ranked"].values()}
    vocal_target = ranked["Lead Vox"]["target_db"]
    kit_targets = [r["target_db"] for n, r in ranked.items() if n != "Lead Vox"]

    assert vocal_target > max(kit_targets), (
        "%s: vocal target %.2f is under the kit %s"
        % (genre, vocal_target, sorted(kit_targets))
    )


@pytest.fixture
def pannable_band(mixguideeq):
    """Like `band`, but with a doubled guitar pair so the pan stage has
    something to place and therefore something to revert."""
    mixguideeq.add_track("Kick", partials=[(60, 0.8), (3000, 0.2)])
    mixguideeq.add_track("Snare", partials=[(200, 0.6), (4000, 0.3)])
    mixguideeq.add_track("Rhythm Gtr L", partials=[(500, 0.6)])
    mixguideeq.add_track("Rhythm Gtr R", partials=[(500, 0.6)])
    mixguideeq.add_track("Bass DI", partials=[(80, 0.9)])
    mixguideeq.add_track("Lead Vox", partials=[(500, 0.7), (3000, 0.5)])
    mixguideeq.fns.list_role_columns()
    return mixguideeq


# ── analyzing undoes the stages after it ────────────────────────────────────

def test_analyzing_for_eq_undoes_pan_and_levels(pannable_band):
    before_vol = dict(pannable_band.rmock.volumes())
    before_pan = dict(pannable_band.rmock.pans())

    pannable_band.fns.apply_pan_balance("Rock", True)
    pannable_band.fns.apply_volume_balance("Rock")

    ok, note, undone = pannable_band.fns.revert_before_analysis("eq")
    assert ok is True, note
    assert set(undone.values()) == {"levels", "pan"}, note

    for name, vol in before_vol.items():
        assert pannable_band.rmock.volumes()[name] == pytest.approx(vol), name
    for name, pan in before_pan.items():
        assert pannable_band.rmock.pans()[name] == pytest.approx(pan), name


def test_analyzing_for_pan_undoes_levels_too(pannable_band):
    before_vol = dict(pannable_band.rmock.volumes())
    pannable_band.fns.apply_pan_balance("Rock", True)
    pannable_band.fns.apply_volume_balance("Rock")

    ok, note, undone = pannable_band.fns.revert_before_analysis("pans")
    assert ok is True
    assert "levels" in set(undone.values()), note

    for name, vol in before_vol.items():
        assert pannable_band.rmock.volumes()[name] == pytest.approx(vol), name


def test_analyzing_for_levels_leaves_pan_alone(pannable_band):
    pannable_band.fns.apply_pan_balance("Rock", True)
    panned = dict(pannable_band.rmock.pans())
    pannable_band.fns.apply_volume_balance("Rock")

    pannable_band.fns.revert_before_analysis("levels")

    for name, pan in panned.items():
        assert pannable_band.rmock.pans()[name] == pytest.approx(pan), (
            "%s pan was undone by a level analysis" % name
        )
