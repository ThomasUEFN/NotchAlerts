# NotchAlerts

iPhone Dynamic Island–style alerts for the MacBook notch. It runs next to
[boringNotch](https://github.com/TheBoredTeam/boring.notch): alerts grow out of
boringNotch's closed notch and use its shape, size and spring animation.

## Alerts

| iPhone Dynamic Island | NotchAlerts on Mac |
|---|---|
| Low battery 20% / 10% | Low battery at 20%, 10% and 5% |
| Charging | Charger connected (off by default because boringNotch already shows one) |
| Mute switch | Sound muted / unmuted |
| Face ID / Apple Watch unlock | Mac locked / unlocked, also shown on the lock screen |
| AirPods connected + battery | AirPods & Bluetooth headphones with Left / Right / Case battery |
| Accessory connected | USB accessories, external & network drives (connect + eject), displays |
| AirDrop | File received over AirDrop |
| AirPlay | Audio switched to an AirPlay speaker |
| Airplane mode | Wi‑Fi turned on / off |
| No Data | Internet lost / back online |
| Shortcuts | Any Shortcut or script can show an alert (see below) |
| Camera / mic dots | Green / orange dot beside the notch while in use |
| Accessory battery | Magic Mouse / Keyboard / Trackpad connected, and low battery (20/10/5%) |
| iPhone / iPad | Plugged in with a cable |
| Screenshot | Screenshot or screen recording saved, with a thumbnail |
| Focus | Focus mode on / off (needs Full Disk Access) |

### Click an alert

Hovering an alert makes it grow slightly and keeps it open. Clicking it:

| Alert | Click does |
|---|---|
| Muted | Unmutes |
| AirPods / Magic accessory | Opens Bluetooth settings |
| Low battery / Charging | Opens Battery settings |
| Drive connected | Opens the drive in Finder |
| AirDrop | Shows the file in Finder |
| Screenshot | Opens the screenshot |
| iPhone / iPad | Opens Finder (the device is in the sidebar) |
| Display, Wi‑Fi, Internet, AirPlay, Focus | Opens that page in System Settings |
| Shortcut alert | Opens its `url=` link, if it has one |

Alerts without a click action stay fully click-through.

These iPhone alerts have no Mac equivalent: flashlight, Apple Pay, CarKey, NFC,
SIM and Personal Hotspot. Focus mode only works if you give NotchAlerts Full
Disk Access (menu bar icon → Alerts → Focus — Allow Full Disk Access…), and catches manual
changes more reliably than scheduled ones. Screenshot alerts arrive when macOS
saves the file, which is after the floating thumbnail slides away.

## How it works with boringNotch

- **Waits while boringNotch is open.** boringNotch has no "I'm open" API, so
  NotchAlerts assumes it's open from the moment you hover the notch until the
  pointer leaves boringNotch's panel. During that time alerts wait in a queue.
  If boringNotch opens while an alert is showing, the alert collapses and plays
  again once boringNotch closes.
- **Doesn't collide with boringNotch's own pop-ups.** When the power source,
  Low Power Mode or volume changes, boringNotch may show its own pop-up, so
  alerts hold for a moment.
- **Click-through.** The alert window ignores the mouse, so hovering and
  clicking always reach boringNotch.
- **One at a time.** Alerts queue up. Status alerts (battery, mute, Wi‑Fi)
  replace older ones instead of stacking.
- If boringNotch isn't running, NotchAlerts works on its own.

## Install

### Download

1. Download `NotchAlerts.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move **NotchAlerts** to your Applications folder.
3. NotchAlerts isn't signed with a paid Apple Developer account, so macOS blocks
   it the first time. Run this once in Terminal, then open it normally:

   ```bash
   xattr -dr com.apple.quarantine /Applications/NotchAlerts.app
   ```

### Build it yourself

You need Xcode or the Command Line Tools (`xcode-select --install`).

```bash
cd NotchAlerts
./build.sh --install
```

That builds `NotchAlerts.app`, copies it to `/Applications` and opens it. The
first launch plays a demo of every alert. You can replay it from the menu bar
icon with **Play Demo**, and preview single alerts under **Preview**.

macOS asks for a few permissions:

- **Bluetooth**, to read AirPods battery levels.
- **Downloads folder**, to spot AirDrop files.
- **Desktop folder** (or wherever screenshots go), to spot screenshots.
- **Full Disk Access**, only if you want Focus alerts. Grant it yourself in System Settings.

All are optional. If you decline, those alerts still work without the extra
details. Because the app is signed locally, rebuilding can make macOS ask
again.

Turn on **Launch at Login** from the menu bar icon to start it automatically.
If you hide the menu bar icon, open the app again from Applications to bring it
back.

## Fit to the notch

The alert starts at the exact size of the notch (or of boringNotch's album art
and bars while music plays). If it looks a pixel off on your screen, use the
menu bar icon's **Fit to Notch** menu: **Taller / Shorter by 1 Pixel** adjusts it
and shows a sample right away. **Use Menu Bar Height** matches boringNotch's
"Match menubar height" option.

## Alerts from Shortcuts and scripts

Open a `notchalerts://` link:

```
notchalerts://show?title=Build%20done&symbol=hammer.fill&color=green
notchalerts://show?title=Backup&subtitle=Finished%20in%204%20min&symbol=externaldrive.fill&color=blue&duration=4
```

- `title` (required)
- `subtitle` (optional): makes it a taller card
- `symbol`: any SF Symbol name
- `color`: white, gray, red, orange, yellow, green, blue, purple or pink
- `duration`: 1–15 seconds
- `url`: something to open when the alert is clicked

In Shortcuts, use **Run Shell Script** with `open -g "notchalerts://show?title=Done"`.
The `-g` keeps your current app focused. **Open URLs** also works, but it
briefly switches apps.

## Notes

- The lock screen alert uses the same private SkyLight call boringNotch uses to
  draw over the lock screen (from
  [Lakr233/SkyLightWindow](https://github.com/Lakr233/SkyLightWindow), MIT).
- AirPods battery levels come from undocumented IOBluetooth properties. If a
  future macOS removes them, the AirPods alert still appears, just without
  battery.
- Requires macOS 14 Sonoma or later, the same as boringNotch.
