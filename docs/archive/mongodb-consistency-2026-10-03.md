# MongoDB browse consistency boundary

MongoDB browse metadata is best-effort and does not use snapshot isolation.
`fetch_rows` scans the collection once, derives type metadata, and retains the
requested page from that same cursor. This removes the gap between its former
schema scan and page query, but the cursor can still return an older version of
a document already read when another client updates it. A test pauses `getMore`
after `_id: 0` has been read, changes its `value` from String to Decimal128, and
verifies the result still contains the earlier String value while native storage
contains Decimal128. MongoDB writes remain last-write-wins; clients should not
interpret the metadata scan as a conflict check.

The shell `run_find` path first scans for collection type metadata, then runs a
filtered query. It merges types observed in returned rows: a selected document
that changes kind between those operations is marked `mixed`. Changes to
documents outside the returned page cannot be detected by that merge.

CSV and JSON export serialize the already materialized result. When a returned
mixed value is canonical Extended JSON, its BSON marker is preserved in the
export. Export does not refresh the query or establish a collection snapshot.

The full scan costs O(N) reads for each browse page. A local MongoDB 7
diagnostic measured one sample with a 50-row page: 6 ms for 1,000 documents and
51 ms for 10,000 documents. These figures depend on the local container and are
not thresholds or latency guarantees.

October 4 current-checkout revalidation: all 12 `value_contract_mongodb_`
app tests passed, including the five census/browse race cases and the seven
BSON parser/edit contracts. This confirms selected-row `run_find` type merging
and export behavior on the current source; it does not change the off-page or
non-snapshot limits above. See the
[current regression evidence](../evidence/mongodb-current-census-results-2026-10-04/manifest.json).

The app-server tests, driver timing test, and retained output are listed in the
[MongoDB census evidence manifest](../evidence/mongodb-census-results-2026-10-03/manifest.json).
