require 'xcodeproj'
require 'pathname'

root = Pathname.new(__dir__)
project_path = root + 'AutoSwitch.xcodeproj'
project = Xcodeproj::Project.new(project_path.to_s)
project.instance_variable_set(:@object_version, 77)
project.root_object.attributes['LastSwiftUpdateCheck'] = '2620'
project.root_object.attributes['LastUpgradeCheck'] = '2620'
project.root_object.compatibility_version = 'Xcode 26.0'
project.root_object.attributes['TargetAttributes'] = {}
project.root_object.development_region = 'en'
project.root_object.has_scanned_for_encodings = '0'
project.root_object.known_regions = %w[en Base]
project.root_object.minimized_project_reference_proxies = '0'
project.root_object.preferred_project_object_version = '77'

main_group = project.main_group
app_group = main_group.new_group('AutoSwitch')
app_group.path = 'AutoSwitch'
app_group.source_tree = '<group>'

tests_group = main_group.new_group('AutoSwitchTests')
tests_group.path = 'AutoSwitchTests'
tests_group.source_tree = '<group>'

scripts_group = main_group.new_group('Scripts')
scripts_group.path = 'Scripts'
scripts_group.source_tree = '<group>'

resources_group = app_group.new_group('Resources')
resources_group.path = 'Resources'
resources_group.source_tree = '<group>'
assets_group = resources_group.new_group('Assets.xcassets')
assets_group.path = 'Assets.xcassets'
assets_group.source_tree = '<group>'

app_files = %w[
  App/AutoSwitchApp.swift
  App/AppDelegate.swift
  App/AppState.swift
  App/SingleInstanceCoordinator.swift
  Config/AppRule.swift
  Config/BuiltinSpotlightBundles.swift
  Config/Config.swift
  Config/ConfigStore.swift
  Engine/FocusCoordinator.swift
  Engine/RuleEngine.swift
  Engine/SwitchScheduler.swift
  InputSource/InputSource.swift
  InputSource/InputSourceClassifier.swift
  InputSource/InputSourceController.swift
  Monitor/AppActivationMonitor.swift
  Monitor/FocusEvent.swift
  Monitor/LockScreenMonitor.swift
  Monitor/SpotlightPanelMonitor.swift
  System/DocumentSwitchChecker.swift
  System/LoginItemManager.swift
  System/PermissionsManager.swift
  System/SystemSettingsLinks.swift
  Update/UpdaterController.swift
  UI/AppRulesTab.swift
  UI/Components/InputSourcePicker.swift
  UI/Components/StatusPill.swift
  UI/Components/SystemActionButton.swift
  UI/GeneralTab.swift
  UI/RunningAppsPicker.swift
  UI/SettingsScene.swift
  UI/SpotlightTab.swift
]

test_files = %w[
  RuleEngineTests.swift
  SwitchSchedulerTests.swift
  ConfigStoreTests.swift
  AppStateWindowSizingTests.swift
  FocusCoordinatorTests.swift
]

app_file_refs = app_files.map do |relative|
  ref = app_group.new_file(relative)
  ref.source_tree = '<group>'
  ref
end
info_plist_ref = app_group.new_file('App/Info.plist')
info_plist_ref.source_tree = '<group>'

test_file_refs = test_files.map do |relative|
  ref = tests_group.new_file(relative)
  ref.source_tree = '<group>'
  ref
end

assets_contents = assets_group.new_file('Contents.json')
assets_contents.source_tree = '<group>'

app_target = project.new_target(:application, 'AutoSwitch', :osx, '26.0')
app_target.product_name = 'AutoSwitch'

test_target = project.new_target(:unit_test_bundle, 'AutoSwitchTests', :osx, '26.0')
test_target.product_name = 'AutoSwitchTests'
test_target.add_dependency(app_target)

sparkle_ref = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
sparkle_ref.repositoryURL = 'https://github.com/sparkle-project/Sparkle.git'
sparkle_ref.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '2.6.0' }
project.root_object.package_references << sparkle_ref
sparkle_dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
sparkle_dep.package = sparkle_ref
sparkle_dep.product_name = 'Sparkle'
app_target.package_product_dependencies << sparkle_dep

common_app_settings = {
  'PRODUCT_BUNDLE_IDENTIFIER' => 'dev.autoswitch.AutoSwitch',
  'MARKETING_VERSION' => '0.1.0',
  'CURRENT_PROJECT_VERSION' => '1',
  'SWIFT_VERSION' => '6.0',
  'ENABLE_STRICT_CONCURRENCY' => 'YES',
  'MACOSX_DEPLOYMENT_TARGET' => '26.0',
  'CODE_SIGN_STYLE' => 'Automatic',
  'CODE_SIGN_IDENTITY' => '-',
  'DEVELOPMENT_TEAM' => '',
  'GENERATE_INFOPLIST_FILE' => 'NO',
  'INFOPLIST_FILE' => 'AutoSwitch/App/Info.plist',
  'SWIFT_EMIT_LOC_STRINGS' => 'YES',
  'DEAD_CODE_STRIPPING' => 'YES',
  'ASSETCATALOG_COMPILER_APPICON_NAME' => 'AppIcon'
}

app_target.build_configuration_list.build_configurations.each do |config|
  common_app_settings.each { |k, v| config.build_settings[k] = v }
  config.build_settings['ARCHS'] = 'arm64'
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
  config.build_settings['CODE_SIGN_STYLE'] = 'Manual'
end

%w[AppKit SwiftUI Carbon ApplicationServices ServiceManagement Foundation].each do |framework|
  app_target.add_system_framework(framework)
end

app_target.source_build_phase.files.clear
app_file_refs.each { |ref| app_target.add_file_references([ref]) }
app_target.resources_build_phase.add_file_reference(assets_contents)

common_test_settings = {
  'PRODUCT_BUNDLE_IDENTIFIER' => 'dev.autoswitch.AutoSwitchTests',
  'MARKETING_VERSION' => '0.1.0',
  'CURRENT_PROJECT_VERSION' => '1',
  'SWIFT_VERSION' => '6.0',
  'ENABLE_STRICT_CONCURRENCY' => 'YES',
  'MACOSX_DEPLOYMENT_TARGET' => '26.0',
  'CODE_SIGN_STYLE' => 'Automatic',
  'CODE_SIGN_IDENTITY' => '-',
  'DEVELOPMENT_TEAM' => '',
  'GENERATE_INFOPLIST_FILE' => 'YES',
  'ENABLE_TESTABILITY' => 'YES',
  'TEST_HOST' => '$(BUILT_PRODUCTS_DIR)/AutoSwitch.app/Contents/MacOS/AutoSwitch',
  'BUNDLE_LOADER' => '$(TEST_HOST)'
}

test_target.build_configuration_list.build_configurations.each do |config|
  common_test_settings.each { |k, v| config.build_settings[k] = v }
  config.build_settings['ARCHS'] = 'arm64'
  config.build_settings['CODE_SIGNING_ALLOWED'] = 'NO'
  config.build_settings['CODE_SIGNING_REQUIRED'] = 'NO'
  config.build_settings['CODE_SIGN_STYLE'] = 'Manual'
end

%w[XCTest Foundation].each do |framework|
  test_target.add_system_framework(framework)
end

test_target.source_build_phase.files.clear
test_file_refs.each { |ref| test_target.add_file_references([ref]) }

scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(app_target, test_target, launch_target: true)
scheme.save_as(project_path.to_s, 'AutoSwitch', true)

project.save
