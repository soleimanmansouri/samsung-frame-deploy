# Samsung Frame Deploy

**Put art on your Samsung The Frame TV from your Mac.** Pick a picture, choose a TV, press *Deploy*: it lands in Art Mode with the right aspect ratio. Works with several Frames, including **older 2017 Frames (LS003)** that most tools fail on.

A native macOS app (SwiftUI) on top of a small Python core ([samsungtvws](https://github.com/xchwarze/samsung-tv-ws-api)).

**[Download the app (macOS, Apple silicon)](https://github.com/soleimanmansouri/samsung-frame-deploy/releases/latest)**

## Features

- **Multiple TVs.** *Add device* scans your network for Frames, pairs with one click (accept the prompt on the TV) and remembers each TV. Switch targets from a picker.
- **Search public-domain art.** Type "Monet water lilies" and fetch from Wikimedia Commons. Title, artist, date and licence are saved with every picture.
- **Aspect ratio you can see.** Every picture shows its ratio: a green seal for native 16:9, an orange triangle for anything else, plus size, artist, date and licence in a detail panel.
- **Never crops.** The whole picture is deployed, converted to sRGB and downsized to fit 4K. Newer Frames scale it themselves; older Frames get it inside a black matte.
- **Works on 2017 Frames.** The library's normal upload is rejected by these TVs (`send_image` error -1). Frame Deploy detects that and falls back to the websocket upload, then applies the matte.
- **Copy the app to any Mac.** It is self-contained: on first launch it builds its own Python environment. No project folder needed.
- **Command line too.** `python frame.py scan | add | devices | use | remove | fetch | info | deploy`.

## Install

Requires Apple silicon, macOS 13+, and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/soleimanmansouri/samsung-frame-deploy.git
cd samsung-frame-deploy
./build.sh          # builds FrameDeploy.app
open FrameDeploy.app
```

The app is ad-hoc signed, not notarized. After copying or downloading it, macOS blocks the first launch: open *System Settings, Privacy & Security* and press **Open Anyway** (older macOS: right-click, Open). Allow *Local Network* access when macOS asks, otherwise the TV cannot be reached.

## Use

1. **Add device**, then **Scan network**, click your Frame, **Add**. Accept the *Allow* prompt on the TV.
2. Pick a picture from the gallery (`~/Pictures/Frame Gallery`) or fetch one from Wikimedia Commons.
3. **Deploy to \<your TV\>**.

If the TV never shows the prompt and the connection closes immediately, open *Settings, General, External Device Manager, Device Connection Manager* on the TV, set **Access Notification** to *First Time Only* or *Every Time*, and delete stale entries in the **Device List**.

## Tested on

| TV | Result |
| --- | --- |
| Samsung The Frame 55" 2017 (UE55LS003) | Pairing, upload, black matte, delete: working |
| A newer Frame | Standard upload path; used by the author with an earlier version of the app |

Other models should work through the same library but are untested. Issues and reports are welcome.

## Pictures and licences

Pictures fetched from Wikimedia Commons keep their licence in a `.txt` next to the image. Many are CC BY-SA and need attribution when you share them publicly. You are responsible for the images you put on your TV.

## Credits

Designed by [Soleiman Mansouri](https://github.com/soleimanmansouri), built with [Claude Code](https://claude.com/claude-code). Uses [samsungtvws](https://github.com/xchwarze/samsung-tv-ws-api) and the Wikimedia Commons API.

Not affiliated with or endorsed by Samsung. *Samsung* and *The Frame* are trademarks of Samsung Electronics.

## License

[MIT](LICENSE)
