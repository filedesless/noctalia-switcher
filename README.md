# Switcher

A Noctalia window switcher for niri, in the spirit of helix's `goto_word`
and macOS's rcmd. One hotkey opens a minimap of every monitor (left to
right), its workspaces (top to bottom) and their windows as tiles, in column
order, with a column's stacked windows one above the other. Each tile shows
the app icon, the window title and a label of one or two letters. Typing a
label focuses that window and closes the panel.

- **Backspace** undoes a letter, **Esc** closes, and a letter that
  matches no label starts over. Clicking a tile works too.
- **Pinned apps** keep a fixed letter: `z` for Zen, say. It focuses the
  app's most recently used window, or the one before when that one is
  current, so pressing it again cycles. The app's other windows get labels
  like any other. A pinned app that isn't running shows in a dock row under
  the map, and its letter launches it (through `niri msg action spawn`, so
  it's niri's child, not Noctalia's).
- **Every other window** is labelled by its app name's first letter that
  isn't pinned (Zed is `e` once `z` is pinned). When several windows share
  that letter, each gets two: the letter plus its name's next one if that
  tells them apart (`st` steam, `sp` Spotify), else a free letter from
  `hint_chars` (two Alacritty windows: `aa`, `as`). Second letters stay
  with their window between openings.

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
(plugins are installed at startup). Bind a key in niri; here right Cmd
(Super_R) is made the level-3 key with the xkb option `lv3:rwin_switch`:

```kdl
binds {
    ISO_Level3_Shift+Space { spawn "noctalia" "msg" "panel-toggle" "filedesless/switcher:panel"; }
}
```

A modifier alone (RAlt, Super) can't be bound: niri only fires binds that
end in a non-modifier key.

## Settings

```toml
[plugin_settings."filedesless/switcher"]
# "key app_id [command...]"; the command defaults to the app_id.
pinned = [
    "z zen-beta",
    "t thunderbird",
    "o md.obsidian.Obsidian obsidian",
]
# Letters for labels when names don't give one, best first.
hint_chars = "asdfghjklqwertyuiopzxcvbnm"
previews = true
gaps = 16 # niri's layout gaps
```

Find an app's `app_id` with `niri msg windows`.
