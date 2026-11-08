-- MULTIDELAY : un délai à plusieurs taps, qui tourne en continu dans l'engine.
-- d'après le manuel Microcosm : activity = nombre de taps actifs (1 à 8).
-- repeats = feedback, shape = pente des niveaux des taps et façon dont chaque
-- note entre dans le délai (reprises de Tessera), time = unité des motifs.
-- hold = répétition infinie.
--
-- ce module fabrique Pattern et Warp : même délai, motifs et traitements
-- des taps différents.

local multidelay = {}

-- pentes des niveaux : shape à gauche, les taps décroissent ; à droite, ils
-- montent. le tap le plus fort sort près du niveau du jeu : −1 dB avec un
-- seul tap, −5 dB avec 8 (les répétitions se chevauchent et s'additionnent).
-- chaque répétition doit s'entendre comme une note.
local function tap_gains(n, S, trim_db)
  local tilt = (S - 0.5) * 2
  local gains, loudest = {}, 0
  for i = 1, 8 do
    local g = 0
    if i <= n then
      local x = n > 1 and (i - 1) / (n - 1) or 0
      g = math.max(0.08, 1 + tilt * (x - 0.5) * 1.7)
      if tilt < 0 then g = g * math.max(0, 1 - 0.6 * x) ^ (-tilt * 1.5) end
    end
    gains[i] = g
    loudest = math.max(loudest, g)
  end
  local k = loudest > 0 and 0.9 / (loudest * n ^ 0.25) * util.dbamp(trim_db) or 0
  for i = 1, 8 do gains[i] = gains[i] * k end
  return gains
end

-- spec : name, variations, times (par variation, en 16es d'unité TIME),
-- modes (traitement des taps par variation, voir Engine_Macrocosm), trims (dB)
function multidelay.make(spec)
  local algo = { name = spec.name, variations = spec.variations }
  local sent = {}

  local function send(key, ...)
    local v = table.concat({ ... }, ",")
    if sent[key] ~= v then
      sent[key] = v
      return true
    end
    return false
  end

  local function update(core)
    local var = core.variation()
    local A = params:get("activity")
    local R = params:get("repeats")
    local S = params:get("shape")
    local n = 1 + util.round(A * 7)

    local mode, rev = spec.modes[var], params:get("reverse")
    if send("on", mode, rev) then engine.delay_on(mode, rev) end

    local sixteenth = core.unit() / 4
    local d = {}
    for i = 1, 8 do d[i] = spec.times[var][i] * sixteenth end
    if send("taps", table.unpack(d)) then engine.delay_taps(table.unpack(d)) end

    local g = tap_gains(n, S, spec.trims[var])
    if send("gains", table.unpack(g)) then engine.delay_gains(table.unpack(g)) end

    core.view_taps = { delays = d, gains = g }

    local fb = 0.97 * R ^ 0.8
    if send("set", fb, S, n - 1) then engine.delay_set(fb, S, n - 1) end
  end

  function algo.start(core)
    sent = {}
    update(core)
    -- les réglages changent à la main : on renvoie ce qui a bougé, 20 fois par seconde
    core.run(function()
      while true do
        clock.sleep(0.05)
        update(core)
      end
    end)
  end

  function algo.stop(core)
    core.view_taps = nil
    engine.delay_off()
  end

  return algo
end

return multidelay
