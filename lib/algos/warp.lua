-- WARP (multidelay) : des filtres et des transpositions sur chaque tap.
-- variations d'après le manuel Microcosm ; temps des taps et réglages des
-- traitements repris de Tessera (16es d'unité TIME).

local multidelay = include("lib/algos/multidelay")

local TIMES = { 3, 5, 7, 9, 12, 15, 18, 22 }

return multidelay.make {
  name = "WARP",
  variations = {
    "envelope filter on each tap",
    "resonant band-pass taps",
    "pitch-shifted taps",
    "taps fade into octave grains",
  },
  times = { TIMES, TIMES, TIMES, TIMES },
  modes = { 1, 2, 3, 4 },
  -- C et D recalés sur le norns (2026-10-24) : la transposition fait perdre du niveau
  trims = { -2.1, 1.4, 3.9, 1.4 },
}
