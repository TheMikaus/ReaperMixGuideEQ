def test_loads_and_exposes_state(mixguideeq):
    assert mixguideeq.app["name"] == "MixGuideEQ"
    assert mixguideeq.app["version"] != ""


def test_exposes_callbacks(mixguideeq):
    for name in ("build_suggestions", "analyze_volume_report", "apply_volume_balance",
                 "list_role_columns", "move_track_to_role"):
        assert mixguideeq.fns[name] is not None, name


def test_columns_start_empty(mixguideeq):
    assert mixguideeq.columns() == {"drums": [], "guitar": [], "bass": [], "vocals": []}
