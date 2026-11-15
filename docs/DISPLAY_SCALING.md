# Display scale and readability

The client has two independent presentation settings, both stored locally on
the player's computer:

| Setting | What it sizes | Choices | Default |
|---|---|---|---|
| **World zoom** | Terrain, buildings, characters, creatures, effects (camera only) | 1.0× – 2.0× in 0.25 steps | 1.5× |
| **Interface size** | Every window, button and text: HUD, help, login, character selection and creation, backpack, equipment, chests, vitals, target, skills, journal, tooltips, drag previews, name labels | 100%, 125%, 150%, 175%, 200% | Picked from the screen: 100% at 720 points tall, 150% at 1080, 200% at 1440 and above |

**Controls:**
- **Mouse wheel** (or `+` / `-`) zooms the world.
- **F2** cycles the interface size.
- **O** (or F10) opens the Settings window: zoom − / +, the five interface
  sizes, and **Reset to default**.

The limits and choices live in `game/data/display.json`.

## Units: display points

Both values are in *display points*.
- On a desktop at 100% scaling, one point is one screen pixel.
- On a Retina Mac, or Windows at 200%, one point is two pixels.

So "1.5×" and "150%" look the same physical size on every monitor. Before this
change the game drew in raw pixels: on a Retina or high-DPI screen everything
was half size, which is the most likely cause of the "far too small" report.

The scale the OS reports comes from `DisplaySettings.os_scale()`:
- **macOS:** `DisplayServer.screen_get_scale()`.
- **Windows:** desktop DPI ÷ 96.
- **Linux:** 1.

## How it is built

The relevant files:
- `project.godot`: stretch mode `canvas_items`, aspect `expand`.
- `game/scripts/core/display_settings.gd`: settings, defaults and
  preferences.
- `game/scripts/main.gd`: `_setup_display`, `_apply_ui_scale`,
  `_sync_viewport_sizes`, `cell_to_world_px`, `world_px_to_screen`.
- `game/scripts/ui/settings_window.gd`.

**Interface scaling.** One multiplier,
`Window.content_scale_factor = interface size × os scale`, set on the root
window with `content_scale_size = 0`. There is no base resolution, so the
layout is simply the window size divided by the factor.
- Godot rasterizes fonts at the final size, so text stays sharp.
- Anchors and containers lay out in the scaled space.
- Popups (tooltips) and drag previews inherit the same factor.
- Mouse events arrive already in layout coordinates.
- No Control node is scaled individually. The old `GameUI.scale` multiplier
  is gone, so no nested scales remain.

**World rendering.** Each world view renders into a `SubViewport` kept at the
*physical* pixel size of its panel, and is shown 1:1 by a `TextureRect`. The
interface scale therefore never resamples the world: only
`Camera2D.zoom = world zoom × os scale` sizes it.
- Tile size, world coordinates, collision and depth sorting are untouched.
- Screen ↔ world conversion goes through `cell_to_world_px` and
  `world_px_to_screen`. Picking, hover, targeting, drag-and-drop, right-mouse
  walking, name labels and floating text all use them, as do the scripted
  tests.

**Staying on screen.**
- If the window is too short for the chosen interface size (layout below 540
  points), the size actually used is reduced, and the Settings window says so.
  The saved choice is kept for larger windows.
- On every resize, all windows are clamped inside the view.

**First launch.** The window opens at 85% of the screen at 16:9, never below
1280×720, centred.

## Preferences

