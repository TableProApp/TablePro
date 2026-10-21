# Large SQL editor analysis, October 21

Source base: `9f5dbd47e`. Owner: [#1287](https://github.com/cozyGarage/BookiE/issues/1287).

## Reproduced mechanism

Completion metadata refresh copied the entire GTK buffer and planned the complete script on cursor changes and edits, without a size limit. Completion proposal generation also extracted the whole buffer. Statement shading checked its existing 200,000-byte limit only after text extraction. Diagnostics extracted full text before its debounce and held a second owned copy for its worker. These are repeated allocations and parsing work, not evidence of a permanent leak.

File reads already run off the GTK thread and refuse files over 8 MiB. Workspace persistence already debounces writes. Neither is described as newly fixed here.

## Change and contract

A shared advisory snapshot checks the GTK character count before extraction, then enforces an exact 200,000-byte UTF-8 limit. It returns the complete text within that limit and no analysis text above it. The character-count check avoids extracting a multi-megabyte ASCII buffer; the subsequent byte check handles multibyte text. No truncated SQL window is analyzed as a complete statement.

Automatic completion metadata refresh, completion proposals, statement shading and advisory character diagnostics use that snapshot. Above the limit, those assistance features are unavailable. Editor text, saving, statement execution, policy classification and change notifications still use the full SQL. The diagnostics snapshot is taken after the existing debounce and shared between scanning and range conversion.

The completion refresh helper moves into the existing completion provider module to keep the editor composition file within its limit. No dependency or core/driver contract changes.

## Regression and validation

An isolated GTK test fails against the original unbounded extraction after an ASCII buffer exceeds the budget. The fixed test also covers an exact-size ASCII document, multibyte UTF-8 below and above the byte limit, and preservation of the complete buffer text. Existing normal completion activation and statement-band cases remain registered. Fresh preflight, all 95 isolated GTK cases, app all-target Clippy and documentation/inventory checks passed on the recorded base. The completion integration case verifies that proposals return and activate after a large buffer is replaced by a small query. The band case verifies clearing after growth past the limit. Native end-to-end profiling remains unverified.

The [pinned TablePro guidance](https://github.com/TableProApp/TablePro/blob/8085bff2dd87d80ab1ca29a550e347e749fa2985/CLAUDE.md) identifies repeated whole-string traversal and eager layout as historical performance hazards. The local source trace and regression establish the mechanism here; no upstream code is copied. Separate query rendering and resource acceptance remain under [#1272](https://github.com/cozyGarage/BookiE/issues/1272).

## Remaining limits

Full-document change notifications, tab labels/tooltips, persistence serialization, syntax highlighting, explicit formatting and execution planning can still process large documents. This change does not claim a native-desktop throughput or memory benchmark, or guarantee responsiveness for every 8 MiB SQL file. Native Wayland and long single-line SQL layout still need profiling.
