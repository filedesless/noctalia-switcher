# Switcher

A Noctalia window switcher for niri, in the spirit of helix's `goto_word`
and macOS's rcmd. Every window gets a label of one or two letters, and
typing a label focuses that window. Held with right Cmd, a label you know
needs no panel at all: rcmd+s, rcmd+p for Spotify.

Two panels show the labels:

- **The list** (rcmd+Space): a row per window with its label, icon and
  app name (and title, when the app has several windows), and last a Space
  row for the minimap.
- **The minimap**: every monitor (left to right), its workspaces (top to
  bottom) and their windows as tiles, in column order, with a column's
  stacked windows one above the other. Each tile shows the window's
  preview, app icon, title and label.

Keys:

- **rcmd+letter** with no panel open: a letter that is a whole label
  focuses its window at once; one that starts longer labels (`s` for `st`
  steam and `sp` Spotify) opens the list with it typed. With a panel
  open, it counts as typed there; typing without rcmd works too.
- **rcmd+Space** opens the switcher. It opens as the list or the minimap,
  whichever you used last (kept in `~/.local/state/noctalia/switcher-mode`).
- **Space** (or rcmd+Space) switches between the list and the minimap.
- **Backspace** undoes a letter, **Esc** closes, and a letter that
  matches no label starts over. Clicking a row or tile works too.
- **Labels come from app names.** Each window is labelled by its app
  name's first letter. When several windows share that letter, each gets
  two: the letter plus the next letter of its name not taken yet (`st`
  steam and `sp` Spotify, `ze` Zen and `zd` Zed), else a free letter from
  `hint_chars`. Second letters stay with their window between openings.

## Previews

Each tile shows the window's last capture, at the window's aspect ratio. A
monitor's workspaces share the panel's height, several per line when there
are many; a row too wide for its cell gets shorter as a whole rather than
squeezed, and tiles too small for a picture show just the icon and label.

niri can't capture a window that isn't on screen (no
ext-image-copy-capture), and its `screenshot-window` action always copies
to the clipboard. So the service captures windows with `grim` (wlr
screencopy) while they're on screen, 0.7 s after things settle and at most
every 1.5 s, into `$XDG_RUNTIME_DIR/noctalia-switcher/`. Nothing is
captured while the panel is open or the session is locked. A window that
hasn't been on screen since Noctalia started shows its icon.

niri's IPC gives on-screen positions only for floating windows, so tiled
ones are worked out from the layout, assuming no struts and the work area's
insets split evenly between top and bottom (equal bars). When a
workspace's columns all fit on screen, nothing scrolls and they sit left to
right; otherwise only the active window's column is certain (full width,
first or last). Set `gaps` to niri's `layout { gaps }` if it isn't the
default 16, or turn `previews` off.

The service follows `niri msg --json event-stream` and keeps the windows
and workspaces in shared state, so the panel opens without waiting on IPC.
That approach comes from teagar/niri-workspace-preview.

## Setup

Install as a local plugin and enable it:

```sh
ln -s ~/src/noctalia-switcher ~/.local/share/noctalia/plugins/switcher
```

Add `"filedesless/switcher"` to `[plugins] enabled`, then restart Noctalia
(plugins are installed at startup). Bind rcmd+Space and rcmd+letter in
niri to the service's `key` event; here right Cmd (Super_R) is made the
level-3 key with the xkb option `lv3:rwin_switch`:

```kdl
binds {
    ISO_Level3_Shift+Space { spawn "noctalia" "msg" "plugin" "filedesless/switcher:service" "all" "key" "space"; }
    ISO_Level3_Shift+A hotkey-overlay-title=null { spawn "noctalia" "msg" "plugin" "filedesless/switcher:service" "all" "key" "a"; }
    // ... one per letter; test/niri-binds.kdl has all 27.
}
```

A modifier alone (RAlt, Super) can't be bound: niri only fires binds that
end in a non-modifier key, hence a bind per letter. The panels open on
their own too: `noctalia msg panel-toggle filedesless/switcher:compact`
(or `:panel` for the minimap).

## Tests

`test/` holds a bench that leaves the running session alone: headless sway
and a second Noctalia with their own runtime dir, session bus and config,
and a stub `niri` that plays back sample windows and logs focus requests.

```sh
nix shell nixpkgs#sway nixpkgs#grim nixpkgs#wtype --command env SWITCHER_TEST_ROOT=/tmp/switcher-bench test/e2e.sh
nix shell nixpkgs#luau --command luau test/labels_test.luau
```

## Settings

```toml
[plugin_settings."filedesless/switcher"]
# Letters labels may use, best first.
hint_chars = "asdfghjklqwertyuiopzxcvbnm"
previews = true
gaps = 16 # niri's layout gaps
```
