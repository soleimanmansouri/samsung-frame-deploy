"""Frame TV art deploy core: list gallery, fetch Met public-domain art, upload to Art Mode.

Usage:
  python frame.py list
  python frame.py fetch "van gogh sunflowers" # saves first Wikimedia Commons hit + licence .txt
  python frame.py deploy "<file in gallery>" [--device NAME]  # uploads and selects it on the TV
  python frame.py devices                     # JSON: {"active": name, "devices": [...]}
  python frame.py info                       # JSON details of every gallery picture
  python frame.py enrich                     # fill title/artist/date of fetched pictures from Wikimedia
  python frame.py scan                       # JSON list of Frame TVs found on the local /24
  python frame.py add NAME IP                 # pair a new Frame (accept the prompt on the TV)
  python frame.py use NAME                    # set the active device
  python frame.py remove NAME
"""

import json
import os
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

from samsungtvws import SamsungTVWS
from samsungtvws.exceptions import ResponseError

CONF_DIR = Path.home() / ".frame-deploy"
DEVICES = CONF_DIR / "devices.json"
GALLERY = Path.home() / "Pictures" / "Frame Gallery"
COMMONS = "https://commons.wikimedia.org/w/api.php"
UA = {"User-Agent": "frame-deploy/0.1 (personal use)"}  # Commons rejects blank agents
IMAGE_TYPES = {".jpg": "JPEG", ".jpeg": "JPEG", ".png": "PNG"}


def gallery_files():
    return sorted(p for p in GALLERY.iterdir() if p.suffix.lower() in IMAGE_TYPES)


def strip_html(v):
    return re.sub(r"\s+", " ", re.sub(r"<[^>]+>", "", v or "")).strip()[:80]


def clean_date(v):
    v = re.sub(r"date QS:.*", "", v or "").strip()
    return re.sub(r"^(\d{4}-\d{2}-\d{2}) \d.*", r"\1", v) or "unknown"


def write_sidecar(img, title, artist, date, licence, source):
    img.with_suffix(".txt").write_text(
        f"Title: {title}\nArtist: {artist}\nDate: {date}\nLicence: {licence}\nSource: {source}\n"
    )


def commons_fields(meta):
    g = lambda k: strip_html(meta.get(k, {}).get("value"))
    return (g("ObjectName"), g("Artist") or "unknown", clean_date(g("DateTimeOriginal") or g("DateTime")),
            g("LicenseShortName") or "unknown")


def commons_fetch(query):
    # ponytail: first hit only, no pagination or picker. Licence saved beside the image.
    params = {
        "action": "query", "format": "json", "generator": "search",
        "gsrsearch": f"filetype:bitmap {query}", "gsrnamespace": 6, "gsrlimit": 10,
        "prop": "imageinfo", "iiprop": "url|extmetadata", "iiurlwidth": 1600,
    }
    req = urllib.request.Request(f"{COMMONS}?{urllib.parse.urlencode(params)}", headers=UA)
    pages = json.load(urllib.request.urlopen(req, timeout=30)).get("query", {}).get("pages", {})
    for page in pages.values():
        info = (page.get("imageinfo") or [{}])[0]
        meta = info.get("extmetadata", {})
        if not info.get("thumburl"):
            continue
        title = page["title"].removeprefix("File:")
        stem = re.sub(r"[^A-Za-z0-9._-]+", "_", Path(title).stem)[:80]
        dest = GALLERY / f"commons_{stem}.jpg"
        req = urllib.request.Request(info["thumburl"], headers=UA)
        dest.write_bytes(urllib.request.urlopen(req, timeout=60).read())
        name, artist, date, licence = commons_fields(meta)
        write_sidecar(dest, name or Path(title).stem, artist, date, licence, info.get("descriptionurl"))
        return dest
    raise SystemExit(f"no image found for {query!r}")


def load_devices():
    if not DEVICES.exists():
        save_devices({"active": "", "devices": []})
    return json.loads(DEVICES.read_text())


def save_devices(conf):
    CONF_DIR.mkdir(mode=0o700, exist_ok=True)
    os.chmod(CONF_DIR, 0o700)  # holds TV pairing tokens: owner only
    DEVICES.write_text(json.dumps(conf, indent=2))
    os.chmod(DEVICES, 0o600)


def find_device(conf, name=None):
    name = name or conf["active"]
    if not name:
        raise SystemExit("no device set up yet: add your Frame first")
    for d in conf["devices"]:
        if d["name"] == name:
            return d
    raise SystemExit(f"unknown device {name!r}; known: {[d['name'] for d in conf['devices']]}")


