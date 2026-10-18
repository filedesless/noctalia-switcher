--!nonstrict
-- Mirrors niri's workspaces and windows from `niri msg --json event-stream`
-- (a full state first, then changes) and publishes them as
-- "switcher.snapshot" for the panel. Approach borrowed from
-- teagar/niri-workspace-preview's service.

local STATE_KEY = "switcher.snapshot"
local STREAM = [[
delay=1
while :; do
  if niri msg --json event-stream; then delay=1; fi
  sleep "$delay"
  if [ "$delay" -lt 16 ]; then delay=$((delay * 2)); else delay=30; fi
done
]]

local workspaces = {}
local windows = {}

local function findById(values, id)
  for index, value in ipairs(values) do
    if value.id == id then
      return index, value
    end
  end
  return nil, nil
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
    pos = layout.pos_in_scrolling_layout,
    size = layout.tile_size or previous.size,
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
  noctalia.state.set(STATE_KEY, { outputs = outputs(), workspaces = workspaces, windows = windows })
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
    local index = findById(windows, e.WindowClosed.id)
    if index then
      table.remove(windows, index)
    end
  elseif e.WindowFocusChanged then
    for _, w in ipairs(windows) do
      w.is_focused = w.id == e.WindowFocusChanged.id
    end
  elseif e.WindowLayoutsChanged then
    for _, change in ipairs(e.WindowLayoutsChanged.changes or {}) do
      local _, w = findById(windows, change[1])
      local layout = change[2]
      if w and type(layout) == "table" then
        w.pos = layout.pos_in_scrolling_layout
        w.size = layout.tile_size or w.size
      end
    end
  else
    return false
  end
  return true
end

publish()
if noctalia.commandExists("niri") then
  noctalia.runStream(STREAM, function(line)
    local event = noctalia.json.decode(line)
    if type(event) == "table" and applyEvent(event) then
      publish()
    end
  end)
else
  noctalia.log("switcher: niri not found on PATH")
end

function onOutputsChanged()
  publish()
end
