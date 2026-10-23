# Shared cell-menu shortcut trigger

Source before correction: Linux `e6f73eca9`. Follow-up to [#1315](https://github.com/cozyGarage/BookiE/issues/1315) and the wide-column allocation profile.

Each realized cell parsed the same Menu and Shift+F10 alternative trigger. The grid already shares its menus, so its immutable parsed trigger can be shared as well, without global GTK state or a new dependency. Controllers and callback actions remain per cell because their targets differ.

The existing registered keyboard-menu regression now attaches two cells and compares their trigger identities before exercising keyboard action availability. It failed before the correction with two distinct GtkAlternativeTrigger instances and passes afterward with a single shared instance. Existing reference and filtered-export action behavior remains covered by the same test.

Function-size checks pass; the changed file remains below 1,200 lines. Full preflight passes on the integrated branch. The complete isolated GTK widget tier also passes, with 153 tests executed successfully. Forgejo acceptance remains pending. This removes repeated parsing and trigger objects; no full-app RSS or elapsed-time improvement has been measured for this change.