def tv(name=None):
    d = find_device(load_devices(), name)
    return SamsungTVWS(d["host"], port=8002, token_file=d["token_file"], timeout=30).art()


def scan_network():
    # ponytail: sweeps the local /24 for the TV REST port (8001); no SSDP. Other subnets: use `add NAME IP`.
    import socket
    from concurrent.futures import ThreadPoolExecutor

    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
        s.connect(("10.255.255.255", 1))  # no packet is sent; just picks the LAN interface
        mine = s.getsockname()[0]
    base = mine.rsplit(".", 1)[0]

    def probe(ip):
        try:
            req = urllib.request.Request(f"http://{ip}:8001/api/v2/")
            d = json.load(urllib.request.urlopen(req, timeout=1.5)).get("device", {})
        except Exception:
            return None
        if d.get("FrameTVSupport") != "true":
            return None
        return {"ip": ip, "name": d.get("name", ip), "model": d.get("modelName", "?")}

    with ThreadPoolExecutor(64) as pool:
        return [r for r in pool.map(probe, (f"{base}.{i}" for i in range(1, 255))) if r]


def add_device(name, host):
    conf = load_devices()
    if any(d["name"] == name for d in conf["devices"]):
        raise SystemExit(f"device {name!r} already exists")
    token_file = str(CONF_DIR / f"token-{re.sub(r'[^A-Za-z0-9_-]+', '_', name)}.txt")
    ws = SamsungTVWS(host, port=8002, token_file=token_file, timeout=60)
    try:
        model = ws.rest_device_info().get("device", {}).get("modelName", "?")
    except Exception as e:
        raise SystemExit(f"no TV answering at {host}: {e}")
    print(f"found {model}; accept the 'Allow' prompt on the TV now...", flush=True)
    if not ws.art().supported():  # REST flag only; does not pair
        raise SystemExit(f"{model} at {host} does not support Art Mode (not a Frame?)")
    try:
        ws.open()  # remote channel: shows the 'Allow' prompt on the TV and saves the token
    except Exception as e:
        raise SystemExit(f"{model} did not accept the connection (prompt not accepted in 60 s?): {e!r}")
    ws.close()
    try:
        ws.art().get_api_version()  # Art channel must answer too, or deploy would hang later
    except Exception as e:
        raise SystemExit(f"paired, but the Art channel does not answer: {e!r}")
    if os.path.exists(token_file):
        os.chmod(token_file, 0o600)
    conf["devices"].append({"name": name, "host": host, "token_file": token_file})
    conf["active"] = name
    save_devices(conf)
    return model


def read_sidecar(img):
    """Fields from the .txt beside a picture; old-format files had the Commons file name on line 1."""
    txt = img.with_suffix(".txt")
    out = {}
    if txt.exists():
        for i, line in enumerate(txt.read_text().splitlines()):
            k, _, v = line.partition(": ")
            if k in ("Title", "Artist", "Date", "Licence", "Source") and v:
                out[k] = v
            elif i == 0 and line:
                out["Title"] = re.sub(r"\.\w+$", "", line)
    return out


def guess_from_name(stem):
    """'Artist; Title; 1954' or 'Title - Artist' (hand-added files); anything else = title only."""
    parts = stem.split("; ")
    if len(parts) == 3:
        return {"Artist": parts[0], "Title": parts[1], "Date": parts[2]}
    if " - " in stem and not stem.startswith("commons_"):
        title, artist = stem.rsplit(" - ", 1)
        return {"Title": title, "Artist": artist}
    return {"Title": stem}


RATIOS = {"16:9": 16 / 9, "4:3": 4 / 3, "3:2": 3 / 2, "5:4": 5 / 4, "1:1": 1, "16:10": 1.6, "2:1": 2, "21:9": 21 / 9, "3:4": 3 / 4, "2:3": 2 / 3}


def gallery_info():
    import subprocess

    rows = []
    for p in gallery_files():
        d = {**guess_from_name(p.stem), **read_sidecar(p)}
        out = subprocess.run(["/usr/bin/sips", "-g", "pixelWidth", "-g", "pixelHeight", str(p)],
                             capture_output=True, text=True).stdout
        w, h = (int(m.group(1)) if (m := re.search(rf"{k}: (\d+)", out)) else 0 for k in ("pixelWidth", "pixelHeight"))
        r = w / h if h else 0
        label = next((n for n, v in RATIOS.items() if abs(r - v) < 0.03 * v), f"{r:.2f}:1")
        rows.append({"file": p.name, "title": d.get("Title", p.stem), "artist": d.get("Artist", "unknown"),
                     "date": clean_date(d.get("Date")), "licence": d.get("Licence", ""), "source": d.get("Source", ""),
                     "width": w, "height": h, "ratio": label, "native": label == "16:9"})
    return rows


