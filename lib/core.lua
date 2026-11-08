-- macrocosm : le cœur du script
--
-- paramètres, horloge (TIME), têtes de lecture, Hold / Reverse et interface.
-- un algorithme est un module qui expose :
--   name, variations (4 descriptions), start(core)
--   et, s'il réagit au jeu, onset(core) : appelé à chaque attaque détectée
--   et, s'il a quelque chose à arrêter dans l'engine, stop(core)

local core = {}
local looper = include("lib/looper")
local midi_in = include("lib/midi_in")
local splash = include("lib/splash")

-- TIME : durée de l'unité en valeurs de notes (en temps, 1 = noire), de
-- la plus longue à la plus courte comme le Microcosm (x1/4 … x8), avec en
-- plus les triolets (T) et la noire pointée (D) de Tessera. En mode free,
-- l'unité est une durée fixe (time free), indépendante du tempo.
local SUBDIV_NAMES = { "1 bar", "1/2", "1/4D", "1/4", "1/4T", "1/8", "1/8T", "1/16", "1/16T", "1/32" }
local SUBDIV_BEATS = { 4, 2, 3 / 2, 1, 2 / 3, 1 / 2, 1 / 3, 1 / 4, 1 / 6, 1 / 8 }

-- A à D comme le Microcosm ; certains effets en ont davantage (bonus)
local VARIATION_LETTERS = { "A", "B", "C", "D", "E", "F", "G", "H" }
local REVERB_NAMES = { "bright room", "dark medium", "large hall", "ambient", "shimmer", "cathedral" }
-- un seul réglage, un rôle par mode de réverbe
local CHARACTER_NAMES = { "air", "warmth", "decay", "movement", "sparkle", "bloom" }

-- au-delà, le buffer d'historique (21,8 s) serait réécrit pendant la lecture
local HISTORY_SECONDS = 1048576 / 48000

-- réglages regroupés comme sur le Microcosm (réglage et sa fonction secondaire),
-- dans l'ordre du trajet du son : effet, dosage, timbre, réverbe, couleur,
-- looper, puis les réglages de base qu'on fixe avant de jouer
local PAGES = {
  { "activity", "repeats" },
  { "shape", "time_div" },
  { "mix", "fx_level" },
  { "filter_lphp", "resonance" },
  { "space", "rev_mode" },
  { "rev_character", "rev_position" },
  { "mod_depth", "mod_rate" },
  { "drift", "lofi" },
  { "loop_level", "loop_speed" },
  { "loop_reverse", "loop_rec_start" },
  { "clock_tempo", "onset_sens" },
}

-- en mode free, la page de TIME règle la durée libre
local function page_param(id)
  if id == "time_div" and params:get("time_mode") == 2 then return "time_free" end
  return id
end

-- familles : { name, algo1, algo2... } ; algos = toutes les familles à plat,
-- dans l'ordre (c'est la liste du paramètre effect)
local families = {}
local algos = {}
local family_of = {}
local algo
-- horloges de l'algorithme courant, arrêtées quand on change d'effet
local algo_loops = {}
local voice_ends = {}
-- Engine View : têtes en cours, connues au lancement (rien à demander au
-- moteur), et niveau de l'entrée, une colonne par 1/32 s
local view_heads = {}
local VIEW_MAX_HEADS = 48
local VIEW_COLS = 128
local view_env = {}
for i = 1, VIEW_COLS do view_env[i] = 0 end
local view_pos = 1
local page = 1
local shift = false
local onset_flash = 0
local engine_voices = 0
local saved_monitor
local loops = {}

---------------------------------------------------------------------------
-- utilitaires

function core.lerp(a, b, t) return a + (b - a) * t end

function core.uniform(lo, hi) return lo + math.random() * (hi - lo) end

function core.chance(p) return math.random() < p end

