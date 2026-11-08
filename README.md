# SlideOver

iPadOS-style **Slide Over** for macOS – a tiny menu bar app that lets any Mac app slide in from the edge of the screen, just like on the iPad.

*Deutsch weiter unten.*

## Features

- Pick any app as your Slide Over app – it slides in and out from the left or right screen edge with an animation
- Remembers **position, size and side per app** – just move/resize the window, it'll come back exactly there
- **Arrow handle** at the screen edge (like on iPad) when Slide Over is stashed away or covered – click it to bring the app back
- Optional: show it by resting the mouse at the screen edge (~0.3 s, corners excluded so Hot Corners keep working)
- Optional: auto-hide when you switch to another app
- Launches the app if it isn't running yet
- No dependencies, a single Swift file, no Xcode project needed

## Shortcuts

| Shortcut | Action |
|---|---|
| `⌃⌥⇧S` | Make the frontmost app the Slide Over app (and show it) |
| `⌃⌥S` | Show / hide Slide Over |
| `⌃⌥A` | Switch side (left/right) |

Everything else (app, side, size, handle, edge trigger, auto-hide) is in the menu bar icon.

## Build & install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh install
```

This builds `SlideOver.app`, copies it to `~/Applications` and launches it.

On first launch, grant **Accessibility** access (System Settings → Privacy & Security → Accessibility). The app needs it to move and resize other apps' windows.

> **Note:** The app is ad-hoc signed. After each rebuild macOS may treat it as a new app – if nothing slides anymore, remove the SlideOver entry under Accessibility with “–”, relaunch and grant access again.

## Limitations

- macOS doesn't allow keeping another app's window permanently on top without system-level hacks, so Slide Over hides (or shows the handle) when you click another app.
- Apps with a minimum window width won't get narrower than that.
- The edge trigger doesn't fire on an edge that borders another display.

---

## Deutsch

Slide Over wie auf dem iPad (iPadOS 26) für den Mac: Eine beliebige App gleitet per Tastenkürzel, Mausbewegung an den Bildschirmrand oder Klick auf den Pfeil-Griff vom Rand herein. Position, Größe und Seite werden pro App gemerkt.

Installation: `./build.sh install`, danach in Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen den Zugriff für **SlideOver** erlauben.

Kürzel: `⌃⌥⇧S` vorderste App als Slide Over festlegen · `⌃⌥S` ein-/ausblenden · `⌃⌥A` Seite wechseln.
