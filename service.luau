--!nonstrict
-- Mirrors niri's workspaces and windows from `niri msg --json event-stream`
-- (a full state first, then changes) and publishes them as
-- "switcher.snapshot" for the panel. Approach borrowed from
-- teagar/niri-workspace-preview's service.
--
-- Previews: niri can't capture a window that isn't on screen (no
-- ext-image-copy-capture), and its screenshot-window action always copies
-- to the clipboard. So shortly after things settle, grim captures each
-- window that is on screen where its position can be worked out, and the
-- panel shows the last capture. IPC gives on-screen positions only for
-- floating windows; tiled ones are laid out here from the layout (see
-- tiledRects), assuming no struts and work-area insets split evenly
-- between top and bottom.

local STATE_KEY = "switcher.snapshot"
local OPEN_KEY = "switcher.open"
local PANEL_ID = "filedesless/switcher:panel"
local STREAM = [[
delay=1
while :; do
  if niri msg --json event-stream; then delay=1; fi
  sleep "$delay"
  if [ "$delay" -lt 16 ]; then delay=$((delay * 2)); else delay=30; fi
done
]]
-- Args: dir, then "id x y w h scale" per window. Skips everything while the
-- session is locked (the lock screen would be captured instead). Prints
-- "id path" per capture and deletes that window's older ones.
local CAPTURE = [[
dir=$1; shift
mkdir -p -m 700 "$dir" || exit 1
s=$(loginctl show-user "$(id -un)" -p Display --value 2>/dev/null)
[ -n "$s" ] && [ "$(loginctl show-session "$s" -p LockedHint --value)" = yes ] && exit 0
stamp=$(date +%s%N)
while [ $# -ge 6 ]; do
  id=$1 x=$2 y=$3 w=$4 h=$5 sc=$6; shift 6
  f=$dir/$id-$stamp.jpg
  if grim -g "$x,$y ${w}x$h" -s "$sc" -t jpeg -q 75 "$f" 2>/dev/null; then
    for old in "$dir/$id"-*.jpg; do [ "$old" = "$f" ] || rm -f "$old"; done
    echo "$id $f"
  fi
done
]]

local PREVIEW_W = 480 -- px, thumbnail width
local SETTLE_MS = 700 -- after the last change, before capturing
local MIN_GAP_MS = 1500 -- between two captures
local ICONS_PER_CALL = 2
local IDLE_MS, BUSY_MS = 60000, 100

local previewsOn = noctalia.getConfig("previews") ~= false
local GAP = tonumber(noctalia.getConfig("gaps")) or 16
local dir = (noctalia.getenv("XDG_RUNTIME_DIR") or "/tmp") .. "/noctalia-switcher"

local workspaces = {}
local windows = {}
-- app_id -> icon path (false when there is none). Resolved here, a few at
-- a time as apps appear, because resolving them all in the panel's onOpen
-- can exceed its CPU budget.
local icons = {}
local previews = {} -- "w<id>" -> jpeg path
local niriOutputs = {} -- name -> logical { x, y, width, height }
local captureDue = nil
local capturing = false
local lastCapture = 0
local panelOpen = false

local function findById(values, id)
  for index, value in ipairs(values) do
    if value.id == id then
      return index, value
    end
  end
  return nil, nil
end

-- niri's focus_timestamp as a number (seconds), for most-recently-used order.
local function stamp(t)
  if type(t) ~= "table" then
    return nil
  end
  return (tonumber(t.secs) or 0) + (tonumber(t.nanos) or 0) / 1e9
end

local function normalizeWindow(w, previous)
  if type(w) ~= "table" or w.id == nil then
    return nil
  end
  previous = previous or {}
  local layout = type(w.layout) == "table" and w.layout or {}
  return {
    id = w.id,
    app_id = w.app_id or "",
    title = w.title or "",
    -- Floating windows can report no workspace while moving; keep the last.
    workspace_id = w.workspace_id or previous.workspace_id,
    is_focused = w.is_focused == true,
    is_floating = w.is_floating == true,
    focus = stamp(w.focus_timestamp) or previous.focus or 0,
    pos = layout.pos_in_scrolling_layout,
    size = layout.tile_size or previous.size,
    wsize = layout.window_size or previous.wsize,
    offset = layout.window_offset_in_tile or previous.offset,
    tile_pos = layout.tile_pos_in_workspace_view,
  }
end

local function normalizeWorkspace(ws)
  return {
    id = ws.id,
    idx = ws.idx,
    name = ws.name,
    output = ws.output,
    is_active = ws.is_active == true,
    is_focused = ws.is_focused == true,
    active_window_id = ws.active_window_id,
  }
end

local function outputs()
  local result = {}
  for _, o in ipairs(noctalia.outputs() or {}) do
    table.insert(result, { name = o.name, x = o.x or 0, y = o.y or 0, width = o.width, height = o.height, focused = o.focused == true })
  end
  table.sort(result, function(a, b)
    if a.x ~= b.x then
      return a.x < b.x
    end
    return a.y < b.y
  end)
  return result
end

local function publish()
  noctalia.state.set(STATE_KEY, { outputs = outputs(), workspaces = workspaces, windows = windows, icons = icons, previews = previews })
end

-- Resolves up to ICONS_PER_CALL missing icons; true if some are still
-- missing. A cold lookup is slow enough that a dozen at once overruns the
-- callback's CPU budget, so the rest are left to update() ticks.
local function resolveIcons()
  local done = 0
  for _, w in ipairs(windows) do
    if w.app_id ~= "" and icons[w.app_id] == nil then
      if done == ICONS_PER_CALL then
        return true
      end
      icons[w.app_id] = noctalia.appIconPath(w.app_id, 32) or false
      done += 1
    end
  end
  return false
end

local function iconsPending()
  for _, w in ipairs(windows) do
    if w.app_id ~= "" and icons[w.app_id] == nil then
      return true
    end
  end
  return false
end

local function tick()
  noctalia.setUpdateInterval((iconsPending() or captureDue ~= nil) and BUSY_MS or IDLE_MS)
end

local function refresh()
  resolveIcons()
  publish()
  tick()
end

local function scheduleCapture()
  if previewsOn then
    captureDue = noctalia.nowMs() + SETTLE_MS
    tick()
  end
end

-- On-screen rects (logical, output-relative) of the tiled windows of one
-- active workspace, where they're certain. With no struts and gaps G, a
-- column's tiles fill the work area's height between gaps, which gives the
-- work area (its insets split evenly, as with equal top and bottom bars).
-- If all columns fit, nothing scrolls and they sit left to right from G.
-- Otherwise only the active window's column is known for sure: when it is
-- full width, the first column (at G) or the last (against the right edge).
local function tiledRects(ws, list, out)
  local columns, order = {}, {}
  for _, w in ipairs(list) do
    if w.pos and not w.is_floating and w.size then
      local c = w.pos[1]
      if columns[c] == nil then
        columns[c] = {}
        table.insert(order, c)
      end
      table.insert(columns[c], w)
    end
  end
  table.sort(order)
  if #order == 0 then
    return {}
  end

  local widths, total = {}, -GAP
  for _, c in ipairs(order) do
    table.sort(columns[c], function(a, b)
      return (a.pos[2] or 0) < (b.pos[2] or 0)
    end)
    local width = 0
    for _, w in ipairs(columns[c]) do
      width = math.max(width, w.size[1])
    end
    widths[c] = width
    total += width + GAP
  end

  -- Fullscreen: the tile is the whole output.
  local rects = {}
  local areaW = out.width
  local xs = {}
  if total <= areaW - 2 * GAP then
    local x = GAP
    for _, c in ipairs(order) do
      xs[c] = x
      x += widths[c] + GAP
    end
  else
    local active = nil
    for _, w in ipairs(list) do
      if w.id == ws.active_window_id and w.pos then
        active = w.pos[1]
      end
    end
    if active ~= nil then
      if widths[active] >= areaW - 2 * GAP then
        xs[active] = GAP
      elseif active == order[1] then
        xs[active] = GAP
      elseif active == order[#order] then
        xs[active] = areaW - GAP - widths[active]
      end
    end
  end

  for c, x in pairs(xs) do
    local tiles = columns[c]
    local used = GAP * (#tiles + 1)
    for _, w in ipairs(tiles) do
      used += w.size[2]
    end
    local top = math.floor((out.height - used) / 2) + GAP
    local y = top
    for _, w in ipairs(tiles) do
      if w.size[1] >= out.width and w.size[2] >= out.height then
        rects[w.id] = { 0, 0 }
      else
        rects[w.id] = { x, y }
      end
      y += w.size[2] + GAP
    end
  end
  return rects
end

local function captureTargets()
  local byWs = {}
  for _, w in ipairs(windows) do
    if w.workspace_id then
      byWs[w.workspace_id] = byWs[w.workspace_id] or {}
      table.insert(byWs[w.workspace_id], w)
    end
  end
  local args = {}
  for _, ws in ipairs(workspaces) do
    local out = niriOutputs[ws.output]
    local list = byWs[ws.id]
    if ws.is_active and out and list then
      local rects = tiledRects(ws, list, out)
      for _, w in ipairs(list) do
        if w.is_floating and w.tile_pos then
          rects[w.id] = { w.tile_pos[1], w.tile_pos[2] }
        end
      end
      for _, w in ipairs(list) do
        local r = rects[w.id]
        local size = w.wsize or w.size
        if r and size then
          local off = w.offset or { 0, 0 }
          local x = math.floor(r[1] + off[1])
          local y = math.floor(r[2] + off[2])
          local width, height = math.floor(size[1]), math.floor(size[2])
          -- Only windows wholly on their output.
          if x >= 0 and y >= 0 and x + width <= out.width and y + height <= out.height and width > 0 and height > 0 then
            for _, v in ipairs({
              tostring(w.id),
              tostring(out.x + x),
              tostring(out.y + y),
              tostring(width),
              tostring(height),
              string.format("%.4f", math.min(1, PREVIEW_W / width)),
            }) do
              table.insert(args, v)
            end
          end
        end
      end
    end
  end
  return args
end

local function capture()
  local args = captureTargets()
  if #args == 0 then
    return
  end
  capturing = true
  lastCapture = noctalia.nowMs()
  local argv = { "sh", "-c", CAPTURE, "sh", dir }
  for _, a in ipairs(args) do
    table.insert(argv, a)
  end
  noctalia.runAsync(argv, function(res)
    capturing = false
    for id, path in tostring(res.stdout or ""):gmatch("(%d+) (%S+)") do
      previews["w" .. id] = path
    end
    publish()
  end)
end

function update()
  if iconsPending() then
    resolveIcons()
    publish()
  end
  if captureDue ~= nil and noctalia.nowMs() >= captureDue then
    if panelOpen or capturing or noctalia.nowMs() - lastCapture < MIN_GAP_MS then
      captureDue = noctalia.nowMs() + SETTLE_MS
    else
      captureDue = nil
      capture()
    end
  end
  tick()
end

local function loadOutputs()
  noctalia.runAsync({ "niri", "msg", "--json", "outputs" }, function(res)
    local decoded = noctalia.json.decode(res.stdout or "")
    if type(decoded) ~= "table" then
      return
    end
    niriOutputs = {}
    for name, o in pairs(decoded) do
      if type(o) == "table" and type(o.logical) == "table" then
        niriOutputs[o.name or name] = o.logical
      end
    end
    scheduleCapture()
  end)
end

local function applyEvent(e)
  if e.WorkspacesChanged then
    workspaces = {}
    for _, ws in ipairs(e.WorkspacesChanged.workspaces or {}) do
      table.insert(workspaces, normalizeWorkspace(ws))
    end
  elseif e.WorkspaceActivated then
    local _, activated = findById(workspaces, e.WorkspaceActivated.id)
    if activated == nil then
      return false
    end
    for _, ws in ipairs(workspaces) do
      if ws.output == activated.output then
        ws.is_active = ws.id == activated.id
      end
      if e.WorkspaceActivated.focused then
        ws.is_focused = ws.id == activated.id
      end
    end
  elseif e.WorkspaceActiveWindowChanged then
    local _, ws = findById(workspaces, e.WorkspaceActiveWindowChanged.workspace_id)
    if ws == nil then
      return false
    end
    ws.active_window_id = e.WorkspaceActiveWindowChanged.active_window_id
  elseif e.WindowsChanged then
    local previous = {}
    for _, w in ipairs(windows) do
      previous[w.id] = w
    end
    windows = {}
    for _, w in ipairs(e.WindowsChanged.windows or {}) do
      local n = normalizeWindow(w, previous[w.id])
      if n then
        table.insert(windows, n)
      end
    end
  elseif e.WindowOpenedOrChanged then
    local w = e.WindowOpenedOrChanged.window
    local index, previous = findById(windows, w and w.id)
    local n = normalizeWindow(w, previous)
    if n == nil then
      return false
    end
    if n.is_focused then
      for _, other in ipairs(windows) do
        other.is_focused = false
      end
    end
    if index then
      windows[index] = n
    else
      table.insert(windows, n)
    end
  elseif e.WindowClosed then
    local id = e.WindowClosed.id
    local index = findById(windows, id)
    if index then
      table.remove(windows, index)
    end
    local path = previews["w" .. tostring(id)]
    if path then
      previews["w" .. tostring(id)] = nil
      noctalia.runAsync({ "rm", "-f", path })
    end
  elseif e.WindowFocusChanged then
    for _, w in ipairs(windows) do
      w.is_focused = w.id == e.WindowFocusChanged.id
    end
  elseif e.WindowFocusTimestampChanged then
    local _, w = findById(windows, e.WindowFocusTimestampChanged.id)
    if w == nil then
      return false
    end
    w.focus = stamp(e.WindowFocusTimestampChanged.focus_timestamp) or w.focus
  elseif e.WindowLayoutsChanged then
    for _, change in ipairs(e.WindowLayoutsChanged.changes or {}) do
      local _, w = findById(windows, change[1])
      local layout = change[2]
      if w and type(layout) == "table" then
        w.pos = layout.pos_in_scrolling_layout
        w.size = layout.tile_size or w.size
        w.wsize = layout.window_size or w.wsize
        w.offset = layout.window_offset_in_tile or w.offset
        w.tile_pos = layout.tile_pos_in_workspace_view
      end
    end
  else
    return false
  end
  return true
end

publish()
if noctalia.commandExists("niri") then
  loadOutputs()
  noctalia.runStream(STREAM, function(line)
    local event = noctalia.json.decode(line)
    if type(event) == "table" and applyEvent(event) then
      refresh()
      scheduleCapture()
    end
  end)
else
  noctalia.log("switcher: niri not found on PATH")
end

-- The panel says when it's open: captures wait, so it isn't in them.
noctalia.state.watch(OPEN_KEY, function(value)
  panelOpen = value == true
  if not panelOpen then
    scheduleCapture()
  end
end)

function onOutputsChanged()
  publish()
  loadOutputs()
end

-- The previously focused window: the second most recently used. Not "the
-- latest that isn't focused": while the panel holds the keyboard, niri
-- reports no window focused.
local function previousWindow()
  local first, second = nil, nil
  for _, w in ipairs(windows) do
    if first == nil or w.focus > first.focus then
      first, second = w, first
    elseif second == nil or w.focus > second.focus then
      second = w
    end
  end
  return second
end

-- noctalia msg plugin filedesless/switcher:service all toggle
-- Opens the panel; pressed again while it's open, goes back to the previous
-- window (a quick alt-tab) and closes it.
function onIpc(event)
  if event ~= "toggle" then
    return
  end
  if panelOpen then
    local w = previousWindow()
    if w then
      noctalia.runAsync({ "niri", "msg", "action", "focus-window", "--id", tostring(w.id) })
    end
  end
  noctalia.togglePanel(PANEL_ID)
end
