require "xcodeproj"

root = File.expand_path("../apps/ios/PrivateMusicWorkspace", __dir__)
project_path = File.join(root, "PrivateMusicWorkspace.xcodeproj")
project = Xcodeproj::Project.new(project_path)

project.root_object.attributes["LastSwiftUpdateCheck"] = "2600"
project.root_object.attributes["LastUpgradeCheck"] = "2600"

target = project.new_target(:application, "PrivateMusicWorkspace", :ios, "17.0")
target.product_name = "Private Music Workspace"

sources_group = project.main_group.new_group("Sources", "Sources")
assets_ref = project.main_group.new_file("Assets.xcassets")

Dir[File.join(root, "Sources/PrivateMusicWorkspace/*.swift")].sort.each do |file|
  ref = sources_group.new_file(file.sub("#{root}/Sources/", ""))
  target.add_file_references([ref])
end

target.resources_build_phase.add_file_reference(assets_ref)

target.build_configurations.each do |config|
  config.build_settings["PRODUCT_BUNDLE_IDENTIFIER"] = "Theo.PrivateMusicWorkspace"
  config.build_settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  config.build_settings["SWIFT_VERSION"] = "6.0"
  config.build_settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.0"
  config.build_settings["TARGETED_DEVICE_FAMILY"] = "1"
  config.build_settings["GENERATE_INFOPLIST_FILE"] = "YES"
  config.build_settings["INFOPLIST_KEY_CFBundleDisplayName"] = "Private Music Workspace"
  config.build_settings["INFOPLIST_KEY_UIApplicationSceneManifest_Generation"] = "YES"
  config.build_settings["INFOPLIST_KEY_UIApplicationSupportsIndirectInputEvents"] = "YES"
  config.build_settings["INFOPLIST_KEY_UIBackgroundModes"] = ["audio", "fetch"]
  config.build_settings["ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME"] = "AccentColor"
  config.build_settings["ASSETCATALOG_COMPILER_APPICON_NAME"] = ""
  config.build_settings["CODE_SIGN_STYLE"] = "Automatic"
  config.build_settings["DEVELOPMENT_TEAM"] = ""
end

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(target)
scheme.set_launch_target(target)
scheme.save_as(project_path, "PrivateMusicWorkspace", true)

project.save
