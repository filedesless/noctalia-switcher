--!nonstrict
-- The switcher: a minimap of every monitor (left to right), its workspaces
-- (top to bottom) and their windows (in column order, a column's stacked
-- windows one above the other), each window labelled. Typing a label
-- focuses that window; Backspace undoes a letter, Esc closes.
--
-- Labels: a pinned app's key goes to its last used window, and a pinned app
-- with no window shows in the dock, where its key launches it. Every other
-- window gets a lasting label from the leftover letters, after its app's
-- name where it can (see assignLabels). Space goes back to the previous
-- window.

local SNAPSHOT = "switcher.snapshot"
local OPEN_KEY = "switcher.open"
local LABELS_KEY = "switcher.labels"
-- Must match [[panel]] width/height in plugin.toml.
local PANEL_W, PANEL_H = 1400, 880
local PAD = 16
local HEADER_H, DOCK_H, OUTPUT_LABEL_H = 34, 44, 22
local OUTPUT_GAP = 16
local ROW_GAP = 8
local TILE_GAP = 6
local WS_LABEL_W = 36
local ROW_MIN_H, ROW_MAX_H = 26, 240
local FOOT_H = 22 -- a preview tile's strip with icon, label and title
local TILE_PAD = 3
local MIN_IMG_H = 36 -- below this, tiles go compact: no preview
local COMPACT_MIN_W, COMPACT_MAX_W = 34, 200

local snapshot = nil
local typed = ""
local targets = {} -- label -> { kind = "window", id = n } | { kind = "launch", argv = {...} }
local pinned = {} -- ordered { key, app_id, argv, name }
local iconCache = {}

local function split(text)
  local words = {}
  for word in tostring(text or ""):gmatch("%S+") do
    table.insert(words, word)
  end
  return words
end

local function loadPinned()
  pinned = {}
  local seen = {}
  for _, line in ipairs(noctalia.getConfig("pinned") or {}) do
    local words = split(line)
    local key, app = words[1], words[2]
    if key and app and #key == 1 and key:match("%l") and not seen[key] then
      seen[key] = true
      local argv = {}
      for i = 3, #words do
        table.insert(argv, words[i])
      end
      if #argv == 0 then
        argv = { app }
      end
      table.insert(pinned, { key = key, app_id = app, argv = argv })
    end
  end
end

local function hintAlphabet()
  local taken = {}
  for _, p in ipairs(pinned) do
    taken[p.key] = true
  end
  local letters = {}
  local chars = tostring(noctalia.getConfig("hint_chars") or "asdfghjklqwertyuiopzxcvbnm")
  for c in chars:gmatch("%l") do
    if not taken[c] then
      taken[c] = true
      table.insert(letters, c)
    end
  end
  return letters
end

-- Icons come resolved from the service; pinned apps that aren't running
-- are looked up here (a handful, cached).
local function icon(appId)
  local known = snapshot and snapshot.icons and snapshot.icons[appId]
  if known ~= nil then
    return known or nil
  end
  if iconCache[appId] == nil then
    iconCache[appId] = noctalia.appIconPath(appId, 32) or false
  end
  return iconCache[appId] or nil
end

-- Workspaces worth showing, per output: those with windows, plus the active
-- one so an empty monitor still shows where it is.
local function layoutModel()
  local s = snapshot or {}
  local byWs = {}
  for _, w in ipairs(s.windows or {}) do
    if w.workspace_id ~= nil then
      byWs[w.workspace_id] = byWs[w.workspace_id] or {}
      table.insert(byWs[w.workspace_id], w)
    end
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

-- Words in an app_id that don't name the app: reverse-DNS parts and
-- suffixes like Mattermost.Desktop's.
local GENERIC = {
  com = true, org = true, io = true, dev = true, net = true, md = true, app = true,
  desktop = true, client = true, bin = true, beta = true,
}

-- The letters an app would like as its label, best first: its name's, in
-- order ("md.obsidian.Obsidian" -> o, b, s, i, d, a, n).
local function mnemonic(appId)
  local name = ""
  for part in tostring(appId or ""):gmatch("[^%.]+") do
    if not GENERIC[part:lower()] then
      name = part
    end
  end
  local letters, seen = {}, {}
  for c in name:lower():gmatch("%l") do
    if not seen[c] then
      seen[c] = true
      table.insert(letters, c)
    end
  end
  return letters
