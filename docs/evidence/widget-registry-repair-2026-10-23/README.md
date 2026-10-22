# Merged GTK registry repair

Issue: [#1438](https://github.com/cozyGarage/BookiE/issues/1438).
Base: `83bf13682c5534a81f411818f32c730adde54604`.

Full preflight stopped in the existing inventory guard because
`connection_actions_leave_room_for_text_in_a_narrow_row` was unmapped.
The connection-row action-dispatch test and both editor query-publication
tests were also missing from the isolated GTK registry. All four tests
already exist in product source and are restored without changing assertions.

The next preflight guard rejected duplicate UI-43 ledger rows for #1337
and #1366. The repair retains #1366 as UI-43 and assigns #1337 UI-44.
The ledger and ignored-test inventory now pass. Full preflight and all 115 registered GTK widget tests passed.
These results apply to the recorded base. Publication, integration with newer
Linux and exact-head Forgejo acceptance remain pending.
