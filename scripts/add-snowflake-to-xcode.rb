#!/usr/bin/env ruby
# Adds the SnowflakeDriverPlugin .tableplugin target to the Xcode project,
# cloning the BigQueryDriverPlugin target's build settings so the bundle is
# produced and signed identically. Idempotent.
# Usage: ruby scripts/add-snowflake-to-xcode.rb

require 'xcodeproj'

project_path = File.join(__dir__, '..', 'TablePro.xcodeproj')
proj = Xcodeproj::Project.open(project_path)

TARGET_NAME = 'SnowflakeDriverPlugin'
PLUGIN_DIR = 'Plugins/SnowflakeDriverPlugin'
BUNDLE_ID = 'com.TablePro.SnowflakeDriverPlugin'
PRINCIPAL_CLASS = '$(PRODUCT_MODULE_NAME).SnowflakePlugin'

if proj.targets.any? { |t| t.name == TARGET_NAME }
  puts "⏭️  Target #{TARGET_NAME} already exists"
  exit 0
end

template = proj.targets.find { |t| t.name == 'BigQueryDriverPlugin' }
abort 'BigQueryDriverPlugin target not found (needed as a template)' unless template

framework_ref = proj.files.find { |f| f.display_name == 'TableProPluginKit.framework' }
abort 'TableProPluginKit.framework reference not found' unless framework_ref

target = proj.new_target(:bundle, TARGET_NAME, :osx, '14.0', proj.products_group, :swift)

# Mirror the product wrapper so build/CI scripts find <target>.tableplugin
product = target.product_reference
product.path = "#{TARGET_NAME}.tableplugin"
product.explicit_file_type = 'wrapper.cfbundle'
product.include_in_index = '0'

# Clone the template's build settings, then override identity-specific keys
template.build_configurations.each do |template_cfg|
  cfg = target.build_configurations.find { |c| c.name == template_cfg.name }
  next unless cfg
  settings = template_cfg.build_settings.dup
  settings['INFOPLIST_FILE'] = "#{PLUGIN_DIR}/Info.plist"
  settings['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
  settings['INFOPLIST_KEY_NSPrincipalClass'] = PRINCIPAL_CLASS
  settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  cfg.build_settings = settings
end

# Explicit (non-synchronized) group holding the plugin sources
group = proj.main_group.find_subpath(PLUGIN_DIR, true)
group.set_source_tree('<group>')
group.path = PLUGIN_DIR

source_files = Dir.glob(File.join(__dir__, '..', PLUGIN_DIR, '*.swift')).sort
abort 'No Swift sources found for the Snowflake plugin' if source_files.empty?

refs = source_files.map { |path| group.new_reference(File.basename(path)) }
target.add_file_references(refs)

# new_target(:osx) auto-links Cocoa.framework; the other driver plugins link
# only TableProPluginKit, so clear the phase first to match them exactly.
target.frameworks_build_phase.files_references.dup.each do |ref|
  target.frameworks_build_phase.remove_file_reference(ref)
end
# new_target also creates a stray Cocoa.framework file reference; drop it so the
# project stays identical to the other hand-authored plugin targets.
proj.files.select { |f| f.display_name == 'Cocoa.framework' }.each(&:remove_from_project)
target.frameworks_build_phase.add_file_reference(framework_ref)

proj.save

puts "🎉 Added #{TARGET_NAME} target with #{refs.length} source files"
puts '   Sources:'
refs.each { |r| puts "     - #{r.path}" }
