-- PATTERN (multidelay) : les taps forment quatre motifs rythmiques.
-- A = délai linéaire classique (manuel Microcosm). les motifs B à D du
-- Microcosm ne sont pas publics : motifs de Tessera (16es d'unité TIME).

local multidelay = include("lib/algos/multidelay")

return multidelay.make {
  name = "PATTERN",
  variations = {
    "straight, classic delay",
    "syncopated taps",
    "clustered taps",
    "triplet taps",
  },
  times = {
    { 2, 4, 6, 8, 10, 12, 14, 16 },
    { 3, 6, 10, 13, 16, 19, 22, 26 },
    { 2, 2.5, 3, 8, 8.5, 9, 14, 14.5 },
    { 4 / 3, 8 / 3, 4, 16 / 3, 20 / 3, 8, 28 / 3, 32 / 3 },
  },
  modes = { 0, 0, 0, 0 },
  trims = { -2.9, -0.5, -0.9, -1.8 },
}
