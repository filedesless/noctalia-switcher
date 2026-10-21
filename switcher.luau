--!nonstrict
-- The switcher's two panels, one core. Each panel's entry (panel.luau,
-- compact.luau) calls start with its mode, since a panel can't tell which
-- manifest entry loaded it:
--
-- - "full": a minimap of every monitor (left to right), its workspaces (top
--   to bottom) and their windows (in column order, a column's stacked
--   windows one above the other), each window labelled.
-- - "compact": a list of the windows' labels and app names, no previews.
--
-- Typing a label focuses that window; Space switches to the other panel,
-- Backspace undoes a letter, Esc closes. Letters typed with rcmd held reach
-- niri's binds, and come here through the service (KEY_KEY). Labels come
-- from labels.luau.

local labelsLib = require("./labels.luau")

local SNAPSHOT = "switcher.snapshot"
local OPEN_KEY = "switcher.open" -- the open panel's mode, or false
local PENDING_KEY = "switcher.pending" -- letters to start with, from the service
local KEY_KEY = "switcher.key" -- { key, n }: a key forwarded by the service
local PANEL_IDS = { full = "filedesless/switcher:panel", compact = "filedesless/switcher:compact" }
-- Must match the [[panel]] sizes in plugin.toml.
local PANEL_W, PANEL_H = 1400, 880
local COMPACT_W, COMPACT_H = 560, 520
local PAD = 16
local HEADER_H, OUTPUT_LABEL_H = 34, 22
local OUTPUT_GAP = 16
local ROW_GAP = 8
local TILE_GAP = 6
local WS_LABEL_W = 36
local ROW_MIN_H, ROW_MAX_H = 26, 240
local FOOT_H = 22 -- a preview tile's strip with icon, label and title
local TILE_PAD = 3
local MIN_IMG_H = 36 -- below this, tiles go compact: no preview
local COMPACT_MIN_W, COMPACT_MAX_W = 34, 200
local LIST_ROW_H, LIST_GAP, BADGE_W = 30, 4, 38

local M = {}

local mode = "full"
local snapshot = nil
local typed = ""
local targets = {} -- label -> window id
local lastKey = nil -- n of the last forwarded key handled

-- Icons come resolved from the service.
local function icon(appId)
  local known = snapshot and snapshot.icons and snapshot.icons[appId]
  return known or nil
end

-- Workspaces worth showing, per output: those with windows, plus the active
-- one so an empty monitor still shows where it is.
local function layoutModel()
  local s = snapshot or {}
  local byWs = {}
  for _, w in ipairs(labelsLib.windowsShown(s)) do
    byWs[w.workspace_id] = byWs[w.workspace_id] or {}
    table.insert(byWs[w.workspace_id], w)
  end
  local model = {}
  for _, o in ipairs(s.outputs or {}) do
    local entry = { output = o, workspaces = {} }
    local list = {}
    for _, ws in ipairs(s.workspaces or {}) do
      if ws.output == o.name and (byWs[ws.id] or ws.is_active) then
        table.insert(list, ws)
      end
    end
    table.sort(list, function(a, b)
      return (a.idx or 0) < (b.idx or 0)
    end)
    for _, ws in ipairs(list) do
      -- Columns in order; floating windows after them, one per column.
      local columns, floating = {}, {}
      for _, w in ipairs(byWs[ws.id] or {}) do
        if w.pos and not w.is_floating then
          local c = w.pos[1]
          columns[c] = columns[c] or {}
          table.insert(columns[c], w)
        else
          table.insert(floating, { w })
        end
      end
      local ordered = {}
      local keys = {}
      for c in pairs(columns) do
        table.insert(keys, c)
      end
      table.sort(keys)
      for _, c in ipairs(keys) do
        table.sort(columns[c], function(a, b)
          return (a.pos[2] or 0) < (b.pos[2] or 0)
        end)
        table.insert(ordered, columns[c])
      end
      for _, f in ipairs(floating) do
        table.insert(ordered, f)
      end
      table.insert(entry.workspaces, { ws = ws, columns = ordered })
    end
    table.insert(model, entry)
  end
  return model
end

-- The current window, to highlight: the most recently used one. Not
-- is_focused: niri reports no window focused while the panel holds the
-- keyboard.
local function isCurrent(w)
  local first = nil
  for _, v in ipairs((snapshot or {}).windows or {}) do
    if first == nil or (v.focus or 0) > (first.focus or 0) then
      first = v
    end
  end
  return first ~= nil and first.id == w.id
end

local function assignLabels()
  local labels
  labels, targets = labelsLib.assign(labelsLib.windowsShown(snapshot))
  return labels
end

