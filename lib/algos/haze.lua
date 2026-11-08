-- HAZE (granules) : des nuages de grains créent une nappe.
-- d'après le manuel Microcosm : activity = densité et dispersion des grains.
-- interprétation : repeats = durée des grains (ce qui « dure »).
-- densité, normalisation du gain et enveloppe douce reprises de Tessera.

local haze = {
  name = "HAZE",
  variations = {
    "short, stretched and diffused",
    "many randomized grains",
    "normal and double speed",
    "normal and half speed",
    "mostly reversed, detuned",
  },
}

local TRIM_DB = 2.3
local MAX_GRAINS = 22

local function grain(core, A, R, S, var, rate_hz)
  local dur = core.lerp(0.04, 0.4, R) * core.uniform(0.6, 1.4)
  -- dispersion dans le passé récent : quelques dizaines de ms à 4 s
  local spread = core.lerp(0.05, 4, A ^ 1.5)
  local rate = 1

  if var == 1 then
    -- grains très proches et presque à l'unisson : le son s'étire
    rate = 2 ^ core.uniform(-0.003, 0.003)
    spread = spread * 0.25
  elseif var == 2 then
    -- tout aléatoire : durée, position et léger désaccord
    dur = core.uniform(0.02, 0.5) * core.lerp(0.5, 1.5, R)
    rate = 2 ^ (core.uniform(-0.5, 0.5) / 12)
    spread = spread * 1.5
  elseif var == 3 then
    rate = core.pick { 1, 1, 2 }
  elseif var == 4 then
    rate = core.pick { 1, 1, 0.5 }
  else
    -- deux grains sur trois à l'envers, légèrement désaccordés
    rate = core.pick { 1, -1, -1 } * 2 ^ core.uniform(-0.03, 0.03)
  end

  local overlap = rate_hz * dur
  local len = dur * math.abs(rate)
  core.spawn {
    len = len,
    ago = len + math.random() * spread + 0.01,
    rate = rate,
    life = dur,
    loop = false,
    gain = 0.9 / math.sqrt(math.max(1, overlap)) * util.dbamp(TRIM_DB),
    pan = core.uniform(-0.8, 0.8),
    -- les grains gardent toujours une enveloppe douce
    shape = core.lerp(0.2, 0.8, S),
  }
end

function haze.start(core)
  core.run(function()
    while true do
      local A = params:get("activity")
      local rate_hz = core.lerp(5, 50, A ^ 1.3)
      clock.sleep(core.uniform(0.5, 1.5) / rate_hz)
      if core.active_count() < MAX_GRAINS then
        grain(core, A, params:get("repeats"), params:get("shape"), core.variation(), rate_hz)
      end
    end
  end)
end

return haze
