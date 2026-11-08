-- ARP (glitch) : les dernières notes jouées deviennent un arpège.
-- d'après le manuel Microcosm : activity = nombre de pas de l'arpège.
-- interprétation : repeats = vitesse des pas (l'unité TIME divisée par 1,
-- 2, 3, 4, 6 ou 8). chaque attaque lance un arpège qui décroît jusqu'à 20 %.
-- A et C enchaînent les notes récentes ; B et D transposent la dernière note
-- (rapports repris de Tessera).

local arp = {
  name = "ARP",
  variations = {
    "arpeggio of recent notes",
    "pitch-shifted pattern",
    "random filter on each step",
    "crushed arpeggios",
  },
}

local TRIM_DB = { 4.9, 4.8, 12, 4.8 }
local DIVS = { 1, 2, 3, 4, 6, 8 }
-- tierce majeure, quinte et octave
local PITCHED = { 1, 1.259921, 1.498307, 2, 1.498307, 1.259921 }
local CRUSHED = { 1, 0.5, 2, 1 }

local remaining = 0
local index = 0
local gain = 1
local decay = 0.9
local idle_units = 0

local function div_for(R)
  return DIVS[math.min(6, math.floor(R * 6) + 1)]
end

local function start_arp(core)
  local A = params:get("activity")
  local R = params:get("repeats")
  local step_sec = core.unit() / div_for(R)
  -- compté en pas, mais borné en secondes
  remaining = math.max(2, math.min(3 + util.round(A * 21), math.floor(core.max_life(R) / step_sec)))
  index = 0
  gain = 1
  decay = 0.2 ^ (1 / remaining)
end

local function step(core)
  local var = core.variation()
  local div = div_for(params:get("repeats"))
  local hold = core.held()

  -- en Hold, relancer un arpège toutes les 2 unités sur les notes gelées
  if hold and remaining <= 0 and core.onset_count > 0 then
    idle_units = idle_units + 1 / div
    if idle_units >= 2 then
      idle_units = 0
      start_arp(core)
    end
  end
  if remaining <= 0 then return end

  local recent = math.min(core.onset_count, 4)
  local src, ratio = core.recent_onset(0), 1
  if var == 1 or var == 3 then
    src = core.recent_onset(index % recent)
  elseif var == 2 then
    ratio = PITCHED[index % #PITCHED + 1]
  else
    ratio = CRUSHED[index % #CRUSHED + 1]
  end

  local dur = core.unit() / div * 0.92
  local avail = core.ago_of(src) - (hold and 0 or 0.002)
  local len = math.min(dur * ratio, avail, 0.3)
  if len > 0.008 then
    local v = {
      ago = core.ago_of(src), len = len, rate = ratio, loop = true, xfade = 0.3, life = dur,
      gain = 0.75 * gain * util.dbamp(TRIM_DB[var]), pan = math.sin(index * 1.7) * 0.6,
      shape = params:get("shape"),
    }
    if var == 3 then
      local f = 2 ^ core.uniform(math.log(300, 2), math.log(4000, 2))
      v.filter = { 1, f, f, 5, 0, 0 }
    elseif var == 4 then
      v.crush = { 6, 4 }
    end
    core.spawn(v)
  end
  gain = gain * decay
  index = index + 1
  remaining = remaining - 1
end

function arp.onset(core)
  start_arp(core)
end

function arp.start(core)
  remaining = 0
  idle_units = 0
  core.every(function() return div_for(params:get("repeats")) end, function() step(core) end)
end

return arp
