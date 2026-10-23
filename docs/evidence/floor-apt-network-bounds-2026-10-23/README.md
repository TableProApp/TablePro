# Floor image APT network bounds

Follow-up for [issue 957](https://github.com/cozyGarage/BookiE/issues/957). Both floor-image Dockerfiles lacked download retries and HTTP/HTTPS acquisition timeouts. They now write an APT configuration before the first package operation: three retries and a 30-second timeout per HTTP/HTTPS acquisition. The runtime image retains this configuration for later package installation.

The new image-contract test fails on both original Dockerfiles and passes after the change. It verifies settings precede package operations. This is configuration coverage, not a reproduced network outage or proof of the historical failure's cause. Acquisition timeouts are not a total install deadline and do not bound package maintainer scripts. The existing job deadlines remain unchanged.

A real Debian testing runtime-image build passed. A disposable container running `apt-config dump` confirmed all three settings; the [image identity and readback](image-validation.json) are recorded. Full local preflight passed: script harness, Clippy, 2,073 unit tests, 2,086 sandbox tests and the Redis cancellation check. Debian package validation was skipped because `dpkg-deb` is unavailable. Review was a separate self-review, not an independent review. No gate acceptance is claimed. No user-facing behavior, GTK assertion or test timeout changes.
