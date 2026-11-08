-- macrocosm
-- granular micro-looper
-- inspired by the Microcosm
--
-- E1 page, E2 / E3 controls
-- hold K1: E1 family,
-- E2 effect, E3 variation
-- K2 hold, K3 reverse
-- K1 + K2 looper on / off
-- K1 + K3 reverse
-- looper: K2 rec / play / dub
-- (long press: undo dub),
-- K3 stop (long press: erase)
-- MIDI: see the manual

engine.name = "Macrocosm"

local core = include("lib/core")

function init()
  core.init {
    {
      name = "micro loop",
      include("lib/algos/mosaic"),
      include("lib/algos/seq"),
      include("lib/algos/glide"),
    },
    {
      name = "granules",
      include("lib/algos/haze"),
      include("lib/algos/tunnel"),
      include("lib/algos/strum"),
    },
    {
      name = "multidelay",
      include("lib/algos/pattern"),
      include("lib/algos/warp"),
    },
    {
      name = "glitch",
      include("lib/algos/blocks"),
      include("lib/algos/interrupt"),
      include("lib/algos/arp"),
    },
  }
end

function enc(n, d) core.enc(n, d) end

function key(n, z) core.key(n, z) end

function redraw() core.redraw() end

function cleanup() core.cleanup() end
