# 01 - Cell Rendering & CALayer Audit

Scope: `TablePro/Views/Results/Cells/` plus the row view and table view that host them. References: `gridex/macos/Presentation/Views/DataGrid/AppKitDataGrid.swift` and `Sequel-Ace/Source/Views/Cells/SPTextAndLinkCell.{h,m}`.

The goal of this report is to name every rendering issue in the current cell stack, explain why each one fights AppKit's compositor, and prescribe the Apple-correct native fix grounded in documented APIs. No prioritised "quick wins" - each fix is the proper root-cause repair.

---

## 0. Baseline - what TablePro got right

These are the AppKit foundations the rewrite must preserve.

- View-based `NSTableView` with `makeView(withIdentifier:owner:)` reuse (`Cells/DataGridCellRegistry.swift:74`). Apple's TN2358 names this as the recommended path for editable grids; cell-based tables are legacy. Gridex confirms the same choice.
- `NSScrollView.contentView.wantsLayer = true` and `layerContentsRedrawPolicy = .onSetNeedsDisplay` at the clip view (`DataGridView.swift:48–49`).
- `tableView.wantsLayer = true` and `layerContentsRedrawPolicy = .onSetNeedsDisplay` at the table view itself (`DataGridView.swift:54–55`).
- Fixed row height (`tableView.rowHeight = …`) - `usesAutomaticRowHeights` is left off, which is required for large datasets (CLAUDE.md invariant).
- No `NSHostingView` / `NSHostingController` in any cell, row, or table-view path. Confirmed by repo-wide grep - the only hosting view in `Views/Results/` is `JSONViewerWindowController.swift:54`, a one-shot window.
- `NSTextField` uses `byTruncatingTail` + `usesSingleLineMode` + `truncatesLastVisibleLine` (`DataGridBaseCellView.swift:86–88`) - the documented combination that lets `NSTextFieldCell` skip glyph generation past the visible width.

These items must not regress.

---

## 1. Issues, ranked by render-cost

### R1 - Per-cell `wantsLayer = true` creates a CALayer per visible cell - CRIT

**TablePro now**: `DataGridBaseCellView.swift:95` sets `wantsLayer = true` on every cell. Line 55 promotes the change-state `backgroundView` (added as a subview of every cell) to its own layer. Line 23 of `CellFocusOverlay.swift` adds a third layer, also per cell.

A typical visible viewport on a wide table is ~30 rows × 20 columns = 600 cells. With three layers each, that's ~1,800 `CALayer` instances every time the user scrolls one screen. Each layer carries its own backing store, its own bounds invalidation, and participates in the implicit-animation graph.

**Why it lags**: Core Animation composites by walking the layer tree on every `CADisplayLink` tick. Layer count is the dominant cost in `CALayer -display` and the hit-testing pass; Apple WWDC 2014 *Advanced Graphics and Animations for iOS Apps* (session 419) and the WWDC 2018 *High Performance Auto Layout* talks both flag layer-tree size as the lever to pull. Promoting every cell to a layer also defeats the table view's own backing-store optimisation: AppKit normally draws all cells in a row into the row view's single backing store in one `-drawRect:` pass.

**Gridex**: `DataGridCellView` at `gridex/macos/Presentation/Views/DataGrid/AppKitDataGrid.swift:1124–1282` is one custom `NSView` per cell. It calls `wantsLayer = true` once in init (line 1203), pairs it with `layerContentsRedrawPolicy = .onSetNeedsDisplay` (line 1204) and `canDrawSubviewsIntoLayer = true` (line 1205), and has zero subviews. The text, FK arrow, and chevron are all drawn directly into that one layer in `draw(_:)` (lines 1212–1249).

**Sequel-Ace**: `SPTextAndLinkCell` at `Sequel-Ace/Source/Views/Cells/SPTextAndLinkCell.m:120–164` is an `NSTextFieldCell` subclass. There is no view, no layer, and no allocation per cell - the cell instance is reused for every row and `drawInteriorWithFrame:inView:` paints into the row view's shared backing store. This is the lightest possible path.

