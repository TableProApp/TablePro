substitutions = configuration_data()
substitutions.set('app-id', application_id)
substitutions.set('bindir', bindir)
substitutions.set('gettext-package', meson.project_name())

desktop_file_in = configure_file(
  input: 'app.tablepro.TablePro.desktop.in.in',
  output: application_id + '.desktop.in',
  configuration: substitutions,
)

desktop_file = i18n.merge_file(
  input: desktop_file_in,
  output: application_id + '.desktop',
  type: 'desktop',
  po_dir: meson.project_source_root() / 'po',
  install: true,
  install_dir: get_option('datadir') / 'applications',
)

metainfo_file_in = configure_file(
  input: 'app.tablepro.TablePro.metainfo.xml.in.in',
  output: application_id + '.metainfo.xml.in',
  configuration: substitutions,
)

metainfo_file = i18n.merge_file(
  input: metainfo_file_in,
  output: application_id + '.metainfo.xml',
  type: 'xml',
  po_dir: meson.project_source_root() / 'po',
  install: true,
  install_dir: get_option('datadir') / 'metainfo',
)

configure_file(
  input: 'app.tablepro.TablePro.service.in',
  output: application_id + '.service',
  configuration: substitutions,
  install: true,
  install_dir: get_option('datadir') / 'dbus-1' / 'services',
)

install_data(
  'icons' / 'hicolor' / 'scalable' / 'apps' / application_id + '.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps',
  rename: application_id + '.svg',
)

install_data(
  'icons' / 'hicolor' / 'symbolic' / 'apps' / 'app.tablepro.TablePro-symbolic.svg',
  install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'symbolic' / 'apps',
  rename: application_id + '-symbolic.svg',
)

install_data(
  meson.project_source_root() / 'LICENSE',
  install_dir: get_option('datadir') / 'licenses' / application_id,
)

if get_option('flatpak') and get_option('kerberos')
  install_data(
    meson.project_source_root() / 'build-aux' / 'flatpak' / 'krb5.conf',
    install_dir: get_option('sysconfdir'),
  )
endif

desktop_file_validate = find_program('desktop-file-validate', required: false)
if desktop_file_validate.found()
  test(
    'validate-desktop',
    desktop_file_validate,
    args: [desktop_file],
    suite: 'data',
  )
endif

appstreamcli = find_program('appstreamcli', required: false)
if appstreamcli.found()
  test(
    'validate-appstream',
    appstreamcli,
    args: ['validate', '--no-net', '--explain', metainfo_file],
    suite: 'data',
  )
endif
