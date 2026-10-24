# Optional prebuilt iOS SDK. The release job supplies its version and checksum.
class Theinsidejob < Formula
  desc "Prebuilt Debug iOS runtime for Button Heist"
  homepage "https://github.com/TheButtonHeist/TheButtonHeist"
  version "RELEASE_VERSION"
  license "Apache-2.0"

  url "https://github.com/TheButtonHeist/TheButtonHeist/releases/download/v#{version}/theinsidejob-#{version}.zip"
  sha256 "PLACEHOLDER"

  depends_on :macos

  # Preserve the SDK's debug symbols and platform-specific binaries.
  skip_clean "libexec"
  preserve_rpath

  def install
    odie "Runtime VERSION does not match the formula" unless (buildpath/"VERSION").read.strip == version.to_s
    (libexec/"TheInsideJob.xcframework").install buildpath.children
  end

  def caveats
    <<~EOS
      Copy the runtime into your app's project directory:
        ditto "#{opt_libexec}/TheInsideJob.xcframework" ./TheInsideJob.xcframework

      Use the same version of the Button Heist CLI.
      Add the copied framework to your app in Debug only.
      Installation: https://github.com/TheButtonHeist/TheButtonHeist/blob/v#{version}/docs/PREBUILT-IOS.md
    EOS
  end

  test do
    runtime = libexec/"TheInsideJob.xcframework"
    assert_equal version.to_s, (runtime/"VERSION").read.strip
    assert_predicate runtime/"Info.plist", :file?
    assert_predicate runtime/"XCODE_VERSION", :file?
    assert_predicate runtime/"Licenses/ButtonHeist.txt", :file?
  end
end
