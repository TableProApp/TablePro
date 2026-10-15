python = find_program('python3', required: false)

# Keeps __pycache__ out of the source tree.
python_env = environment()
python_env.set('PYTHONDONTWRITEBYTECODE', '1')

if python.found()
  test(
    'packaging-scripts',
    python,
    args: ['-m', 'unittest', 'discover', '-s', meson.current_source_dir() / 'tests'],
    env: python_env,
    suite: 'packaging',
  )

  test(
    'license-metadata',
    python,
    args: [
      meson.current_source_dir() / 'packaging' / 'license_metadata.py',
      'check',
      '--licenses', meson.project_source_root() / 'data' / 'licenses' / 'third-party.json',
      '--license-file', meson.project_source_root() / 'LICENSE',
      '--copyright', meson.current_source_dir() / 'debian' / 'copyright',
      '--spec', meson.current_source_dir() / 'rpm' / 'tablepro.spec',
    ],
    env: python_env,
    suite: 'packaging',
  )

  test(
    'release-metadata',
    python,
    args: [
      meson.current_source_dir() / 'packaging' / 'check_packaging.py',
      '--source-root', meson.project_source_root(),
      '--version', meson.project_version(),
    ],
    env: python_env,
    suite: 'packaging',
  )
endif
