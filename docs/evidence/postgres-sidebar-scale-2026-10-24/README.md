# PostgreSQL sidebar catalog scaling

Related: [#580](https://github.com/cozyGarage/BookiE/issues/580).

The focused test builds 50,000 tables across 100 schemas, builds the sidebar tree, searches for every table, and verifies that all 50,200 tree nodes remain visible. The same test body was run against the Linux baseline and the optimized implementation.

| Source | Test duration |
| --- | ---: |
| Linux baseline `351bb3c8b6a0acfe148975f037e1db7f0b41332f` | 8.56 s |
| Optimized sidebar implementation `646fe4b5f0f7fbb3154e2ccdec44791721888846` | 0.07 s |

These are one-run debug test-harness durations on the same machine. Both use the exact same temporary test, including the exact visible-node assertion, and include synthetic data creation, tree construction and filtering, but exclude Cargo compilation. The test harness reported about 122 times lower runtime for the optimized code. This is synthetic CPU evidence, not an end-to-end UI result.

The source-pinned test output is in [baseline-scale.txt](baseline-scale.txt) and [fixed-scale.txt](fixed-scale.txt). The baseline sidebar source is byte-identical to the earlier `b3d892546` reproduction.

The baseline rebuilds schema groups by filtering the complete table and view lists for each schema. The optimized path groups tables and views during one pass, records parent node indexes while building the tree, and follows those indexes during search and collapsed-ancestor checks without rebuilding key strings or a per-search hash map.

## Limits

This is not an end-to-end GTK measurement and does not include database catalog loading, real metadata permissions, connection latency or main-loop responsiveness. It does not verify query scoping, restricted-role metadata correctness or MCP catalog scoping; those remain open in #580 and belong to the B3 driver handoff.

Each tree node now retains a parent index. Peak RSS was not measured, so this evidence does not claim an overall memory improvement.

## Saved collapse regression

On baseline `b3d892546`, a saved collapse for `public` hides all tables and views when catalog refresh leaves only that named schema. The sidebar omits schema headings for a single schema, so there is no heading to expand. The regression `removing_other_schemas_keeps_the_remaining_catalog_visible_after_a_saved_schema_collapse` fails with an empty visible list instead of `Tables`, `users`, `Views`, and `recent`.

The optimized parent indexes follow only nodes present in the tree. This keeps those objects visible while preserving collapsible table and view groups. The regression was executed against the baseline before applying the fix; [baseline-regression.txt](baseline-regression.txt) records the empty-list failure. All 18 sidebar tests pass with the fix, including this regression. This is a behavior correction in addition to the synthetic scaling improvement.

## Local validation

At `646fe4b5f`, `bash scripts/preflight.sh` passed 406 harness tests, 2,077 unit tests, 2,090 sandbox tests, the separate Redis cancellation test and the repository guards. `bash scripts/test-gtk-widgets.sh` passed all 163 isolated GTK tests. The focused sidebar tests passed 18/18. These local results do not establish Forgejo acceptance or native desktop acceptance.
