-- MOSAIC (micro loop) : boucles superposées rejouées à plusieurs vitesses.
-- activity = nombre de boucles actives ; repeats = durée de vie des boucles.
-- variations d'après le manuel Microcosm ; mécanique de déclenchement reprise de Tessera.

local mosaic = {
  name = "MOSAIC",
  variations = {
    "normal + octave up",
    "normal + octave down",
    "all at double speed",
    "half to quad speed",
    "forward and reversed, x1 and x2",
    "half to quad, some reversed",
  },
}

local SPEEDS = {
  { 1, 2 },
  { 1, 0.5 },
  { 2 },
  { 0.5, 1, 2, 4 },
  { 1, 2, -1, -2 },
  { 0.5, 1, 2, 4, -1, -0.5 },
}

local LENGTHS = { 0.25, 0.5, 0.5, 1 }

local function step(core)
  local A = params:get("activity")
  local R = params:get("repeats")
  local U = core.unit()

  local max_voices = 2 + math.floor(A * 10)
  if not core.chance(core.lerp(0.15, 0.7, A)) or core.active_count() >= max_voices then
    return
  end

  local len = U * core.pick(LENGTHS)
  core.spawn {
    len = len,
    ago = len + math.random(0, 3) * U * 0.25,
    rate = core.pick(SPEEDS[core.variation()]),
    life = math.min(U * core.lerp(1, 12, R), core.max_life(R)) * core.uniform(0.75, 1.25),
    loop = true,
    xfade = 0.06,
    gain = 0.55,
    pan = core.uniform(-0.7, 0.7),
    shape = params:get("shape"),
  }
end

function mosaic.start(core)
  core.every(4, function() step(core) end)
end

return mosaic
