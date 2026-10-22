cask "overtime" do
  version "1.1.0"
  sha256 "12a4a546c854252f07f15122dac2631f23d766dd496928e2bc6d189269a9c97d"

  url "https://github.com/ivanhernandez-dev/overtime/releases/download/v#{version}/Overtime-#{version}.zip"
  name "Overtime"
  desc "Prevent sleep while Claude Code works, with the lid open or closed"
  homepage "https://github.com/ivanhernandez-dev/overtime"

  livecheck do
    url "https://github.com/ivanhernandez-dev/overtime/releases/latest/download/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Overtime.app"

  uninstall quit: "io.github.ivanhernandez-dev.overtime"

  zap launchctl: "io.github.ivanhernandez-dev.overtime.helper",
      script:    {
        executable: "Overtime.app/Contents/Resources/uninstall.sh",
        args:       ["--purge", "--app-absent"],
      },
      delete:    [
        "/Library/Application Support/Overtime",
        "/Library/Logs/Overtime",
      ],
      trash:     [
        "~/Library/Application Support/Overtime",
        "~/Library/Caches/io.github.ivanhernandez-dev.overtime",
        "~/Library/HTTPStorages/io.github.ivanhernandez-dev.overtime",
        "~/Library/HTTPStorages/io.github.ivanhernandez-dev.overtime.binarycookies",
        "~/Library/Logs/Overtime",
        "~/Library/Preferences/io.github.ivanhernandez-dev.overtime.plist",
        "~/Library/Saved Application State/io.github.ivanhernandez-dev.overtime.savedState",
      ]

  caveats <<~EOS
    Overtime is signed with its own certificate, not an Apple Developer ID, so macOS blocks the first open.
    On macOS 15 or later, open Overtime once, then choose System Settings > Privacy & Security > Open Anyway.
    On macOS 14, Control-click Overtime in Applications and choose Open.
    Updates from Overtime's own updater do not ask again.
  EOS
end
