cask "crisp" do
  version "1.5.1"
  sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  url "https://github.com/didriksg/Crisp/releases/download/v#{version}/Crisp.dmg"
  name "Crisp"
  desc "External monitor control for macOS"
  homepage "https://crispmac.app/"

  auto_updates true

  # Fixture sentinel: this unrelated comment must survive byte-for-byte.
  app "Crisp.app"

  zap trash: "~/Library/Preferences/com.crisp.app.plist"
end
