-- animation de lancement : des grains flottent, une vague les emporte de
-- gauche à droite, ils se posent pour écrire le nom, puis s'éparpillent.
-- Tout se calcule à partir de t : pas d'état à faire évoluer, et splash.draw(t)
-- donne n'importe quelle image. Le script tourne déjà derrière ; une touche
-- ou un encodeur l'arrête.

local splash = { active = false }

local DURATION = 3.6
local OUT_AT = 2.9      -- le nom commence à s'éparpiller
local FRONT_SPEED = 110 -- px/s
local FRONT_START = -34
local FRONT_WIDTH = 34
local SETTLE = 0.6      -- durée pour rejoindre sa place
local EXTRA = 70        -- grains qui ne servent pas au nom

local GLYPHS = {
  m = { "11110", "10101", "10101", "10101", "10101" },
  a = { "1110", "0001", "0111", "1001", "0111" },
  c = { "0111", "1000", "1000", "1000", "0111" },
  r = { "1011", "1100", "1000", "1000", "1000" },
  o = { "0110", "1001", "1001", "1001", "0110" },
  s = { "0111", "1000", "0110", "0001", "1110" },
}
local NAME = "macrocosm"
local SCALE = 2
local NAME_Y = 27

local grains = {}
local start_time

local function smooth(x)
  x = util.clamp(x, 0, 1)
  return x * x * (3 - 2 * x)
end

local function new_grain(tx, ty)
  return {
    x0 = math.random() * 128, y0 = math.random() * 64,
    vx = (math.random() - 0.5) * 8, vy = (math.random() - 0.5) * 6,
    phase = math.random() * 6.28,
    -- direction de l'éparpillement
    ox = (math.random() - 0.3) * 90, oy = (math.random() - 0.5) * 50,
    born = math.random() * 0.5,
    tx = tx, ty = ty,
  }
end

local function build()
  grains = {}
  local x = 0
  for i = 1, #NAME do x = x + #GLYPHS[NAME:sub(i, i)][1] + 1 end
  local left = (128 - (x - 1) * SCALE) // 2
  x = 0
  for i = 1, #NAME do
    local glyph = GLYPHS[NAME:sub(i, i)]
    for row, line in ipairs(glyph) do
      for col = 1, #line do
        if line:sub(col, col) == "1" then
          local tx = left + (x + col - 1) * SCALE
          table.insert(grains, new_grain(tx, NAME_Y + (row - 1) * SCALE))
        end
      end
    end
    x = x + #glyph[1] + 1
  end
  for _ = 1, EXTRA do table.insert(grains, new_grain()) end
end

-- une image, à l'instant t
function splash.draw(t)
  screen.clear()
  local front = FRONT_START + t * FRONT_SPEED
  local out = smooth((t - OUT_AT) / (DURATION - OUT_AT))
  for _, g in ipairs(grains) do
    local x = g.x0 + g.vx * t
    local dx = x - front
    local wave = math.exp(-(dx / FRONT_WIDTH) ^ 2)
    -- la vague aspire les grains sur sa courbe, avec un peu d'écume
    local crest = 32 + 20 * math.sin(x * 0.085 - t * 3.5) + 2.5 * math.sin(g.phase)
    local y = g.y0 + g.vy * t
    y = y + (crest - y) * wave
    x = x + 12 * wave
    local level = smooth((t - g.born) / 0.5) * 4 + 11 * wave
    if g.tx then
      -- la vague passe, le grain rejoint sa place
      local arrive = (g.tx - FRONT_START) / FRONT_SPEED + 0.1
      local k = smooth((t - arrive) / SETTLE)
      x, y = x + (g.tx - x) * k, y + (g.ty - y) * k
      level = level + (15 - level) * k
    elseif dx < -FRONT_WIDTH then
      -- les autres s'éteignent derrière elle
      level = level * math.max(0, 1 + (dx + FRONT_WIDTH) / 40)
    end
    level = util.round(level * (1 - out))
    if level > 0 then
      x, y = x + g.ox * out * out, y + g.oy * out * out
      screen.level(math.min(level, 15))
      screen.rect(util.round(x), util.round(y), g.tx and 2 or 1, g.tx and 2 or 1)
      screen.fill()
    end
  end
  screen.update()
end

function splash.redraw()
  local t = util.time() - start_time
  if t >= DURATION then
    splash.active = false
    return
  end
  splash.draw(t)
end

function splash.start()
  build()
  start_time = util.time()
  splash.active = true
end

function splash.stop()
  splash.active = false
end

return splash