def enrich():
    """One-off: rewrite old sidecars with Title/Artist/Date taken from the Commons page named in Source."""
    done = 0
    for p in gallery_files():
        old = read_sidecar(p)
        if "Date" in old or "Source" not in old:
            continue
        name = urllib.parse.unquote(old["Source"].rsplit("/File:", 1)[-1])
        params = {"action": "query", "format": "json", "titles": f"File:{name}", "prop": "imageinfo", "iiprop": "extmetadata"}
        req = urllib.request.Request(f"{COMMONS}?{urllib.parse.urlencode(params)}", headers=UA)
        pages = json.load(urllib.request.urlopen(req, timeout=30)).get("query", {}).get("pages", {})
        meta = next(iter((next(iter(pages.values()), {}).get("imageinfo") or [{}])), {}).get("extmetadata", {})
        n, a, d, lic = commons_fields(meta)
        write_sidecar(p, n or old.get("Title", p.stem),
                      a if a != "unknown" else old.get("Artist", "unknown"), d, old.get("Licence", lic), old["Source"])
        done += 1
    return done


def prepare(path):
    """sRGB JPEG bytes, whole picture, downsized to fit 3840x2160 (never cropped, never upscaled)."""
    import subprocess, tempfile

    def sips(*args):
        return subprocess.run(["/usr/bin/sips", *args], capture_output=True, text=True, check=True).stdout

    info = sips("-g", "pixelWidth", "-g", "pixelHeight", str(path))
    w, h = (int(re.search(rf"{k}: (\d+)", info).group(1)) for k in ("pixelWidth", "pixelHeight"))
    scale = min(3840 / w, 2160 / h, 1)
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "out.jpg"
        sips("-s", "format", "jpeg", "-s", "formatOptions", "92",
             "-m", "/System/Library/ColorSync/Profiles/sRGB Profile.icc",
             "--resampleHeightWidth", str(round(h * scale)), str(round(w * scale)), str(path), "--out", str(out))
        return out.read_bytes()


def deploy(path, device=None):
    path = Path(path)
    if not path.is_absolute():
        path = GALLERY / path
    if path.suffix.lower() not in IMAGE_TYPES:
        raise SystemExit(f"unsupported file type: {path.name}")
    file_type = "JPEG"  # prepare() always outputs JPEG
    art = tv(device)
    try:
        content_id = art.upload(prepare(path), matte="none", file_type=file_type)
    except ResponseError:
        # Older Frames (e.g. 2017 LS003) reject the socket upload with error -1 but accept the
        # websocket-binary one, which the library only uses for "api 0.97". Force it.
        # They also cannot scale a non-16:9 picture and refuse to show one uploaded with a matte,
        # so: upload plain, show it, then apply a black matte (the TV letterboxes it itself).
        art.get_api_version = lambda: "0.97"
        content_id = art.upload(prepare(path), matte="none", file_type=file_type)
        art.select_image(content_id, show=True)
        art.change_matte(content_id, "modern_black")
        return content_id
    art.select_image(content_id, show=True)
    return content_id


if __name__ == "__main__":
    GALLERY.mkdir(parents=True, exist_ok=True)
    argv = sys.argv[1:]
    device = argv.pop(argv.index("--device") + 1) if "--device" in argv else None
    if "--device" in argv:
        argv.remove("--device")
    cmd, arg, arg2 = (argv + [None, None, None])[:3]
    if cmd == "list":
        for p in gallery_files():
            print(p.name)
    elif cmd == "fetch" and arg:
        print("saved", commons_fetch(arg))
    elif cmd == "deploy" and arg:
        print("deployed, content id", deploy(arg, device))
    elif cmd == "info":
        print(json.dumps(gallery_info()))
    elif cmd == "enrich":
        print("enriched", enrich(), "sidecars")
    elif cmd == "scan":
        print(json.dumps(scan_network()))
    elif cmd == "devices":
        print(json.dumps(load_devices()))
    elif cmd == "add" and arg and arg2:
        print("added", arg, add_device(arg, arg2))
    elif cmd == "use" and arg:
        conf = load_devices()
        find_device(conf, arg)
        conf["active"] = arg
        save_devices(conf)
        print("active device:", arg)
    elif cmd == "remove" and arg:
        conf = load_devices()
        find_device(conf, arg)
        conf["devices"] = [d for d in conf["devices"] if d["name"] != arg]
        if conf["active"] == arg:
            conf["active"] = conf["devices"][0]["name"] if conf["devices"] else ""
        save_devices(conf)
        print("removed", arg)
    else:
        print(__doc__)
