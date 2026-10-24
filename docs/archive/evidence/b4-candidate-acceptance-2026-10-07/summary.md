# B4 candidate acceptance checkpoint — 2026-10-07

The broad candidate layer report records local work based on `fork/linux`
`4f819f9123fe005db7dbd5f530ad8f3c73e1f0d4` (PR #159). It passed the full,
security-policy, drivers, TLS, SSH, PostgreSQL release, widgets, keyring,
app-server, supply-chain and SQL Server Kerberos layers. The Arch packaging
contract passed. The Debian package step lacked `dpkg-deb` on the host; its
validator passed in a disposable Debian testing container.

PR #162 fixes the GTK safety setup and adds Xvfb/AT-SPI runtime packages to
the PostgreSQL release job. PR #161 had already added GTK build dependencies.
On PR #162 SHA `301b05926418eddd7cf895781de56dea77c87c77`, the full local UI
layer passed all 47 scenarios in 268.396 seconds.

The first hosted PR #162 run exposed a GTK accessibility role mismatch: Debian
reported the visible SSH trust prompt as a frame, while the test required an
alert. It also exposed that the tunnel-loss GTK scenario trusted the bastion
but not the configured second hop. The prompt selector now accepts either
AT-SPI role, and a shared helper trusts each configured SSH hop. After these
changes, the full PostgreSQL release layer passed all five default GTK
scenarios, and the tunnel-loss/reconnect scenario passed separately. The
original hosted PostgreSQL failure report and log are retained here.

Hosted Fast checks failed before building when Debian's mirror served
`media-types_14.0.0_all.deb` at a size inconsistent with the package index;
installed GTK smoke was skipped as a consequence. This is independent of the
GTK role and two-hop test corrections. In that first hosted run, preflight,
driver TLS, DuckDB, security, supply chain, SonarCloud, harness, ref resolution,
workflow lint and both Flatpak builds passed; driver integration was still
running at the last observation. See the manifest for exact statuses and
hashes. Fresh hosted validation is required on the final follow-up commit.

This PR #159 checkpoint predates the later frozen candidate. It did not
establish installed Arch/Omarchy/Hyprland Wayland acceptance, upgrade/rollback,
Debian/GNOME Wayland acceptance or B3 completion. The later frozen-candidate
results are recorded in the [PR #258 evidence comment](https://github.com/cozyGarage/BookiE/pull/258#issuecomment-6048355227).
PR #258 later passed its 11 required hosted checks, but the Docker driver
integration, TLS, PostgreSQL release, and installed GTK safety jobs were
skipped on the pull-request event. Hosted B4 fixture runs and installed
acceptance therefore remain open. This historical checkpoint does not close
B4 or qualify a release.
