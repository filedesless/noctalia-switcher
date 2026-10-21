--!nonstrict
-- The compact switcher: labels and app names, no previews (see
-- switcher.luau).

local switcher = require("./switcher.luau").start("compact")

function onOpen(context)
  switcher.onOpen(context)
end

function onClose()
  switcher.onClose()
end

function onKey(chord, pressed)
  switcher.onKey(chord, pressed)
end