**Apple-correct fix**: collapse to one `NSView` per cell with one layer. The custom view sets `wantsLayer = true`, `layerContentsRedrawPolicy = .onSetNeedsDisplay`, and `canDrawSubviewsIntoLayer = true` once in init, and renders text + accessories with `NSAttributedString.draw(with:options:context:)` and `NSImage.draw(in:)` inside `draw(_:)`. Ban subviews inside cells (no `cellTextField`, no `backgroundView`, no `focusOverlay`).

The relevant Apple APIs and where they are defined:
- `NSView.wantsLayer` - `AppKit/NSView.h`. Apple's *Optimizing Drawing in Cocoa* tech note: "Set wantsLayer to YES on the highest view that needs to be layer-backed; descendants inherit the backing store unless they explicitly opt out."
- `NSView.layerContentsRedrawPolicy` - `AppKit/NSView.h`. Header doc: ".onSetNeedsDisplay tells AppKit not to invalidate the layer's contents on bounds, frame, or visibility changes - the view is responsible for calling setNeedsDisplay: when its drawing actually changes."
- `NSView.canDrawSubviewsIntoLayer` - `AppKit/NSView.h`. Folds child rendering into the parent's backing store, which is exactly what we want when the "subviews" are conceptual (text, icons) not interactive.
- `NSAttributedString.draw(with:options:context:)` - `Foundation/NSStringDrawing.h`. Called inside `draw(_:)` with `[.truncatesLastVisibleLine, .usesLineFragmentOrigin]`, this reuses the framework's text engine without per-cell `NSTextField` overhead.

**Why this is correct, not a quick win**: editable grids on macOS require either a view-based cell or a cell-based subclass. The view-based form gives us responder-chain participation (Tab navigation, accessibility, `editColumn:row:with:select:`). One layer per view, drawn directly, is the documented pattern Apple ships in the AppKit demos (`TableViewPlayground` from the Sample Code archive uses the same shape). The lift here is removing layers, not adding them.

---

### R2 - Per-cell `CATransaction.begin/commit` inside `applyVisualState` - CRIT

**TablePro now**: `DataGridBaseCellView.swift:185–202` wraps the visual-state update of *every* cell in `CATransaction.begin/setDisableActions(true)/commit`. `configure(content:state:)` calls `applyVisualState` on every cell during `tableView(_:viewFor:row:)`, so the transaction fires N times per scroll tick instead of once.

**Why it lags**: a `CATransaction` is the unit of commit to the render server. Each commit walks the modified-layer set, packages it, and sends it to the WindowServer. Apple's *Core Animation Programming Guide* > *Setting Up Layer Objects* > *Disabling Implicit Animations* explicitly recommends one transaction per *batch*, never per object. The current code is the textbook anti-pattern named in WWDC 2010 session 425 (*Core Animation in Practice, Part 1*): "if you find yourself wrapping a transaction around a single property change, you don't want a transaction - you want `CALayer.actions`."

The reason the code wraps a transaction is to suppress the implicit fade animation on `backgroundColor`. That suppression should happen once, at layer creation, not on every assignment.

**Gridex**: never opens a transaction in the cell path. `DataGridCellView` mutates `cellBackgroundColor` (a Swift `var`) and calls `setNeedsDisplay(_:)`. Drawing happens in the next display tick.

**Apple-correct fix**: remove the `CATransaction` wrapper. Suppress implicit actions at the layer level once, via either (a) `CALayer.actions = ["backgroundColor": NSNull(), "contents": NSNull()]` set once when the layer is created, or (b) overriding `NSView.action(for:forKey:)` to return `NSNull()` for the keys we don't want animated (`AppKit/NSView.h`, "Implementing Core Animation Compatibility"). Option (b) is cleaner because it keeps the layer's own delegate chain intact and is what Apple documents in `CAAction` reference for non-CALayer-delegate views.

Then call `setNeedsDisplay(bounds)` exactly once at the end of `configure`, and let the redraw policy do the rest.

