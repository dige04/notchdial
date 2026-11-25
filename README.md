# NotchDial

**Turn your keyboard's knob into an app switcher that drops out of the MacBook notch.**

Spin the knob → a half-circle dial slides out of the camera notch, your apps rotate along the arc → stop spinning (or press the knob) → that app comes to the front.

Like a Stream Deck, but it's a dial, and it lives in the notch.

<p align="center"><img src="docs/demo.gif" width="620" alt="NotchDial demo"></p>

- Native Swift/AppKit, a single file (~650 lines), no dependencies, no Electron
- Blends into the notch: pure black shape with concave shoulders and a springy drop-in animation
- Rotating tick ring, focused-app spotlight, running-app dots, and a thin countdown ring before it commits
- Works with any knob or keys that can send F13/F14/F15 (NuPhy, Keychron, QMK/VIA boards, Stream Deck, …)
- Global hotkeys via Carbon, so it needs **no Accessibility or Input Monitoring permission**
- macOS 14+. Works on Macs without a notch too (the dial drops from the top edge)

## Install

```sh
git clone https://github.com/dige04/notchdial && cd notchdial
./build.sh --install                 # builds and copies to ~/Applications/NotchDial.app
open ~/Applications/NotchDial.app
scripts/login-item.sh enable         # optional: start at login
```

Requires the Xcode command line tools (`xcode-select --install`).

## Controls

| Input | Action |
|---|---|
| `F13` (knob clockwise) | next app |
| `F14` (knob counter-clockwise) | previous app |
| `F15` (knob press) | open the dial / switch now |
| `⌃⌥⌘ →` / `⌃⌥⌘ ←` / `⌃⌥⌘ ↩` | same, for keyboards without a knob |

If you stop turning for `commitDelay` seconds, it switches automatically.

The dial opens on the app you're currently in, so one click of the knob takes you to the app next to it.

## Mapping your knob to F13 / F14 / F15

Pick whichever your keyboard supports.

**NuPhy (NuPhyIO web configurator).** Plug the keyboard in with the cable, open [nuphy.io](https://nuphy.io) in Chrome or Edge, and connect it. Open the knob settings and set *rotate right* to `F13`, *rotate left* to `F14`, and *press* to `F15`. Save it to the keyboard.

**VIA / QMK boards (Keychron, NuPhy QMK firmware, …).** Open [usevia.app](https://usevia.app) and load your board's JSON if it asks for one. Click the knob in the layout and set the clockwise and counter-clockwise encoder actions to `KC_F13` and `KC_F14`. Then set the knob's press key to `KC_F15`.

**Can't remap the knob? Use Karabiner-Elements.** Leave the knob as a volume knob and let Karabiner translate *that keyboard's* volume keys into F13/F14/F15. Your other keyboards keep working normally. First find your keyboard's `vendor_id` and `product_id` in Karabiner-EventViewer → Devices. Then add this rule to `~/.config/karabiner/assets/complex_modifications/notchdial.json` and enable it:

```json
{
  "title": "NotchDial knob",
  "rules": [{
    "description": "Knob on my keyboard → NotchDial (F13/F14/F15)",
    "manipulators": [
      { "type": "basic", "from": { "consumer_key_code": "volume_increment" }, "to": [{ "key_code": "f13" }],
        "conditions": [{ "type": "device_if", "identifiers": [{ "vendor_id": 0, "product_id": 0 }] }] },
      { "type": "basic", "from": { "consumer_key_code": "volume_decrement" }, "to": [{ "key_code": "f14" }],
        "conditions": [{ "type": "device_if", "identifiers": [{ "vendor_id": 0, "product_id": 0 }] }] },
      { "type": "basic", "from": { "consumer_key_code": "mute" }, "to": [{ "key_code": "f15" }],
        "conditions": [{ "type": "device_if", "identifiers": [{ "vendor_id": 0, "product_id": 0 }] }] }
    ]
  }]
}
```

Replace each `0` with your keyboard's IDs.

## Configure

`~/.config/notchdial/config.json` is created on first launch:

```json
{
  "apps": ["Ghostty", "Google Chrome", "com.tinyspeck.slackmacgap", "Obsidian", "~/Applications/Some Other.app"],
  "commitDelay": 0.7
}
```

Each entry can be an app name, a bundle id, or a path. After editing, reload it:

```sh
~/Applications/NotchDial.app/Contents/MacOS/NotchDial reload
```

The same binary is also a small CLI you can script: `next`, `prev`, `commit`, `show`, `reload`, `quit`.

## Hacking

Everything is in [`Sources/main.swift`](Sources/main.swift). `DialView` draws the dial with Core Graphics on a `CADisplayLink`, and `Controller` handles the hotkeys, the panel, and switching apps.

To render frames without having to watch the screen:

```sh
build/NotchDial.app/Contents/MacOS/NotchDial --render still.png 0 1      # offset, reveal
build/NotchDial.app/Contents/MacOS/NotchDial --demo frames/              # scripted spin, 50 fps
ffmpeg -framerate 50 -i frames/f%04d.png -c:v libx264 -pix_fmt yuv420p demo.mp4
```

## License

MIT
