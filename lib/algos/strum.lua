-- STRUM (granules) : chaînes rythmiques des dernières attaques.
-- d'après le manuel Microcosm : activity = densité du motif.
-- repeats = longueur de la chaîne. mécanique reprise de Tessera : chaque
-- attaque lance une chaîne de répétitions qui décroît jusqu'à 12 % ; le pas
-- vaut l'unité TIME divisée par 1, 2, 3, 4, 6 ou 8 selon activity.

local strum = {
  name = "STRUM",
  variations = {
    "repeats the latest note",
    "overlapping copies, phasing",
    "cascade of recent notes",
    "cascade with octave-up grains",
  },
}

local TRIM_DB = { 3.6, 0.7, 3.9, 4.2 }
local DIVS = { 1, 2, 3, 4, 6, 8 }
local RING = 8

local onsets = {}
local count = 0
local remaining = 0
local chain_index = 0
local chain_gain = 1
local chain_decay = 0.9
local idle_units = 0

local function div_for(A)
  return DIVS[math.min(6, math.floor(A * 6) + 1)]
end

local function start_chain(core)
  local R = params:get("repeats")
  local step_sec = core.unit() / div_for(params:get("activity"))
  -- la chaîne est comptée en pas, mais bornée en secondes
  remaining = math.max(2, math.min(2 + util.round(R * 30), math.floor(core.max_life(R) / step_sec)))
  chain_index = 0
  chain_gain = 1
  chain_decay = 0.12 ^ (1 / remaining)
end

local function step(core)
  local var = core.variation()
  local S = params:get("shape")
  local div = div_for(params:get("activity"))
  local step_sec = core.unit() / div
  local hold = core.held()

  -- en Hold, relancer une chaîne toutes les 2 unités sur les notes gelées
  if hold and remaining <= 0 and count > 0 then
    idle_units = idle_units + 1 / div
    if idle_units >= 2 then
      idle_units = 0
      start_chain(core)
    end
  end
  if remaining <= 0 then return end

  local which = 0
  if var >= 3 then which = chain_index % math.min(count, 4) end
  local src = onsets[(count - 1 - which) % RING + 1]
  local rate = (var == 4 and chain_index % 2 == 1) and 2 or 1

  -- chaque répétition chevauche un peu la suivante ; attendre (sans
  -- consommer de pas) qu'assez de la note soit enregistrée, au plus 100 ms
  local wanted = math.min(step_sec * 1.3 * rate, 0.6)
  local recorded = core.ago_of(src)
  if not hold and recorded < math.min(0.7 * wanted, 0.1) then return end
  local len = math.min(wanted, recorded)

  if len > 0.01 then
    local gain = 0.8 * chain_gain * util.dbamp(TRIM_DB[var])
    local pan = chain_index % 2 == 0 and -0.4 or 0.4
    core.spawn { ago = recorded, len = len, rate = rate, loop = false, life = len / rate,
      gain = gain, pan = pan, shape = S }
    if var == 2 then
      -- deux copies légèrement décalées et désaccordées : phasing
      for _ = 1, 2 do
        local r = 1 + core.uniform(-0.004, 0.004)
        core.spawn { ago = recorded, len = len, rate = r, loop = false, life = len / r,
          gain = 0.5 * chain_gain * util.dbamp(TRIM_DB[var]), pan = -pan * core.uniform(0.5, 1),
          shape = S, delay = core.uniform(0.004, 0.03) }
      end
    end
  end
  chain_gain = chain_gain * chain_decay
  chain_index = chain_index + 1
  remaining = remaining - 1
end

function strum.onset(core)
  count = count + 1
  onsets[(count - 1) % RING + 1] = core.buffer_beat()
  start_chain(core)
end

function strum.start(core)
  remaining = 0
  idle_units = 0
  core.every(function() return div_for(params:get("activity")) end, function() step(core) end)
end

return strum