`user://settings.cfg` (Godot's per-user data folder) holds:
- `[display] world_zoom`
- `[display] ui_scale`
- `[interface] show_help`

The file is loaded at startup and written whenever a value changes. **Reset
to default** restores zoom 1.5× and the screen-based interface size. Automated
runs (`--scenario`, `--shot`) and `--no_prefs` never read or write it. Nothing
goes to the server or the character database.

The `--zoom=`, `--ui_scale=` and `--window=WxH` command-line options set exact
values for testing and screenshots. `--zoom` may go outside 1.0–2.0, for
close-ups.

## Readability

Base font sizes, in UI pixels at 100% interface size:

| Text | At 100% | At 150% (1080p default) | At 200% |
|---|---|---|---|
| Window titles, HUD, character names | 13–14 | 19.5–21 px | 26–28 px |
| Labels, buttons, fields | 12–13 | 18–19.5 px | 24–26 px |
| Secondary text, vitals bars, item counts (raised from 10–11) | 12 | 18 px | 24 px |

## Art at the new scale (64×32 set)

- At 1.5× the character, 72 px in the art, is about **108 screen pixels**
  tall. That is inside the 100–120 px range the directive names, and clothing,
  weapon and animation read clearly.
- 1.25× and 1.75× resample pixel art unevenly (nearest-neighbour). In
  screenshots this shows as slightly irregular pixels on fine detail (fence
  rails, tree outlines), not as blur. 1.0×, 1.5× and 2.0× are clean.
- **No higher-resolution export is required for 1080p.** On 1440p and 4K
  displays at 2.0× the 64×32 art is still sharp but chunky. Those displays
  are where the existing 96×48 set (Tab) is the better candidate: it is
  already rendered, and was validated in Slice 001. It has not been made the
  default.

## Verification (all executed, all automated)

All GUI runs used Xvfb (software OpenGL, llvmpipe) with the screen set to
the window size. The interface default therefore came from that screen:
- 100% at 1280×720;
- 150% at 1920×1080;
- 200% at 2560×1440.

The operating-system scale was 1.0 in every run. **No HiDPI (Retina or
Windows 150–200%) display was available**, so the `os_scale()` path is
untested on real hardware.

| Run | 1280×720 | 1920×1080 | 2560×1440 |
|---|---|---|---|
| `--scenario=display` (33 checks, listed below) | 33/33 | 33/33 | 33/33 |
| `--scenario=acceptance`: Slice 002 UI, real input | 45/45 | 45/45 | 45/45 |
| `--scenario=combat`: Slice 005 walkthrough | – | 16/16 | – |
| `tests/persist/dod_gui.sh`: register, log in, create and select characters, restart, all through the UI | – | 38/38 | – |
| Three-process multiplayer GUI with 60 ms lag, 20 ms jitter, 5% loss (Alice / Bob) | – | 5/5, 6/6 | – |
| `tests/display_tests.gd` (headless) | 17/17 | | |
| Headless regression: rules / multiplayer / combat | 79/79, 93/93, 60/60 | | |

The display scenario checks, in order:
1. **Defaults:** 1.5× zoom; interface size for the screen; character 108
   screen px tall; world rendered at full window resolution; windows on
   screen.
2. **Mouse-wheel zoom:** zoom in and out with stops at 1.0 and 2.0, with the
   interface unchanged. Hover picks objects at 2.0× and 1.0×.
3. **Settings window:** opened with O. The zoom `+` button and the 200% button
   work, with the world zoom unchanged and the world still at full
   resolution. Windows stay on screen, and the backpack and equipment don't
   overlap.
4. **Picking and drag-and-drop at 200% and 125%:** ground to backpack slot,
   slot to slot, backpack to ground under the cursor, and back.
5. **Resize** to a 1280×720 window at 200%: the size used is reduced, a
   540-point layout is kept, windows stay on screen, and drop and hover still
   work.
6. **Reset to default**, and the preferences file is untouched by automated
   runs.

Screenshots and logs: `docs/images/display/`.

**Not verified:**
- A human looking at a real 1080p monitor ("without leaning toward the
  screen").
- A physical HiDPI display.
- macOS and Windows builds.
- GPU rendering (frame rates in the screenshots are software rendering).
- 175% in a GUI run (it is in the headless tests only).

**Known cosmetic issues:**
- At 1.25× and 1.75× pixel art is unevenly resampled. It reads correctly but
  is less crisp than at 1.0×, 1.5× and 2.0×.
- Floating combat text can overlap the name label above the character.
- The keyboard help panel is large at 200% on a 1080p screen; H hides it, and
  that choice is remembered.

## Fixed along the way

- **Terrain seams:** at fractional zoom, dotted gaps appeared along ground
  tile edges, where nearest-neighbour rounding left pixels uncovered. The old
  default of 2.0× hid them. Each terrain tile is now drawn half a pixel larger
  on each side, so neighbours overlap. Logical tile size is unchanged. See
  `seams_before_fix_1.5x.png` and `seams_after_fix_1.25_1.5_1.75.png`.
- **Window layout:** the backpack and equipment windows used to overlap after
  an interface-size change. Windows the player hasn't moved are now laid out
  again from their default anchors, and moved ones are only kept on screen.
- **Stale multiplayer procedure:** the three-process procedure in
  `MULTIPLAYER_TESTING.md` started the server without `--dev_tls`. Clients
  holding the Slice 004 dev certificate always use DTLS, so they never
  connected. The procedure now includes the flag.
