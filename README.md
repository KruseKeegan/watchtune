# WatchTune

Shows the Spotify song playing on your iPhone on an [Ollee Watch](https://www.olleewatch.com), and lets the watch's buttons control it.

| Watch | Does |
| --- | --- |
| A tap | Play / pause |
| A hold | Scroll the song again |
| L tap | Next track |
| L hold | Previous track |
| Main digits | `Title - Artist`, scrolled once when the song changes |
| Day digits | ` P` playing, `11` paused |
| LAP | Phone connected |

## Parts

- `watch/watchtune.js`: the Forge watch face (Ollee Watch Forge, Beta 2).
- `ios/`: the iPhone app. It polls Spotify's Web API every 3 s and relays the song to the watch over the Forge BLE service. Built unsigned on GitHub Actions, installed with AltStore.
- `docs/callback/`: GitHub Pages page Spotify redirects to after sign-in; it hands the code to the app (`watchtune://`).
- `tests/test_watchface.js`: Node tests for the watch face against a mock of the Ollee API.

## Setup

1. **Watch face:** open `watch/watchtune.js` in the [Forge emulator](https://github.com/olleewatch/forge_emulator), click **Upload**, then in the Ollee Watch app go to **Settings > Forge Apps > My Apps** and send it to a Forge slot.
2. **Spotify app:** at https://developer.spotify.com/dashboard, create an app with **Web API** ticked and this Redirect URI:
   `https://krusekeegan.github.io/watchtune/callback/`
   Copy its **Client ID**. (Development mode needs Spotify Premium.)
3. **iPhone app:** install `WatchTune.ipa` from the [latest release](https://github.com/KruseKeegan/watchtune/releases/tag/latest) with AltStore.
4. Open WatchTune, paste the Client ID, **Sign in to Spotify**, then **Find watch** if it doesn't connect by itself.

## Watch protocol

Each BLE write is at most 20 bytes; the first character is the type.

| Direction | Message | Meaning |
| --- | --- | --- |
| phone → watch | `S<text>` / `C<text>` / `E` | start, continue, end of the song text |
| phone → watch | `P1` / `P0` | playing / paused |
| phone → watch | `X` | nothing playing |
| watch → phone | `PP` / `NX` / `PV` | play-pause / next / previous |
| watch → phone | `?` | resend everything |

## Limits

- The free Apple ID signature that AltStore uses lasts 7 days; AltStore refreshes it over Wi-Fi while AltServer runs on your PC.
- Song text is reduced to plain ASCII (é becomes e), and some letters look rough on the 7-segment LCD.
- "Keep running in background" plays silence mixed with Spotify so iOS doesn't suspend the app. iOS can still close it under memory pressure.
