#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint printing_ffi.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'printing_ffi'
  s.version          = '0.0.1'
  s.summary          = 'A Flutter FFI plugin for direct printer communication.'
  s.description      = <<-DESC
A Flutter plugin for direct printer communication using native FFI bindings for macOS, Windows, and Linux.
                       DESC
  s.homepage         = 'https://github.com/Shreemanarjun/printing_ffi' 
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Shreeman Arjun Sahu' => 'shreemanarjunsahu@gmail.com' }

  # This will ensure the source files in Classes/ are included in the native
  # builds of apps using this FFI plugin. Podspec does not support relative
  # paths, so Classes contains a forwarder C file that relatively imports
  # `../src/*` so that the C sources can be shared among all target platforms.
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '14.0'

  # The payload does not exist at pod install / Xcode build planning time.
  # Copy it explicitly after generation, rather than having Copy Resources
  # snapshot the placeholder bundle before the native build fills it.
  s.preserve_paths = 'Resources/CupsRuntime.bundle'
  s.frameworks = 'Foundation', 'CoreFoundation', 'Security', 'SystemConfiguration'
  s.libraries = 'z', 'iconv', 'resolv'
  stage = '$(PODS_TARGET_SRCROOT)/.build/arm64'
  s.script_phases = [{
    :name => 'Build bundled iOS CUPS and DNP drivers',
    :script => 'bash "${PODS_TARGET_SRCROOT}/../tool/ios/build.sh"',
    :execution_position => :before_compile,
  }, {
    # Build the on-device CUPS daemon .deb from the app build (printing_ffi is in
    # pub-cache, not a separate checkout), so the app can ship + install it.
    :name => 'Build on-device CUPS daemon package',
    :script => 'bash "${PODS_TARGET_SRCROOT}/../tool/ios/daemon/build_daemon_deb.sh"',
    :execution_position => :before_compile,
  }, {
    :name => 'Embed bundled iOS CUPS runtime',
    :script => 'bash "${PODS_TARGET_SRCROOT}/../tool/ios/embed_runtime.sh"',
    :execution_position => :after_compile,
    :output_files => [
      '$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/CupsRuntime.bundle',
      '$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/com.fotobox.cupsd.deb',
    ],
    :always_out_of_date => '1',
  }]
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SUPPORTED_PLATFORMS' => 'iphoneos',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) PRINTING_FFI_IOS=1 _DARWIN_C_SOURCE=1',
    'HEADER_SEARCH_PATHS' => "$(inherited) #{stage}/include",
    'LIBRARY_SEARCH_PATHS' => "$(inherited) #{stage}/lib",
    'OTHER_LDFLAGS' => '$(inherited) -lcups -lcupsimage',
  }
end
