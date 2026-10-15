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
| A word in context, with values in it | `pgettext_f` |
| A count whose word depends on where it appears | `npgettext` |

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

4. Compile and install it. The package build does this on its own. To
   test locally, put the catalogue where the build looks: the directory
   is built in from Meson's `localedir`, so point the prefix at a folder
   you can write and rebuild.

   ```sh
   meson configure _build --prefix="$HOME/.local"
   meson compile -C _build
   mkdir -p ~/.local/share/locale/xx/LC_MESSAGES
   msgfmt po/xx.po -o ~/.local/share/locale/xx/LC_MESSAGES/tablepro.mo
   LC_ALL=xx.UTF-8 meson devenv -C _build ./crates/app/tablepro
   ```

   glibc loads no catalogue at all under `C` or `C.UTF-8`, so testing a
   translation needs a real locale generated on the machine.

## POTFILES.in

`POTFILES.in` lists every file xgettext reads. Regenerate it with:

```sh
git ls-files 'crates/app/src/*.rs' 'data/resources/*.ui' 'data/*.desktop.in.in' \
  'data/*.gschema.xml.in' 'data/*.metainfo.xml.in.in' > po/POTFILES.in
```

CI runs the same command and fails on a diff, so a new source file cannot
silently drop out of translation.

## Regenerating tablepro.pot

`tablepro.pot` is the master template. A change that adds, edits or
removes a user-facing string regenerates it in the same commit:

```sh
meson compile -C _build tablepro-pot
```

The template names the file each string is in but not the line, so moving
code leaves it alone. The Translations CI job regenerates it and fails when
the committed file differs in anything but its creation date. It then
uploads the template it wrote as the `tablepro-pot` artifact, which can be
committed as it is.

This needs **gettext 0.24 or newer**, which is the first release whose
xgettext reads Rust. Fedora 44 ships 0.26; Ubuntu 26.04 ships 0.23.2. An
older xgettext falls back to its C lexer, which misreads lifetimes such as
`'static` as character constants and produces a template you should not
commit. `meson setup` warns when the xgettext it found is too old.

Use `msgmerge` to fold new strings into existing translations:

```sh
for f in po/*.po; do msgmerge --update "$f" po/tablepro.pot; done
```
