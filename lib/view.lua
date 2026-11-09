-- macrocosm : l'Engine View
--
-- Ce que fait l'effet, de y = 13 à 59. En largeur le temps (maintenant à
-- droite, 4 s à gauche, les têtes plus anciennes restent au bord), en
-- hauteur la vitesse (centre = normal, ±2 octaves), en luminosité le volume.
-- Les têtes sont connues au lancement (rien à demander au moteur) ; le fond
-- est le niveau de l'entrée, une colonne par 1/32 s.

local view = {}

local MAX_HEADS = 48
local COLS = 128
local MID, HALF = 36, 22

local core
local heads = {}
local env = {}
for i = 1, COLS do env[i] = 0 end
local pos = 1

function view.init(c) core = c end

-- une colonne du fond : le niveau de l'entrée (0..1)
function view.push_env(x)
  env[pos] = x
  pos = pos % COLS + 1
end

-- une tête lancée : t0 (util.time() du départ), bb (core.buffer_beat()),
-- ago, len, life, loop, rate, rate_end, gain, shape, glide
function view.add_head(h)
  if #heads >= MAX_HEADS then
    for i = #heads, 1, -1 do
      if heads[i].t0 + heads[i].life <= h.t0 then table.remove(heads, i) end
    end
  end
  if #heads < MAX_HEADS then table.insert(heads, h) end
end

local function x_of(ago)
  return util.clamp(util.round(COLS - 1 - ago * 32), 0, COLS - 1)
end

-- niveau de l'entrée il y a `ago` secondes (0..1)
local function env_at(ago)
  local k = util.clamp(math.floor(ago * 32), 0, COLS - 1)
  return env[(pos - 2 - k) % COLS + 1]
end

-- vitesse (valeur absolue) et distance parcourue à l'âge e, comme dans la tête
local function head_motion(h, e)
  local r0 = math.max(math.abs(h.rate), 1e-3)
  local r1 = math.max(math.abs(h.rate_end), 1e-3)
  local q = r1 / r0
  if h.glide and h.glide[1] > 0 then
    -- va-et-vient : la distance est approchée par la vitesse moyenne
    local w = util.clamp(h.glide[2], 0.01, 0.99)
    local ph = e * h.glide[1] % 1
    local lfo = ph < w and ph / w or (1 - ph) / (1 - w)
    return r0 * q ^ lfo, math.sqrt(r0 * r1) * e
  elseif math.abs(q - 1) < 1e-4 then
    return r0, r0 * e
  end
  return r0 * q ^ (e / h.life), h.life * r0 * (q ^ (e / h.life) - 1) / math.log(q)
end

-- l'enveloppe de la tête, comme dans le moteur
local function head_env(h, t)
  local sh2 = h.shape * 2
  local attack = 0.01 + 0.84 * util.clamp(sh2 - 1, 0, 1)
  local k = 5 - 4.85 * util.clamp(sh2, 0, 1)
  local a = math.sin(math.min(t / attack, 1) * math.pi / 2)
  return a * a * (1 - util.clamp((t - attack) / (1 - attack + 1e-6), 0, 1)) ^ k
end

function view.draw()
  -- l'entrée : gris très sombre, de l'ancien vers le récent
  screen.level(1)
  for x = 0, COLS - 1 do
    local h = util.round(env[(pos - 2 - (COLS - 1 - x)) % COLS + 1] * HALF)
    if h > 0 then
      screen.rect(x, MID - h, 1, 2 * h)
      screen.fill()
    end
  end

  -- Multidelay : une barre par tap, qui s'allume quand le son y passe
  if core.view_taps then
    for i = 1, 8 do
      local g = core.view_taps.gains[i]
      if g > 0 then
        local d = core.view_taps.delays[i]
        local h = math.max(2, util.round(math.min(g, 1) * HALF))
        screen.level(2 + util.round(13 * env_at(d)))
        screen.rect(x_of(d), MID - h, 1, 2 * h)
        screen.fill()
      end
    end
  end

  local now = util.time()
  for i = #heads, 1, -1 do
    local h = heads[i]
    local e = now - h.t0
    if e > h.life then
      table.remove(heads, i)
    elseif e >= 0 then
      local r, travel = head_motion(h, e)
      local seg = h.ago + core.ago_of(h.bb)
      local ph = h.rate < 0 and -travel or travel
      local read = seg - (h.loop and ph % h.len or ph)
      local y = MID - util.clamp(math.log(r, 2) / 2, -1, 1) * (HALF - 2)
      y = util.round(y)
      local lvl = util.clamp(util.round(2 + 13 * head_env(h, e / h.life) * h.gain * 1.5), 2, 15)
      -- boucle : le morceau lu, en trait
      if h.loop then
        local x0, x1 = x_of(seg), x_of(seg - h.len)
        screen.level(math.max(2, lvl // 3))
        screen.rect(x0, y, math.max(1, x1 - x0), 1)
        screen.fill()
      end
      screen.level(lvl)
      local x = x_of(read)
      if h.rate < 0 then
        -- à l'envers : creux
        screen.rect(x - 0.5, y - 0.5, 3, 3)
        screen.line_width(1)
        screen.stroke()
      else
        screen.rect(x, y, 2, 2)
        screen.fill()
      end
    end
  end
end

return view
