--!nonstrict
-- The switcher: a minimap of every monitor (left to right), its workspaces
-- (top to bottom) and their windows (in column order, a column's stacked
-- windows one above the other), each window labelled. Typing a label
-- focuses that window; Backspace undoes a letter, Esc closes.
--
-- Labels: each window gets its app name's first letter, or two letters
-- when several windows share it (see assignLabels).

local SNAPSHOT = "switcher.snapshot"
local OPEN_KEY = "switcher.open"
local LABELS_KEY = "switcher.labels"
-- Must match [[panel]] width/height in plugin.toml.
local PANEL_W, PANEL_H = 1400, 880
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

local snapshot = nil
local typed = ""
local targets = {} -- label -> window id

local function hintAlphabet()
  local taken = {}
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

-- Labels for every window. Each is filed under its app name's first
-- letter in hint_chars. A letter with one window is that window's label;
-- when several windows share it (steam and spotify, or two terminals),
-- each gets that letter plus a second: the next letter of its name not
-- taken there yet (st steam, sp spotify; ze zen, zd zed), else a free one
-- from hint_chars. Second letters are remembered per window (LABELS_KEY)
-- so they don't reshuffle between openings.
local function assignLabels(model)
  targets = {}
  local labels = {}
  local others = {}
  for _, entry in ipairs(model) do
    for _, row in ipairs(entry.workspaces) do
      for _, column in ipairs(row.columns) do
        for _, w in ipairs(column) do
          table.insert(others, w)
        end
      end
    end
  end

  local alphabet = hintAlphabet()
  local inPool = {}
  for _, c in ipairs(alphabet) do
    inPool[c] = true
  end
  local function give(w, label)
    labels[w.id] = label
    targets[label] = w.id
  end

  -- File each window under a first letter: its name's first in the pool,
  -- or for a name with none, a pool letter no name claimed.
  table.sort(others, byRecency)
  local groups, order, homeless, names = {}, {}, {}, {}
  for _, w in ipairs(others) do
    local name = mnemonic(w.app_id)
    names[w.id] = name
    local home = nil
    for i, c in ipairs(name) do
      if inPool[c] then
        home = c
        names[w.id] = { table.unpack(name, i + 1) }
        break
      end
    end
    if home then
      if groups[home] == nil then
        groups[home] = {}
        table.insert(order, home)
      end
      table.insert(groups[home], w)
    else
      table.insert(homeless, w)
    end
  end
  for _, w in ipairs(homeless) do
    local home = nil
    for _, c in ipairs(alphabet) do
      if groups[c] == nil then
        home = c
        break
      end
    end
    home = home or alphabet[1]
    if home then
      if groups[home] == nil then
        groups[home] = {}
        table.insert(order, home)
      end
      table.insert(groups[home], w)
    end
  end

  local remembered = noctalia.state.get(LABELS_KEY) or {}
  for _, home in ipairs(order) do
    local list = groups[home]
    if #list == 1 then
      give(list[1], home)
    else
      local used = {}
      local fresh = {}
      -- Remembered second letters first (still under this letter).
      for _, w in ipairs(list) do
        local old = remembered["w" .. tostring(w.id)]
        if type(old) == "string" and #old == 2 and old:sub(1, 1) == home and not used[old] then
          used[old] = true
          give(w, old)
        else
          table.insert(fresh, w)
        end
      end
      -- The rest of its name first (most recent windows choose first), then
      -- the pool.
      for _, w in ipairs(fresh) do
        local wanted = table.clone(names[w.id])
        for _, h in ipairs(alphabet) do
          table.insert(wanted, h)
        end
        for _, second in ipairs(wanted) do
          local label = home .. second
          if not used[label] then
            used[label] = true
            give(w, label)
            break
          end
        end
      end
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

local function focus(id)
  if id == nil then
    return
  end
  panel.close()
  noctalia.runAsync({ "niri", "msg", "action", "focus-window", "--id", tostring(id) })
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

-- Fits everything in the panel: each monitor gets an equal share of the
-- width and its workspaces an equal share of the height. Tiles keep their
-- windows' aspect ratios; a row too wide for its monitor's share gets
-- shorter as a whole instead of squeezed.
local function render()
  local model = layoutModel()
  local labels = assignLabels(model)

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
      ui.label({ text = "Type a label · Backspace to undo · Esc to close", fontSize = 11, color = "on_surface_variant" }),
    }),
    status or ui.row({ gap = OUTPUT_GAP, align = "start" }, blocks),
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
  elseif chord == "backspace" then
    typed = typed:sub(1, -2)
    render()
    return
  elseif not chord:match("^%l$") then
    return
  end

  typed ..= chord
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
