#!/bin/sh
# Compares each catalogue in LINGUAS with the template, as msgmerge would
# bring it up to date, and prints a Markdown table of what each leaves
# untranslated or fuzzy. The entries themselves go to stderr. Exits 1 when
# a catalogue is incomplete, 2 when the check cannot run.
#
# From linux/, after `meson compile -C _build tablepro-pot`:
#   po/check-complete.sh [po-directory]
set -eu

po_dir=${1:-po}
template=$po_dir/tablepro.pot
if [ ! -f "$template" ]; then
  echo "$template is missing: run meson compile -C _build tablepro-pot first" >&2
  exit 2
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# One count from msgfmt --statistics, which leaves out a part that is 0.
count() {
  printf '%s\n' "$1" | tr ',' '\n' | sed -n "s/^ *\([0-9][0-9]*\) $2.*/\1/p" | grep . || echo 0
}

# The entries msgattrib keeps, without the header entry.
entries() {
  msgattrib "$@" --no-obsolete --no-location --no-wrap "$merged" \
    | awk 'BEGIN { RS = ""; ORS = "\n\n" } !/(^|\n)msgid ""\nmsgstr/'
}

langs=$(sed -e 's/#.*//' "$po_dir/LINGUAS")
incomplete=0
printf '| Language | Translated | Fuzzy | Untranslated |\n|---|---|---|---|\n'
for lang in $langs; do
  merged=$work/$lang.po
  # Without fuzzy matching a new string counts as untranslated, not as a
  # guess from a similar one that a translator still has to check.
  msgmerge --quiet --no-fuzzy-matching --output-file="$merged" "$po_dir/$lang.po" "$template" || exit 2
  stats=$(LC_ALL=C msgfmt --statistics --output-file=/dev/null "$merged" 2>&1) || exit 2
  translated=$(count "$stats" 'translated message')
  fuzzy=$(count "$stats" 'fuzzy translation')
  untranslated=$(count "$stats" 'untranslated message')
  # msgfmt counts a plural entry whose first form is filled as translated, so an empty later form counts here.
  partial=$(msgattrib --translated --no-fuzzy --no-obsolete --no-wrap "$merged" | awk '
    /^msgstr\[[0-9]+\] ""$/ { pending = 1; next }
    pending { if ($0 !~ /^"/) partial = 1; pending = 0 }
    /^$/ { if (partial) n++; partial = 0 }
    END { if (pending || partial) n++; print n + 0 }')
  translated=$((translated - partial))
  untranslated=$((untranslated + partial))
  printf '| `%s` | %s | %s | %s |\n' "$lang" "$translated" "$fuzzy" "$untranslated"
  if [ "$fuzzy" -ne 0 ] || [ "$untranslated" -ne 0 ]; then
    incomplete=1
    {
      echo "== $lang: $untranslated untranslated, $fuzzy fuzzy"
      entries --untranslated
      entries --only-fuzzy
      msgattrib --translated --no-fuzzy --no-obsolete --no-wrap "$merged" \
        | awk 'BEGIN { RS = ""; ORS = "\n\n" } /msgstr\[[0-9]+\] ""(\n[^"]|$)/'
    } >&2
  fi
done
exit "$incomplete"
