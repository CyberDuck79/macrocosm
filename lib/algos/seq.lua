-- SEQ (micro loop) : courts échantillons réarrangés en séquences rythmiques.
-- une phrase de 8 pas (1/4 d'unité TIME) est capturée, puis rejouée dans un
-- ordre mélangé ; repeats = nombre de cycles avant de capturer une nouvelle
-- phrase. le rôle d'activity dépend de la variation (manuel Microcosm).
-- capture et mélange repris de Tessera.

local seq = {
  name = "SEQ",
  variations = {
    "filtered, shuffled rhythms",
    "normal and half speed",
    "layers with filter sweeps",
    "crushed interlocking layers",
  },
}

-- compensation de niveau par variation (dB) : des tranches courtes et
-- filtrées sonnent moins fort que le sec. C recalé de +4 dB sur le norns (2026-10-24).
local TRIM_DB = { 4, 2.8, 10, 3.3 }

local STEPS = 8
local captured_beat
local pattern = {}
local cycles_left = 0
local step_index = 0

local function capture(core, R, step_beats)
  -- la phrase est la mesure de 8 pas qui vient de se terminer (en Hold :
  -- celle qui précède le gel, mélangée à nouveau)
  captured_beat = core.buffer_beat() - STEPS * step_beats
  for k = 1, STEPS do
    pattern[k] = core.chance(0.35) and k or math.random(STEPS)
  end
  local step_sec = step_beats * clock.get_beat_sec()
  cycles_left = math.max(1, math.min(1 + util.round(R * 15),
    math.floor(core.max_life(R) / (STEPS * step_sec))))
end

-- une tranche de la phrase, à l'emplacement k (1..8)
local function slice(core, k, step_beats, v)
  local seg_beat = captured_beat + (k - 1) * step_beats
  v.ago = core.ago_of(seg_beat)
  v.len = v.len or step_beats * clock.get_beat_sec()
  v.loop = false
  v.life = v.len / math.abs(v.rate or 1)
  v.shape = v.shape or params:get("shape")
  core.spawn(v)
end

local function step(core)
  local A = params:get("activity")
  local R = params:get("repeats")
  local var = core.variation()
  local step_beats = core.unit_beats() / 4
  local gain = 0.9 * util.dbamp(TRIM_DB[var])

  local idx = step_index % STEPS + 1
  step_index = step_index + 1
  if captured_beat == nil or idx == 1 then
    cycles_left = cycles_left - 1
    if captured_beat == nil or cycles_left <= 0 then capture(core, R, step_beats) end
  end
  if not core.chance(0.9) then return end

  local k = pattern[idx]
  local pan = idx % 2 == 0 and -0.35 or 0.35

  if var == 1 then
    -- activity élargit la plage de fréquences du filtre (jusqu'à ±2 octaves)
    local fc = 2200 * 2 ^ (core.uniform(-2, 2) * A)
    slice(core, k, step_beats, { gain = gain, pan = pan, filter = { 0, fc, fc, 1.2, 0, 0 } })

  elseif var == 2 then
    -- activity fait rebondir la lecture entre vitesse normale et moitié
    local rate = core.chance(core.lerp(0.05, 0.7, A)) and 0.5 or 1
    slice(core, k, step_beats, { gain = gain, pan = pan, rate = rate })
    -- à fond : une nappe douce sous la séquence, relancée à chaque cycle
    if A > 0.95 and idx == 1 then
      local len = 2 * step_beats * clock.get_beat_sec()
      core.spawn {
        ago = core.ago_of(captured_beat), len = len, loop = true, xfade = 0.5,
        life = STEPS * len, gain = 0.35, pan = 0, shape = 0.85, rate = 0.5,
      }
    end

  elseif var == 3 then
    -- activity ajoute des couches qui se chevauchent, chacune balayée
    local layers = 1 + math.floor(A * 2.99)
    for l = 1, layers do
      local lo, hi = core.uniform(180, 600), core.uniform(1500, 5000)
      local up = core.chance(0.5)
      slice(core, l == 1 and k or math.random(STEPS), step_beats, {
        gain = gain / math.sqrt(layers),
        pan = l == 1 and pan or core.uniform(-0.7, 0.7),
        len = 2 * step_beats * clock.get_beat_sec(),
        filter = { 1, up and lo or hi, up and hi or lo, 1.5, 0, 0 },
      })
    end

  else
    -- activity ajoute des couches rythmiques imbriquées, toutes passées au
    -- bitcrush ; la deuxième couche ne joue que les pas pairs, la troisième
    -- les pas impairs à l'envers
    local layers = 1 + math.floor(A * 2.99)
    slice(core, k, step_beats, { gain = gain, pan = pan, crush = { 7, 3 } })
    if layers >= 2 and idx % 2 == 0 then
      slice(core, math.random(STEPS), step_beats, { gain = gain * 0.7, pan = -pan, rate = 2, crush = { 6, 4 } })
    end
    if layers >= 3 and idx % 2 == 1 then
      slice(core, math.random(STEPS), step_beats, { gain = gain * 0.7, pan = -pan, rate = -1, crush = { 6, 4 } })
    end
    -- à fond : tranches à l'octave inférieure, bitcrushées
    if A > 0.95 and idx % 4 == 1 then
      slice(core, k, step_beats, { gain = gain * 0.8, pan = 0, rate = 0.5, crush = { 5, 6 } })
    end
  end
end

function seq.start(core)
  captured_beat = nil
  step_index = 0
  core.every(4, function() step(core) end)
end

return seq
