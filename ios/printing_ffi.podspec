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

  s.resources = 'Resources/CupsRuntime.bundle'
  s.frameworks = 'Foundation', 'CoreFoundation', 'Security', 'SystemConfiguration'
  s.libraries = 'z', 'iconv', 'resolv'
  stage = '$(PODS_TARGET_SRCROOT)/.build/arm64'
  s.script_phase = {
    :name => 'Build bundled iOS CUPS and DNP drivers',
    :script => 'bash "${PODS_TARGET_SRCROOT}/../tool/ios/build.sh"',
    :execution_position => :before_compile,
  }
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SUPPORTED_PLATFORMS' => 'iphoneos',
    'GCC_PREPROCESSOR_DEFINITIONS' => '$(inherited) PRINTING_FFI_IOS=1',
    'HEADER_SEARCH_PATHS' => "$(inherited) #{stage}/include",
    'LIBRARY_SEARCH_PATHS' => "$(inherited) #{stage}/lib",
    'OTHER_LDFLAGS' => '$(inherited) -lcups -lcupsimage',
  }
end
