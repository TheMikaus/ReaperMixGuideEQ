"""Genre profiles carry a spectral target per role, and EQ moves come from
measured-minus-target rather than from the level offset.

Absolute calibration of ROLE_BAND_REFERENCE needs real material to tune. What
these lock down is the *relative* behaviour, which is what was previously wrong:
each genre must push each role in the direction its description claims.
"""
import pathlib

import pytest

from test_frequency_analysis import analyze

EQ_RULES = (pathlib.Path(__file__).resolve().parent.parent / "eq_rules.lua").as_posix()

# Material with energy at the analyzer's actual probe frequencies
# (80/200/500/1200/3000/7000/10000 Hz), so the measurement is real signal rather
# than spectral leakage from partials that fall between bins.
MATERIAL = {
    "Rhythm Gtr": [(80, 0.15), (200, 0.50), (500, 0.70), (1200, 0.50),
                   (3000, 0.30), (7000, 0.12), (10000, 0.08)],
    "Lead Vox": [(80, 0.05), (200, 0.25), (500, 0.60), (1200, 0.50),
                 (3000, 0.45), (7000, 0.25), (10000, 0.18)],
    "Bass DI": [(80, 0.90), (200, 0.60), (500, 0.25), (1200, 0.08),
                (3000, 0.02), (7000, 0.01), (10000, 0.005)],
}

ROLE_OF = {"Rhythm Gtr": "guitar", "Lead Vox": "vocals", "Bass DI": "bass"}


@pytest.fixture
def mixed_project(mixguideeq):
    for name, partials in MATERIAL.items():
        mixguideeq.add_track(name, partials=partials)
    mixguideeq.fns.list_role_columns()
    analyze(mixguideeq)
    return mixguideeq


def all_band_gains(mixguideeq, track_name, genre, strength=100):
    """Every band's correction for one track under one genre.

    Goes through eq_rules directly with no move cap, so a band that would fall
    outside the three ReaEQ slots still reports its value — comparing genres on
    a truncated list makes an absent band look like "no correction".
    """
    metrics = None
    for role_row in mixguideeq.app["last_frequency_report"]["rows"].values():
        for entry in role_row["tracks"].values():
            if entry["name"] == track_name:
                metrics = entry["metrics"]
    assert metrics is not None, "no metrics for %r" % track_name

    profile = mixguideeq.fns.get_volume_profile_definition(genre)
    targets = profile["band_targets"][ROLE_OF[track_name]]

    mixguideeq.lua.execute('eq_rules_probe = dofile("%s")' % EQ_RULES)
    deltas = mixguideeq.lua.eval(
        "function(role, targets, metrics, strength)"
        "  return eq_rules_probe.band_deltas_db(role, targets, metrics, strength) end"
    )(ROLE_OF[track_name], targets, metrics, strength)
    return {band: deltas[band]["gain"] for band in ("low", "low_mid", "presence", "high")}


def suggested_moves(mixguideeq, track_name, genre, strength=100):
    """What the Suggestions card actually shows — capped at three moves."""
    report = mixguideeq.fns.build_suggestions(strength, genre)
    for row in report["rows"].values():
        for suggestion in row["track_suggestions"].values():
            if suggestion["name"] == track_name:
                return {m["band"]: m["gain"] for m in suggestion["moves"].values()}
    raise AssertionError("no suggestion for %r" % track_name)


# ── the inversion this replaces ─────────────────────────────────────────────

def test_edm_carves_guitar_mids_harder_than_rock(mixed_project):
    """The headline bug: EDM wants guitars out of the way and rock wants them
    big, but deriving EQ from the level offset made rock cut mud the hardest."""
    edm = all_band_gains(mixed_project, "Rhythm Gtr", "EDM")["low_mid"]
    rock = all_band_gains(mixed_project, "Rhythm Gtr", "Rock")["low_mid"]
    assert edm < rock, "EDM guitar low-mid %.2f dB is not below Rock's %.2f dB" % (edm, rock)


def test_guitar_midrange_ranks_rock_over_even_over_pop_over_edm(mixed_project):
    """Full ordering, not just a pair: how much midrange each genre allows a
    rhythm guitar."""
    gains = {
        genre: all_band_gains(mixed_project, "Rhythm Gtr", genre)["low_mid"]
        for genre in ("Rock", "Even", "Pop", "EDM")
    }
    ordered = sorted(gains, key=gains.get, reverse=True)
    assert ordered == ["Rock", "Even", "Pop", "EDM"], gains


def test_pop_pushes_vocal_presence_hardest(mixed_project):
    gains = {
        genre: all_band_gains(mixed_project, "Lead Vox", genre)["presence"]
        for genre in ("Even", "Pop", "Rock", "EDM")
    }
    assert gains["Pop"] > gains["Rock"], gains
    assert gains["Pop"] > gains["Even"], gains


def test_edm_gives_bass_the_most_low_end(mixed_project):
    gains = {
        genre: all_band_gains(mixed_project, "Bass DI", genre)["low"]
        for genre in ("Even", "Pop", "Rock", "EDM")
    }
    assert gains["EDM"] == max(gains.values()), gains


