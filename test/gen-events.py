# Writes events.jsonl: what `niri msg --json event-stream` starts with, for
# 8 windows on 4 workspaces over 2 outputs. Recency (focus) decides second
# letters: st steam / sp spotify, ze zen / zd zed, al / ac for the two
# terminals; obsidian (o) and thunderbird (t) have their letter alone.
import json
import pathlib

ws = [
    dict(id=1, idx=1, name=None, output="HEADLESS-1", is_active=True, is_focused=True, active_window_id=1),
    dict(id=2, idx=2, name=None, output="HEADLESS-1", is_active=False, is_focused=False, active_window_id=3),
    dict(id=3, idx=1, name=None, output="HEADLESS-2", is_active=True, is_focused=False, active_window_id=5),
    dict(id=4, idx=2, name=None, output="HEADLESS-2", is_active=False, is_focused=False, active_window_id=8),
]


def win(id, app, title, wsid, col, row, focus, w=944, h=1032):
    return dict(
        id=id, title=title, app_id=app, pid=None, workspace_id=wsid, is_focused=False,
        is_floating=False, is_urgent=False, focus_timestamp=dict(secs=focus, nanos=0),
        layout=dict(pos_in_scrolling_layout=[col, row], tile_size=[w, h], window_size=[w, h],
                    tile_pos_in_workspace_view=None, window_offset_in_tile=[0, 0]),
    )


wins = [
    win(1, "steam", "Steam", 1, 1, 1, 100),
    win(2, "spotify", "Spotify Premium", 1, 2, 1, 80),
    win(3, "zen", "Zen Browser", 2, 1, 1, 90),
    win(4, "dev.zed.Zed", "main.rs — zed", 2, 2, 1, 50),
    win(5, "Alacritty", "~/src/these", 3, 1, 1, 70, h=508),
    win(6, "Alacritty", "htop", 3, 1, 2, 40, h=508),
    win(7, "md.obsidian.Obsidian", "notes - Obsidian", 3, 2, 1, 60),
    win(8, "thunderbird", "Inbox - Thunderbird", 4, 1, 1, 30),
]
lines = [{"WorkspacesChanged": {"workspaces": ws}}, {"WindowsChanged": {"windows": wins}}]
out = pathlib.Path(__file__).with_name("events.jsonl")
out.write_text("".join(json.dumps(e) + "\n" for e in lines))
