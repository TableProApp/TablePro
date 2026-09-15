project(
  'tablepro',
  'rust',
  version: '0.1.0',
  meson_version: '>= 1.4',
  license: 'AGPL-3.0-or-later',
  license_files: 'LICENSE',
)

i18n = import('i18n')
gnome = import('gnome')

base_id = 'app.tablepro.TablePro'
profile = get_option('profile')

git = find_program('git', required: false)

if profile == 'development'
  application_id = base_id + '.Devel'
  vcs_tag = ''
  if git.found()
    vcs_tag = run_command(git, 'rev-parse', '--short', 'HEAD', check: false).stdout().strip()
  endif
  if vcs_tag == ''
    version_suffix = '-devel'
  else
    version_suffix = '-' + vcs_tag
  endif
else
  application_id = base_id
  version_suffix = ''
endif

version = meson.project_version() + version_suffix

# Floors match what the crates link today. W8-16 raises them with the
# GNOME 50 bump.
dependency('gtk4', version: '>= 4.14')
dependency('libadwaita-1', version: '>= 1.6')
dependency('gtksourceview-5', version: '>= 5.12')
dependency('sqlite3', version: '>= 3.46')

if get_option('kerberos')
  dependency('mit-krb5-gssapi')
endif

cargo = find_program('cargo')
find_program('glib-compile-schemas')

prefix = get_option('prefix')
bindir = prefix / get_option('bindir')
libexecdir = prefix / get_option('libexecdir')
localedir = prefix / get_option('localedir')

cargo_home = meson.project_build_root() / 'cargo-home'
cargo_target_dir = meson.project_build_root() / 'cargo-target'

cargo_env = environment()
cargo_env.set('CARGO_HOME', cargo_home)
cargo_env.set('CARGO_TARGET_DIR', cargo_target_dir)
cargo_env.set('TABLEPRO_APP_ID', application_id)
cargo_env.set('TABLEPRO_VERSION', version)
cargo_env.set('TABLEPRO_PROFILE', profile)
cargo_env.set('TABLEPRO_LOCALEDIR', localedir)
cargo_env.set('TABLEPRO_LIBEXECDIR', libexecdir)

subdir('data')
subdir('po')
subdir('crates/app')

# `meson devenv` runs cargo against the build tree, where the askpass
# helper sits next to the binary rather than under libexecdir.
devenv = cargo_env
devenv.set('TABLEPRO_LIBEXECDIR', cargo_target_dir / cargo_profile_dir)
meson.add_devenv(devenv)

gnome.post_install(
  gtk_update_icon_cache: true,
  update_desktop_database: true,
)

summary({
  'Profile': profile,
  'Application ID': application_id,
  'Version': version,
  'Kerberos': get_option('kerberos'),
  'Flatpak': get_option('flatpak'),
})
