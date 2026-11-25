# Manual

How to get Frame Deploy from GitHub, run it, update it and fix common problems.

## 1. Get the app

**Option A: download (no tools needed).** Open the [latest release](https://github.com/soleimanmansouri/samsung-frame-deploy/releases/latest), download `FrameDeploy-*-macos-arm64.zip`, unzip it and drag `FrameDeploy.app` into *Applications*. Apple silicon Macs only.

**Option B: build from source with git.** Needs macOS 13+ and the Xcode command line tools (`xcode-select --install`).

```sh
git clone https://github.com/soleimanmansouri/samsung-frame-deploy.git
cd samsung-frame-deploy
./build.sh
open FrameDeploy.app
```

## 2. First launch

1. macOS blocks the app because it is not notarized. Open *System Settings, Privacy & Security*, scroll down and press **Open Anyway**.
2. Allow **Local Network** access when asked. Without it the TV cannot be reached.
3. The app sets up its own Python environment in `~/.frame-deploy/venv` (about a minute, needs internet once).

## 3. Add your Frame

1. Press **Add device...**, then **Scan network**. Frames on your network appear in the list.
2. Click yours, give it a name, press **Add**.
3. **Accept the "Allow" prompt on the TV** within 60 seconds. The pairing token is stored in `~/.frame-deploy/` (readable by you only).

No scan result? Type the IP from the TV under *Settings, General, Network, Network Status*. The Mac and the TV must be on the same network.

Add as many TVs as you like and switch with the picker next to *Deploy*.

## 4. Deploy a picture

- Your pictures live in `~/Pictures/Frame Gallery`. Drop any JPG or PNG there.
- Or type a search ("Monet water lilies") and press **Fetch** to download public-domain art from Wikimedia Commons, with title, artist, date and licence.
- Click a picture, then **Deploy to <TV>**. It appears in Art Mode.

Badges: a green seal means native 16:9. An orange triangle means another ratio. Nothing is ever cropped: newer Frames scale the picture, 2017 Frames show it inside a black matte.

## 5. Command line

```sh
~/.frame-deploy/venv/bin/python frame.py scan
~/.frame-deploy/venv/bin/python frame.py add "Living Room" 192.168.1.50
~/.frame-deploy/venv/bin/python frame.py devices
~/.frame-deploy/venv/bin/python frame.py fetch "Hokusai wave"
~/.frame-deploy/venv/bin/python frame.py deploy "picture.jpg" --device "Living Room"
```

## 6. Update

Downloaded the app: get the new zip from Releases and replace the old app. Cloned the repo:

```sh
cd samsung-frame-deploy
git pull
./build.sh
```

Your TVs and pictures are kept: they live in `~/.frame-deploy` and `~/Pictures/Frame Gallery`, not in the app.

## 7. Report a problem or contribute

- Bug or unsupported model: open an [issue](https://github.com/soleimanmansouri/samsung-frame-deploy/issues) with your TV model and the error text. Do not paste your TV's IP address or token files.
- Fix or feature: fork the repo, make a branch (`git switch -c my-fix`), commit, push and open a pull request.

## 8. Troubleshooting

| Symptom | Fix |
| --- | --- |
| Pairing closes at once, no prompt on the TV | TV: *Settings, General, External Device Manager, Device Connection Manager*. Set **Access Notification** to *First Time Only*, delete old entries in **Device List**. |
| "Local network" errors or nothing found | *System Settings, Privacy & Security, Local Network*: enable Frame Deploy. |
| Deploy error on an old Frame | Update to the latest version. 2017 Frames need the websocket upload, which is built in. |
| TV screen stays black after testing | Check Art Mode brightness and motion sensor on the TV, press power on the remote, or unplug it for 30 seconds. |
| Python setup failed | Run `xcode-select --install`, then start the app again. |
| Start over | Quit the app and delete `~/.frame-deploy`. |