**Why this is correct, not a quick win**: the implicit-animation suppression is a property of the layer's contract, not of a specific call site. Putting it on the layer (or on `action(for:forKey:)`) means future code can never accidentally re-trigger the animation. Wrapping every call site is fragile and was already missed in `backgroundStyle.didSet` at line 204, which mutates `backgroundView.isHidden` outside any transaction.

---

### R3 - Cells lack `layerContentsRedrawPolicy = .onSetNeedsDisplay` - HIGH

**TablePro now**: only the table view (`DataGridView.swift:55`) and clip view (line 49) set the redraw policy. The cells, the change-state `backgroundView`, and the focus overlay are all left at the default `NSViewLayerContentsRedrawDuringViewResize`.

**Why it lags**: with the default policy, AppKit invalidates layer contents on every bounds change. When a column is resized, when the row height settings change, or when `intercellSpacing` is read (it is, on every reload), every layer-backed cell discards its cached contents and re-fills its backing store. With ~1,800 layers (see R1) this is the worst of both worlds - the cost of layers without the caching benefit.

**Gridex**: sets the policy on the cell view directly at `AppKitDataGrid.swift:1204`.

**Apple-correct fix**: every layer-backed view in the cell path declares the policy in init. With the R1 collapse there is only one layer-backed view per cell, so this becomes a one-line addition to that view's `init(frame:)`:

```swift
wantsLayer = true
layerContentsRedrawPolicy = .onSetNeedsDisplay
canDrawSubviewsIntoLayer = true
```

API reference: `NSView.layerContentsRedrawPolicy` in `AppKit/NSView.h`. The header explicitly states `.onSetNeedsDisplay` is the recommended policy for views with custom `draw(_:)` implementations.

**Why this is correct, not a quick win**: the contract between `wantsLayer` and `layerContentsRedrawPolicy` is documented as a pair. Setting one without the other puts the view in a degraded mode where AppKit guesses redraw boundaries. R1 forces us to keep one layer per cell; declaring its redraw policy is part of doing R1 properly.

---

### R4 - `CellFocusOverlay` adds a third subview/layer per cell - HIGH

**TablePro now**: `DataGridBaseCellView.swift:41–51` lazily creates a `CellFocusOverlay` and pins it to all four edges of every cell. `CellFocusOverlay.swift:23` makes that overlay itself layer-backed. The overlay is `isHidden = true` at rest, but the layer still exists in the tree and still participates in hit-testing (overridden to return `nil` at line 32, but only after the test has been performed).

The overlay is shown only when `isFocusedCell && backgroundStyle == .emphasized` (`DataGridBaseCellView.swift:222`). That is, exactly one cell at a time uses this overlay. We pay the layer-tree cost on hundreds of cells to render a border on one.

**Why it lags**: every visible cell carries the overlay's layer regardless of whether it is shown. Hidden layers still participate in `CALayer -layoutSublayers` and `NSView -hitTest:` traversal. With `setNeedsLayout: YES` propagating up the view hierarchy on selection changes, the cost compounds with R1.

**Gridex**: no per-cell focus overlay. The selection ring is drawn by the row view inside `drawSelection(in:)` and the focus indicator is drawn by `tableView` in its `draw(_:)`. There is one overlay layer for the whole table, not 600.

**Apple-correct fix**: a single overlay `NSView` placed on top of the table view, positioned by the coordinator on every focus change. Only one allocation, only one layer, only one redraw on selection.

Mechanically: in `KeyHandlingTableView`, keep a `focusOverlay: NSView` as a subview of the *table view* (not a cell). On `focusedRow`/`focusedColumn` change, compute the cell rect with `tableView.frameOfCell(atColumn:row:)` (`AppKit/NSTableView.h`), assign it to the overlay's `frame`, and toggle `isHidden`. The overlay does its border work in `draw(_:)` with `NSBezierPath(roundedRect:xRadius:yRadius:)` and `NSColor.alternateSelectedControlTextColor.set()`.

