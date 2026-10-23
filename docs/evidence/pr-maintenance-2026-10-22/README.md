# Pull request maintenance, October 22

## Recorded source

The initial inventory contained 35 open PRs. Refresh base: Linux
`28730f745cb7773ad0ca6cd65fc5a18858f1120d`. This is dated preparation
evidence, not acceptance or a current queue owner. Each PR owns its acceptance.

## Preparation

| PR | Initial GitHub state | Local refresh |
| --- | --- | --- |
| [#1428](https://github.com/cozyGarage/BookiE/pull/1428) | conflicting | Not refreshed in this pass |
| [#1427](https://github.com/cozyGarage/BookiE/pull/1427) | mergeable | Prepared, merge commit pending |
| [#1424](https://github.com/cozyGarage/BookiE/pull/1424) | mergeable | Prepared, merge commit pending |
| [#1422](https://github.com/cozyGarage/BookiE/pull/1422) | mergeable | Prepared, merge commit pending |
| [#1421](https://github.com/cozyGarage/BookiE/pull/1421) | mergeable | Prepared, merge commit pending |
| [#1418](https://github.com/cozyGarage/BookiE/pull/1418) | mergeable | Not refreshed in this pass |
| [#1414](https://github.com/cozyGarage/BookiE/pull/1414) | mergeable | Prepared, merge commit pending |
| [#1412](https://github.com/cozyGarage/BookiE/pull/1412) | conflicting | Prepared, merge commit pending |
| [#1411](https://github.com/cozyGarage/BookiE/pull/1411) | mergeable | Prepared, merge commit pending |
| [#1410](https://github.com/cozyGarage/BookiE/pull/1410) | conflicting | Prepared, merge commit pending |
| [#1409](https://github.com/cozyGarage/BookiE/pull/1409) | conflicting | Prepared, merge commit pending |
| [#1408](https://github.com/cozyGarage/BookiE/pull/1408) | conflicting | Prepared, merge commit pending |
| [#1405](https://github.com/cozyGarage/BookiE/pull/1405) | conflicting | Not refreshed in this pass |
| [#1400](https://github.com/cozyGarage/BookiE/pull/1400) | conflicting | Not refreshed in this pass |
| [#1398](https://github.com/cozyGarage/BookiE/pull/1398) | mergeable | Prepared, merge commit pending |
| [#1397](https://github.com/cozyGarage/BookiE/pull/1397) | conflicting | Prepared, merge commit pending |
| [#1390](https://github.com/cozyGarage/BookiE/pull/1390) | conflicting | Prepared, merge commit pending |
| [#1384](https://github.com/cozyGarage/BookiE/pull/1384) | conflicting | Prepared, merge commit pending |
| [#1381](https://github.com/cozyGarage/BookiE/pull/1381) | mergeable | Prepared, merge commit pending |
| [#1380](https://github.com/cozyGarage/BookiE/pull/1380) | mergeable | Prepared, merge commit pending |
| [#1379](https://github.com/cozyGarage/BookiE/pull/1379) | conflicting | Prepared, merge commit pending |
| [#1378](https://github.com/cozyGarage/BookiE/pull/1378) | mergeable | Prepared, merge commit pending |
| [#1376](https://github.com/cozyGarage/BookiE/pull/1376) | conflicting | Prepared, merge commit pending |
| [#1375](https://github.com/cozyGarage/BookiE/pull/1375) | conflicting | Prepared, merge commit pending |
| [#1374](https://github.com/cozyGarage/BookiE/pull/1374) | conflicting | Prepared, merge commit pending |
| [#1372](https://github.com/cozyGarage/BookiE/pull/1372) | conflicting | Prepared, merge commit pending |
| [#1369](https://github.com/cozyGarage/BookiE/pull/1369) | conflicting | Prepared, merge commit pending |
| [#1367](https://github.com/cozyGarage/BookiE/pull/1367) | mergeable | Prepared, merge commit pending |
| [#1363](https://github.com/cozyGarage/BookiE/pull/1363) | conflicting | Prepared, merge commit pending |
| [#1361](https://github.com/cozyGarage/BookiE/pull/1361) | mergeable | Prepared, merge commit pending |
| [#1352](https://github.com/cozyGarage/BookiE/pull/1352) | mergeable | Prepared, merge commit pending |
| [#1346](https://github.com/cozyGarage/BookiE/pull/1346) | conflicting | Prepared, merge commit pending |
| [#1340](https://github.com/cozyGarage/BookiE/pull/1340) | conflicting | Prepared, merge commit pending |
| [#1338](https://github.com/cozyGarage/BookiE/pull/1338) | conflicting | Prepared, merge commit pending |
| [#1334](https://github.com/cozyGarage/BookiE/pull/1334) | conflicting | Not refreshed in this pass |

## Findings and validation

- #1338 and #1340 conflicted in the isolated-test registration list. Both PR additions and current Linux additions were retained. Their stale ledger row assigned UI-43 to #1337, colliding with #1366; the prepared rows use UI-44 for #1337.
- #1390 retained its intentional removal of the replaced copy-button test and all new Linux registrations. The ignored-test inventory passes after resolution.
- #1372, #1410 and #1409 full preflight passed. #1372 also passed all 110 GTK widget tests. Further preflight runs are recorded separately and remain pending until their exit statuses are captured.
- #1379, #1376, #1384 and #1397 merged current Linux without conflicts. Whitespace, ignored-test inventory, ledger and documentation-link checks pass.
- #1424 failed in train-fixture teardown, not a transaction-age assertion. [#1429](https://github.com/cozyGarage/BookiE/issues/1429) records the traceback and unresolved writer. No retry or ignored cleanup error was added.
- #1428 is stale after constituent #1323 and #1335 merges. It must not be accepted using an unrelated feature train result.

## Remaining work

Prepared merges are not published. Local merges need commits, checks and refreshed GitHub heads before any exact-head Forgejo gate. No aggregate or constituent is accepted by this document. Remaining PRs require review and refresh; draft aggregate manifests require rebuilding against current Linux.

[Initial head inventory](inventory.json) preserves the heads inspected during this pass.

## Subsequent preparation

Thirty standalone PR refreshes are prepared. #1338 and #1340 were advanced to their newer published heads before resolving the registrations again. #1369 and #1374 also required registration-list reconciliation. #1418 merged during preparation, advancing Linux to `8bf1bc3214fb24cb701d83feaa2e92636fb717c3`. [Prepared source and merge parents](prepared-heads.json) record each local merge scope. A prepared merge is not a published PR update.

The #1429 local stress probe ran all 12 train-helper tests with low automatic-maintenance thresholds. All passed; Trace2 recorded 106 detached maintenance invocations. This establishes a possible fixture lifetime hazard, not reproduction or proof of the CI writer. No speculative fix was applied.

## Validation follow-up

All five queued preflight runs completed successfully: #1372, #1410, #1409, #1338 and #1340. GTK runs completed successfully for #1372 (110), #1410 (110), and the inspected #1338 tree (112). #1409 selected zero tests for its new catalog regression despite the selector existing in source; that run failed and a forced rebuild is pending. #1340 GTK ended without a recorded terminal status and is incomplete; #1390 GTK did not start. Shared-target results must not be attributed to a newer published head without a source comparison.

After forcing the app crate to rebuild, #1409’s `choosing_a_longer_kind_does_not_change_the_dropdown_width` executed and passed. The first empty selection therefore came from a stale shared-cache binary. The rebuilt full suite was still running with 64 successful individual results at inspection; that is not a completed tier. No product workaround was added.

The rebuilt #1409 GTK tier completed successfully: 111 tests, including its new catalog-width regression. #1340’s interrupted GTK check is being rerun after forcing source rebuild; it is not yet accepted.

A subsequent unresolved-index scan of all numbered standalone refresh worktrees found no remaining conflict entries. This proves conflict resolution only; local merge commits, publication and acceptance remain pending.

#1340’s rebuilt GTK tier completed successfully with 112 tests. #1390 full preflight passed and its GTK tier is pending. These results apply to the prepared local trees; publication remains pending.

The first #1390 GTK build failed importing `tablepro_app_services::editor_panel`. Its refreshed source explicitly exports that module. A forced app-services rebuild is pending to distinguish stale shared-target metadata from a source defect. The failed build is not counted as a passed tier.

#1390’s rebuilt GTK tier completed successfully: 132 tests. Rebuilding app-services resolved the stale metadata import failure without a product change. Full preflight also passed; local refresh publication and exact-head Forgejo acceptance remain pending.

#1379 full preflight completed successfully on the prepared refresh. This does not establish its real-engine driver acceptance. #1376 preflight is next in the same sequential process.

#1384 full preflight passed. Its scope remains partial for #1366: implicit schemas and session-local SET propagation are not established. #1397 preflight is next in the existing sequential queue. #1376’s separate forced rebuild progressed beyond the earlier missing-symbol error; full completion remains pending.
