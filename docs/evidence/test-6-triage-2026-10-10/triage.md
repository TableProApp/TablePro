# TEST-6 triage (2026-10-10)

First slice of [manual verification](../../manual-verification-0.2-features.md)
items mapped to the lowest useful tier. Automate only the accessible slice in
this pass; layout, light/dark, narrow-window and Wayland placement stay manual.

| Section / item | Tier | Status this PR |
| --- | --- | --- |
| Export Format list (CSV/JSON/Markdown/HTML/XML/SQL/Excel) | unit (`export_dialog`) | Mapped in `change-test-map.json`; existing unit tests |
| SQL absent for MongoDB/Redis | unit (`export_dialog`) | Mapped |
| CSV options only for CSV | unit (`export_dialog`) | Mapped |
| SQL table name from `schema.table` / label | unit (`export_dialog`) | Mapped |
| Excel over sheet limit refused with limit named | unit (`export/xlsx`) + gtk-installed workbook | Unit mapped; installed scenario already present |
| Cancelled large export leaves destination untouched | gtk-installed | Already covered (`gtk_workbook.py`) |
| Connection list colour swatch / group subtitle | unit (`connection_row`) | Mapped |
| Kerberos row hides username separator | unit (`connection_row`) | Mapped |
| Export HTML/XML/JSON/Markdown/SQL value contracts | unit (core export) | Mapped exact selectors |
| CSV import type inference / plan value contracts | unit (core import) | Mapped exact selectors |
| Connection dialog defaults / Enter / Escape / narrow width | stays-manual | Needs installed UI + theme |
| Browse shortcut labels vs Left/Right/Space/pointer | stays-manual | Needs installed UI labels |
| Long-query notification while unfocused | stays-manual | Needs desktop focus |
| Connection bundles passphrase / plan untick | gtk-installed / keyring | Keep existing B4 evidence; not expanded here |
| Structure tab column comments | stays-manual / gtk-widgets later | Engine + UI |
| Editor history / dirty close / file dialogs | stays-manual | B5 installed acceptance |
| Light/dark, narrow window, popover placement, Orca | stays-manual | DOC-3 / PKG-1 |
| Grid Columns dialog / context menu on native Ubuntu | stays-manual (TEST-28) | Needs native Ubuntu / product fix |

## Native Ubuntu still needed

- TEST-28: grid cell menu / Columns via AT-SPI on native Ubuntu Wayland/X11.
- PKG-1 / Wayland smoke: keyboard/action-first scenarios; no coordinate clicks.
- Remaining TEST-6 appearance and placement checklist after the unit slice above.