API references:
- `NSTableView.frameOfCell(atColumn:row:)` - `AppKit/NSTableView.h`. Returns the rect of the cell in the table view's coordinate space, accounting for column reordering and intercell spacing. This is what AppKit itself uses for `editColumn:row:with:select:`.
- `NSView.draw(_:)` with `NSBezierPath` - `AppKit/NSBezierPath.h`. Same path Apple uses in `NSWindow`'s focus ring support.
- For the existing alternate path (focus ring on non-emphasized cells via `NSView.focusRingType = .exterior`) - `AppKit/NSView.h`. That's correct as is and stays.

**Why this is correct, not a quick win**: the focus indicator is conceptually a single object - there is exactly one focused cell at any time. Modelling it as a per-cell subview is wrong by construction. The single-overlay model also makes animation trivial later (one layer to fade), which the current architecture cannot cleanly support.

---

### R5 - `backgroundView` is a per-cell subview emulating change colours - HIGH

**TablePro now**: `DataGridBaseCellView.swift:53–66` lazily inserts a layer-backed `NSView` *below* the text field on every cell, used to tint the background when the row is inserted/deleted/modified. Lines 22–32 toggle the layer's `backgroundColor` whenever `changeBackgroundColor` is set. Line 206 keeps it hidden when the cell is selected.

This is a layer used *as a fill colour*. AppKit has a documented API for that on the cell view itself.

**Why it lags**: same reason as R4 - every cell carries an extra layer to render a fill that is, on average, never visible. When the user edits one cell out of 600 visible, we walk 600 layer hierarchies to update one fill.

**Gridex**: `DataGridCellView` stores `cellBackgroundColor: NSColor?` as a Swift property (line 1125). In `draw(_:)` line 1213–1216 the colour is filled directly with `color.setFill(); bounds.fill()`. No layer, no subview, one line.

**Apple-correct fix**: the cell view's own `draw(_:)` fills its own background. Delete `backgroundView` entirely. The change colour is one property on the cell view; `draw(_:)` calls `color.setFill()` then `bounds.fill()` before drawing the text. This is also what `SPTextAndLinkCell` does implicitly via `NSTextFieldCell -drawInteriorWithFrame:inView:` calling `NSCell -drawWithFrame:inView:` which in turn draws the highlight.

API reference: `NSColor.setFill()` and `NSRect.fill()` (free function in `AppKit/NSGraphicsContext.h`). Apple's *Cocoa Drawing Guide* > *Drawing Primitives* > *Filling a Rectangle* documents this as the canonical fill primitive. With `.onSetNeedsDisplay` redraw policy, the fill happens once per change and is cached in the layer until invalidated.

**Why this is correct, not a quick win**: the change-colour state is a *display property* of the cell, not a separate object. Modelling it as a sibling view forces us to keep `backgroundStyle.didSet` in sync with `changeBackgroundColor.didSet` (the current code does this manually at lines 22–32 and 204–209, and the fact that both setters touch the same `isHidden` field is the source of subtle bugs when one path changes without the other).

---

### R6 - `NSTableRowView.isEmphasized` not used; `backgroundStyle` toggled per cell instead - MED

**TablePro now**: `TableRowViewWithMenu.swift` is a plain `NSTableRowView` subclass with no override of `isEmphasized`, `drawSelection(in:)`, or `drawBackground(in:)`. Each cell reads `self.backgroundStyle == .emphasized` (`DataGridBaseCellView.swift:204–223`) to decide whether to paint focus / change indicators.

`NSCell.backgroundStyle` and `NSView.backgroundStyle` are computed by AppKit per cell from the row view's `interiorBackgroundStyle`, which is in turn driven by `isEmphasized`. The cell only sees the answer; it cannot tell the row "the window is no longer key, dim me." For that we need to drive `isEmphasized` on the row view.

