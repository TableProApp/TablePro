# Vendored tree-sitter grammars

Generated parsers and their query files, copied from each grammar's own repository. Nothing here is written by
TablePro. Each grammar keeps its upstream `LICENSE` beside its sources, and each is listed in
`TablePro/Resources/ThirdPartyLicenses/licenses.yml` so the text reaches the Acknowledgements window.

| Grammar | Upstream | Licence |
| --- | --- | --- |
| `bash` | https://github.com/tree-sitter/tree-sitter-bash | MIT, Copyright (c) 2017 Max Brunsfeld |
| `javascript` | https://github.com/tree-sitter/tree-sitter-javascript | MIT, Copyright (c) 2014 Max Brunsfeld |
| `json` | https://github.com/tree-sitter/tree-sitter-json | MIT, Copyright (c) 2014 Max Brunsfeld |
| `sql` | https://github.com/DerekStride/tree-sitter-sql | MIT, Copyright (c) 2021 Derek Stride |

`vendored-headers/tree_sitter` holds the parser ABI headers a generated parser includes. They come from
https://github.com/tree-sitter/tree-sitter, MIT, Copyright (c) 2018-2024 Max Brunsfeld.

The `.scm` query files under `Sources/TableProGrammars/Queries` come from the same four repositories and carry the
same licences. `SyntaxHighlightingTests` compiles every one of them against its grammar, so a query that drifts out of
step with a regenerated parser fails there rather than at runtime.

To update a grammar, copy `src/parser.c`, `src/scanner.c` and the `queries/*.scm` files from the tagged release,
refresh the `LICENSE` beside them, and run the editor suites.
