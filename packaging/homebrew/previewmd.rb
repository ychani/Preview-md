# Draft cask for the ychani/homebrew-tap repository (Casks/previewmd.rb).
# On each release: bump `version`, then set `sha256` to the output of
#   shasum -a 256 dist/PreviewMD-<version>.dmg
cask "previewmd" do
  version "0.4.0"
  sha256 "98681440cbf57bb042e8fdfecf2cc48c80845d9dbaadbacdc15a2aa827677d7f"

  url "https://github.com/ychani/Preview-md/releases/download/v#{version}/PreviewMD-#{version}.dmg"
  name "PreviewMD"
  desc "Markdown reader with a Quick Look extension"
  homepage "https://github.com/ychani/Preview-md"

  depends_on macos: :ventura # i.e. macOS 13 or later

  app "PreviewMD.app"

  zap trash: [
    "~/Library/Caches/com.narnarlabs.previewmd",
    "~/Library/Containers/com.narnarlabs.previewmd.quicklook",
    "~/Library/HTTPStorages/com.narnarlabs.previewmd",
    "~/Library/Preferences/com.narnarlabs.previewmd.plist",
    "~/Library/Saved Application State/com.narnarlabs.previewmd.savedState",
    "~/Library/WebKit/com.narnarlabs.previewmd",
  ]
end
