# Developing Snapmenu

Technical notes for anyone working on the plugin. The [README](README.md) is the
user-facing one.

## Requirements

Omarchy Quattro, and `grim` (Omarchy ships it). Everything else is optional, and
the plugin says which of it is missing rather than failing silently:

| For | Needed | Without it |
|---|---|---|
| Anything at all | `jq`, which the helper uses for every reply | the helper prints nothing and the overlay reports "the capture helper returned nothing" |
| Cropping a selection | `vips` (libvips), or `magick`/`convert`, or `ffmpeg` | grim reads the frozen frame back off the screen, which is exact but slower |
| Clipboard as image **and** file | a Rust toolchain, then `make native` | `wl-copy --type image/png`, the image alone |
| Removing a shot | `gio` (Omarchy ships it) | falls back to `rm` |
| Annotate | `tensaku-edit` | the row is not offered |
| Share | `omarchy-menu-share` | the row is not offered |

The native clipboard helper is the only thing that needs building: Rust, linking
Wayland's `wlr-data-control` protocol directly, so no PyGObject or GTK is involved.

## How a shot is taken

Region selection is done **in the shell**, not by slurp:

1. `bin/snapmenu-capture.sh --freeze` waits for the card's layer surface to be
   withdrawn (it polls `hyprctl layers` instead of guessing at a sleep) and then
   captures the focused monitor to a PNG. Nothing of Snapmenu can therefore
   appear in its own screenshot. Fullscreen and previous-area are single `grim`
   calls, and they wait for the layer the same way.
2. `RegionSelector.qml` maps a full-screen layer surface on that monitor, shows the
   frozen frame, and drags the selection in-process with a crosshair, live size
   label and window snapping from `--rects`.
3. `--crop "X,Y WxH"` reads those pixels back out. The selection is global while
   the frame file starts at the monitor, so the file crop subtracts the monitor
   origin (`--origin`) and the grim read-back keeps the global rectangle. The
   reply says which path produced the file (`source`), and reports the size read
   back from the PNG header rather than the size that was asked for.

The picker deliberately does not go through `omarchy-capture-region`: that path
freezes the screen with hyprpicker and picks with slurp, which is where the
"screen frozen, clicks dead" reports in the wild come from (a second layer
surface competing for input, and a freeze process that can outlive a cancelled
pick). Nothing in Snapmenu leaves a process behind, with one deliberate
exception: the native clipboard helper stays alive until another client takes the
selection, which is what keeps the image pasteable.

Screenshots land in `$SNAPMENU_DIR`, else `$OMARCHY_SCREENSHOT_DIR`, else the XDG
Pictures directory, named `screenshot-YYYY-MM-DD_HH-MM-SS.png`.

History *is* the export folder: a listing of the newest PNGs there, so a shot that
leaves the folder leaves the list, no matter who removed it. Delete uses `gio
trash` when available and `rm` otherwise; a shot the plugin is throwing away (with
`saveToDisk` off) is deleted rather than sent to the Trash, and the temp directory
is pruned. Such a shot is `pendingTempShot` while the card holds it: the card's rows
work on a file that is still there, `claimTempShot` marks it as taken when one of
them hands it off, and `releaseTempShot` is what removes it when the card closes
without anything taking it.

## Files

| Path | Role |
|---|---|
| `manifest.json` | Plugin manifest: `overlay` + `bar-widget` kinds, settings schema |
| `Snapmenu.qml` | The card: stages, key routing, capture orchestration, actions |
| `MenuPopout.qml` | The bar dropdown: the same rows, sent to the overlay as commands |
| `RegionSelector.qml` | The frozen-frame region/window picker |
| `ActionRow.qml` | One menu row (glyph, label, detail, trailing value/toggle) |
| `SnapmenuModel.js` | Pure logic: row lists, parsing, geometry, settings, navigation |
| `BarWidget.qml` | The bar glyph, its state (camera / armed timer / recording), and the popup's lifecycle |
| `bin/snapmenu-capture.sh` | Freeze, crop, rects, clipboard, delete — one JSON line out |
| `native/snapmenu-clipboard` | The Rust clipboard helper |
| `tests/model.test.mjs` | `node --test tests/` |

