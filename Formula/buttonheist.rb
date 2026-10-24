# Homebrew formula for Button Heist CLI + MCP server.
#
# Formula shape lives here. Release artifact names and repository constants
# live in scripts/release-contract.sh. The release workflow renders this into
# TheButtonHeist/homebrew-tap with real SHA-256 values.
#
# Users install with:
#   brew install TheButtonHeist/tap/buttonheist

class Buttonheist < Formula
  desc "Give AI agents full programmatic control of iOS apps"
  homepage "https://github.com/TheButtonHeist/TheButtonHeist"
  version "RELEASE_VERSION"

  url "https://github.com/TheButtonHeist/TheButtonHeist/releases/download/v#{version}/buttonheist-#{version}-macos.tar.gz"
  sha256 "PLACEHOLDER"

  resource "mcp" do
    url "https://github.com/TheButtonHeist/TheButtonHeist/releases/download/v#{version}/buttonheist-mcp-#{version}-macos.tar.gz"
    sha256 "PLACEHOLDER"
  end

  resource "insidejob" do
    url "https://github.com/TheButtonHeist/TheButtonHeist/releases/download/v#{version}/theinsidejob-#{version}.zip"
    sha256 "PLACEHOLDER"
  end

  depends_on :macos
  on_macos do
    depends_on macos: :sonoma
  end
  depends_on arch: :arm64

  def install
    bin.install "buttonheist"
    lib.install "ThePlans" if (buildpath/"ThePlans").exist?
    resource("mcp").stage { bin.install "buttonheist-mcp" }
    resource("insidejob").stage(libexec/"TheInsideJob")
  end

  def caveats
    <<~EOS
      MCP server is installed at:
        #{opt_bin}/buttonheist-mcp

      Prebuilt Debug iOS runtime is installed at:
        #{opt_libexec}/TheInsideJob
      Follow its README.md to weak-link the XCFrameworks and remove them from non-Debug builds.

      Add to your project's .mcp.json:
        {
          "mcpServers": {
            "buttonheist": {
              "command": "#{opt_bin}/buttonheist-mcp",
              "args": []
            }
          }
        }
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/buttonheist --version")
    assert_predicate bin/"buttonheist-mcp", :exist?
    assert_predicate bin/"buttonheist-mcp", :executable?
    assert_predicate lib/"ThePlans/arm64-apple-macosx/release/Modules/ThePlans.swiftinterface", :exist?
    refute_predicate lib/"ThePlans/arm64-apple-macosx/release/Modules/ThePlans.swiftmodule", :exist?
    assert_predicate lib/"ThePlans/arm64-apple-macosx/release/description.json", :exist?
    assert_equal version.to_s, (libexec/"TheInsideJob/VERSION").read.strip
    assert_predicate libexec/"TheInsideJob/XCFrameworks/TheInsideJob.xcframework/Info.plist", :exist?
    assert_predicate libexec/"TheInsideJob/Scripts/integrate-insidejob.sh", :executable?
  end
end
