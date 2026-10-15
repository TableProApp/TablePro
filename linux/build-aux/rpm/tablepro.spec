# Line tables, as the .deb keeps, are enough to symbolize a backtrace.
# Full debuginfo adds to what each rustc of the app and the final link
# need, and an 8 GB builder ran out of memory with it.
%global rustflags_debuginfo 1
# Fedora's one codegen unit puts the whole app crate through LLVM as one
# module, and its unit test build passed 7 GB that way. Cargo's release
# default of 16 splits the work, and thin LTO still optimizes across it.
%global rustflags_codegen_units 16

%bcond check 1

Name:           tablepro
Version:        0.1.0
Release:        1%{?dist}
Summary:        Work with your databases
# build-aux/update-third-party-licenses.sh writes this tag from the
# license expression of each crate the binaries link, every choice kept.
License:        %{shrink:
    AGPL-3.0-or-later AND
    CC0-1.0 AND
    Apache-2.0 AND
    (Apache-2.0 OR Apache-2.0 WITH LLVM-exception OR MIT) AND
    (Apache-2.0 OR BSD-2-Clause OR MIT) AND
    (Apache-2.0 OR BSL-1.0) AND
    (Apache-2.0 OR BSL-1.0 OR MIT) AND
    (Apache-2.0 OR ISC) AND
    (Apache-2.0 OR ISC OR MIT) AND
    (Apache-2.0 OR ISC OR MIT-0) AND
    (Apache-2.0 OR MIT) AND
    (Apache-2.0 OR MIT OR Zlib) AND
    BSD-3-Clause AND
    CDLA-Permissive-2.0 AND
    ISC AND
    MIT AND
    (MIT OR Unlicense) AND
    Unicode-3.0 AND
    Zlib
}
URL:            https://tablepro.app
# A pre-release packages as 0.2.0~rc.1 and is tagged linux-v0.2.0-rc.1.
Source0:        https://github.com/TableProApp/TablePro/releases/download/linux-v%{version_no_tilde}/%{name}-%{version_no_tilde}.tar.xz
Source1:        https://github.com/TableProApp/TablePro/releases/download/linux-v%{version_no_tilde}/%{name}-%{version_no_tilde}-vendor.tar.xz

BuildRequires:  cargo >= 1.97
BuildRequires:  rust >= 1.97
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
%if %{with check}
# The gtk suite opens windows on a display and owns D-Bus names, and the
# catalogue test needs a real locale.
BuildRequires:  /usr/bin/xvfb-run
BuildRequires:  /usr/bin/xauth
BuildRequires:  /usr/bin/dbus-run-session
BuildRequires:  adwaita-icon-theme
BuildRequires:  glibc-langpack-en
BuildRequires:  openssh-clients >= 8.7
%endif

Requires:       hicolor-icon-theme
# GTK's renderer loads libGLESv2 at runtime through libepoxy, which aborts
# without it, and neither gtk4 nor libepoxy declares it: GNOME Shell pulls
# it in, but a minimal install, a toolbox or another desktop may not.
%if %{__isa_bits} == 64
Requires:       libGLESv2.so.2()(64bit)
%else
Requires:       libGLESv2.so.2
%endif
# SSH tunnels run through the system OpenSSH client, and every master
# passes ForkAfterAuthentication, which OpenSSH 8.7 added.
Requires:       openssh-clients >= 8.7

%description
TablePro connects to PostgreSQL, MySQL, SQLite, SQL Server and ClickHouse.
Browse tables, edit rows in place, run SQL with syntax highlighting, and
reach servers behind an SSH bastion.

%prep
%autosetup -n %{name}-%{version_no_tilde} -a1
# Writes .cargo/config.toml with the vendored crates as the only source.
# Cargo reads it from the parent of the Meson build directory it runs in.
%cargo_prep -v vendor
# Some crates ship executable .rs files, whose leading #![...] attribute
# brp-mangle-shebangs then rejects as a shebang in the debugsource package.
find vendor -type f -name '*.rs' -perm /111 -exec chmod a-x {} +

%build
# Cargo starts a rustc per CPU, and one rustc of the app takes several
# GB, so the jobs are also capped at one per 4 GB. %%check builds the
# tests the same.
%constrain_build -m 4096
export CARGO_BUILD_JOBS=%{_smp_build_ncpus}
# Fedora's rustc runs out of 8 GB in the release profile's fat LTO link of
# this binary; thin LTO fits a builder. %%check repeats it, since meson
# test rebuilds the binary first.
export CARGO_PROFILE_RELEASE_LTO=thin
%meson -Dprofile=default -Dkerberos=true
%meson_build
# These cover the whole workspace, test-only crates included: cargo2rpm
# 0.4 drops the value of its --package option.
%{cargo_license_summary}
%{cargo_license} > LICENSE.dependencies
%{cargo_vendor_manifest}

%install
%meson_install

%check
desktop-file-validate %{buildroot}%{_datadir}/applications/app.tablepro.TablePro.desktop
appstreamcli validate --no-net %{buildroot}%{_metainfodir}/app.tablepro.TablePro.metainfo.xml
%if %{with check}
# The same RUSTFLAGS and LTO as %%build, or cargo rebuilds every crate.
%set_build_flags
export CARGO_PROFILE_RELEASE_LTO=thin
export CARGO_BUILD_JOBS=%{_smp_build_ncpus}
# %%meson_test expands to lines of its own; shrink joins them to this one.
%{shrink:xvfb-run -a dbus-run-session -- %meson_test}
%endif

%files
%license LICENSE data/licenses/THIRD-PARTY-NOTICE.md
%license LICENSE.dependencies cargo-vendor.txt
%doc README.md
%{_bindir}/tablepro
%{_libexecdir}/tablepro-askpass
%{_datadir}/applications/app.tablepro.TablePro.desktop
%{_datadir}/dbus-1/services/app.tablepro.TablePro.service
%{_datadir}/glib-2.0/schemas/app.tablepro.TablePro.gschema.xml
%{_datadir}/icons/hicolor/scalable/apps/app.tablepro.TablePro.svg
%{_datadir}/icons/hicolor/symbolic/apps/app.tablepro.TablePro-symbolic.svg
%{_mandir}/man1/tablepro.1*
%{_metainfodir}/app.tablepro.TablePro.metainfo.xml

%changelog
* Wed Oct 14 2026 TablePro Authors <hello@tablepro.app> - 0.1.0-1
- First package
