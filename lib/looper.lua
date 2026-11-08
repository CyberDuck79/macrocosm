-- Phrase Looper (manuel Microcosm, chapitre 6), commun à tous les effets.
-- l'audio est dans l'engine (macrocosm_looper) ; ici, les états et les touches.
--
-- K1 maintenu + K2 : entre dans le looper / en sort (K2 et K3 changent de rôle)
-- looper actif, l'écran nomme toujours l'action de K2 et de K3 :
--   K2 : enregistrer, puis lire, puis overdub (ordre réglable) ;
--        maintenu : annule l'overdub (retour à la phrase initiale)
--   K3 : arrête (ou annule un départ armé) ; boucle arrêtée : efface ;
--        maintenu : efface
--   en mode Burst, K2 enregistre tant qu'il est maintenu
--
-- ajouts pour jouer sans pédale (pas dans le Microcosm) : départ calé sur la
-- mesure ou après un décompte, longueur fixée en mesures, quantize à la
-- mesure, clic de métronome.

local looper = {}

local SPEED_NAMES = { "1/4", "1/2", "1", "2", "4" }
local SPEEDS = { 0.25, 0.5, 1, 2, 4 }
local LENGTH_NAMES = { "free", "1 bar", "2 bars", "4 bars", "8 bars" }
local LENGTH_BARS = { 0, 1, 2, 4, 8 }
local MAX_SECONDS = 60
local LONG_PRESS = 0.6
-- même réveil anticipé que les têtes (LEAD de core.lua) : les départs calés
-- sur l'horloge sont envoyés d'autant en avance, pour tomber pile
local LEAD = 0.05
-- la phrase est fermée un peu après sa longueur exacte, pour que tout ce
-- qui est relu ait bien été enregistré
local CLOSE_MARGIN = 0.01

looper.active = false
-- empty, armed, rec, play, dub, stop
looper.state = "empty"
looper.pos = 0
-- temps (beats) où l'enregistrement armé démarrera
looper.armed_beat = nil

