cask "crisp" do
  version "1.5.1"
  sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  url "https://github.com/didriksg/Crisp/releases/download/v#{version}/Crisp.dmg"
  name "Crisp"
  desc "External monitor control for macOS"
  homepage "https://crispmac.app/"

  auto_updates true

  app "Crisp.app"
  binary "#{appdir}/Crisp.app/Contents/MacOS/crispctl"

  # Fixture sentinel: preserve this block and its spacing.
  zap trash: [
    "~/Library/Caches/com.crisp.app",
    "~/Library/Preferences/com.crisp.app.plist",
  ]
end
