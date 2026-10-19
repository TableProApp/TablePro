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
3. Generate the template ([Generating tablepro.pot](#generating-tablepropot)),
   start `xx.po` from it and translate the entries:

   ```sh
   meson compile -C _build tablepro-pot
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

## Generating tablepro.pot

`tablepro.pot` is not committed, as in other GNOME apps. Generate it from
the code before running `msginit` or `msgmerge`:

```sh
meson compile -C _build tablepro-pot
```

This needs **gettext 1.0 or newer**, the first release whose xgettext
reads a call through a path such as `crate::i18n::gettext(...)`, the way
most of the app calls it. Ubuntu 26.10 ships 1.0; Fedora 44 ships 0.26 and
Ubuntu 26.04 0.23.2. gettext 0.24 to 0.26 read Rust but skip every
path-qualified call, and anything older falls back to its C lexer, which
misreads lifetimes such as `'static` as character constants. `meson setup`
warns when the xgettext it found is too old.

Then fold new strings into existing translations:

```sh
for f in po/*.po; do msgmerge --update "$f" po/tablepro.pot; done
```

`meson compile -C _build tablepro-update-po` does both steps for every
locale in `LINGUAS`.
