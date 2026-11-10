project(
  'tablepro',
  'rust',
  version: '0.1.0-beta.3',
  meson_version: '>= 1.7',
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

# GNOME 50 floor; see docs/decisions/0015-gnome-50-platform-floor.md.
dependency('glib-2.0', version: '>= 2.88')
dependency('gio-2.0', version: '>= 2.88')
dependency('gtk4', version: '>= 4.22')
dependency('libadwaita-1', version: '>= 1.9')
dependency('gtksourceview-5', version: '>= 5.18')
dependency('sqlite3', version: '>= 3.46')
# glycin, which decodes a value's picture in a sandbox.
dependency('libseccomp')
dependency('lcms2')

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

# A release build always talks to tablepro.app (docs/testing.md, The app against a local stack).
dev_cloud = ['dev_account_url', 'dev_api_url', 'dev_entitlement_keys']
foreach name : dev_cloud
  if get_option(name) != '' and profile != 'development'
    error(name + ' is for -Dprofile=development only')
  endif
endforeach
cargo_env.set('TABLEPRO_DEV_ACCOUNT_URL', get_option('dev_account_url'))
cargo_env.set('TABLEPRO_DEV_API_URL', get_option('dev_api_url'))
cargo_env.set('TABLEPRO_DEV_ENTITLEMENT_KEYS', get_option('dev_entitlement_keys'))
cargo_env.set('TABLEPRO_POSTHOG_KEY', get_option('posthog_key'))

subdir('data')
subdir('po')
subdir('crates/app')
subdir('data/completions')
subdir('build-aux')

# `meson devenv` runs cargo against the build tree, where the askpass
# helper sits next to the binary rather than under libexecdir.
devenv = cargo_env
devenv.set('TABLEPRO_LIBEXECDIR', cargo_target_dir / cargo_profile_dir)
meson.add_devenv(devenv)

gnome.post_install(
  glib_compile_schemas: true,
  gtk_update_icon_cache: true,
  update_desktop_database: true,
)

summary({
  'Profile': profile,
  'Application ID': application_id,
  'Version': version,
  'Kerberos': get_option('kerberos'),
  'Flatpak': get_option('flatpak'),
  'Account service': get_option('dev_account_url') == '' ? 'production' : get_option('dev_account_url'),
  'Usage data': get_option('posthog_key') == '' ? 'off' : 'PostHog, on by default',
})