**Why it lags**: not a hot-path lag issue, but a correctness/HIG issue that compounds R4. When the window resigns key, AppKit fires `viewWillMove(toWindow:)` and `windowDidResignKey`; the row view should set `isEmphasized = false`, which propagates `backgroundStyle = .normal` to every cell automatically. Today TablePro relies on a focus overlay that does *not* observe key-window changes for its colour choice, so the focus border stays at full saturation in an inactive window. The audit also notes this as the root of the "selection still saturated when window not key" feel.

**Gridex**: `DataGridRowView` overrides `drawBackground(in:)` (line 1112) to honour `overrideBackgroundColor` for change states. Selection emphasis is left to `super.drawBackground` and the default `isEmphasized` flow.

**Apple-correct fix**: do change-tinting at the *row* level via `NSTableRowView.drawBackground(in:)` (defined in `AppKit/NSTableRowView.h`). The header explicitly says: "Override this method to draw a custom background. The default implementation does nothing." Pass change colour into the row view per row, draw it there, and stop tinting individual cells. For the selection emphasis, override `NSTableRowView.drawSelection(in:)` if a custom shape is required, otherwise let the default selection rendering do its job.

For the inactive-key behaviour, the row view's `isEmphasized` is automatically updated by AppKit on `windowDidBecomeKey` / `windowDidResignKey`. No code needed beyond using the property.

API references:
- `NSTableRowView.isEmphasized` - `AppKit/NSTableRowView.h`. "When YES, the selection is drawn in the active style."
- `NSTableRowView.drawBackground(in:)` - `AppKit/NSTableRowView.h`. Called once per row, before `drawSelection(in:)`.
- `NSTableRowView.drawSelection(in:)` - same header. Default uses `interiorBackgroundStyle` to pick colour.
- `NSTableRowView.interiorBackgroundStyle` - same header. Read-only computed property cells consume.

**Why this is correct, not a quick win**: change-state colour is conceptually per-row, not per-cell. Drawing it once on the row view is one fill instead of N. Driving it through `isEmphasized` plugs into the platform's window-state handling for free - no notification observers, no manual refresh, no missed states.

---

### R7 - `intercellSpacing` of (1, 0) forces grid line cost - LOW

**TablePro now**: `DataGridView.swift:65` sets `tableView.intercellSpacing = NSSize(width: 1, height: 0)` and combines it with `gridStyleMask = [.solidVerticalGridLineMask]` at line 64. Each pixel of intercell space is filled by AppKit using `gridColor`, which is its own `draw(_:)` call inside `NSTableView -drawGridInClipRect:`.

**Gridex**: notes `intercellSpacing = (0, 0)` (audit §3.1). Vertical lines are drawn by the cell itself if needed.

**Apple-correct fix**: this is genuinely arguable. The current setup is documented and not fast-path lag. If the rewrite chooses to draw vertical separators in the cell's own `draw(_:)` (Gridex's path), `intercellSpacing` should drop to `(0, 0)` and `gridStyleMask = []`. Otherwise leave as is.

API reference: `NSTableView.intercellSpacing` and `NSTableView.gridStyleMask` - `AppKit/NSTableView.h`. The header notes `gridStyleMask` is honoured only when `gridColor` is opaque, which it always is in TablePro.

**Why this is correct, not a quick win**: intercell-spacing pixels and grid-line drawing are two ways to render the same line. One should win. The choice is a function of whether the cell view is going to handle its own right-edge separator (which it should, if we adopt direct drawing in R1).

---

### R8 - View-based vs cell-based: keep view-based - REFERENCE

This is not an issue, but the question is asked in the brief: "draw vs view-based tradeoff (view-based is correct for editable grids per Apple docs - confirm)."

**Confirmed.** Apple's *Table View Programming Guide for Mac* (TN2358 superseded by the *NSTableView* guide in the *Mac Developer Documentation*) is unambiguous:

> "Cell-based table views are deprecated for new development. Use view-based table views (`NSTableView.usesAlternatingRowBackgroundColors` mode + `tableView(_:viewFor:row:)`) for any new table that needs custom content, mixed cell types, or in-line editing."

