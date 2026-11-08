-- INTERRUPT (glitch) : des rafales viennent interrompre le jeu en direct.
-- d'après le manuel Microcosm : activity = variation et manipulation des
-- échantillons, repeats = fréquence des interruptions. à Mix 100 %, le sec
-- est vraiment coupé pendant les rafales (l'engine le fait, voir vduck).
-- tailles, vitesses et réglages de filtre / bitcrush repris de Tessera.

local interrupt = {
  name = "INTERRUPT",
  variations = {
    "rearranged interruptions",
    "pitch-shifted interruptions",
    "filter sweeps and delay",
    "crushed, drastic glitches",
  },
}

local TRIM_DB = { 4.8, 4.2, 10.8, 4.7 }

local busy_until = 0

local function step(core)
  local A = params:get("activity")
  local R = params:get("repeats")
  if util.time() < busy_until or not core.chance(core.lerp(0.1, 0.7, R)) then return end
  local var = core.variation()
  local U = core.unit()
  local gain = 0.9 * util.dbamp(TRIM_DB[var])

  local unit = U * core.pick { 0.125, 0.25 }
  local reps = 1 + util.round(core.lerp(1, 5, A) * core.uniform(0.5, 1))
  local v = {
    loop = true,
    xfade = 0.02,
    gain = gain,
    pan = core.uniform(-0.5, 0.5),
    shape = params:get("shape"),
    rate = 1,
    ducks = true,
  }

  if var == 1 then
    if core.chance(0.3 * A) then v.rate = -1 end
  elseif var == 2 then
    if core.chance(0.4 + 0.6 * A) then v.rate = core.pick { 2, 0.5, 1.5 } end
  elseif var == 3 then
    local up = core.chance(0.5)
    v.filter = { 1, up and 300 or 5000, up and 5000 or 300, 2.5, 0, 0 }
  else
    v.crush = { util.round(core.lerp(6, 3, A)), util.round(core.lerp(4, 10, A)) }
    if core.chance(A) then v.rate = core.pick { 0.5, 2, -1 } end
  end

  -- activity va chercher le matériau plus loin dans le passé
  v.len = unit * math.abs(v.rate)
  v.ago = v.len + math.random() * (0.25 + 2 * A) * U
  v.life = unit * reps
  core.spawn(v)

  if var == 3 then
    -- delay : deux échos de la rafale, plus faibles, qui ne coupent pas le sec
    for k = 1, 2 do
      local e = {}
      for key, val in pairs(v) do e[key] = val end
      e.ducks = nil
      e.delay = k * U * 0.25
      e.gain = gain * 0.5 ^ k
      e.pan = (k % 2 == 0) and v.pan or -v.pan
      core.spawn(e)
    end
  end

  busy_until = util.time() + v.life + U * 0.125
end

function interrupt.start(core)
  busy_until = 0
  core.every(2, function() step(core) end)
end

return interrupt
