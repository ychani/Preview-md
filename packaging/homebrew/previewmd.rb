# Draft cask for the ychani/homebrew-tap repository (Casks/previewmd.rb).
# On each release: bump `version`, then set `sha256` to the output of
#   shasum -a 256 dist/PreviewMD-<version>.dmg
cask "previewmd" do
  version "0.3.0"
  sha256 "TODO"

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
