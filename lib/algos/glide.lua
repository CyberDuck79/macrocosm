-- GLIDE (micro loop) : courtes boucles superposées dont la hauteur glisse.
-- d'après le manuel Microcosm : activity = vitesse du glissement, shape =
-- forme du motif de glissement. interprétation : chaque boucle va et vient
-- entre les deux vitesses de la variation ; shape choisit la forme du
-- va-et-vient (0 = rampe descendante, 0,5 = triangle, 1 = rampe montante).
-- repeats = durée de vie des boucles.
-- (Tessera fait un seul glissement par boucle et garde shape pour le volume.)

local glide = {
  name = "GLIDE",
  variations = {
    "between half and normal",
    "between double and half",
    "between normal and double",
    "both directions at once",
    "one glide up from half",
    "one glide down from double",
    "one glide up to double",
    "random one-way glides",
  },
}

-- paires de vitesses par variation ; D lance deux boucles du même segment,
-- l'une montante, l'autre descendante
local PAIRS = {
  { { 0.5, 1 } },
  { { 2, 0.5 } },
  { { 1, 2 } },
  { { 1, 2 }, { 1, 0.5 } },
}

-- E à H : un seul glissement sur toute la vie de la boucle (comme Tessera) ;
-- activity = probabilité et nombre de boucles, shape = enveloppe de volume
local ONE_WAY = {
  { { 0.5, 1 } },
  { { 2, 0.5 } },
  { { 1, 2 } },
  { { 1, 2 }, { 1, 0.5 }, { 0.5, 2 }, { 2, 1 } },
}

local LENGTHS = { 0.25, 0.5 }
local MAX_VOICES = 6

local function one_way(core, var)
  local A = params:get("activity")
  local R = params:get("repeats")
  local U = core.unit()
  if not core.chance(core.lerp(0.3, 1, A)) or core.active_count() >= 1 + math.floor(A * 5) then
    return
  end
  local p = core.pick(ONE_WAY[var - 4])
  local len = U * core.pick(LENGTHS)
  core.spawn {
    len = len,
    ago = len + math.random(0, 1) * U * 0.25,
    rate = p[1],
    rate_end = p[2],
    life = math.min(U * core.lerp(1, 16, R), core.max_life(R)),
    loop = true,
    xfade = 0.1,
    gain = 0.8,
    pan = core.uniform(-0.6, 0.6),
    shape = params:get("shape"),
  }
end

local function step(core)
  local var = core.variation()
  if var > 4 then return one_way(core, var) end

  local A = params:get("activity")
  local R = params:get("repeats")
  local S = params:get("shape")
  local U = core.unit()
  local pairs_ = PAIRS[var]

  if not core.chance(0.6) or core.active_count() + #pairs_ > MAX_VOICES then
    return
  end

  -- période du va-et-vient : 16 unités TIME à activity 0, 1/2 unité à fond
  local hz = util.clamp(1 / (U * 2 ^ core.lerp(4, -1, A)), 0.02, 10)
  local len = U * core.pick(LENGTHS)
  local ago = len + math.random(0, 1) * U * 0.25
  local life = math.min(U * core.lerp(1, 16, R), core.max_life(R))
  local pan = core.uniform(-0.6, 0.6)

  for i, p in ipairs(pairs_) do
    core.spawn {
      len = len,
      ago = ago,
      rate = p[1],
      rate_end = p[2],
      glide = { hz, S },
      life = life,
      loop = true,
      xfade = 0.1,
      gain = 0.8 / math.sqrt(#pairs_),
      pan = i == 1 and pan or -pan,
      -- shape sert au glissement : enveloppe de volume fixe et douce
      shape = 0.55,
    }
  end
end

function glide.start(core)
  core.every(1, function() step(core) end)
end

return glide