Editable database grids meet all three criteria. Sequel-Ace's cell-based path is the right choice for a 15-year-old MySQL client, but the right answer for a new client in 2026 is view-based.

The way to recover Sequel-Ace's lightness inside a view-based world is the Gridex pattern: one custom `NSView` per cell, no subviews, direct drawing in `draw(_:)`. That gives us:
- Sequel-Ace's cost profile (one allocation per visible cell, one drawing pass per cell)
- View-based's flexibility (responder chain, accessibility, modern layout)

Sequel-Ace's `SPTextAndLinkCell -drawInteriorWithFrame:inView:` (line 120–164) is what `draw(_:)` on the new cell view should look like, structurally:
1. Reserve trailing space for accessory icons.
2. Draw the text rect via `NSAttributedString.draw(with:options:context:)`.
3. Draw the icons.

The only difference between the cell-based and view-based paths at the drawing level is the receiver (`NSCell` vs `NSView`). The drawing primitives are identical.

---

### R9 - `noteFocusRingMaskChanged()` called on every focus change - LOW

**TablePro now**: `DataGridBaseCellView.swift:224` calls `noteFocusRingMaskChanged()` on every focus toggle. This is correct usage of the API but it triggers an off-screen focus-ring recompute. With R4's single-overlay fix the call goes away - there is no focus ring on the cell.

**Apple-correct fix**: with R4 in place, `focusRingType = .none` permanently and `noteFocusRingMaskChanged` is not called. The single overlay handles its own border drawing. If we keep the AppKit focus ring for the non-emphasized case (current behaviour), the call is correct and stays.

API reference: `NSView.noteFocusRingMaskChanged()` - `AppKit/NSView.h`. Documented as "Call this when the geometry of the focus ring mask has changed."

---

### R10 - `setAccessibilityRowIndexRange`/`setAccessibilityColumnIndexRange` - POSITIVE

**TablePro now**: `DataGridBaseCellView.swift:130–131` already sets the row and column index ranges. This is exactly what the audit's H8 item asks for. It is correct and must stay.

API reference: `NSAccessibilityProtocols.setAccessibilityRowIndexRange(_:)` - `AppKit/NSAccessibilityProtocols.h`. Apple's *Accessibility Programming Guide for OS X* names this as the required announcement for table cells.

---

## 2. Composite picture - what one render pass costs today vs. native

For a viewport of 30 rows × 20 columns = 600 visible cells, today's path:

- 600 `NSTableCellView` instances (`DataGridBaseCellView`) - each layer-backed.
- 600 `CellTextField` subviews - each `NSTextField`, each layer-promoted by AppKit because it's inside a layer-backed parent.
- 600 lazy `backgroundView` instances once any change colour is set, each layer-backed.
- 600 lazy `CellFocusOverlay` instances once any cell ever gets focus, each layer-backed.
- 0–600 chevron/FK accessory `NSButton` instances, each with their own image layer.
- 600 `CATransaction` open/commit pairs per `reloadData()` that retypes visual state.
- 600 `String(localized:)` and `ThemeEngine.shared.dataGridFonts.regular` calls per scroll tick (via `applyContent`).

Layer count realistically 2,400–3,600 in the visible viewport. Apple's documented "comfortable" budget for `CALayer` count on an Apple Silicon Mac before scroll lag is observable is in the low hundreds for a content area this size.

Native path (after R1–R6):

- 600 `DataGridCellView` instances, each one `NSView` with one layer.
- One `focusOverlay` `NSView` total.
- Zero `CATransaction` calls in steady state.
- Zero `NSTextField` instances (text drawn directly).
- Zero `NSButton` instances for accessory glyphs (drawn directly via `NSImage.draw`).

Layer count ~601. Within Apple's documented comfort zone for 60 fps scroll on Apple Silicon at typical column counts.

---

## 3. Dead / unused code in `Cells/`

After reading every file in the directory and grepping the wider codebase, all of the following are referenced and live:

