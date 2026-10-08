Pod::Spec.new do |s|
  s.name             = 'ZebChat'
  s.version          = '1.0.0'
  s.summary          = 'ZebChat live chat for iOS apps.'
  s.description      = <<-DESC
    Embeds the ZebChat visitor chat in your iOS app: a full-screen chat screen, a secure visitor
    session in the Keychain, user identification, screen views and push notifications through
    your own Firebase project. UIKit and WebKit only, no third-party dependencies.
  DESC
  s.homepage         = 'https://www.zebchat.com/docs/mobile-sdk'
  s.license          = { :type => 'MIT', :file => 'LICENSE' }
  s.author           = { 'ZebChat' => 'hello@zebchat.com' }
  # Published from the public mirror of sdks/ios (see PUBLISHING.md). Local consumers use
  # `pod 'ZebChat', :path => '<path to sdks/ios>'`.
  s.source           = { :git => 'https://github.com/techavenuelabs/zebchat-ios.git', :tag => s.version.to_s }

  s.ios.deployment_target = '14.0'
  s.swift_versions   = ['5.9']
  s.frameworks       = 'UIKit', 'WebKit', 'Security'

  s.source_files     = 'Sources/ZebChat/**/*.swift'
  s.resource_bundles = {
    'ZebChat' => [
      'Sources/ZebChat/Resources/*.lproj',
      'Sources/ZebChat/PrivacyInfo.xcprivacy',
    ],
  }
  # Unit tests run through Swift Package Manager (`xcodebuild test`, see .github/workflows/sdk-ios.yml).
end
