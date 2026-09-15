# Translations

TablePro Linux uses [GNU gettext](https://www.gnu.org/software/gettext/) for
localisation. Source strings go through the helpers in
`crates/app/src/i18n.rs`; at runtime `bindtextdomain("tablepro", …)` points
gettext at `config::LOCALEDIR`, which meson sets at build time.

## Which function to call

| Case | Call |
|---|---|
| A plain string | `gettext("Cancel")` |
| A string with values in it | `gettext_f("{table} in {schema}", &[("table", name), ("schema", schema)])` |
| A count | `ngettext_f("{n} row", "{n} rows", n, &[("n", &n.to_string())])` |
| A word whose sense depends on where it appears | `pgettext("filter operator", "all")` |
| Both of the last two | `npgettext` / `pgettext_f` |

Placeholders are **named**, never positional. A translator can reorder
`{table}` and `{schema}` freely, and a value is substituted once, so a
value containing braces is never expanded again. An unknown placeholder
stays in the string rather than disappearing, which makes a typo visible.

Do not translate symbols, SQL keywords, or the word TablePro.

## Adding a new translation

1. Pick a locale code (e.g. `vi`, `de`, `pt_BR`).
2. Add it on its own line to [`LINGUAS`](LINGUAS).
3. Copy `tablepro.pot` to `xx.po` and translate the entries:

   ```sh
   msginit --locale=xx --input=po/tablepro.pot --output=po/xx.po
   ```

4. Compile and install (the package build does this automatically; for
   local testing):

   ```sh
   mkdir -p ~/.local/share/locale/xx/LC_MESSAGES
   msgfmt po/xx.po -o ~/.local/share/locale/xx/LC_MESSAGES/tablepro.mo
   LC_ALL=xx.UTF-8 TABLEPRO_LOCALEDIR=~/.local/share/locale ./_build/crates/app/tablepro
   ```

   glibc loads no catalogue at all under `C` or `C.UTF-8`, so testing a
   translation needs a real locale generated on the machine.

## POTFILES.in

`POTFILES.in` lists every file xgettext reads. Regenerate it with:

```sh
git ls-files 'crates/app/src/*.rs' 'data/resources/*.ui' 'data/*.desktop.in.in' \
  'data/*.gschema.xml' 'data/*.metainfo.xml.in.in' > po/POTFILES.in
```

CI runs the same command and fails on a diff, so a new source file cannot
silently drop out of translation.

## Regenerating tablepro.pot

`tablepro.pot` is the master template, regenerated during release
preparation rather than on every change:

```sh
meson compile -C _build tablepro-pot
```

This needs **gettext 0.24 or newer**, which is the first release whose
xgettext reads Rust. An older xgettext falls back to its C lexer, which
misreads lifetimes such as `'static` as character constants and produces a
template you should not commit. `meson setup` warns when the xgettext it
found is too old.

Use `msgmerge` to fold new strings into existing translations:

```sh
for f in po/*.po; do msgmerge --update "$f" po/tablepro.pot; done
```
