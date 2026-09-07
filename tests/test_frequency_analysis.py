"""The analyzer probes a fixed set of frequencies and turns the results into EQ
advice, so a probe that measures the wrong band produces confidently wrong advice."""
import pytest


def analyze(mixguideeq, strength=100):
    """Run the incremental analysis to completion and return the report."""
    mixguideeq.fns.start_frequency_analysis(strength)
    for _ in range(200):
        _, status = mixguideeq.fns.step_frequency_analysis(8)
        if status["done"]:
            return status["report"]
    pytest.fail("frequency analysis never finished")


def track_entry(report, track_name):
    for role_row in report["rows"].values():
        for track in role_row["tracks"].values():
            if track["name"] == track_name:
                return track
    raise AssertionError("no analysis entry for %r" % track_name)


def metrics_for(report, track_name):
    metrics = track_entry(report, track_name)["metrics"]
    assert metrics is not None, "%s produced no metrics" % track_name
    return metrics


def test_bright_track_reads_brighter_than_dark_track(mixguideeq):
    """The headline property: a track with real high-frequency content must
    measure brighter than one without."""
    mixguideeq.add_track("Vox Bright", partials=[(10000, 0.8), (200, 0.2)])
    mixguideeq.add_track("Vox Dark", partials=[(200, 0.8), (400, 0.2)])

    report = analyze(mixguideeq)
    bright = metrics_for(report, "Vox Bright")
    dark = metrics_for(report, "Vox Dark")

    assert bright["brightness_ratio"] > dark["brightness_ratio"], (
        "a 10 kHz-heavy track measured no brighter than a 200 Hz-heavy one "
        "(bright=%.4f dark=%.4f)" % (bright["brightness_ratio"], dark["brightness_ratio"])
    )


def test_low_mid_energy_is_not_reported_as_air(mixguideeq):
    """A 1 kHz-heavy track used to light up the 10 kHz "air" probe, because that
    probe was above Nyquist and folded back onto ~1 kHz."""
    mixguideeq.add_track("Boxy", partials=[(1000, 0.9)])
    mixguideeq.add_track("Airy", partials=[(12000, 0.9)])

    report = analyze(mixguideeq)
    boxy = metrics_for(report, "Boxy")
    airy = metrics_for(report, "Airy")

    assert boxy["high"] < airy["high"], (
        "1 kHz content reported more high-band energy (%.4f) than 12 kHz content "
        "(%.4f)" % (boxy["high"], airy["high"])
    )


def test_mud_ratio_tracks_low_mid_content(mixguideeq):
    mixguideeq.add_track("Muddy", partials=[(250, 0.9), (3000, 0.05)])
    mixguideeq.add_track("Clear", partials=[(250, 0.1), (3000, 0.9)])

    report = analyze(mixguideeq)
    assert metrics_for(report, "Muddy")["mud_ratio"] > metrics_for(report, "Clear")["mud_ratio"]


def test_silent_track_is_skipped(mixguideeq):
    mixguideeq.add_track("Silence", partials=[])
    report = analyze(mixguideeq)
    assert track_entry(report, "Silence")["metrics"] is None, "a silent track produced metrics"


def test_near_silence_is_gated_out(mixguideeq):
    """A track at -100 dBFS is noise, not material for EQ advice."""
    mixguideeq.add_track("Bleed", partials=[(1000, 0.00001)])
    report = analyze(mixguideeq)
    assert track_entry(report, "Bleed")["metrics"] is None, "near-silent track was analyzed anyway"


def test_analysis_is_repeatable(mixguideeq):
    mixguideeq.add_track("Gtr", partials=[(200, 0.5), (3000, 0.4)])
    first = metrics_for(analyze(mixguideeq), "Gtr")["mud_ratio"]
    second = metrics_for(analyze(mixguideeq), "Gtr")["mud_ratio"]
    assert first == pytest.approx(second)
