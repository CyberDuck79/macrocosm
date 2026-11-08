-- BLOCKS (glitch) : le jeu récent est réarrangé en blocs répétés.
-- d'après le manuel Microcosm : activity = quantité de variation et de
-- manipulation des échantillons. interprétation : repeats = nombre de
-- répétitions de chaque bloc. un bloc peut partir à chaque demi-unité TIME.
-- tailles de blocs, vitesses et réglages de filtre / bitcrush repris de Tessera.

local blocks = {
  name = "BLOCKS",
  variations = {
    "rearranged, bursts of runs",
    "rearranged and pitch-shifted",
    "soft, filtered, overlapping",
    "pitch-shifted and crushed",
  },
}

local TRIM_DB = { 3.3, 2.5, 2.2, 5.0 }
local UNITS = {
  { 0.125, 0.0625, 0.25 },
  { 0.25, 0.125 },
  { 0.25, 0.5 },
  { 0.125, 0.0625 },
}

local busy_until = 0

local function step(core)
  if util.time() < busy_until or not core.chance(0.6) then return end
  local A = params:get("activity")
  local R = params:get("repeats")
  local var = core.variation()
  local U = core.unit()
  local gain = util.dbamp(TRIM_DB[var])

  -- activity : on va chercher plus loin dans le jeu récent, et on manipule plus
  local unit = U * (core.chance(A) and core.pick(UNITS[var]) or UNITS[var][1])
  local reps = 1 + util.round(R * 7 * core.uniform(0.5, 1))
  local v = {
    loop = true,
    xfade = 0.02,
    gain = gain,
    pan = core.uniform(-0.5, 0.5),
    shape = params:get("shape"),
    rate = 1,
  }

  if var == 1 then
    if core.chance(0.4 * A) then v.rate = -1 end
  elseif var == 2 then
    if core.chance(0.3 + 0.7 * A) then v.rate = core.pick { 0.5, 0.75, 1.5, 2 } end
  elseif var == 3 then
    v.filter = { 0, 6000, 500, 0.8, 0, 0 }
    v.xfade = 0.3
    v.gain = gain * 0.8
  else
    if core.chance(0.3 + 0.7 * A) then v.rate = core.pick { 0.5, 2, 1.5, 0.75 } end
    v.crush = { util.round(core.lerp(7, 4, A)), util.round(core.lerp(4, 8, A)) }
  end

  v.len = unit * math.abs(v.rate)
  v.ago = v.len + math.random(0, util.round(1 + A * 7)) * U * 0.25
  v.life = unit * reps
  core.spawn(v)

  if var == 1 and core.chance(0.5 * A) then
    -- rafale : une courte suite de notes récentes, enchaînées après le bloc
    for k = 1, math.random(2, 4) do
      local u = U * 0.125
      core.spawn { len = u, ago = u + math.random(1, 8) * U * 0.25, life = u, loop = false,
        gain = gain * 0.9, pan = core.uniform(-0.6, 0.6), shape = 0.3, delay = v.life + (k - 1) * u }
    end
  elseif var == 3 and core.chance(A) then
    -- une couche douce de plus, qui chevauche la première
    local w = {}
    for key, val in pairs(v) do w[key] = val end
    w.ago = v.len + math.random(0, 7) * U * 0.25
    w.delay = unit * 0.5
    w.pan = -v.pan
    core.spawn(w)
  end

  busy_until = util.time() + v.life * 0.6
end

function blocks.start(core)
  busy_until = 0
  core.every(2, function() step(core) end)
end

return blocks