end

local function byRecency(a, b)
  return (a.focus or 0) > (b.focus or 0)
end

-- The two most recently used windows: the current one (niri reports none
-- focused while the panel holds the keyboard) and the one Space goes back
-- to (as the service's toggle does).
local function recent()
  local first, second = nil, nil
  for _, w in ipairs((snapshot or {}).windows or {}) do
    if first == nil or (w.focus or 0) > (first.focus or 0) then
      first, second = w, first
    elseif second == nil or (w.focus or 0) > (second.focus or 0) then
      second = w
    end
  end
  return first, second
end

local function previousWindow()
  local _, second = recent()
  return second
end

local function isCurrent(w)
  local first = recent()
  return first ~= nil and first.id == w.id
end

-- Labels for every window and the dock's launchers.
--
-- A pinned app's key goes to its most recently used window, or to the one
-- before when that one is focused (pressing it again cycles). Every other
-- window gets a label from the leftover letters, preferring its app name's
-- letters, and keeps it while it lives (remembered in LABELS_KEY) unless
-- the labels must change length. When windows outnumber the letters, the
-- last few letters become prefixes of two-letter labels, as few as needed,
-- so most windows keep one letter.
local function assignLabels(model)
  targets = {}
  local labels = {}
  local pinnedByApp = {}
  for _, p in ipairs(pinned) do
    pinnedByApp[p.app_id] = p
  end
  local others, pinnedWindows = {}, {}
  for _, entry in ipairs(model) do
    for _, row in ipairs(entry.workspaces) do
      for _, column in ipairs(row.columns) do
        for _, w in ipairs(column) do
          local p = pinnedByApp[w.app_id]
          if p then
            pinnedWindows[p.key] = pinnedWindows[p.key] or {}
            table.insert(pinnedWindows[p.key], w)
          else
            table.insert(others, w)
          end
        end
      end
    end
  end

  for _, p in ipairs(pinned) do
    local list = pinnedWindows[p.key]
    if list == nil then
      targets[p.key] = { kind = "launch", argv = p.argv }
    else
      table.sort(list, byRecency)
      local chosen = list[1]
      if isCurrent(chosen) and list[2] then
        chosen = list[2]
      end
      labels[chosen.id] = p.key
      targets[p.key] = { kind = "window", id = chosen.id }
      for _, w in ipairs(list) do
        if w ~= chosen then
          table.insert(others, w)
        end
      end
    end
  end

  local alphabet = hintAlphabet()
  local n = #alphabet
  if n == 0 then
    return labels
  end
  -- k prefixes leave n - k single letters and make k * n pairs.
  local k = 0
  while k < n and (n - k) + k * n < #others do
    k += 1
  end
  local single, prefix = {}, {}
  for i, c in ipairs(alphabet) do
    if i <= n - k then
      single[c] = true
    else
      prefix[c] = true
    end
  end
  local inPool = {}
  for _, c in ipairs(alphabet) do
    inPool[c] = true
  end
  local function valid(label)
    if type(label) ~= "string" or targets[label] then
      return false
    end
    if #label == 1 then
      return single[label] == true
    end
    return #label == 2 and prefix[label:sub(1, 1)] == true and inPool[label:sub(2, 2)] == true
  end
  local function give(w, label)
    labels[w.id] = label
    targets[label] = { kind = "window", id = w.id }
  end

  table.sort(others, byRecency)
  local remembered = noctalia.state.get(LABELS_KEY) or {}
  local fresh = {}
  for _, w in ipairs(others) do
    local old = remembered["w" .. tostring(w.id)]
    if valid(old) then
      give(w, old)
    else
      table.insert(fresh, w)
    end
  end
  for _, w in ipairs(fresh) do
    local wanted = mnemonic(w.app_id)
    for _, c in ipairs(alphabet) do
      table.insert(wanted, c)
    end
    local label = nil
    for _, c in ipairs(wanted) do
      if valid(c) then
        label = c
        break
      end
    end
    if label == nil then
      for _, first in ipairs(alphabet) do
        if prefix[first] then
          for _, c in ipairs(wanted) do
            if valid(first .. c) then
              label = first .. c
              break
            end
          end
        end
        if label then
          break
        end
      end
    end
    if label then
      give(w, label)
    end
  end

  -- Remember the current windows' labels only, so closed ones drop out.
  local keep = {}
  for _, w in ipairs(others) do
    keep["w" .. tostring(w.id)] = labels[w.id]
  end
  noctalia.state.set(LABELS_KEY, keep)
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

local function act(target)
  if target == nil then
    return
  end
  panel.close()
  if target.kind == "window" then
    noctalia.runAsync({ "niri", "msg", "action", "focus-window", "--id", tostring(target.id) })
  else
    -- Through niri, so the app is niri's child (its env, its cgroup), not
    -- noctalia's.
    local argv = { "niri", "msg", "action", "spawn", "--" }
    for _, a in ipairs(target.argv) do
      table.insert(argv, a)
    end
    noctalia.runAsync(argv)
  end
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
      act({ kind = "window", id = w.id })
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

-- Fits everything in the panel: each monitor gets an equal share of the
-- width and its workspaces an equal share of the height. Tiles keep their
-- windows' aspect ratios; a row too wide for its monitor's share gets
-- shorter as a whole instead of squeezed.
local function render()
  local model = layoutModel()
  local labels = assignLabels(model)

  local dock = {}
  for _, p in ipairs(pinned) do
    local t = targets[p.key]
    if t and t.kind == "launch" then
      table.insert(dock, ui.row({
        key = "dock-" .. p.key,
        gap = 6,
        align = "center",
        padding = 6,
        radius = 8,
        fill = "surface_variant/0.4",
        border = "outline/0.3",
        borderWidth = 1,
        opacity = (typed ~= "" and not matches(p.key)) and 0.3 or 0.8,
        onClick = function()
          act(t)
        end,
      }, {
        ui.image({ path = icon(p.app_id), width = 18, height = 18, fit = "contain", visible = icon(p.app_id) ~= nil }),
        ui.label({ text = p.argv[1], fontSize = 11, color = "on_surface_variant" }),
        badge(p.key, false),
      }))
    end
  end

  local blockW = math.floor((PANEL_W - 2 * PAD - OUTPUT_GAP * math.max(0, #model - 1)) / math.max(1, #model))
  local availW = blockW - WS_LABEL_W - TILE_GAP
  local availH = PANEL_H - 2 * PAD - HEADER_H - OUTPUT_LABEL_H - (#dock > 0 and DOCK_H or 0) - 24

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

  local back = previousWindow()
  local backTo = back and (back.app_id ~= "" and back.app_id or back.title) or "nothing"

  local status = nil
  if snapshot == nil then
    status = ui.label({ text = "Waiting for niri…", color = "on_surface_variant" })
  end

  panel.render(ui.column({ gap = 12, padding = 4 }, {
    ui.row({ align = "center", justify = "space_between" }, {
      ui.row({ gap = 8, align = "center" }, {
        ui.glyph({ name = "layout-grid", size = 18, color = "primary" }),
        ui.label({ text = "Switch window", fontSize = 15, fontWeight = "bold" }),
        ui.label({ text = typed, fontSize = 15, fontWeight = "bold", color = "primary", visible = typed ~= "" }),
      }),
      ui.label({ text = "Type a label · Space: back to " .. backTo .. " · Backspace to undo · Esc to close", fontSize = 11, color = "on_surface_variant", maxLines = 1 }),
    }),
    status or ui.row({ gap = OUTPUT_GAP, align = "start" }, blocks),
    ui.row({ gap = 8, visible = #dock > 0 }, dock),
  }))
end

noctalia.state.watch(SNAPSHOT, function(value)
  snapshot = value
  if panel.isOpen == nil or panel.isOpen() then
    render()
  end
end)

function onOpen()
  noctalia.state.set(OPEN_KEY, true)
  loadPinned()
  snapshot = noctalia.state.get(SNAPSHOT)
  typed = ""
  render()
end

function onClose()
  noctalia.state.set(OPEN_KEY, false)
end

function onKey(chord, pressed)
  if not pressed then
    return
  end
  chord = string.lower(chord)
  if chord == "escape" then
    panel.close()
    return
  elseif chord == "space" then
    local w = previousWindow()
    if w then
      act({ kind = "window", id = w.id })
    end
    return
  elseif chord == "backspace" then
    typed = typed:sub(1, -2)
    render()
    return
  elseif not chord:match("^%l$") then
    return
  end

  typed ..= chord
  if targets[typed] then
    act(targets[typed])
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