function core.pick(t) return t[math.random(#t)] end

---------------------------------------------------------------------------
-- horloge

-- durée de l'unité TIME en secondes, bornée à 20 ms – 2,5 s
function core.unit()
  return util.clamp(clock.get_beat_sec() * core.unit_beats(), 0.02, 2.5)
end

function core.unit_beats()
  if params:get("time_mode") == 2 then
    return params:get("time_free") / clock.get_beat_sec()
  end
  return SUBDIV_BEATS[params:get("time_div")]
end

-- core.every se réveille LEAD secondes avant la grille et donne à l'engine
-- l'instant exact : les têtes partent pile dessus. Un événement « maintenant »
-- (attaque) part avec l'avance de l'engine, NOW (Engine_Macrocosm.latency) ;
-- SAFETY = Engine_Macrocosm.safety.
local LEAD = 0.05
local NOW = 0.025
local SAFETY = 0.015

-- pendant un pas de core.every : dans combien de secondes tombe l'instant
-- prévu (transmis à l'engine), et le temps (beats) qui lui correspond
local tick_lead = 0
local tick_beat
local hold_beat
local held_beats = 0

-- appelle fn à chaque 1/div de l'unité TIME, calé sur l'horloge norns.
-- div peut être une fonction, réévaluée à chaque pas (division variable).
function core.every(div, fn)
  local id = clock.run(function()
    while true do
      local step = core.unit_beats() / (type(div) == "function" and div() or div)
      local lead_beats = LEAD / clock.get_beat_sec()
      clock.sync(step, -lead_beats)
      local beats = clock.get_beats()
      tick_beat = util.round((beats + lead_beats) / step) * step
      -- en retard au-delà de l'avance, l'engine part dès que possible
      -- et compense la lecture
      tick_lead = util.clamp((tick_beat - beats) * clock.get_beat_sec(), -0.5, LEAD + 0.01)
      fn()
      tick_lead = 0
      tick_beat = nil
    end
  end)
  table.insert(algo_loops, id)
  return id
end

-- lance une boucle libre (clock.sleep...) arrêtée avec l'algorithme courant
function core.run(fn)
  local id = clock.run(fn)
  table.insert(algo_loops, id)
  return id
end

-- Tap tempo : la moyenne des derniers intervalles ; une pause de plus de 2 s
-- repart de zéro. Sans effet quand l'horloge vient de l'extérieur.
local taps = {}

function core.tap()
  if params:get("clock_source") ~= 1 then return end
  local now = util.time()
  if #taps > 0 and now - taps[#taps] > 2 then taps = {} end
  taps[#taps + 1] = now
  if #taps > 4 then table.remove(taps, 1) end
  if #taps > 1 then
    params:set("clock_tempo", util.clamp(60 * (#taps - 1) / (now - taps[1]), 20, 300))
  end
end

-- temps (beats) de l'événement en cours : l'instant prévu pendant un pas
-- de core.every, sinon maintenant
function core.beat()
  return tick_beat or clock.get_beats()
end

-- Hold réellement en cours : hold_beat suit l'action du paramètre, alors
-- qu'une modulation (matrix) change la lecture du paramètre avant elle
function core.held() return hold_beat ~= nil end

-- position (en temps) dans le buffer d'historique à l'instant de l'événement
-- en cours. le buffer n'enregistre pas pendant Hold : on retire le temps
-- passé figé, pour qu'une position notée avant un Hold reste valable après.
function core.buffer_beat()
  if hold_beat then return hold_beat - held_beats end
  return core.beat() - held_beats
end

-- distance (secondes) dans le buffer entre une position notée avec
-- core.buffer_beat() et l'instant de l'événement en cours
function core.ago_of(buffer_beat)
  return (core.buffer_beat() - buffer_beat) * clock.get_beat_sec()
end

-- durée de vie maximale d'une boucle selon Repeats, pour qu'un TIME long
-- ne laisse pas tourner des boucles longtemps après qu'on a arrêté de jouer
function core.max_life(R)
  return core.lerp(1.5, 12, R)
end

---------------------------------------------------------------------------
-- têtes de lecture

function core.active_count()
  local now = util.time()
  for i = #voice_ends, 1, -1 do
    if voice_ends[i] <= now then table.remove(voice_ends, i) end
  end
  return #voice_ends
end

-- v : ago, len, rate, rate_end, life (secondes / vitesses), loop, xfade,
-- gain, pan, shape, delay, filter = {type, f0, f1, q, lfo_rate, lfo_depth},
-- crush = {bits, hold}, glide = {hz, width},
-- len_mod = {hz, depth (octaves), mode 0 = LFO / 1 = enveloppe du jeu},
-- ducks = true : coupe le sec tant que la tête sonne (Interrupt)
function core.spawn(v)
  local rate = v.rate or 1
  local rate_end = v.rate_end or rate
  if params:get("reverse") == 1 then
    rate, rate_end = -rate, -rate_end
  end
  -- Lo-Fi au-delà de 50 % : les têtes ralentissent, jusqu'à demi-vitesse
  local lofi = params:get("lofi")
  if lofi > 0.5 then
    local k = 2 ^ (-2 * (lofi - 0.5))
    rate, rate_end = rate * k, rate_end * k
  end

  local len = math.max(v.len, 16 / 48000)
  -- le segment doit être entièrement dans le passé
  local ago = math.max(v.ago or len, len + 0.001)
  local loop = v.loop ~= false
  local life = v.life
  if not loop then life = math.min(life, len / math.abs(rate)) end
  life = util.clamp(life, 0.001, 20)
  -- hors Hold, la matière lue ne doit pas être réécrite avant la fin
  if not core.held() then
    life = math.min(life, HISTORY_SECONDS - ago - 0.5)
    if life <= 0 then return end
  end

  if v.filter then engine.vfilter(table.unpack(v.filter)) end
  if v.crush then engine.vcrush(table.unpack(v.crush)) end
  if v.glide then engine.vglide(table.unpack(v.glide)) end
  if v.len_mod then engine.vlen(table.unpack(v.len_mod)) end
  if v.ducks then engine.vduck() end
  engine.voice(ago, len, rate, rate_end, life, loop and 1 or 0,
    v.xfade or 0.05, v.gain or 0.5, v.pan or 0, v.shape or 0.5, v.delay or 0, tick_lead)
  local start = util.time() + (tick_lead > 0 and math.max(tick_lead, SAFETY) or NOW) + (v.delay or 0)
  table.insert(voice_ends, start + life)
  if #view_heads >= VIEW_MAX_HEADS then
    for i = #view_heads, 1, -1 do
      if view_heads[i].t0 + view_heads[i].life <= start then table.remove(view_heads, i) end
    end
  end
  if #view_heads < VIEW_MAX_HEADS then
    table.insert(view_heads, {
      t0 = start, bb = core.buffer_beat(), ago = ago, len = len, life = life, loop = loop,
      rate = rate, rate_end = rate_end, gain = v.gain or 0.5, shape = v.shape or 0.5,
      glide = v.glide,
    })
  end
end

---------------------------------------------------------------------------
-- paramètres

local function pct(param)
  return util.round(param:get() * 100) .. "%"
end

-- les dernières attaques, en temps du buffer (core.buffer_beat())
local ONSET_RING = 8
local onset_ring = {}
core.onset_count = 0

-- position de la k-ième attaque la plus récente (0 = la dernière), ou nil
function core.recent_onset(k)
  if k >= math.min(core.onset_count, ONSET_RING) then return nil end
  return onset_ring[(core.onset_count - 1 - k) % ONSET_RING + 1]
end

-- l'effet peut avoir moins de variations que la valeur réglée (on regarde
-- la valeur de base : une modulation ne doit pas la déplacer)
local function clamp_variation()
  local p = params:lookup_param("variation")
  if algo and p.value > #algo.variations then p:set(#algo.variations) end
end

-- variation en cours, bornée à celles de l'effet, modulation comprise
function core.variation()
  return math.min(params:get("variation"), algo and #algo.variations or 1)
end

local function select_algo(i)
  for _, id in ipairs(algo_loops) do clock.cancel(id) end
  algo_loops = {}
  if algo and algo.stop then algo.stop(core) end
  algo = algos[i]
  clamp_variation()
  algo.start(core)
end

function core.add_params()
  params:add_separator("macrocosm_sep", "macrocosm")

  -- comme le Microcosm : mono par défaut (une guitare n'arrive que sur le
  -- canal gauche de norns, il est alors envoyé des deux côtés)
  params:add_option("input", "input", { "mono (left)", "stereo" }, 1)
  params:set_action("input", function(i) engine.input_mono(i == 1 and 1 or 0) end)

  local names = {}
  for i, a in ipairs(algos) do names[i] = string.lower(a.name) end
  params:add_option("effect", "effect", names, 1)
  params:set_action("effect", select_algo)
  -- nombres et interrupteurs plutôt que listes : matrix ne module pas les listes
  params:add_number("variation", "variation", 1, #VARIATION_LETTERS, 1,
    function() return VARIATION_LETTERS[core.variation()] end)
  params:set_action("variation", clamp_variation)
  params:add_control("activity", "activity", controlspec.new(0, 1, "lin", 0, 0.5), pct)
  params:add_control("repeats", "repeats", controlspec.new(0, 1, "lin", 0, 0.5), pct)
  params:add_control("shape", "shape", controlspec.new(0, 1, "lin", 0, 0.5), pct)
  -- (identifiants nouveaux : les valeurs des anciens presets ne veulent
  -- plus dire la même chose)
  params:add_number("time_div", "time", 1, #SUBDIV_NAMES, 4,
    function(p) return SUBDIV_NAMES[p:get()] end)
  params:add_option("time_mode", "time mode", { "sync", "free" }, 1)
  params:add_control("time_free", "time", controlspec.new(0.05, 2, "exp", 0, 0.5, "s"),
    function(p) return util.round(p:get() * 1000) .. " ms" end)

  -- filtre sur l'effet seulement, bipolaire : au centre ouvert, à gauche
  -- passe-bas (tout à gauche l'effet est coupé : 20 Hz × 1000^x), à droite
  -- passe-haut de 20 Hz à 6 kHz (comme Tessera). Même loi que l'engine.
  params:add_control("filter_lphp", "filter", controlspec.new(-1, 1, "lin", 0, 0), function(p)
    local x = p:get()
    local function hz(f)
      return f >= 1000 and string.format("%.1f kHz", f / 1000) or string.format("%d Hz", util.round(f))
    end
    if x <= -0.04 then
      local l = (x + 1) / 0.96
      if l >= 0.99 then return "open" end
      return "LP " .. hz(20 * 1000 ^ l)
    elseif x >= 0.04 then
      return "HP " .. hz(20 * 300 ^ ((x - 0.04) / 0.96))
    end
    return "open"
  end)
  params:set_action("filter_lphp", function(x) engine.filter(x) end)
  params:add_control("resonance", "resonance", controlspec.new(0, 1, "lin", 0, 0.2), pct)
  params:set_action("resonance", function(x) engine.res(x) end)

  -- au centre, sec et effet sont tous les deux à fond ; de 0 à 50 % l'effet
  -- monte, de 50 à 100 % le sec descend (même loi que l'engine)
  params:add_control("mix", "mix", controlspec.new(0, 1, "lin", 0, 0.5), function(p)
    local m = p:get()
    local dry = util.round(100 * math.min(1, 2 * (1 - m)))
    local fx = util.round(100 * math.min(1, 2 * m))
    if fx == 0 then return "dry only" end
    if dry == 0 then return "fx only" end
    return "dry " .. dry .. " fx " .. fx
  end)
  params:set_action("mix", function(x) engine.mix(x) end)
  params:add_control("fx_level", "effect volume", controlspec.new(0, 2, "lin", 0, 1), pct)
  params:set_action("fx_level", function(x) engine.fxLevel(x) end)

  params:add_control("space", "space", controlspec.new(0, 1, "lin", 0, 0.25), pct)
  params:set_action("space", function(x) engine.space(x) end)
  params:add_option("rev_mode", "reverb", REVERB_NAMES, 3)
  params:set_action("rev_mode", function(i) engine.reverb_mode(i - 1) end)
  params:add_control("rev_character", "character", controlspec.new(0, 1, "lin", 0, 0.5), pct)
  params:set_action("rev_character", function(x) engine.reverb_character(x) end)
  params:add_option("rev_position", "rev position", { "effect only", "after mix", "before fx" }, 1)
  params:set_action("rev_position", function(i) engine.reverb_position(i - 1) end)

  params:add_control("mod_depth", "mod depth", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("mod_depth", function(x) engine.modDepth(x) end)
  params:add_control("mod_rate", "mod rate", controlspec.new(0.05, 8, "exp", 0, 0.8, "hz"))
  params:set_action("mod_rate", function(x) engine.modRate(x) end)
  -- bonus : wow et flutter de bande ; sampler basse définition, qui
  -- ralentit aussi les têtes au-delà de 50 %
  params:add_control("drift", "drift", controlspec.new(0, 1, "lin", 0, 0), pct)
  params:set_action("drift", function(x) engine.drift(x) end)
  params:add_control("lofi", "lo-fi", controlspec.new(0, 1, "lin", 0, 0), function(p)
    local x = p:get()
    return util.round(x * 100) .. "%" .. (x > 0.5 and " slow" or "")
  end)
  params:set_action("lofi", function(x) engine.lofi(x) end)
  -- sur l'effet seulement (comme Tessera) ou sur toute la sortie ; le
  -- ralenti des têtes ne dépend pas de ce choix
  params:add_option("color_on", "drift/lo-fi on", { "effect", "all" }, 1)
  params:set_action("color_on", function(i) engine.colorAll(i - 1) end)

  params:add_control("onset_sens", "attack sens", controlspec.new(0, 1, "lin", 0, 0.5), pct)
  params:set_action("onset_sens", function(x) engine.onset_sens(x) end)

  -- lu ici : l'argument de l'action ignore la modulation de matrix
  params:add_binary("hold", "hold", "toggle", 0)
  params:set_action("hold", function()
    local on = params:get("hold") == 1
    if on and not hold_beat then
      hold_beat = clock.get_beats()
    elseif not on and hold_beat then
      held_beats = held_beats + clock.get_beats() - hold_beat
      hold_beat = nil
    end
    engine.hold(on and 1 or 0)
  end)
  params:add_binary("reverse", "reverse", "toggle", 0)

  -- comme le réglage par défaut du Microcosm : sans traînes, tout se coupe
  -- (réverbe et looper compris) et seul le sec passe
  params:add_binary("bypass", "bypass", "toggle", 0)
  params:set_action("bypass", function()
    engine.bypass(params:get("bypass"))
    params:lookup_param("loop_level"):bang()
  end)
  params:add_trigger("tap", "tap tempo")
  params:set_action("tap", core.tap)

  looper.add_params()
  midi_in.add_params()
end

---------------------------------------------------------------------------
-- cycle de vie

-- fams : les familles du script, chacune { name = ..., algo1, algo2... }
function core.init(fams)
  families = fams
  for f, fam in ipairs(families) do
    for _, a in ipairs(fam) do
      table.insert(algos, a)
      family_of[#algos] = f
    end
  end
  math.randomseed(os.time())

  -- le moteur rend déjà le signal sec : on coupe le monitor de norns
  -- pour ne pas l'entendre deux fois, et on le rend en partant
  saved_monitor = params:get("monitor_level")
  params:set("monitor_level", -math.huge)

  core.add_params()
  -- charge le dernier preset s'il existe, puis envoie tout au moteur :
  -- matrix relit ce preset en silence juste après, les deux restent d'accord
  params:default()

  local p = poll.set("onset", function()
    onset_flash = 6
    core.onset_count = core.onset_count + 1
    onset_ring[(core.onset_count - 1) % ONSET_RING + 1] = core.buffer_beat()
    if algo and algo.onset then algo.onset(core) end
  end)
  p:start()
  looper.init(loops)
  midi_in.init(core, looper, algos)
  local pe = poll.set("input_env", function(x)
    -- en Hold, le buffer est figé : le fond aussi
    if not core.held() then
      view_env[view_pos] = x
      view_pos = view_pos % VIEW_COLS + 1
    end
  end)
  pe:start()
  local pv = poll.set("voices", function(n) engine_voices = n end)
  pv.time = 0.1
  pv:start()

  table.insert(loops, clock.run(function()
    while true do
      clock.sleep(splash.active and 1 / 30 or 1 / 15)
      if onset_flash > 0 then onset_flash = onset_flash - 1 end
      redraw()
    end
  end))
  splash.start()
end

function core.cleanup()
  for _, id in ipairs(loops) do clock.cancel(id) end
  for _, id in ipairs(algo_loops) do clock.cancel(id) end
  if saved_monitor then params:set("monitor_level", saved_monitor) end
end

---------------------------------------------------------------------------
-- interface : E1 page, E2 / E3 les deux réglages de la page ;
-- K2 Hold, K3 Reverse ; quand le looper est actif, K2 et K3 le pilotent
-- (voir looper.lua).
-- K1 maintenu : E1 famille, E2 effet (dans la famille), E3 variation,
-- K2 entre dans le looper / en sort, K3 Reverse de l'effet.

-- premier et dernier index (dans algos) des effets de la famille f
local function family_range(f)
  local first, last
  for i = 1, #algos do
    if family_of[i] == f then
      first = first or i
      last = i
    end
  end
  return first, last
end

function core.enc(n, d)
  if splash.active then return splash.stop() end
  local i = params:get("effect")
  if shift and n == 1 then
    local f = util.clamp(family_of[i] + d, 1, #families)
    if f ~= family_of[i] then params:set("effect", (family_range(f))) end
  elseif shift and n == 2 then
    local first, last = family_range(family_of[i])
    params:set("effect", util.clamp(i + d, first, last))
  elseif shift and n == 3 then
    params:delta("variation", d)
  elseif n == 1 then
    -- page 0 : Engine View, à gauche de la page de départ
    page = util.clamp(page + d, 0, #PAGES)
  else
    -- la vue n'a pas de réglages à elle : E2 et E3 restent sur Activity et Repeats
    params:delta(page_param(PAGES[math.max(page, 1)][n - 1]), d)
  end
end

function core.key(n, z)
  if splash.active and z == 1 then return splash.stop() end
  if n == 1 then
    shift = z == 1
  elseif shift and z == 1 then
    -- K1 + K2 : entrer dans le looper / en sortir ; K1 + K3 : Reverse de
    -- l'effet (K3 seul sert au looper quand il est actif)
    if n == 2 then looper.toggle() end
    if n == 3 then params:delta("reverse", 1) end
  elseif looper.active then
    looper.key(n, z)
  elseif z == 1 and n == 2 then
    params:delta("hold", 1)
  elseif z == 1 and n == 3 then
    params:delta("reverse", 1)
  end
end

-- position 0..1 d'un paramètre, quel que soit son type
local function raw(p)
  if p.get_raw then return p:get_raw() end
  if p.options then return (p:get() - 1) / math.max(1, #p.options - 1) end
  if p.min and p.max then return (p:get() - p.min) / (p.max - p.min) end
  return 0
end

local function draw_param(id, x)
  local p = params:lookup_param(id)
  screen.level(4)
  screen.move(x, 34)
  screen.text(id == "rev_character" and CHARACTER_NAMES[params:get("rev_mode")] or p.name)
  screen.level(15)
  screen.move(x, 46)
  screen.text(params:string(id))
  screen.level(2)
  screen.rect(x, 52, 56, 2)
  screen.fill()
  screen.level(12)
  if id == "filter_lphp" then
    -- bipolaire : la barre part du centre
    local w = util.round(28 * p:get())
    screen.rect(x + 28 + math.min(w, 0), 52, math.max(math.abs(w), 1), 2)
  else
    screen.rect(x, 52, util.round(56 * util.clamp(raw(p), 0, 1)), 2)
  end
  screen.fill()
end

-- Engine View : de y = 13 à 59. En largeur le temps (maintenant à droite,
-- 4 s à gauche, les têtes plus anciennes restent au bord), en hauteur la
-- vitesse (centre = normal, ±2 octaves), en luminosité le volume.
local VIEW_MID, VIEW_HALF = 36, 22

local function view_x(ago)
  return util.clamp(util.round(VIEW_COLS - 1 - ago * 32), 0, VIEW_COLS - 1)
end

-- niveau de l'entrée il y a `ago` secondes (0..1)
local function view_env_at(ago)
  local k = util.clamp(math.floor(ago * 32), 0, VIEW_COLS - 1)
  return view_env[(view_pos - 2 - k) % VIEW_COLS + 1]
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

local function draw_engine_view()
  -- l'entrée : gris très sombre, de l'ancien vers le récent
  screen.level(1)
  for x = 0, VIEW_COLS - 1 do
    local h = util.round(view_env[(view_pos - 2 - (VIEW_COLS - 1 - x)) % VIEW_COLS + 1] * VIEW_HALF)
    if h > 0 then
      screen.rect(x, VIEW_MID - h, 1, 2 * h)
      screen.fill()
    end
  end

  -- Multidelay : une barre par tap, qui s'allume quand le son y passe
  if core.view_taps then
    for i = 1, 8 do
      local g = core.view_taps.gains[i]
      if g > 0 then
        local d = core.view_taps.delays[i]
        local h = math.max(2, util.round(math.min(g, 1) * VIEW_HALF))
        screen.level(2 + util.round(13 * view_env_at(d)))
        screen.rect(view_x(d), VIEW_MID - h, 1, 2 * h)
        screen.fill()
      end
    end
  end

  local now = util.time()
  for i = #view_heads, 1, -1 do
    local h = view_heads[i]
    local e = now - h.t0
    if e > h.life then
      table.remove(view_heads, i)
    elseif e >= 0 then
      local r, travel = head_motion(h, e)
      local seg = h.ago + core.ago_of(h.bb)
      local ph = h.rate < 0 and -travel or travel
      local read = seg - (h.loop and ph % h.len or ph)
      local y = VIEW_MID - util.clamp(math.log(r, 2) / 2, -1, 1) * (VIEW_HALF - 2)
      y = util.round(y)
      local lvl = util.clamp(util.round(2 + 13 * head_env(h, e / h.life) * h.gain * 1.5), 2, 15)
      -- boucle : le morceau lu, en trait
      if h.loop then
        local x0, x1 = view_x(seg), view_x(seg - h.len)
        screen.level(math.max(2, lvl // 3))
        screen.rect(x0, y, math.max(1, x1 - x0), 1)
        screen.fill()
      end
      screen.level(lvl)
      local x = view_x(read)
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

function core.redraw()
  if splash.active then return splash.redraw() end
  screen.clear()
  screen.font_size(8)

  -- ligne 1 : effet et variation, puis attaque, nombre de têtes, Hold (ou
  -- l'état du looper), Rev et l'horloge
  screen.level(15)
  screen.move(0, 10)
  screen.text(algo.name .. " " .. params:string("variation"))

  if onset_flash > 0 then
    screen.level(onset_flash * 2)
    screen.circle(55, 7, 2)
    screen.fill()
  end
  screen.level(3)
  screen.move(70, 10)
  screen.text_right(string.format("%d", engine_voices))
  -- labels de K2 et K3 : ce que fait la touche, et son état (grisé = au
  -- repos, allumé = actif, clignotant = en cours dans le looper)
  local k2, k2_on, k3, k3_on
  if shift then
    k2, k2_on = looper.active and "EXIT" or "LOOP", looper.active
    k3, k3_on = "REV", params:get("reverse") == 1
  elseif looper.active then
    k2, k2_on = looper.k2_label()
    k3, k3_on = looper.k3_label()
  else
    k2, k2_on = "HOLD", core.held()
    k3, k3_on = "REV", params:get("reverse") == 1
  end
  local blink = looper.active and not shift and util.time() % 0.5 < 0.25
  -- alignés à gauche : un label de 3 ou 4 lettres part toujours du même point
  screen.move(76, 10)
  screen.level(k2_on and (blink and 5 or 15) or 3)
  screen.text(k2)
  if k3 then
    screen.move(101, 10)
    screen.level(k3_on and 15 or 3)
    screen.text(k3)
  end
  -- une boucle qui joue (looper actif ou non) : sa position sous la description
  if looper.state == "play" or looper.state == "dub" then
    screen.level(looper.state == "dub" and 12 or 5)
    screen.rect(0, page == 0 and 12 or 23, util.round(128 * util.clamp(looper.pos, 0, 1)), 1)
    screen.fill()
  end

  -- horloge : un éclair à chaque temps, plus grand sur le premier de la mesure
  local beats = clock.get_beats()
  local flash = beats % 1 < 0.2
  if math.floor(beats) % params:get("beats_per_bar") == 0 then
    screen.level(flash and 15 or 3)
    screen.rect(123, 5, 5, 5)
  else
    screen.level(flash and 10 or 2)
    screen.rect(124, 6, 3, 3)
  end
  screen.fill()

  -- la vue prend la place de la description et des réglages ; K1 maintenu
  -- affiche quand même la famille par-dessus
  if page == 0 then draw_engine_view() end
  local bypassed = params:get("bypass") == 1
  if page ~= 0 or shift or bypassed then
    if page == 0 then
      screen.level(0)
      screen.rect(0, 13, 128, 9)
      screen.fill()
    end
    -- ligne 2 : description de la variation, ou la famille tant que K1 est maintenu
    screen.move(0, 20)
    if shift then
      local f = family_of[params:get("effect")]
      screen.level(10)
      screen.text(families[f].name .. "  " .. f .. "/" .. #families)
    elseif bypassed then
      screen.level(15)
      screen.text("bypass")
    else
      screen.level(3)
      local text = algo.variations[core.variation()]
      while screen.text_extents(text) > 128 do text = text:sub(1, -3) .. "." end
      screen.text(text)
    end
  end

  if page ~= 0 then
    draw_param(page_param(PAGES[page][1]), 0)
    draw_param(page_param(PAGES[page][2]), 66)
  end

  -- indicateurs de page, centrés ; la vue est un trait plus haut que les points
  local first = 64 - 2 * #PAGES - 1
  for i = 0, #PAGES do
    screen.level(i == page and 15 or 2)
    if i == 0 then
      screen.rect(first, 60, 2, 4)
    else
      screen.rect(first + i * 4, 62, 2, 2)
    end
    screen.fill()
  end
  screen.update()
end

return core
