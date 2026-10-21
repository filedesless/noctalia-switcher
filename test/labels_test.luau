--!nonstrict
-- Unit tests for labels.luau, with noctalia's state and config faked:
--   nix shell nixpkgs#luau --command luau test/labels_test.luau

local store = {}
local fake = {
  getConfig = function(_key)
    return nil
  end,
  state = {
    get = function(key)
      return store[key]
    end,
    set = function(key, value)
      store[key] = value
    end,
  },
}

local labels = require("../labels")
labels.host = fake

local fails = 0
local function check(name, got, want)
  if got == want then
    print("PASS " .. name)
  else
    print("FAIL " .. name .. ": want " .. tostring(want) .. ", got " .. tostring(got))
    fails += 1
  end
end

local function win(id, app, focus)
  return { id = id, app_id = app, focus = focus, workspace_id = 1 }
end

local windows = {
  win(1, "steam", 100),
  win(2, "spotify", 80),
  win(3, "zen", 90),
  win(4, "dev.zed.Zed", 50),
  win(5, "Alacritty", 70),
  win(6, "Alacritty", 40),
  win(7, "md.obsidian.Obsidian", 60),
  win(8, "thunderbird", 30),
}

local l, t = labels.assign(windows)
check("steam st", l[1], "st")
check("spotify sp", l[2], "sp")
check("zen ze", l[3], "ze")
check("zed zd", l[4], "zd")
check("recent terminal al", l[5], "al")
check("other terminal ac", l[6], "ac")
check("obsidian alone o", l[7], "o")
check("thunderbird alone t", l[8], "t")
check("targets map back", t.sp, 2)

-- Spotify becomes the most recent: remembered second letters stay put.
windows[2].focus = 200
l = labels.assign(windows)
check("st kept after reordering", l[1], "st")
check("sp kept after reordering", l[2], "sp")

-- Steam closes: Spotify alone under s gets the single letter.
table.remove(windows, 1)
l = labels.assign(windows)
check("spotify alone s", l[2], "s")

-- A second Steam window later: Spotify's remembered "s" is one letter, so
-- it is relabelled after its name, newest first.
table.insert(windows, win(9, "steam", 300))
l = labels.assign(windows)
check("new steam st", l[9], "st")
check("spotify sp again", l[2], "sp")

-- Equal focus (never focused): ordered by id, not input order.
local a = labels.assign({ win(21, "zen", 0), win(20, "dev.zed.Zed", 0) })
check("tie broken by id", a[20], "ze")

check("appName capitalizes", labels.appName("spotify"), "Spotify")
check("appName keeps case", labels.appName("md.obsidian.Obsidian"), "Obsidian")
check("appName skips generic", labels.appName("com.mattermost.Desktop"), "Mattermost")

local shown = labels.windowsShown({
  outputs = { { name = "A" } },
  workspaces = { { id = 1, output = "A" }, { id = 2, output = "gone" } },
  windows = { { id = 1, workspace_id = 1 }, { id = 2, workspace_id = 2 }, { id = 3 } },
})
check("windowsShown keeps known outputs only", #shown == 1 and shown[1].id, 1)

print(fails .. " failed")
if fails > 0 then
  error("labels tests failed")
end
