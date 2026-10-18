# Switcher

A Noctalia window switcher for niri, in the spirit of helix's `goto_word`
and macOS's rcmd. One hotkey opens a minimap of every monitor (left to
right), its workspaces (top to bottom) and their windows as tiles, in column
order, with a column's stacked windows one above the other. Each tile shows
the app icon, the window title and a label of one or two letters. Typing a
label focuses that window and closes the panel.

- **Backspace** undoes a letter, **Esc** closes, and a letter that matches
  no label starts over. Clicking a tile works too.
- **Pinned apps** keep a fixed first letter: `z` for Zen, say. With one
  window the label is `z`; with several, `zj`, `zk`… A pinned app that
  isn't running shows in a dock row under the map, and its letter launches
  it (through `niri msg action spawn`, so it's niri's child, not
  Noctalia's).
- **Every other window** gets a label from the leftover letters
  (`hint_chars`, home row first): one letter each while they suffice, two
  for all of them after, so no label is a prefix of another.

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
# Letters for the other windows' labels, best first.
hint_chars = "asdfghjklqwertyuiopzxcvbnm"
```

Find an app's `app_id` with `niri msg windows`.
