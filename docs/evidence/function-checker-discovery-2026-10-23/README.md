# Function-size regression discovery

Follow-up for [issue 562](https://github.com/cozyGarage/BookiE/issues/562). The public Sonar Linux analysis at revision `3b6ef5f4489f36d8e8d4604d74c65de1b6bf1e4e` reported 69.0% new-code coverage and 172 uncovered lines in the function-size checker. Its security and reliability quality conditions passed. These are dated scan observations, not a claim about a later analysis.

The checker had three existing regression functions invoked only by the test script's `main`. The general harness ran that script explicitly, but the Sonar workflow runs unittest discovery alone. Discovery therefore executed zero function-size regressions.

The repair turns the same cases into unittest methods, retaining all original assertions, and removes the now-redundant standalone invocation from the harness. Both discovery and direct invocation execute three cases. This pins existing checker behavior; no checker algorithm, policy, exclusion or coverage threshold changes.

Using the workflow's coverage 7.10.6 in an isolated uv environment, discovery now executes 104 of the checker's 172 statements. Combined statement/branch coverage for this focused three-case run is 55%. This is partial coverage, not a promise that the overall Sonar condition passes.

Reproduce with `python3 -m unittest discover -s scripts/tests -p test_function_size.py`. The [measurement](discovery.json) records the before/after discovery counts and focused coverage. Full preflight passed: 397 script-harness tests, 2,073 unit tests, 2,086 sandbox tests and the Redis cancellation check. Review was a separate self-review, not an independent review. Forgejo acceptance remains pending. No application behavior changed.
