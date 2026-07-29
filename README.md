# Crisp

Crisp is a free, open-source alternative to BetterDisplay and Lunar: a lightweight, native macOS menu bar app for managing external displays. It's built to feel like an expanded version of the Mac's built-in display menu: the controls you already use, plus the ones it's missing.

The headline feature is proper display scaling for external monitors. macOS only offers sharp, scaled resolutions on its own Retina displays, so most monitors below 4K (like 1080p and 1440p) look either blurry when you scale them up or too small at native resolution. Crisp adds the HiDPI (Retina-style) scaled resolutions macOS leaves out, so everything looks sharp and scaled right. It also handles brightness for external displays (DDC), display arrangement, color, and presets, all from the menu bar.

No Pro tier, no license key. Crisp keeps every feature free, including a few that BetterDisplay and Lunar charge for: disconnecting displays, color adjustments, and auto-brightness that follows your built-in screen.

Fully localized in English and Simplified Chinese (简体中文).

https://github.com/user-attachments/assets/90a62808-84d2-40d6-8563-0b282b9b4b6d

## Install

```sh
brew install --cask didriksg/tap/crisp
```

Or grab `Crisp.dmg` from the [latest release](https://github.com/didriksg/Crisp/releases) and drag Crisp to Applications. The app isn't notarized, so on first launch macOS blocks it: open **System Settings > Privacy & Security**, scroll down, and click **Open Anyway**. (Homebrew installs skip this.)

## Features

- **Sharp, Retina-quality scaling on any display**: HiDPI scaled resolutions that make external monitors crisp instead of blurry or undersized, with automatic HiDPI setup for 1440p and larger displays
- **Brightness everywhere**: hardware DDC control for external monitors with software (gamma) fallback, smooth fades, brightness-key routing to the display under the cursor, and true darkness below the hardware floor
- **Presets**: save named display configurations (resolution, brightness, arrangement) with custom icons and colors, apply with one click, update in place
- **Display arrangement**: drag-to-arrange canvas, main display switching
- **Disconnect displays**: turn physical displays off and back on from the menu, remembered across sleep/wake (Apple Silicon)
- **System toggles**: Dark Mode, Night Shift, and True Tone, one click from the menu bar
- **Color**: ICC profile switching, gamma/contrast/gain image adjustment
- **Virtual displays**: create HiDPI virtual screens
- **Extras**: combined brightness slider, auto brightness following the built-in display, notch hiding, launch at login

## Support

Crisp is free, and every feature stays free. No Pro tier, no license key.

If you'd like to help, my main running cost is the $99/yr Apple Developer Program, Apple's fee for signing and notarizing apps so they install cleanly. Sponsoring helps me cover it and keeps me building:

- [GitHub Sponsors](https://github.com/sponsors/didriksg)
- [爱发电](https://ifdian.net/a/didriksg)

Completely optional. If Crisp saved you a BetterDisplay or Lunar license and you'd like to say thanks, it genuinely helps.

## Requirements

- macOS 15 (Sequoia) or later; on macOS 26 the panel uses the native Liquid Glass backdrop

## Permissions

- **Accessibility** (System Settings > Privacy & Security > Accessibility): needed only for routing the keyboard brightness keys to the display under the cursor. Without it, everything else still works; the brightness keys just control the built-in display as usual.
- **Administrator password** (one time, per monitor): the first time you enable HiDPI for a display, Crisp installs a display override file into `/Library/Displays/Contents/Resources/Overrides`, which macOS protects. Every later toggle is password-free.

## Building

```sh
brew install xcodegen
xcodegen generate   # generates Crisp.xcodeproj from project.yml
open Crisp.xcodeproj
```

For a distributable DMG (Command Line Tools only, no full Xcode) and the fast edit-compile-run dev loop, see [docs/BUILDING.md](docs/BUILDING.md).

## Contributing

Issues and pull requests are welcome. Found a bug, want a feature, or have a display Crisp doesn't handle well? [Open an issue](https://github.com/didriksg/Crisp/issues). PRs are just as welcome, whether it's a fix, a feature, or a new translation.

## Origin

Crisp began as a fork of [FreeDisplay](https://github.com/huberdf/FreeDisplay) and has since been substantially rewritten: a custom panel architecture, native controls throughout, a reworked brightness pipeline, and a full redesign. Thanks to FreeDisplay for the foundation and the spirit: free display management for everyone.

## License

[MIT](LICENSE). Portions derived from FreeDisplay remain available under its MIT terms, reproduced in [ACKNOWLEDGMENTS.md](ACKNOWLEDGMENTS.md).