local rec_started = 0
local rec_id = 0
local closing = false
local press_clock = {}
local long_fired = {}
-- touches enfoncées (pour annoncer l'action d'un appui long à l'écran)
local held = {}

local function on(id) return params:get(id) == 2 end

local function bpb() return params:get("beats_per_bar") end

local function beat_sec() return clock.get_beat_sec() end

local function send_rate()
  local r = SPEEDS[params:get("loop_speed")]
  engine.loop_rate(on("loop_reverse") and -r or r)
end

local function send_fade()
  local t, mode = params:get("loop_fade"), params:get("loop_fade_mode")
  engine.loop_fade(mode ~= 3 and t or 0, mode ~= 2 and t or 0)
end

local function data_path(number)
  return norns.state.data .. string.format("loop-%02d", number)
end

-- attend jusqu'à LEAD secondes avant le temps `beat`, et renvoie dans combien
-- de secondes il tombe
local function wait_until(beat)
  local wait = (beat - clock.get_beats()) * beat_sec() - LEAD
  if wait > 0 then clock.sleep(wait) end
  return math.max(0, (beat - clock.get_beats()) * beat_sec())
end

---------------------------------------------------------------------------
-- états

-- ferme la phrase initiale ; next_state = play, dub ou stop.
-- lead : dans combien de secondes (fermeture calée sur l'horloge) ;
-- len : longueur imposée (s)
local function finish(next_state, lead, len)
  engine.loop_rec(0, lead or 0, ({ play = 0, dub = 1, stop = 2 })[next_state])
  closing = false
  -- la longueur imposée part juste après la réponse du serveur, qui
  -- annonce la longueur enregistrée
  if len then
    clock.run(function()
      clock.sleep((lead or 0) + 0.05)
      engine.loop_len(len)
    end)
  end
  looper.state = next_state
end

function looper.close(next_state)
  if closing or looper.state ~= "rec" then return end
  next_state = next_state or (params:get("loop_order") == 2 and "dub" or "play")
  local q = params:get("loop_quantize")
  if q == 1 then return finish(next_state) end

  -- Quantize : longueur arrondie au temps (ou à la mesure) le plus proche ;
  -- si c'est plus long que l'enregistrement, on continue jusque-là
  local unit = (q == 3 and bpb() or 1) * beat_sec()
  local elapsed = util.time() - rec_started
  local target = math.min(math.max(1, util.round(elapsed / unit)) * unit, MAX_SECONDS - 0.2)
  if target <= elapsed then return finish(next_state, 0, target) end
  closing = true
  clock.run(function()
    local wait = target - (util.time() - rec_started) - LEAD
    if wait > 0 then clock.sleep(wait) end
    local lead = math.max(0, target - (util.time() - rec_started)) + CLOSE_MARGIN
    finish(next_state, lead, target)
  end)
end

-- start_beat : temps (beats) où l'enregistrement commence vraiment
local function start_rec(lead, start_beat)
  lead = lead or 0
  start_beat = start_beat or clock.get_beats()
  engine.loop_rec(1, lead, 0)
  rec_started = util.time() + lead
  rec_id = rec_id + 1
  looper.state = "rec"
  local id = rec_id

  -- longueur fixée : la phrase se ferme seule au bout de N mesures
  local bars = LENGTH_BARS[params:get("loop_length")]
  if bars > 0 and not on("loop_burst") then
    clock.run(function()
      local end_beat = start_beat + bars * bpb()
      local len = bars * bpb() * beat_sec()
      local l = wait_until(end_beat)
      if looper.state == "rec" and rec_id == id and not closing then
        finish(params:get("loop_order") == 2 and "dub" or "play", l + CLOSE_MARGIN, len)
      end
    end)
  end

  -- au bout de 60 s, la phrase se ferme d'elle-même
  clock.run(function()
    clock.sleep(lead + MAX_SECONDS - 0.2)
    if looper.state == "rec" and rec_id == id then looper.close() end
  end)
end

-- départ selon « rec start » : tout de suite, à la mesure suivante, ou
-- après au moins une mesure complète de décompte
local function arm()
  local mode = params:get("loop_rec_start")
  if mode == 1 then return start_rec() end
  local beats = clock.get_beats()
  local target = math.ceil(beats / bpb() - 1e-6) * bpb()
  if mode == 3 then target = target + bpb() end
  looper.armed_beat = target
  looper.state = "armed"
  local id = rec_id
  clock.run(function()
    local l = wait_until(target)
    if looper.state == "armed" and rec_id == id then
      looper.armed_beat = nil
      start_rec(l, target)
    end
  end)
end

local function play()
  engine.loop_dub(0)
  if looper.state == "stop" then engine.loop_play(1) end
  looper.state = "play"
end

local function dub()
  engine.loop_dub(1)
  looper.state = "dub"
end

local function stop()
  if looper.state == "armed" then
    looper.armed_beat = nil
    looper.state = "empty"
    return
  end
  if looper.state == "rec" then return looper.close("stop") end
  engine.loop_dub(0)
  engine.loop_play(0)
  looper.state = "stop"
end

local function erase()
  rec_id = rec_id + 1
  looper.armed_beat = nil
  engine.loop_erase()
  looper.state = "empty"
end

local function undo()
  engine.loop_undo()
  if looper.state == "dub" then play() end
end

---------------------------------------------------------------------------
-- touches

local function short_press(n)
  local s = looper.state
  if n == 2 then
    if s == "empty" then arm()
    elseif s == "rec" then looper.close()
    elseif s == "play" then dub()
    elseif s == "dub" or s == "stop" then play()
    end
  elseif n == 3 then
    if s == "stop" then erase()
    elseif s ~= "empty" then stop()
    end
  end
end

local function long_press(n)
  if n == 2 and (looper.state == "play" or looper.state == "dub") then undo() end
  if n == 3 and looper.state ~= "empty" then erase() end
end

function looper.key(n, z)
  -- un relâchement sans appui (K2 enfoncé avec K1, par exemple) ne compte pas
  if z == 0 and not held[n] then return end
  held[n] = z == 1
  if n == 2 and on("loop_burst") then
    -- Burst : une seule couche, enregistrée tant que K2 est maintenu
    if z == 1 then
      if looper.state ~= "empty" then erase() end
      start_rec()
    elseif looper.state == "rec" then
      looper.close("play")
    end
    return
  end

  if z == 1 then
    long_fired[n] = false
    press_clock[n] = clock.run(function()
      clock.sleep(LONG_PRESS)
      long_fired[n] = true
      long_press(n)
    end)
  else
    if press_clock[n] then clock.cancel(press_clock[n]) end
    press_clock[n] = nil
    if not long_fired[n] then short_press(n) end
  end
end

-- K1 + K2 : le Hold n'est pas accessible quand le looper est actif (manuel)
function looper.toggle()
  looper.active = not looper.active
  if looper.active then params:set("hold", 0) end
end

-- commandes directes, pour le MIDI (une par CC du manuel) : elles marchent
-- que le looper soit actif à l'écran ou non
function looper.set_active(on)
  if on ~= looper.active then looper.toggle() end
end

function looper.rec()
  local s = looper.state
  if s == "empty" then arm() elseif s == "rec" then looper.close() end
end

function looper.play()
  local s = looper.state
  if s == "rec" then looper.close("play") elseif s == "dub" or s == "stop" then play() end
end

function looper.dub()
  local s = looper.state
  if s == "rec" then
    looper.close("dub")
  elseif s == "play" then
    dub()
  elseif s == "stop" then
    play()
    dub()
  end
end

function looper.stop()
  if looper.state ~= "empty" then stop() end
end

function looper.erase()
  if looper.state ~= "empty" then erase() end
end

function looper.undo()
  if looper.state == "play" or looper.state == "dub" then undo() end
end

-- labels de K2 et K3 quand le looper est actif : ce que fait la touche, et
-- si son action est en cours (« on » : le label clignote ou s'allume).
-- renvoie texte, on
function looper.k2_label()
  local s = looper.state
  if held[2] and not on("loop_burst") and (s == "play" or s == "dub") then return "UNDO", false end
  if s == "armed" and looper.armed_beat then
    -- décompte : temps restants avant le départ
    return "ARM" .. math.max(1, math.ceil(looper.armed_beat - clock.get_beats())), true
  end
  if s == "rec" then return "REC", true end
  if s == "dub" then return "DUB", true end
  if s == "play" then return "DUB", false end
  if s == "stop" then return "PLAY", false end
  return "REC", false
end

function looper.k3_label()
  local s = looper.state
  if s == "empty" then return nil end
  if s == "stop" or (held[3] and not on("loop_burst")) then return "CLR", false end
  return "STOP", false
end

---------------------------------------------------------------------------
-- métronome : un clic par temps, calé sur l'horloge norns

local function metronome()
  while true do
    local lead_beats = LEAD / beat_sec()
    clock.sync(1, -lead_beats)
    local beats = clock.get_beats()
    local beat = util.round(beats + lead_beats)
    local mode = params:get("metronome")
    if mode == 3 or (mode == 2 and looper.state == "armed") then
      local accent = beat % bpb() == 0 and 1 or 0
      engine.click(accent, params:get("click_level"), math.max(0, (beat - beats) * beat_sec()))
    end
  end
end

---------------------------------------------------------------------------
-- paramètres et sauvegarde avec les presets

function looper.add_params()
  params:add_separator("looper_sep", "looper")
  params:add_control("loop_level", "loop level", controlspec.new(0, 1.5, "lin", 0, 1),
    function(p) return util.round(p:get() * 100) .. "%" end)
  params:set_action("loop_level", function(x)
    engine.loop_level(params:get("bypass") == 1 and 0 or x)
  end)
  params:add_number("loop_speed", "loop speed", 1, #SPEED_NAMES, 3,
    function(p) return SPEED_NAMES[p:get()] end)
  params:set_action("loop_speed", send_rate)
  params:add_option("loop_reverse", "loop reverse", { "off", "on" }, 1)
  params:set_action("loop_reverse", send_rate)
  params:add_control("loop_fade", "loop fade", controlspec.new(0, 5, "lin", 0, 0.1, "s"))
  params:set_action("loop_fade", send_fade)
  params:add_option("loop_fade_mode", "fade", { "in / out", "in only", "out only" }, 1)
  params:set_action("loop_fade_mode", send_fade)
  -- raccord : ce qui sonnait à la fin de la phrase s'éteint sur son début
  params:add_control("loop_seam", "loop seam", controlspec.new(0.005, 0.5, "exp", 0, 0.08, "s"),
    function(p) return util.round(p:get() * 1000) .. " ms" end)
  params:set_action("loop_seam", function(x) engine.loop_seam(x) end)
  params:add_option("loop_route", "routing", { "post-fx", "pre-fx" }, 1)
  params:set_action("loop_route", function(i) engine.loop_route(i - 1) end)
  params:add_option("loop_rec_start", "rec start", { "now", "next bar", "count-in" }, 1)
  params:add_option("loop_length", "rec length", LENGTH_NAMES, 1)
  params:add_option("loop_quantize", "quantize", { "off", "beat", "bar" }, 1)
  params:add_option("loop_burst", "burst", { "off", "on" }, 1)
  params:add_option("loop_only", "looper only", { "off", "on" }, 1)
  params:set_action("loop_only", function(i) engine.loop_only(i - 1) end)
  params:add_option("loop_order", "order", { "rec > play > dub", "rec > dub > play" }, 1)
  params:add_number("beats_per_bar", "beats per bar", 1, 12, 4)
  params:add_option("metronome", "metronome", { "off", "count-in", "always" }, 2)
  params:add_control("click_level", "click level", controlspec.new(0, 1, "lin", 0, 0.25),
    function(p) return util.round(p:get() * 100) .. "%" end)
  -- longueur de la phrase, enregistrée avec le preset
  params:add_control("loop_len", "loop length", controlspec.new(0, MAX_SECONDS, "lin", 0, 0, "s"))
  params:hide("loop_len")

  params.action_write = function(_, _, number) engine.loop_save(data_path(number)) end
  params.action_read = function(_, _, number)
    engine.loop_load(data_path(number), params:get("loop_len"))
    looper.state = params:get("loop_len") > 0 and "stop" or "empty"
  end
  params.action_delete = function(_, _, number)
    os.remove(data_path(number) .. "-a.wav")
    os.remove(data_path(number) .. "-b.wav")
  end
end

-- loops : la liste des horloges du script (arrêtées en quittant)
function looper.init(loops)
  local pl = poll.set("loop_len", function(s) params:set("loop_len", s, true) end)
  pl:start()
  local pp = poll.set("loop_pos", function(x) looper.pos = x end)
  pp.time = 1 / 15
  pp:start()
  table.insert(loops, clock.run(metronome))
end

return looper
