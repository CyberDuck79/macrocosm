-- macrocosm : le cœur du script
--
-- horloge (TIME), têtes de lecture, Hold / Reverse, choix de l'effet et
-- cycle de vie. Les réglages sont dans params.lua, l'interface dans ui.lua,
-- l'Engine View dans view.lua, les constantes de temps dans timing.lua.
-- un algorithme est un module qui expose :
--   name, variations (4 descriptions), start(core)
--   et, s'il réagit au jeu, onset(core) : appelé à chaque attaque détectée
--   et, s'il a quelque chose à arrêter dans l'engine, stop(core)

local core = {}
-- include relance le fichier à chaque appel (dofile) : les modules qui ont
-- un état ne sont inclus qu'ici, puis passés à ceux qui en ont besoin
local looper = include("lib/looper")
local midi_in = include("lib/midi_in")
local splash = include("lib/splash")
local view = include("lib/view")
local ui = include("lib/ui")
local parameters = include("lib/params")
local timing = include("lib/timing")

-- familles : { name, algo1, algo2... } ; algos = toutes les familles à plat,
-- dans l'ordre (c'est la liste du paramètre effect). core.algo : l'effet en
-- cours. Lus par ui.lua et params.lua.
core.families = {}
core.algos = {}
core.family_of = {}
core.algo = nil
-- nombre de têtes selon l'engine (affiché en haut de l'écran)
core.engine_voices = 0
-- horloges de l'algorithme courant, arrêtées quand on change d'effet
local algo_loops = {}
local voice_ends = {}
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
  return parameters.SUBDIV_BEATS[params:get("time_div")]
end

-- pendant un pas de core.every : dans combien de secondes tombe l'instant
-- prévu (transmis à l'engine), et le temps (beats) qui lui correspond.
-- core.every se réveille timing.LEAD secondes avant (voir timing.lua).
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
      local lead_beats = timing.LEAD / clock.get_beat_sec()
      clock.sync(step, -lead_beats)
      local beats = clock.get_beats()
      tick_beat = util.round((beats + lead_beats) / step) * step
      -- en retard au-delà de l'avance, l'engine part dès que possible
      -- et compense la lecture
      tick_lead = util.clamp((tick_beat - beats) * clock.get_beat_sec(), -0.5, timing.LEAD + 0.01)
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

-- Hold : le buffer ne s'enregistre plus, on compte le temps passé figé
function core.set_hold(on)
  if on and not hold_beat then
    hold_beat = clock.get_beats()
  elseif not on and hold_beat then
    held_beats = held_beats + clock.get_beats() - hold_beat
    hold_beat = nil
  end
  engine.hold(on and 1 or 0)
end

---------------------------------------------------------------------------
-- têtes de lecture

-- mode lite (Pi 3, norns standard) : moins de têtes, réverbe légère dans
-- l'engine. Mesuré sur Pi 4 : le mode complet va jusqu'à 38 % ; un Pi 3
-- tient à peu près ce qu'un Pi 4 fait sous 25 %.
local FULL_VOICES, LITE_VOICES = 24, 10
core.voice_cap = FULL_VOICES

function core.set_lite(lite)
  core.voice_cap = lite and LITE_VOICES or FULL_VOICES
  engine.lite(lite and 1 or 0)
end

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
  if core.active_count() >= core.voice_cap then return end
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
    life = math.min(life, timing.HISTORY_SECONDS - ago - 0.5)
    if life <= 0 then return end
  end

  if v.filter then engine.vfilter(table.unpack(v.filter)) end
  if v.crush then engine.vcrush(table.unpack(v.crush)) end
  if v.glide then engine.vglide(table.unpack(v.glide)) end
  if v.len_mod then engine.vlen(table.unpack(v.len_mod)) end
  if v.ducks then engine.vduck() end
  engine.voice(ago, len, rate, rate_end, life, loop and 1 or 0,
    v.xfade or 0.05, v.gain or 0.5, v.pan or 0, v.shape or 0.5, v.delay or 0, tick_lead)
  local start = util.time() + (tick_lead > 0 and math.max(tick_lead, timing.SAFETY) or timing.NOW) + (v.delay or 0)
  table.insert(voice_ends, start + life)
  view.add_head({
    t0 = start, bb = core.buffer_beat(), ago = ago, len = len, life = life, loop = loop,
    rate = rate, rate_end = rate_end, gain = v.gain or 0.5, shape = v.shape or 0.5,
    glide = v.glide,
  })
end

---------------------------------------------------------------------------
-- attaques et effet en cours

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
function core.clamp_variation()
  local p = params:lookup_param("variation")
  local algo = core.algo
  if algo and p.value > #algo.variations then p:set(#algo.variations) end
end

-- variation en cours, bornée à celles de l'effet, modulation comprise
function core.variation()
  return math.min(params:get("variation"), core.algo and #core.algo.variations or 1)
end

function core.select_algo(i)
  for _, id in ipairs(algo_loops) do clock.cancel(id) end
  algo_loops = {}
  if core.algo and core.algo.stop then core.algo.stop(core) end
  core.algo = core.algos[i]
  core.clamp_variation()
  core.algo.start(core)
end

---------------------------------------------------------------------------
-- cycle de vie

-- fams : les familles du script, chacune { name = ..., algo1, algo2... }
function core.init(fams)
  core.families = fams
  for f, fam in ipairs(fams) do
    for _, a in ipairs(fam) do
      table.insert(core.algos, a)
      core.family_of[#core.algos] = f
    end
  end
  math.randomseed(os.time())

  -- le moteur rend déjà le signal sec : on coupe le monitor de norns
  -- pour ne pas l'entendre deux fois, et on le rend en partant
  saved_monitor = params:get("monitor_level")
  params:set("monitor_level", -math.huge)

  view.init(core)
  ui.init(core, looper, splash, view)
  parameters.add(core, looper, midi_in)
  -- charge le dernier preset s'il existe, puis envoie tout au moteur :
  -- matrix relit ce preset en silence juste après, les deux restent d'accord
  params:default()

  local p = poll.set("onset", function()
    ui.flash()
    core.onset_count = core.onset_count + 1
    onset_ring[(core.onset_count - 1) % ONSET_RING + 1] = core.buffer_beat()
    if core.algo and core.algo.onset then core.algo.onset(core) end
  end)
  p:start()
  looper.init(loops)
  midi_in.init(core, looper, core.algos)
  local pe = poll.set("input_env", function(x)
    -- en Hold, le buffer est figé : le fond aussi
    if not core.held() then
      view.push_env(x)
    end
  end)
  pe:start()
  local pv = poll.set("voices", function(n) core.engine_voices = n end)
  pv.time = 0.1
  pv:start()

  table.insert(loops, clock.run(function()
    while true do
      clock.sleep(splash.active and 1 / 30 or 1 / 15)
      ui.tick()
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

function core.enc(n, d) ui.enc(n, d) end

function core.key(n, z) ui.key(n, z) end

function core.redraw() ui.redraw() end

return core
