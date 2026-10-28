# Homebrew cask for Snug, tapped from this repository:
#   brew tap hedgertronic/snug https://github.com/hedgertronic/snug
#   brew install --cask hedgertronic/snug/snug
# scripts/build.py --release writes the version and sha256 below for each new download.
cask "snug" do
  version "1.0.0"
  sha256 "d45b4bd67e97d2f02e65be6ed73534504ca804b11c072cc16ecba013f2cf5bb6"

  url "https://github.com/hedgertronic/snug/releases/download/v#{version}/Snug-#{version}.zip"
  name "Snug"
  desc "Screenshots that fit like a glove"
  homepage "https://snugshot.app/"

  livecheck do
    url "https://snugshot.app/appcast.xml"
    strategy :sparkle, &:short_version
  end

  # Snug updates itself with Sparkle.
  auto_updates true
  depends_on macos: ">= :tahoe"

  app "Snug.app"

  zap trash: [
    "~/Library/Application Support/Snug",
    "~/Library/Caches/com.hedgertronic.snug",
    "~/Library/Caches/Snug",
    "~/Library/HTTPStorages/com.hedgertronic.snug",
    "~/Library/Logs/Snug",
    "~/Library/Preferences/com.hedgertronic.snug.plist",
  ]
end
