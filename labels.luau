--!nonstrict
-- Window labels, shared by the panels and the service (which needs them to
-- focus a window on rcmd+letter without opening a panel).
--
-- Each window gets its app name's first letter, or two letters when
-- several windows share it (see assign).

local M = {}

-- The noctalia API (config, shared state); test/labels_test.luau swaps in
-- a fake, since a required module doesn't see the test's globals.
M.host = noctalia

local LABELS_KEY = "switcher.labels"

function M.hintAlphabet()
  local taken = {}
  local letters = {}
  local chars = tostring(M.host.getConfig("hint_chars") or "asdfghjklqwertyuiopzxcvbnm")
  for c in chars:gmatch("%l") do
    if not taken[c] then
      taken[c] = true
      table.insert(letters, c)
    end
  end
  return letters
end

-- Words in an app_id that don't name the app: reverse-DNS parts and
-- suffixes like Mattermost.Desktop's.
local GENERIC = {
  com = true, org = true, io = true, dev = true, net = true, md = true, app = true,
  desktop = true, client = true, bin = true, beta = true,
}

-- The part of an app_id that names the app ("md.obsidian.Obsidian" ->
-- "Obsidian").
local function namePart(appId)
  local name = ""
  for part in tostring(appId or ""):gmatch("[^%.]+") do
    if not GENERIC[part:lower()] then
      name = part
    end
  end
  return name
end

-- The app's name for display: its name part, capitalized when the app_id
-- is all lower case ("spotify" -> "Spotify", "dev.zed.Zed" -> "Zed").
function M.appName(appId)
  local name = namePart(appId)
  if name == "" then
    return tostring(appId or "")
  end
  if name == name:lower() then
    name = name:sub(1, 1):upper() .. name:sub(2)
  end
  return name
end

-- The letters an app would like as its label, best first: its name's, in
-- order ("md.obsidian.Obsidian" -> o, b, s, i, d, a, n).
function M.mnemonic(appId)
  local letters, seen = {}, {}
  for c in namePart(appId):lower():gmatch("%l") do
    if not seen[c] then
      seen[c] = true
      table.insert(letters, c)
    end
  end
  return letters
end

-- Most recently used first; by id among never-focused windows, so labels
-- don't depend on the order windows come in.
function M.byRecency(a, b)
  if (a.focus or 0) ~= (b.focus or 0) then
    return (a.focus or 0) > (b.focus or 0)
  end
  return (a.id or 0) < (b.id or 0)
end

-- The windows the panels show: those on a workspace of a known output.
function M.windowsShown(snapshot)
  local s = snapshot or {}
  local outputs, shownWs = {}, {}
  for _, o in ipairs(s.outputs or {}) do
    outputs[o.name] = true
  end
  for _, ws in ipairs(s.workspaces or {}) do
    if outputs[ws.output] then
      shownWs[ws.id] = true
    end
  end
  local list = {}
  for _, w in ipairs(s.windows or {}) do
    if w.workspace_id ~= nil and shownWs[w.workspace_id] then
      table.insert(list, w)
    end
  end
  return list
end

-- Labels for the given windows: window id -> label, and label -> window
-- id. Each window is filed under its app name's first letter in
-- hint_chars. A letter with one window is that window's label; when
-- several windows share it (steam and spotify, or two terminals), each gets
-- that letter plus a second: the next letter of its name not taken there
-- yet (st steam, sp spotify; ze zen, zd zed), else a free one from
-- hint_chars. Second letters are remembered per window (LABELS_KEY) so
-- they don't reshuffle between openings.
function M.assign(windows)
  local labels, targets = {}, {}
  local others = table.clone(windows)

  local alphabet = M.hintAlphabet()
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
  table.sort(others, M.byRecency)
  local groups, order, homeless, names = {}, {}, {}, {}
  for _, w in ipairs(others) do
    local name = M.mnemonic(w.app_id)
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

  local remembered = M.host.state.get(LABELS_KEY) or {}
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
  M.host.state.set(LABELS_KEY, keep)
  return labels, targets
end

return M
