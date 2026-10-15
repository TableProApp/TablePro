Name:           tablepro
Version:        0.1.0
Release:        1%{?dist}
Summary:        Work with your databases
# build-aux/update-third-party-licenses.sh writes this line from the
# crates the binaries link.
License:        AGPL-3.0-or-later AND Apache-2.0 AND BSD-3-Clause AND CDLA-Permissive-2.0 AND ISC AND MIT AND Unicode-3.0 AND Zlib
URL:            https://tablepro.app
Source0:        https://github.com/TableProApp/TablePro/releases/download/linux-v%{version}/%{name}-%{version}.tar.xz
Source1:        https://github.com/TableProApp/TablePro/releases/download/linux-v%{version}/%{name}-%{version}-vendor.tar.xz

ExclusiveArch:  %{rust_arches}

BuildRequires:  cargo >= 1.98
BuildRequires:  rust >= 1.98
BuildRequires:  cargo-rpm-macros >= 26
BuildRequires:  meson >= 1.4
BuildRequires:  gcc
BuildRequires:  clang-devel
BuildRequires:  gettext
BuildRequires:  desktop-file-utils
BuildRequires:  /usr/bin/appstreamcli
BuildRequires:  /usr/bin/glib-compile-schemas
BuildRequires:  /usr/bin/xmllint
BuildRequires:  pkgconfig(glib-2.0) >= 2.88
BuildRequires:  pkgconfig(gio-2.0) >= 2.88
BuildRequires:  pkgconfig(gtk4) >= 4.22
BuildRequires:  pkgconfig(libadwaita-1) >= 1.9
BuildRequires:  pkgconfig(gtksourceview-5) >= 5.18
# The SQLite driver and the query history link the system library
# (sqlx's sqlite-unbundled) rather than a copy in the binary, so SQLite
# security fixes arrive through Fedora's sqlite package.
BuildRequires:  pkgconfig(sqlite3) >= 3.46
BuildRequires:  pkgconfig(mit-krb5-gssapi)
# %%check: the gtk suite opens windows on a display and owns D-Bus names,
# and the catalogue test needs a real locale.
BuildRequires:  /usr/bin/xvfb-run
BuildRequires:  /usr/bin/xauth
BuildRequires:  /usr/bin/dbus-run-session
BuildRequires:  adwaita-icon-theme
BuildRequires:  glibc-langpack-en
BuildRequires:  openssh-clients

Requires:       hicolor-icon-theme
# SSH tunnels run through the system OpenSSH client.
Requires:       openssh-clients

%description
TablePro connects to PostgreSQL, MySQL, SQLite, SQL Server and ClickHouse.
Browse tables, edit rows in place, run SQL with syntax highlighting, and
reach servers behind an SSH bastion.

%prep
%autosetup -a1
%cargo_prep -v vendor
# Some crates ship executable .rs files, whose leading #![...] attribute
# brp-mangle-shebangs then rejects as a shebang in the debugsource package.
find vendor -type f -name '*.rs' -perm /111 -exec chmod a-x {} +

%build
# Cargo starts a rustc per CPU, and under Fedora's RUSTFLAGS (one codegen
# unit, full debuginfo) one rustc of the app takes several GB, so the
# jobs are also capped at one per 4 GB. %%check builds the tests the same.
%constrain_build -m 4096
export CARGO_BUILD_JOBS=%{_smp_build_ncpus}
# Fedora's rustc runs out of 8 GB in the release profile's fat LTO link of
# this binary; thin LTO fits a builder. %%check repeats it, since meson
# test rebuilds the binary first.
export CARGO_PROFILE_RELEASE_LTO=thin
%meson -Dprofile=default -Dkerberos=true
%meson_build
# The app's manifest rather than the workspace, so the test-only crates
# are left out.
(cd crates/app && %{cargo_license}) > LICENSE.dependencies
(cd crates/app && %{cargo_vendor_manifest})

%install
%meson_install

%check
# The same RUSTFLAGS and LTO as %%build, or cargo rebuilds every crate.
%set_build_flags
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_BUILD_JOBS=%{_smp_build_ncpus}
desktop-file-validate %{buildroot}%{_datadir}/applications/app.tablepro.TablePro.desktop
appstreamcli validate --no-net %{buildroot}%{_metainfodir}/app.tablepro.TablePro.metainfo.xml
# %%meson_test expands to lines of its own; shrink joins them to this one.
%{shrink:xvfb-run -a dbus-run-session -- %meson_test}

%files
%license LICENSE LICENSE.dependencies crates/app/cargo-vendor.txt
%doc README.md
%{_bindir}/tablepro
%{_libexecdir}/tablepro-askpass
%{_datadir}/applications/app.tablepro.TablePro.desktop
%{_datadir}/dbus-1/services/app.tablepro.TablePro.service
%{_datadir}/glib-2.0/schemas/app.tablepro.TablePro.gschema.xml
%{_datadir}/icons/hicolor/scalable/apps/app.tablepro.TablePro.svg
%{_datadir}/icons/hicolor/symbolic/apps/app.tablepro.TablePro-symbolic.svg
%{_datadir}/licenses/app.tablepro.TablePro/
%{_mandir}/man1/tablepro.1*
%{_metainfodir}/app.tablepro.TablePro.metainfo.xml

%changelog
* Wed Oct 14 2026 TablePro Authors <hello@tablepro.app> - 0.1.0-1
- First package
