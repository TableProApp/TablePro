# Borrowed row identity checks, October 22

Owner: [#1387](https://github.com/cozyGarage/BookiE/issues/1387), UX lane. Status: merged through [#1394](https://github.com/cozyGarage/BookiE/pull/1394), commit `d38a0185608b7a6f4e42c2ac70456047cc676dab`; the owning issue is closed. Measurements retain their original candidate scope.

The stale-edit check formerly cloned every cell before comparing primary-key values. A row with a large unrelated text or binary value therefore made an unnecessary full payload copy during validation. The check now borrows each primary-key value through the existing row accessor. Exact key order, NULL equality, key count checks and missing-key refusal remain covered. No-key and draft-row handling remains in the existing caller.

The focused fixture uses a 16 MiB non-key text value, eight successful key checks and one refused key. It asserts key outcomes and verifies the payload remains intact. These functional tests pin existing behavior; the allocation comparison demonstrates the removed copy.

| Heaptrack measurement | Before | Candidate |
| --- | ---: | ---: |
| Peak allocated heap, decimal MB | 33.80 | 17.03 |
| Allocation calls | 2,130 | 2,112 |

The two captures used distinct executable hashes. [Measurements and profile hashes](measurements.json), [baseline report](baseline-heap.txt) and [candidate report](candidate-heap.txt) preserve the evidence. Compressed captures are retained outside the build cache in the local `bookie-test/profiles/row-key-2026-10-22` directory. Test executables are local build artifacts.

This is one capture per variant of a narrow test on a shared machine. It does not establish application latency, whole-app peak memory or removal of full-row copies from other editing operations. Reproduce by building application library tests and running the exact test named in the manifest under `heaptrack --record-only`, with one test thread. The fixture uses a GLib row object and requires no display.

Local validation passed: all 15 row-identity tests, 726 non-ignored application unit tests, full preflight, application all-target Clippy and all 106 registered isolated GTK widget tests. The candidate was subsequently published as #1393 and included in merged train #1394. The owning issue records acceptance; this review did not independently inspect or rerun Forgejo.

A follow-up regression covers the shared-result row storage used by the grid. It verifies the original key, an edited key override and refusal after the weak source expires. All 15 focused tests, all 726 application unit tests and application all-target Clippy passed after this test-only addition. The earlier preflight and 106 GTK checks apply to unchanged production code before that addition; no new allocation comparison is claimed for the rebuilt test executable.