local function matches(label)
  return label ~= nil and label:sub(1, #typed) == typed
end

local function badge(label, big)
  local done = label:sub(1, #typed)
  local rest = label:sub(#typed + 1)
  local size = big and 16 or 13
  return ui.row({ radius = 6, fill = "primary", paddingH = 7, paddingV = 2, align = "center" }, {
    ui.label({ text = done, fontSize = size, fontWeight = "bold", color = "on_primary", opacity = 0.45, visible = done ~= "" }),
    ui.label({ text = rest, fontSize = size, fontWeight = "bold", color = "on_primary" }),
  })
end

local function focus(id)
  if id == nil then
    return
  end
  panel.close()
  noctalia.runAsync({ "niri", "msg", "action", "focus-window", "--id", tostring(id) })
end

-- The other panel; opening it closes this one.
local function switchMode()
  noctalia.togglePanel(mode == "full" and PANEL_IDS.compact or PANEL_IDS.full)
end

local function aspectOf(w)
  local size = w.wsize or w.size
  if size and size[2] and size[2] > 0 then
    return size[1] / size[2]
  end
  return 16 / 10
end

local function previewOf(w)
  local previews = snapshot and snapshot.previews
  return previews and previews["w" .. tostring(w.id)] or nil
end

-- A tile of the given height: with an image area (the window's last
-- capture, or its icon) sized to the window's aspect ratio when there's
-- room, else compact (icon and label).
local function tileSize(w, height)
  local imgH = height - FOOT_H - 2 * TILE_PAD
  if imgH >= MIN_IMG_H then
    return math.floor(imgH * aspectOf(w)) + 2 * TILE_PAD, imgH
  end
  return math.max(COMPACT_MIN_W, math.min(COMPACT_MAX_W, math.floor(height * aspectOf(w)))), nil
end

local function tile(w, label, height)
  local dim = typed ~= "" and not matches(label)
  local current = isCurrent(w)
  local width, imgH = tileSize(w, height)
  local path = icon(w.app_id)
  local content
  if imgH == nil then
    content = {
      ui.row({ gap = 4, align = "center", justify = "center", flexGrow = 1 }, {
        ui.image({ path = path, width = 16, height = 16, fit = "contain", visible = path ~= nil and width >= 64 }),
        label and badge(label, false) or ui.spacer({}),
      }),
    }
  else
    local imgW = width - 2 * TILE_PAD
    local preview = previewOf(w)
    local picture
    if preview then
      picture = ui.image({ key = preview, path = preview, width = imgW, height = imgH, radius = 4, fit = "contain" })
    else
      local size = math.min(48, math.floor(imgH * 0.6))
      picture = ui.row({ width = imgW, height = imgH, align = "center", justify = "center", radius = 4, fill = "surface/0.35" }, {
        ui.image({ path = path, width = size, height = size, fit = "contain", visible = path ~= nil }),
      })
    end
    content = {
      picture,
      ui.row({ gap = 5, align = "center", height = FOOT_H, paddingH = 2 }, {
        label and badge(label, false) or ui.spacer({}),
        ui.image({ path = path, width = 14, height = 14, fit = "contain", visible = path ~= nil }),
        ui.label({ text = w.title ~= "" and w.title or w.app_id, fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
      }),
    }
  end
  return ui.column({
    key = "w" .. w.id,
    width = width,
    height = height,
    padding = TILE_PAD,
    gap = 0,
    radius = 7,
    fill = current and "primary/0.16" or "surface_variant/0.55",
    border = current and "primary" or "outline/0.35",
    borderWidth = current and 2 or 1,
    opacity = dim and 0.3 or 1,
    onClick = function()
      focus(w.id)
    end,
  }, content)
end

-- The row's width at a given height: each column as wide as its widest
-- tile, a column's stacked tiles sharing the height.
local function rowWidth(columns, rowH)
  local total = TILE_GAP * math.max(0, #columns - 1)
  for _, column in ipairs(columns) do
    local k = #column
    local tileH = math.floor((rowH - TILE_GAP * (k - 1)) / k)
    local widest = 0
    for _, w in ipairs(column) do
      widest = math.max(widest, (tileSize(w, tileH)))
    end
    total += widest
  end
  return total
end

-- The minimap. Fits everything in the panel: each monitor gets an equal
-- share of the width and its workspaces an equal share of the height. Tiles
-- keep their windows' aspect ratios; a row too wide for its monitor's share
-- gets shorter as a whole instead of squeezed.
local function renderMap(labels)
  local model = layoutModel()
  local blockW = math.floor((PANEL_W - 2 * PAD - OUTPUT_GAP * math.max(0, #model - 1)) / math.max(1, #model))
  local availW = blockW - WS_LABEL_W - TILE_GAP
  local availH = PANEL_H - 2 * PAD - HEADER_H - OUTPUT_LABEL_H - 24

  local blocks = {}
  for _, entry in ipairs(model) do
    local n = math.max(1, #entry.workspaces)

    -- How a row of one workspace comes out in a cell of the given size:
    -- its height (shrunk until it fits the width) and the tiles' area.
    local function fitRow(row, cellW, cellH)
      local rowH = cellH
      local width = rowWidth(row.columns, rowH)
      local tries = 0
      while width > cellW and rowH > ROW_MIN_H and tries < 6 do
        rowH = math.max(ROW_MIN_H, math.floor(rowH * cellW / width))
        width = rowWidth(row.columns, rowH)
        tries += 1
      end
      return rowH, width * rowH
    end

    -- Workspaces go in a grid, g per line; g is the one that gives the
    -- tiles the most area (many small workspaces: several per line).
    local best, bestArea = 1, -1
    for g = 1, 4 do
      local lines = math.ceil(n / g)
      local cellW = math.floor((availW + WS_LABEL_W + TILE_GAP - OUTPUT_GAP * (g - 1)) / g) - WS_LABEL_W - TILE_GAP
      local cellH = math.max(ROW_MIN_H, math.min(ROW_MAX_H, math.floor((availH - ROW_GAP * (lines - 1)) / lines)))
      local area = 0
      for _, row in ipairs(entry.workspaces) do
        local _, a = fitRow(row, cellW, cellH)
        area += a
      end
      if cellW > 40 and area > bestArea * 1.05 then
        best, bestArea = g, area
      end
    end
    local g = best
    local lines = math.ceil(n / g)
    local cellW = math.floor((availW + WS_LABEL_W + TILE_GAP - OUTPUT_GAP * (g - 1)) / g) - WS_LABEL_W - TILE_GAP
    local cellH = math.max(ROW_MIN_H, math.min(ROW_MAX_H, math.floor((availH - ROW_GAP * (lines - 1)) / lines)))

    local cells = {}
    for _, row in ipairs(entry.workspaces) do
      local rowH = fitRow(row, cellW, cellH)
      local cols = {}
      for _, column in ipairs(row.columns) do
        local k = #column
        local tileH = math.max(18, math.floor((rowH - TILE_GAP * (k - 1)) / k))
        local stacked = {}
        for _, w in ipairs(column) do
          table.insert(stacked, tile(w, labels[w.id], tileH))
        end
        table.insert(cols, ui.column({ gap = TILE_GAP }, stacked))
      end
      local ws = row.ws
      table.insert(cells, ui.row({ gap = TILE_GAP, align = "center", width = cellW + WS_LABEL_W + TILE_GAP, height = cellH }, {
        ui.label({ text = ws.name or tostring(ws.idx or ""), width = WS_LABEL_W, fontSize = 11, fontWeight = ws.is_active and "bold" or "normal", color = ws.is_active and "primary" or "on_surface_variant", maxLines = 1 }),
        ui.row({ gap = TILE_GAP, align = "center" }, cols),
      }))
    end
    local gridLines = {}
    for i = 1, #cells, g do
      local line = {}
      for j = i, math.min(i + g - 1, #cells) do
        table.insert(line, cells[j])
      end
      table.insert(gridLines, ui.row({ gap = OUTPUT_GAP }, line))
    end
    local o = entry.output
    table.insert(blocks, ui.column({ width = blockW, gap = ROW_GAP }, {
      ui.label({ text = o.name or "", fontSize = 12, fontWeight = "bold", color = o.focused and "primary" or "on_surface_variant" }),
      ui.column({ gap = ROW_GAP }, gridLines),
    }))
  end
  return ui.row({ gap = OUTPUT_GAP, align = "start" }, blocks)
end

local function listRow(key, keyCap, content, opts)
  return ui.row({
    key = key,
    gap = 8,
    align = "center",
    height = LIST_ROW_H,
    paddingH = 8,
    radius = 6,
    fill = opts.current and "primary/0.16" or "surface_variant/0.35",
    opacity = opts.dim and 0.3 or 1,
    onClick = opts.onClick,
  }, {
    ui.row({ width = BADGE_W, align = "center" }, { keyCap }),
    table.unpack(content),
  })
end

-- The compact list: a row per window, by label, with its app's name; the
-- window's title too when its app has several. Last, Space for the
-- minimap. Two columns when one is too short.
local function renderList(labels)
  local windows = labelsLib.windowsShown(snapshot)
  local perApp = {}
  for _, w in ipairs(windows) do
    perApp[w.app_id] = (perApp[w.app_id] or 0) + 1
  end
  table.sort(windows, function(a, b)
    return (labels[a.id] or "") < (labels[b.id] or "")
  end)

  local rows = {}
  for _, w in ipairs(windows) do
    local label = labels[w.id]
    local path = icon(w.app_id)
    table.insert(rows, listRow("w" .. w.id, label and badge(label, false) or ui.spacer({}), {
      ui.row({ width = 16, height = 16 }, {
        ui.image({ path = path, width = 16, height = 16, fit = "contain", visible = path ~= nil }),
      }),
      ui.label({ text = labelsLib.appName(w.app_id), fontSize = 13, fontWeight = "bold", maxLines = 1 }),
      ui.label({ text = w.title, fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1, visible = perApp[w.app_id] > 1 }),
    }, {
      current = isCurrent(w),
      dim = typed ~= "" and not matches(label),
      onClick = function()
        focus(w.id)
      end,
    }))
  end
  table.insert(rows, listRow("space", ui.row({ radius = 6, fill = "secondary", paddingH = 7, paddingV = 2 }, {
    ui.label({ text = "␣", fontSize = 13, fontWeight = "bold", color = "on_secondary" }),
  }), {
    ui.glyph({ name = "layout-grid", size = 16, color = "secondary" }),
    ui.label({ text = "All windows", fontSize = 13, fontWeight = "bold", color = "secondary" }),
  }, { dim = typed ~= "", onClick = switchMode }))

  local availH = COMPACT_H - 2 * PAD - HEADER_H - 12
  local perColumn = math.max(1, math.floor((availH + LIST_GAP) / (LIST_ROW_H + LIST_GAP)))
  local columns = {}
  for i = 1, #rows, perColumn do
    local column = {}
    for j = i, math.min(i + perColumn - 1, #rows) do
      table.insert(column, rows[j])
    end
    table.insert(columns, ui.column({ gap = LIST_GAP, flexGrow = 1 }, column))
  end
  return ui.row({ gap = 12, align = "start" }, columns)
end

local function render()
  local labels = assignLabels()
  local body
  if snapshot == nil then
    body = ui.label({ text = "Waiting for niri…", color = "on_surface_variant" })
  elseif mode == "compact" then
    body = renderList(labels)
  else
    body = renderMap(labels)
  end
  local hint = mode == "compact" and "Type a label · Space for all windows · Esc to close"
    or "Type a label · Space for the list · Backspace to undo · Esc to close"
  panel.render(ui.column({ gap = 12, padding = 4 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = mode == "compact" and "list" or "layout-grid", size = 18, color = "primary" }),
        ui.label({ text = "Switch window", fontSize = 15, fontWeight = "bold" }),
        ui.label({ text = typed, fontSize = 15, fontWeight = "bold", color = "primary", visible = typed ~= "" }),
      }),
      ui.label({ text = hint, fontSize = 11, color = "on_surface_variant" }),
    }),
    body,
  }))
end

local function isOpen()
  return noctalia.state.get(OPEN_KEY) == mode
end

-- A key, typed here or forwarded by the service.
local function handle(key)
  if key == "escape" then
    panel.close()
    return
  elseif key == "space" then
    switchMode()
    return
  elseif key == "backspace" then
    typed = typed:sub(1, -2)
    render()
    return
  elseif not key:match("^%l$") then
    return
  end

  typed ..= key
  if targets[typed] then
    focus(targets[typed])
    return
  end
  for label in pairs(targets) do
    if matches(label) then
      render()
      return
    end
  end
  -- Nothing starts with that: start over.
  typed = ""
  render()
end

-- Defines the panel's callbacks for the given mode ("full" or "compact").
function M.start(m)
  mode = m
  lastKey = (noctalia.state.get(KEY_KEY) or {}).n

  noctalia.state.watch(SNAPSHOT, function(value)
    snapshot = value
    if isOpen() then
      render()
    end
  end)

  noctalia.state.watch(KEY_KEY, function(value)
    if type(value) ~= "table" or value.n == lastKey then
      return
    end
    lastKey = value.n
    if isOpen() and type(value.key) == "string" then
      handle(value.key)
    end
  end)

  return {
    onOpen = function(_context)
      noctalia.state.set(OPEN_KEY, mode)
      snapshot = noctalia.state.get(SNAPSHOT)
      local pending = noctalia.state.get(PENDING_KEY)
      noctalia.state.set(PENDING_KEY, false)
      typed = ""
      render()
      -- Letters sent with rcmd before the panel was up, as if typed here.
      if type(pending) == "string" then
        for c in pending:gmatch("%l") do
          handle(c)
        end
      end
    end,
    onClose = function()
      -- Switching panels may open the other one first.
      if isOpen() then
        noctalia.state.set(OPEN_KEY, false)
      end
    end,
    onKey = function(chord, pressed)
      if pressed then
        handle(string.lower(chord))
      end
    end,
  }
end

return M
