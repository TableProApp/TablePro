import os
import sys
from pathlib import Path

repo = Path(os.environ["TABLEPRO_PROFILE_REPO"])
sys.path.insert(0, str(repo / "apps/linux/app/tests"))

import gtk_safety
import gtk_ux

original_scenarios = gtk_ux.scenarios


def scenarios(ui):
    profile = next(item for item in original_scenarios(ui) if item.__name__ == "profile_large_result_in_the_grid")
    rows = os.environ["TABLEPRO_PROFILE_ROWS"]
    scheme = os.environ["ADW_DEBUG_COLOR_SCHEME"]

    def capture(database, base):
        profile(database, base)
        gtk_ux.capture_grid_navigation_artifact(f"large-result-grid-{scheme}-{rows}")

    capture.__name__ = profile.__name__
    return [capture]


gtk_ux.scenarios = scenarios
gtk_safety.main()
