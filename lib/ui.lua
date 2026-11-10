-- macrocosm : l'interface
--
-- E1 page, E2 / E3 les deux réglages de la page ; K2 Hold, K3 Reverse ;
-- quand le looper est actif, K2 et K3 le pilotent (voir looper.lua).
-- K1 maintenu : E1 famille, E2 effet (dans la famille), E3 variation,
-- K2 entre dans le looper / en sort, K3 Reverse de l'effet.
-- La page 0, à gauche de la page de départ, est l'Engine View (view.lua).

local ui = {}

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

-- un seul réglage, un rôle par mode de réverbe
local CHARACTER_NAMES = { "air", "warmth", "decay", "movement", "sparkle", "bloom" }

local core, looper, splash, view
local page = 1
local shift = false
local onset_flash = 0

function ui.init(c, l, s, v)
  core, looper, splash, view = c, l, s, v
end

-- une attaque : le point à côté du nom de l'effet s'allume
function ui.flash() onset_flash = 6 end

-- appelé à chaque image : le point s'éteint peu à peu
function ui.tick()
  if onset_flash > 0 then onset_flash = onset_flash - 1 end
end

-- en mode free, la page de TIME règle la durée libre
local function page_param(id)
  if id == "time_div" and params:get("time_mode") == 2 then return "time_free" end
  return id
end

-- premier et dernier index (dans core.algos) des effets de la famille f
local function family_range(f)
  local first, last
  for i = 1, #core.algos do
    if core.family_of[i] == f then
      first = first or i
      last = i
    end
  end
  return first, last
end

function ui.enc(n, d)
  if splash.active then return splash.stop() end
  local i = params:get("effect")
  local family_of = core.family_of
  if shift and n == 1 then
    local f = util.clamp(family_of[i] + d, 1, #core.families)
    if f ~= family_of[i] then params:set("effect", (family_range(f))) end
  elseif shift and n == 2 then
    local first, last = family_range(family_of[i])
    params:set("effect", util.clamp(i + d, first, last))
  elseif shift and n == 3 then
    params:delta("variation", d)
  elseif n == 1 then
    page = util.clamp(page + d, 0, #PAGES)
  else
    -- la vue n'a pas de réglages à elle : E2 et E3 restent sur Activity et Repeats
    params:delta(page_param(PAGES[math.max(page, 1)][n - 1]), d)
  end
end

function ui.key(n, z)
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
  -- le tempo peut arriver non arrondi (modulation, autre script) : on
  -- l'affiche entier
  screen.text(id == "clock_tempo" and string.format("%d", util.round(params:get(id))) or params:string(id))
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

function ui.redraw()
  if splash.active then return splash.redraw() end
  local algo = core.algo
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
  screen.text_right(string.format("%d", core.engine_voices))
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
  if page == 0 then view.draw() end
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
      local f = core.family_of[params:get("effect")]
      screen.level(10)
      screen.text(core.families[f].name .. "  " .. f .. "/" .. #core.families)
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

return ui