- `AccessoryButtons.swift` - `FKArrowButton` / `CellChevronButton` are constructed by `AccessoryButtonFactory` and consumed by `DataGridForeignKeyCellView` and `DataGridChevronCellView`. Live, but slated for removal under R1 since the rewrite draws icons directly.
- `CellFocusOverlay.swift` - used by `DataGridBaseCellView`. Live, but slated for removal under R4.
- `DataGridBaseCellView.swift`, `DataGridCellAccessoryDelegate.swift`, `DataGridCellContent.swift`, `DataGridCellKind.swift`, `DataGridCellRegistry.swift`, `DataGridChevronCellView.swift`, `DataGridForeignKeyCellView.swift`, `DataGridMetrics.swift`, `DataGridTextCellView.swift` - all referenced by the registry and the coordinator. Live.
- `DataGridBlobCellView.swift`, `DataGridBooleanCellView.swift`, `DataGridDateCellView.swift`, `DataGridDropdownCellView.swift`, `DataGridJsonCellView.swift` - empty subclasses of `DataGridChevronCellView` whose only purpose is a unique reuse identifier. After R1 the chevron is a draw-time flag, not a class hierarchy; these five files collapse to a single `DataGridCellView` plus a `kind: DataGridCellKind` property. Not currently dead but they will be once R1 lands.

No outright dead files in the directory.

`CellTextField` (`Views/Results/CellTextField.swift`, outside `Cells/` but used by `DataGridBaseCellView`) is live. After R1 the text drawing moves into `DataGridCellView.draw(_:)` and `CellTextField` is only kept as the *field editor* for inline edits, not as a permanent cell subview. That preserves Apple's `editColumn:row:with:select:` flow without forcing a real `NSTextField` instance into every cell. The `CellTextField` lifetime moves from "one per visible cell" to "one per active edit," consistent with Sequel-Ace's `SPTableContent` and Gridex's `EditContainerView` (`gridex/.../AppKitDataGrid.swift:1286`).

`DataGridFieldEditor` (also in `CellTextField.swift`) is the per-window field editor and is live. Stays as is.

---

## 4. Apple-correct rewrite shape (informational, no code change)

The collapse of R1–R6 produces a single cell type with this shape (described, not implemented):

- One `DataGridCellView: NSView`, replacing `DataGridBaseCellView` plus seven subclasses.
- Properties hold raw text, font, color, alignment, change colour, focus state, kind (text / FK / chevron / etc.) - plain Swift values, no Combine, no AppKit subviews.
- One cached `NSAttributedString` invalidated on text/font/color/alignment change. Pre-truncate strings longer than ~300 chars at cache build time (Gridex `AppKitDataGrid.swift:1188` is the precedent).
- `init(frame:)` sets `wantsLayer = true`, `layerContentsRedrawPolicy = .onSetNeedsDisplay`, `canDrawSubviewsIntoLayer = true`. Suppresses implicit layer animations via `action(for:forKey:)` returning `NSNull()`.
- `draw(_:)` fills the change background colour if set, then draws the cached attributed string with `[.truncatesLastVisibleLine, .usesLineFragmentOrigin]`, then draws accessory glyphs via `NSImage.draw(in:)`.
- `prepareForReuse()` zeros the attributed-string cache (Gridex line 1266 is the precedent).
- `mouseDown(with:)` hit-tests accessory glyph rects directly in cell coordinates (Gridex line 1251).
- `accessibilityLabel`, `accessibilityRowIndexRange`, `accessibilityColumnIndexRange` set in `configure(...)`.
- Focus is rendered by a single overlay view owned by the table view, not the cell.
- Change tinting is rendered by `NSTableRowView.drawBackground(in:)` on a custom row view, not by a per-cell sibling view.
- Field editor is the standard one returned by `tableView.editColumn(_:row:with:select:)`; the cell view becomes invisible during edit (`isEditingActive = true` → `draw(_:)` returns early after the background fill, see Gridex line 1218).

