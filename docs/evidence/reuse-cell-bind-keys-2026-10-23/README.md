# Reuse primary-key values during cell binding

Source baseline: Linux `0053bf339`. Related performance work: [#1315](https://github.com/cozyGarage/BookiE/issues/1315).

The shared column factory collected row primary-key values at the start of binding, then collected them again for pending-row CSS state. Editable text and boolean branches cloned the first vector when saving widget identity. The pending-state lookup now borrows the first collection; the selected editable widget takes ownership of that vector. Branches are mutually exclusive. Primary-key values, identity construction, change-tracker lookup and draft behavior are unchanged.

This is an allocation-only refactor that pins existing behavior rather than changing product rules. Existing isolated GTK tests cover bound values, pending edits and cell identity. At code commit `bc8f8e8ff`, full local preflight and all 153 isolated GTK widget tests pass. This is a self-reviewed ownership refactor; exact-head GitHub and Forgejo acceptance remain pending. No application-level timing or memory improvement is claimed.
