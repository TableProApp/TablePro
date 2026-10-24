# Stream progress plural labels

Related: [#1490](https://github.com/cozyGarage/BookiE/issues/1490), plural-label finding only.

The stream progress formatter always used plural row and page labels. A pure five-case regression failed before the fix with “Received 1 rows · 1 pages” instead of “Received 1 row · 1 page.”

The formatter now uses the existing gettext plural helper separately for row and page counts. The test covers zero, both singular, both plural, and each mixed case. Received totals, retained-page behavior and the retention notice are unchanged.

The five-case regression passes after the fix. Full preflight passed (2,075 unit tests, 2,088 sandbox tests and the separate Redis check). Strict application Clippy and all 158 isolated GTK tests passed. Forgejo acceptance is pending. This is English-output regression evidence plus reuse of the established gettext helper, not a translated-locale or native desktop acceptance run. No new dependency or CI job is added.

An initial fixture revision needed explicit numeric types before compilation; the recorded failing regression is the subsequent valid test assertion, not that compilation error.
