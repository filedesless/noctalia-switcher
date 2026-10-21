--!nonstrict
-- The full switcher: a minimap of every window (see switcher.luau).

local switcher = require("./switcher.luau").start("full")

function onOpen(context)
  switcher.onOpen(context)
end

function onClose()
  switcher.onClose()
end

function onKey(chord, pressed)
  switcher.onKey(chord, pressed)
end