Two surfaces exist on purpose, and they share one source of truth: the dropdown
(`MenuPopout.qml`, owned by the bar's popup machinery) and the overlay
(`Snapmenu.qml`, the same menu plus history, the action card, settings and
about). Both render `Model.menuRows()` and both send the same command payloads,
which the overlay executes — so the dropdown cannot drift from the overlay's
behaviour, and a row that exists is a row that works.

`SnapmenuModel.js` holds every decision worth testing (which rows exist, how
`find` output is parsed, how settings are read out of `shell.json`, how a drag
becomes grim geometry, where the cursor moves) so the QML stays presentation and
key routing. The shell helper always exits 0 and reports status in its JSON line,
because a cancelled pick is not a failure.

## IPC

Every entry point, all callable without opening the menu:

```bash
omarchy-shell snapmenu.menu toggle                                    # the bar dropdown
omarchy-shell snapmenu.menu rows                                      # the rows it would show
omarchy-shell snapmenu.menu activate 3                                # run row 3, as a click would
omarchy-shell shell toggle io.github.analytically.snapmenu '{}'       # the full overlay
omarchy-shell shell call io.github.analytically.snapmenu captureArea ''
omarchy-shell shell call io.github.analytically.snapmenu captureScreen ''
omarchy-shell shell call io.github.analytically.snapmenu captureSmart ''
omarchy-shell shell call io.github.analytically.snapmenu capturePrevious ''
omarchy-shell shell call io.github.analytically.snapmenu openHistory ''
omarchy-shell shell call io.github.analytically.snapmenu cancelCapture ''
# a fixed rectangle, in global logical coordinates ("X,Y WxH")
omarchy-shell shell call io.github.analytically.snapmenu captureAreaAt '1600,900 300x200'
# payload variants, for scripts that want a stage, a delay or a file
omarchy-shell shell summon io.github.analytically.snapmenu '{"stage":"history"}'
omarchy-shell shell summon io.github.analytically.snapmenu '{"mode":"region","delay":5}'
omarchy-shell shell call io.github.analytically.snapmenu debugState ''
```

Payloads also carry commands, which is how the dropdown runs things without
duplicating any of the overlay's work:

```bash
omarchy-shell shell summon io.github.analytically.snapmenu '{"command":{"action":"capture","mode":"region"}}'
omarchy-shell shell summon io.github.analytically.snapmenu '{"command":{"action":"set-delay","value":5}}'
omarchy-shell shell summon io.github.analytically.snapmenu '{"command":{"action":"capture-at","geometry":"1600,900 300x200"}}'
omarchy-shell shell summon io.github.analytically.snapmenu '{"command":{"action":"set-setting","key":"glaze","value":0.14}}'
```

`debugState` returns what the plugin is doing right now (stage, in-flight
capture, frozen frame, the picker's transform and trace, recent state
transitions) — the first thing to ask for when something looks wrong.

A capture carries a **token**: dismissing the card, cancelling a pick or
dismissing the plugin bumps it and stops the running processes, so a freeze or a
crop that is already in flight cannot map the picker or re-open the card after
the user has walked away. Anything that starts a process records the token it
started with and ignores its reply when they no longer match.

## Testing

| Layer | Covers | How |
|---|---|---|
| `tests/capture.test.sh` | every branch of `bin/snapmenu-capture.sh`: freeze geometry, logical→physical crop, negative origins, cropper fallback, clipboard import, trash/rm delete, file sizes, provenance, temp pruning and each failure reason | hermetic — every external tool is a stub reached through the `SNAPMENU_*` overrides, state lives in a temp dir |
| `tests/model.test.mjs` | `SnapmenuModel.js`: row lists and their command payloads, parsing, settings lookup, cursor navigation, geometry math, the unified capture decision (`candidateRect` / `selectionOrDefault` / `legendText`), the release path, the named ratio levels and the bar icon's states | `node --test` |
| `tests/run.sh` (`make test`) | the two suites above, plus `bash -n`, `shellcheck -S warning`, `qmllint` over every `.qml`, and `omarchy plugin validate` | one command, non-zero exit on any failure |
| `tests/manual/menu_dropdown.sh` | the bar dropdown: lifecycle, the rows and capture modes it offers, the timer row writing its setting, a capture row producing a shot and opening the card, the card taking keyboard focus, Esc closing the card, previous-area capture, deleting, and the bar icon following the state | drives the real dropdown and icon over IPC |
| `tests/manual/keyboard_pick.sh`, `freeze_crop_identity.sh` | what no headless runner can reach: a mapped layer surface, real keyboard focus, the compositor | drive the running picker with `wtype`, then assert against `hyprctl`, `identify` and `compare` |

`freeze_crop_identity.sh` opens the picker, keeps the frame it froze, presses
Enter, and asserts the shot is that frame — measured on a scale-1.6 display:
**0 differing pixels of 5,184,000**. `keyboard_pick.sh` asserts that Tab's window
is what gets captured, at `window × output scale` pixels.

Both scripts hide the picker on the way out, including on failure: a stray picker
on screen would swallow the next run's keys.

The rule the suites follow: **semantics are asserted in the model tests**, which
are deterministic, and **the live suite asserts wiring** — that something
happened, and that it is consistent — because it shares the machine with the
user's own captures and cannot depend on timing or on an empty export folder.

There is deliberately **no `qmltestrunner` suite**. Omarchy's `qs.Commons` and
`qs.Ui` singletons (`Color`, `Style`, `Border`, all `pragma Singleton`) only
resolve when Quickshell registers the module URI, so a plain Qt test runner
cannot load these components without patching upstream files. The decisions are
therefore kept in `SnapmenuModel.js` where node can test them, QML is left with
routing and presentation, `qmllint` guards its structure, and behaviour is
verified in the real engine by the manual scripts. Anything that needs a rule
rather than a gesture belongs in the model with a test next to it.

## Developing

```bash
make test      # the gate: everything that must pass before a change ships
make deploy    # make test, then copy into the plugin dir and restart the shell
make manual    # the three checks that need a real session
make native    # build the Rust clipboard helper into bin/
```

Saving a file under `~/.config/omarchy/plugins/` reloads the plugin, but the
running shell keeps the **compiled** QML for a URL it has already loaded: after
editing plugin code, only `omarchy restart shell` makes a change take effect.
Editing a file *during* an interactive picker run also tears that picker down —
the relay is a file watcher. `make deploy` does the copy-and-restart for you.

## Test hooks

The helper honours `SNAPMENU_GRIM`, `SNAPMENU_HYPRCTL`, `SNAPMENU_WL_PASTE`,
`SNAPMENU_MAGICK`, `SNAPMENU_CONVERT`, `SNAPMENU_FFMPEG`, `SNAPMENU_VIPS`,
`SNAPMENU_GIO`, `SNAPMENU_RM`, `SNAPMENU_DIR`, `SNAPMENU_PNG_LEVEL` and
`SNAPMENU_STATE_DIR` purely so the tests can point it at stubs; the defaults are
the absolute paths, so an inherited `PATH` still cannot stand in for a real tool.
`SNAPMENU_KEEP_FREEZE=1` keeps the frame after a crop for pixel comparisons.

## Publishing

Snapmenu is built to be listed on [plugins.omarchy.org](https://plugins.omarchy.org);
[PUBLISHING.md](PUBLISHING.md) has the submission and update procedure.

## License

MIT — see [LICENSE](LICENSE).
