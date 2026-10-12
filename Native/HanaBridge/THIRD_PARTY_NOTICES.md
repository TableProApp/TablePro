# Third-party notices

`scripts/build-hana.sh` builds this bridge with `CGO_ENABLED=0` into the `tablepro-hana-helper` executable, so
everything below is statically linked into it. The helper ships inside the SAP HANA plugin, in
`HanaDriver.tableplugin/Contents/MacOS`. The versions are the ones `go.mod` and `go.sum` pin.

| Component | Version | License | Copyright |
| --- | --- | --- | --- |
| [go-hdb](https://github.com/SAP/go-hdb) | v1.18.12 | Apache-2.0 | 2014-2026 SAP SE or an SAP affiliate company and go-hdb contributors |
| [golang.org/x/text](https://pkg.go.dev/golang.org/x/text) | v0.42.0 | BSD-3-Clause | 2009 The Go Authors |
| [Go runtime and standard library](https://go.dev) | go1.27.1 | BSD-3-Clause | 2009 The Go Authors |

The Go standard library vendors golang.org/x/crypto, x/net, x/sys and x/text. They carry the same BSD-3-Clause notice
from The Go Authors as the standard library itself.

go-hdb has no NOTICE file. Its `REUSE.toml` adds that calls to the APIs of SAP products are not licensed under
Apache-2.0 and are governed by the user's own agreement with SAP.

The full license texts:

- go-hdb: <https://github.com/SAP/go-hdb/blob/v1.18.12/LICENSE.md>
- golang.org/x/text: <https://github.com/golang/text/blob/v0.42.0/LICENSE>
- Go: <https://github.com/golang/go/blob/go1.27.1/LICENSE>

The app's acknowledgements carry the same three texts in `TablePro/Resources/ThirdPartyLicenses/texts/`.
