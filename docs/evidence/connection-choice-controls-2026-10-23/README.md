# Connection choice controls

Repair for [issue 1488](https://github.com/cozyGarage/BookiE/issues/1488). All five connection-choice callers use the same shared control. The ActionRow lacked an activation target, the popup was manually parented to a plain button, and popup entries did not indicate the selected value.

GTK MenuButton now owns the popup, the row targets that button for activation, and each existing choice button includes a checkmark whose opacity follows the current selection. The marker references are weak. Programmatic selection remains silent; activating a choice retains the existing callback behavior. Existing labels and option order are preserved.

The activation-target test fails before the fix. The selection-marker test fails before marker creation. After repair, activation, marker updates and popup weak-reference release tests each pass in a separate process under fatal GTK criticals. A combined invocation is invalid because separate Rust test threads cannot initialize GTK; that failed invocation is not counted as product evidence. The test inventory records all three isolated registrations.

Full preflight passed (400 harness, 2,073 unit and 2,086 sandbox tests, plus Redis cancellation); warnings-denied app Clippy and all 157 isolated GTK tests passed. Installed connection-form, MySQL socket endpoint and real Tab/Space/Enter scenarios passed without retries. Initial installed probes needed native toggle selectors, Tab navigation instead of unsupported AT-SPI grabFocus, and Escape instead of a nonexistent idle Cancel button. Those failed probe attempts are not counted as passes. No Forgejo acceptance is claimed.
