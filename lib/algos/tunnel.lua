-- TUNNEL (granules) : des micro-boucles cycliques forment des drones.
-- d'après le manuel Microcosm : activity = profondeur du modificateur de
-- chaque variation ; repeats = temps de décroissance du drone.
-- mécanique reprise de Tessera : chaque nouvelle note donne un drone bouclé
-- sur son sustain (l'attaque est sautée), et un drone de fond part de temps
-- en temps à partir du jeu récent.

local tunnel = {
  name = "TUNNEL",
  variations = {
    "loop length breathes",
    "sub-octave, filter sweeps",
    "resonant band-pass drones",
    "playing squeezes the loop",
    "filter breathes slowly",
    "drones with octave-up layer",
  },
}

-- C recalé de +6 dB sur le norns (2026-10-24) : les passe-bandes étroits sortaient trop bas
local TRIM_DB = { 1.4, 1.2, 15.1, 1.4, 1.4, 1.4 }
local MAX_VOICES = 4
local SKIP_ATTACK = 0.09
local BP_FREQS = { 220, 330, 440, 660, 880, 1320, 1760 }

local pending = false
local units_left = 0

local function drone(core, ago, len)
  local A = params:get("activity")
  local R = params:get("repeats")
  local var = core.variation()
  if core.active_count() >= MAX_VOICES then return end

  local v = {
    ago = ago,
    len = len,
    rate = 1,
    life = core.lerp(1, 16, R ^ 1.5),
    loop = true,
    xfade = 0.5,
    gain = 0.5 * util.dbamp(TRIM_DB[var]),
    pan = core.uniform(-0.6, 0.6),
    shape = params:get("shape"),
  }

  if var == 1 then
    -- la longueur de boucle se comprime et s'allonge (jusqu'à ±1 octave)
    v.len_mod = { core.uniform(0.1, 0.4), A, 0 }
    v.filter = { 0, 5000, 5000, 0.9, 0, 0 }
  elseif var == 2 then
    -- drone à l'octave inférieure, balayage de filtre de profondeur activity
    v.rate = 0.5
    v.filter = { 0, 4500, 350, 1.6, 0.3, 1.5 * A }
  elseif var == 3 then
    -- passe-bandes résonants, de plus en plus étroits avec activity
    local f = core.pick(BP_FREQS)
    v.filter = { 1, f, f, core.lerp(2, 12, A), 0.1, 0.3 * A }
  elseif var == 4 then
    -- jouer comprime la boucle, qui se rallonge quand on s'arrête
    v.len_mod = { 0, 1.5 * A, 1 }
    v.filter = { 0, 5000, 5000, 0.9, 0, 0 }
  elseif var == 5 then
    -- passe-bas qui respire lentement, plus sombre et plus ample avec activity
    local f = core.lerp(5000, 1200, A)
    v.filter = { 0, f, f, 0.9, core.uniform(0.15, 0.5), core.lerp(0.5, 2, A) }
  else
    -- une partie des drones à l'octave haute
    v.rate = core.pick { 1, 2 }
    v.filter = { 0, 6000, 6000, 0.9, 0, 0 }
  end
  core.spawn(v)
end

function tunnel.onset(core)
  -- garder la première note en attente, pour que le jeu rapide donne quand
  -- même des drones
  if pending then return end
  pending = true
  local onset_beat = core.buffer_beat()
  local len = core.uniform(0.06, 0.25)
  core.run(function()
    -- attendre que le sustain soit enregistré
    clock.sleep(SKIP_ATTACK + len + 0.02)
    pending = false
    local start = onset_beat + SKIP_ATTACK / clock.get_beat_sec()
    drone(core, core.ago_of(start), len)
  end)
end

function tunnel.start(core)
  pending = false
  units_left = 0
  -- drone de fond : toutes les 2 unités TIME, depuis le jeu récent
  core.every(1, function()
    units_left = units_left - 1
    if units_left > 0 then return end
    units_left = 2
    local len = core.uniform(0.06, 0.25)
    drone(core, len + core.uniform(0, 0.5), len)
  end)
end

return tunnel