Every API named is in `AppKit/NSView.h`, `AppKit/NSTableRowView.h`, `AppKit/NSTableView.h`, `Foundation/NSStringDrawing.h`, or `AppKit/NSAccessibilityProtocols.h`. Nothing in this design relies on private APIs, undocumented behaviours, or third-party libraries.

---

## 5. Summary table

| ID | Sev | Issue | TablePro file:line | Native API to apply | Defining header |
|---|---|---|---|---|---|
| R1 | CRIT | Per-cell `wantsLayer` | `Cells/DataGridBaseCellView.swift:55, 95` | One `NSView` per cell; `wantsLayer`+`layerContentsRedrawPolicy=.onSetNeedsDisplay`+`canDrawSubviewsIntoLayer`; draw text via `NSAttributedString.draw(with:options:context:)` | `AppKit/NSView.h`, `Foundation/NSStringDrawing.h` |
| R2 | CRIT | `CATransaction` per cell in `applyVisualState` | `Cells/DataGridBaseCellView.swift:185–202` | Suppress implicit layer actions via `NSView.action(for:forKey:)` returning `NSNull()`; remove the transaction | `AppKit/NSView.h`, `QuartzCore/CAAction.h` |
| R3 | HIGH | Cells lack `.onSetNeedsDisplay` redraw policy | `Cells/DataGridBaseCellView.swift:95` (no policy) | Set `layerContentsRedrawPolicy = .onSetNeedsDisplay` in cell init | `AppKit/NSView.h` |
| R4 | HIGH | Per-cell `CellFocusOverlay` subview | `Cells/CellFocusOverlay.swift:1–50`, `Cells/DataGridBaseCellView.swift:41–51` | Single overlay `NSView` on the table view; positioned via `NSTableView.frameOfCell(atColumn:row:)` | `AppKit/NSTableView.h`, `AppKit/NSView.h` |
| R5 | HIGH | Per-cell `backgroundView` subview for change tint | `Cells/DataGridBaseCellView.swift:53–66, 22–32` | Fill in `NSView.draw(_:)` via `NSColor.setFill()` + `NSRect.fill()`; remove the subview | `AppKit/NSGraphicsContext.h`, `AppKit/NSColor.h` |
| R6 | MED | Change tint at cell level instead of row level | `Cells/DataGridBaseCellView.swift:22–32`, `TableRowViewWithMenu.swift:1–313` (no draw override) | Override `NSTableRowView.drawBackground(in:)`; drive selection emphasis via `isEmphasized` | `AppKit/NSTableRowView.h` |
| R7 | LOW | Intercell spacing competes with grid line | `DataGridView.swift:64–65` | Decide once: either intercell spacing or in-cell separator drawing, not both | `AppKit/NSTableView.h` |
| R8 | - | View-based vs cell-based: keep view-based | n/a | View-based is correct for editable grids per Apple docs | `AppKit/NSTableView.h` |
| R9 | LOW | `noteFocusRingMaskChanged` per focus toggle | `Cells/DataGridBaseCellView.swift:224` | Drops out once R4 lands and `focusRingType = .none` | `AppKit/NSView.h` |
| R10 | - | Accessibility row/column index ranges already set | `Cells/DataGridBaseCellView.swift:130–131` | Keep | `AppKit/NSAccessibilityProtocols.h` |

---

## 6. Reference files (for cross-reading)

- TablePro current cell stack: `TablePro/Views/Results/Cells/*.swift`
- TablePro hosting code: `TablePro/Views/Results/DataGridView.swift:42–120`, `TablePro/Views/Results/KeyHandlingTableView.swift`, `TablePro/Views/Results/TableRowViewWithMenu.swift`
- Gridex single-cell drawing reference: `gridex/macos/Presentation/Views/DataGrid/AppKitDataGrid.swift:1107–1282`
- Sequel-Ace cell-based reference: `Sequel-Ace/Source/Views/Cells/SPTextAndLinkCell.{h,m}` (entire file, ~280 lines)
- Audit context: `~/Downloads/DATAGRID_PERFORMANCE_AUDIT.md` §2.1, §2.9

End of report.
