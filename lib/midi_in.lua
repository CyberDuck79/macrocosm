-- MIDI : l'implémentation du manuel Microcosm (chapitre 8).
--
-- Une table de CC fixe et les Program Change, sur le canal réglé (1 par
-- défaut). L'horloge MIDI est gérée par norns (PARAMETERS > CLOCK), et le
-- mapping de norns (PARAMETERS > MAP) reste libre pour les autres réglages.
-- Écarts avec le manuel :
--   CC 7 (Shape)        continu ici, 4 zones dans le tableau du manuel
--   CC 17 (vitesse)     les 5 vitesses du looper, réparties sur 0-127
--   CC 18 (vitesse)     8x plafonne à 4x
--   CC 20 (Reverb Time) pilote Character
--   CC 27 (Quantize)    au temps ; la mesure se règle dans PARAMETERS
--   CC 45 (Copy Preset) sans équivalent
--   CC 46 (Save Preset) la valeur (1 à 16) est le numéro du preset
-- Les CC à action (looper, Reverse, Tap) agissent sur toute valeur non nulle :
-- le relâchement d'un bouton, qui envoie 0, ne compte pas.

local midi_in = {}

local core, looper
local programs = {}

-- réglages continus, 0-127 sur toute leur course
local CONTINUOUS = {
  [6] = "activity", [7] = "shape", [8] = "filter_lphp", [9] = "mix", [11] = "repeats",
  [12] = "space", [13] = "loop_level", [14] = "mod_rate", [15] = "resonance",
  [16] = "fx_level", [19] = "mod_depth", [20] = "rev_character", [21] = "loop_fade",
}
-- { id, valeur sous 64, valeur à partir de 64 }
local SWITCHES = {
  [23] = { "loop_reverse", 1, 2 },
  [24] = { "loop_route", 1, 2 },
  [25] = { "loop_only", 1, 2 },
  [26] = { "loop_burst", 1, 2 },
  [27] = { "loop_quantize", 1, 2 },
  [48] = { "hold", 0, 1 },
  [102] = { "bypass", 1, 0 },
}
-- 0 = 1/4, 1 = 1/2, 2 = TAP, 3 = 2x, 4 = 4x, 5 = 8x
local SUBDIV_INDEX = { 1, 2, 4, 6, 8, 10 }
local SPEED_INDEX = { 1, 2, 3, 4, 5, 5 }

-- Program Change : l'ordre du manuel
local PROGRAM_ORDER = {
  "ARP", "INTERRUPT", "BLOCKS", "GLIDE", "SEQ", "MOSAIC",
  "HAZE", "TUNNEL", "STRUM", "PATTERN", "WARP",
}
local FIRST_PRESET, LAST_PRESET = 45, 60

local function actions()
  return {
    [28] = looper.rec, [29] = looper.play, [30] = looper.dub, [31] = looper.stop,
    [34] = looper.erase, [35] = looper.undo,
    [47] = function() params:delta("reverse", 1) end,
    [93] = core.tap,
  }
end
local ACTIONS

local function control_change(cc, v)
  local x = v / 127
  local id = CONTINUOUS[cc]
  local sw = SWITCHES[cc]
  if id then
    params:set_raw(id, x)
  elseif sw then
    params:set(sw[1], v < 64 and sw[2] or sw[3])
  elseif ACTIONS[cc] then
    if v > 0 then ACTIONS[cc]() end
  elseif cc == 5 then
    params:set("time_div", SUBDIV_INDEX[math.min(v, 5) + 1])
  elseif cc == 10 then
    if params:get("time_mode") == 2 then
      params:set_raw("time_free", x)
    else
      params:set("time_div", 1 + util.round(x * 9))
    end
  elseif cc == 17 then
    params:set("loop_speed", 1 + util.round(x * 4))
  elseif cc == 18 then
    params:set("loop_speed", SPEED_INDEX[math.min(v, 5) + 1])
  elseif cc == 22 then
    looper.set_active(v >= 64)
  elseif cc == 46 and v >= 1 and v <= 16 then
    params:write(v)
  end
end

-- n : numéro du manuel, à partir de 1
local function program_change(n)
  if n >= FIRST_PRESET and n <= LAST_PRESET then
    params:read(n - FIRST_PRESET + 1)
  elseif programs[n] then
    params:set("effect", programs[n].effect)
    params:set("variation", programs[n].variation)
  end
end

-- 1 à 44 : effets et variations A-D ; à partir de 61 : les variations en plus
local function build_programs(algos)
  local index = {}
  for i, a in ipairs(algos) do index[a.name] = i end
  local extra = 60
  for k, name in ipairs(PROGRAM_ORDER) do
    local i = index[name]
    for v = 1, #algos[i].variations do
      if v <= 4 then
        programs[(k - 1) * 4 + v] = { effect = i, variation = v }
      end
    end
  end
  for _, name in ipairs(PROGRAM_ORDER) do
    local i = index[name]
    for v = 5, #algos[i].variations do
      extra = extra + 1
      programs[extra] = { effect = i, variation = v }
    end
  end
end

local function event(port, data)
  -- Continue (0xFB) : norns ne le transmet pas au script comme Start et
  -- Stop ; on le prend ici, s'il vient de l'entrée d'horloge de norns
  -- (CLOCK > midi clock in : all, none, puis les ports)
  if data[1] == 0xFB then
    local clock_in = params:get("clock_midi_in")
    if params:string("clock_source") == "midi" and (clock_in == 1 or clock_in == port + 2) then
      looper.transport_continue()
    end
    return
  end
  -- horloge et autres messages système : pour norns
  if data[1] >= 0xF0 or params:get("midi_on") == 1 then return end
  local selected = params:get("midi_port")
  if selected > 1 and selected - 1 ~= port then return end
  local msg = midi.to_msg(data)
  if msg.ch ~= params:get("midi_channel") then return end
  if msg.type == "cc" then
    control_change(msg.cc, msg.val)
  elseif msg.type == "program_change" then
    program_change(msg.val + 1)
  end
end

function midi_in.add_params()
  params:add_separator("midi_sep", "midi")
  params:add_option("midi_on", "midi control", { "off", "on" }, 2)
  local ports = { "all" }
  for i = 1, #midi.vports do
    ports[i + 1] = i .. ": " .. midi.vports[i].name
  end
  params:add_option("midi_port", "midi port", ports, 1)
  params:add_number("midi_channel", "midi channel", 1, 16, 1)
  -- un Program Change qui charge un preset ne doit pas couper le MIDI
  for _, id in ipairs { "midi_on", "midi_port", "midi_channel" } do
    params:set_save(id, false)
  end
end

function midi_in.init(c, l, algos)
  core, looper = c, l
  ACTIONS = actions()
  build_programs(algos)
  for i = 1, #midi.vports do
    midi.connect(i).event = function(data) event(i, data) end
  end
end

return midi_in
