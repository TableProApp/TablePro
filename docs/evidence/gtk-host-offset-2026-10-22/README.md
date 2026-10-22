# Host GTK click calibration, October 22, 2026

Issue: [1385](https://github.com/cozyGarage/BookiE/issues/1385). Base: `a070efdd235e5586185b43806f9ddbdb06e8c619`.

The host click helper used a default vertical offset of 19. The existing distro-floor wrapper already selects 5 for Ubuntu 24.04. The candidate shares that existing calibration with ordinary host tests. An explicit `TABLEPRO_GTK_Y_OFFSET` still takes precedence, including zero. Other distributions and missing distribution metadata retain the old default.

## Reproduction and result

The isolated libadwaita probe on Ubuntu 24.04 / GTK 4.14.5 misses a 34-pixel-high target at offset 19 and clicks it at offset 5. The candidate selects 5 automatically and clicks the same target. Results are in [result.json](result.json); [click-offset-probe.py](click-offset-probe.py) uses the actual harness click helper and observes the button callback. [Dockerfile](Dockerfile) records the runtime image.

The selector regression failed with the unchanged offset selection (`19 != 5`). All four selector unit tests pass after the change. The full script harness passed 345 tests, Arch candidate checks and the function-size checker. Its Debian package subcheck was skipped because `dpkg-deb` is unavailable on the local machine. Documentation links passed.

## Limits

This proves the local Ubuntu calibration mismatch. It does not prove the affected Forgejo runner uses that stack or that all BookiE edit failures have the same cause. No GTK assertions, retries, product code or database checks were weakened. Full preflight passed: 2,053 unit tests, 2,054 sandbox tests and the Redis cancellation regression. The patch is not committed or gated.
