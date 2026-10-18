--!nonstrict
-- The switcher: a minimap of every monitor (left to right), its workspaces
-- (top to bottom) and their windows (in column order, a column's stacked
-- windows one above the other), each window labelled. Typing a label
-- focuses that window; Backspace undoes a letter, Esc closes.
--
-- Labels: a pinned app's windows use its key ("z", or "zj", "zk"... when it
-- has several), and a pinned app with no window shows in the dock, where
-- its key launches it. Every other window gets a label from the leftover
-- letters: one letter each while they suffice, two for all of them after.

local SNAPSHOT = "switcher.snapshot"
-- Must match [[panel]] width/height in plugin.toml.
local PANEL_W, PANEL_H = 1400, 880
local PAD = 16
local HEADER_H, DOCK_H, OUTPUT_LABEL_H = 34, 44, 22
local OUTPUT_GAP = 16
local ROW_GAP = 8
local TILE_GAP = 6
local WS_LABEL_W = 48
local TILE_MIN_W, TILE_MAX_W = 28, 340
local ROW_MIN_H, ROW_MAX_H = 26, 110
-- Below this a tile drops its title and shows just the icon and label.
local FULL_TILE_W, FULL_TILE_H = 96, 54

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

-- Labels for every window (in minimap order) and the dock's launchers.
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

  local alphabet = hintAlphabet()
  for _, p in ipairs(pinned) do
    local list = pinnedWindows[p.key]
    if list == nil then
      targets[p.key] = { kind = "launch", argv = p.argv }
    elseif #list == 1 then
      labels[list[1].id] = p.key
      targets[p.key] = { kind = "window", id = list[1].id }
    else
      for i, w in ipairs(list) do
        local label = p.key .. (alphabet[i] or tostring(i))
        labels[w.id] = label
        targets[label] = { kind = "window", id = w.id }
      end
    end
  end

  local n = #alphabet
  for i, w in ipairs(others) do
    local label
    if #others <= n then
      label = alphabet[i]
    else
      local first = math.floor((i - 1) / n) + 1
      local second = (i - 1) % n + 1
      label = (alphabet[first] or "?") .. alphabet[second]
    end
    labels[w.id] = label
    targets[label] = { kind = "window", id = w.id }
  end
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

local function tile(w, label, width, height)
  local dim = typed ~= "" and not matches(label)
  local compact = width < FULL_TILE_W or height < FULL_TILE_H
  local path = icon(w.app_id)
  local content
  if compact then
    content = {
      ui.row({ gap = 4, align = "center", justify = "center", flexGrow = 1 }, {
        ui.image({ path = path, width = 16, height = 16, fit = "contain", visible = path ~= nil and width >= 64 }),
        label and badge(label, false) or ui.spacer({}),
      }),
    }
  else
    content = {
      ui.row({ gap = 6, align = "center" }, {
        ui.image({ path = path, width = 18, height = 18, fit = "contain", visible = path ~= nil }),
        ui.label({ text = w.title ~= "" and w.title or w.app_id, fontSize = 11, color = "on_surface_variant", maxLines = 1, flexGrow = 1 }),
      }),
      ui.row({ justify = "center", align = "center", flexGrow = 1 }, {
        label and badge(label, true) or ui.spacer({}),
      }),
    }
  end
  return ui.column({
    key = "w" .. w.id,
    width = width,
    height = height,
    padding = compact and 3 or 6,
    gap = 4,
    radius = compact and 6 or 8,
    fill = w.is_focused and "primary/0.16" or "surface_variant/0.55",
    border = w.is_focused and "primary" or "outline/0.35",
    borderWidth = w.is_focused and 2 or 1,
    opacity = dim and 0.3 or 1,
    onClick = function()
      act({ kind = "window", id = w.id })
    end,
  }, content)
end

-- Fits everything in the panel: each monitor gets an equal share of the
-- width and its workspaces an equal share of the height (within limits).
-- Tiles keep their windows' relative widths, at one scale per monitor,
-- shrunk further for a row that would overflow.
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
    local rowH = math.floor((availH - ROW_GAP * (n - 1)) / n)
    rowH = math.max(ROW_MIN_H, math.min(ROW_MAX_H, rowH))

    local widest = 1
    for _, row in ipairs(entry.workspaces) do
      local width = 0
      for _, column in ipairs(row.columns) do
        width += (column[1].size and column[1].size[1] or 800)
      end
      widest = math.max(widest, width)
    end
    local scale = math.min(0.25, availW / widest)

    local rows = {}
    for _, row in ipairs(entry.workspaces) do
      local widths, total = {}, TILE_GAP * math.max(0, #row.columns - 1)
      for i, column in ipairs(row.columns) do
        local size = column[1].size or { 800, 600 }
        widths[i] = math.max(TILE_MIN_W, math.min(TILE_MAX_W, math.floor(size[1] * scale)))
        total += widths[i]
      end
      if total > availW then
        local gaps = TILE_GAP * math.max(0, #row.columns - 1)
        local factor = (availW - gaps) / math.max(1, total - gaps)
        for i in ipairs(widths) do
          widths[i] = math.max(TILE_MIN_W, math.floor(widths[i] * factor))
        end
      end

      local cols = {}
      for i, column in ipairs(row.columns) do
        local k = #column
        local height = math.floor((rowH - TILE_GAP * (k - 1)) / k)
        local stacked = {}
        for _, w in ipairs(column) do
          table.insert(stacked, tile(w, labels[w.id], widths[i], math.max(18, height)))
        end
        table.insert(cols, ui.column({ gap = TILE_GAP }, stacked))
      end
      local ws = row.ws
      table.insert(rows, ui.row({ gap = TILE_GAP, align = "center", height = rowH }, {
        ui.label({ text = ws.name or tostring(ws.idx or ""), width = WS_LABEL_W, fontSize = 11, fontWeight = ws.is_active and "bold" or "normal", color = ws.is_active and "primary" or "on_surface_variant", maxLines = 1 }),
        ui.row({ gap = TILE_GAP }, cols),
      }))
    end
    local o = entry.output
    table.insert(blocks, ui.column({ width = blockW, gap = ROW_GAP }, {
      ui.label({ text = o.name or "", fontSize = 12, fontWeight = "bold", color = o.focused and "primary" or "on_surface_variant" }),
      ui.column({ gap = ROW_GAP }, rows),
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
  loadPinned()
  snapshot = noctalia.state.get(SNAPSHOT)
  typed = ""
  render()
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