def test_pop_tightens_bass_low_mid_more_than_rock(mixed_project):
    """"Controlled low end" should mean losing mud, not losing weight."""
    pop = all_band_gains(mixed_project, "Bass DI", "Pop")
    rock = all_band_gains(mixed_project, "Bass DI", "Rock")
    assert pop["low_mid"] < rock["low_mid"]


# ── the mechanism ───────────────────────────────────────────────────────────

def test_a_track_matching_the_reference_needs_no_moves(eq_rules):
    """Even declares no band offsets, so a track already sitting on the
    reference shape is left alone."""
    move_count = eq_rules.execute("""
        local ref = eq_rules.ROLE_BAND_REFERENCE.guitar
        local metrics = {}
        for _, band in ipairs(eq_rules.BAND_ORDER) do
          metrics[band] = 10 ^ (ref[band] / 10)
        end
        return #eq_rules.build_band_moves("guitar", {}, metrics, 100, 3)
    """)
    assert move_count == 0, "a track matching the reference still got corrective moves"


def test_band_shares_are_level_independent(eq_rules):
    """Shares are normalised by total energy, so a track's shape does not change
    when its level does. Level is the balance stage's concern."""
    assert eq_rules.execute("""
        local quiet = { low = 1.0, low_mid = 0.5, presence = 0.2, high = 0.1 }
        local loud  = { low = 100.0, low_mid = 50.0, presence = 20.0, high = 10.0 }
        local a = eq_rules.band_shares_db(quiet)
        local b = eq_rules.band_shares_db(loud)
        for _, band in ipairs(eq_rules.BAND_ORDER) do
          if math.abs(a[band] - b[band]) > 1e-9 then return false end
        end
        return true
    """) is True


def test_target_offsets_move_the_correction(eq_rules):
    less, more = eq_rules.execute("""
        local metrics = { low = 1.0, low_mid = 1.0, presence = 0.2, high = 0.1 }
        local function low_mid_gain(targets)
          for _, move in ipairs(eq_rules.build_band_moves("guitar", targets, metrics, 100, 4)) do
            if move.band == "low_mid" then return move.gain end
          end
          return 0.0
        end
        return low_mid_gain({ low_mid = -3.0 }), low_mid_gain({ low_mid = 3.0 })
    """)
    assert less < more


def test_uniform_target_boost_is_a_no_op(eq_rules):
    """Asking for more of every band is not a shape. It must renormalise away
    rather than boosting the whole track."""
    assert eq_rules.execute("""
        local ref = eq_rules.ROLE_BAND_REFERENCE.guitar
        local metrics = {}
        for _, band in ipairs(eq_rules.BAND_ORDER) do
          metrics[band] = 10 ^ (ref[band] / 10)
        end
        local targets = { low = 3.0, low_mid = 3.0, presence = 3.0, high = 3.0 }
        return #eq_rules.build_band_moves("guitar", targets, metrics, 100, 4)
    """) == 0


def test_moves_are_clamped(mixed_project):
    for gain in all_band_gains(mixed_project, "Bass DI", "EDM").values():
        assert abs(gain) <= 4.0 + 1e-9, "move exceeded the 4 dB clamp: %.2f" % gain


def test_inaudible_moves_are_dropped(mixed_project):
    """Raw deltas can be tiny; what gets written must not be."""
    raw = all_band_gains(mixed_project, "Rhythm Gtr", "Even")
    assert any(abs(g) < 0.5 for g in raw.values()), "test material has no sub-threshold band"

    for band, gain in suggested_moves(mixed_project, "Rhythm Gtr", "Even").items():
        assert abs(gain) >= 0.5, "a sub-audible move (%.2f dB @ %s) was written" % (gain, band)


def test_suggestions_are_capped_at_three_moves(mixed_project):
    assert len(suggested_moves(mixed_project, "Bass DI", "EDM")) <= 3


def test_strength_scales_the_moves(eq_rules):
    full, half = eq_rules.execute("""
        local metrics = { low = 1.0, low_mid = 0.8, presence = 0.2, high = 0.1 }
        local function gain(strength)
          for _, move in ipairs(eq_rules.build_band_moves("vocals", {}, metrics, strength, 4)) do
            if move.band == "low" then return move.gain end
          end
          return 0.0
        end
        return gain(100), gain(50)
    """)
    assert abs(half) < abs(full)


def test_fader_position_does_not_change_the_eq_suggestion(mixed_project):
    """The two stages stay independent: setting levels first must not perturb
    the EQ decisions that follow."""
    baseline = suggested_moves(mixed_project, "Rhythm Gtr", "Even")
    mixed_project.rmock.track_by_name("Rhythm Gtr")["vol"] = 0.25
    assert suggested_moves(mixed_project, "Rhythm Gtr", "Even") == baseline


def test_suggestions_explain_why(mixed_project):
    report = mixed_project.fns.build_suggestions(100, "EDM")
    for row in report["rows"].values():
        for suggestion in row["track_suggestions"].values():
            lines = list(suggestion["lines"].values())
            assert any("why:" in line for line in lines), lines
            return
