-- macrocosm : les paramètres
--
-- les réglages du menu PARAMETERS et leurs actions vers l'engine. Ceux du
-- looper et du MIDI sont dans looper.lua et midi_in.lua.

local parameters = {}

-- TIME : durée de l'unité en valeurs de notes (en temps, 1 = noire), de
-- la plus longue à la plus courte comme le Microcosm (x1/4 … x8), avec en
-- plus les triolets (T) et la noire pointée (D) de Tessera. En mode free,
-- l'unité est une durée fixe (time free), indépendante du tempo.
local SUBDIV_NAMES = { "1 bar", "1/2", "1/4D", "1/4", "1/4T", "1/8", "1/8T", "1/16", "1/16T", "1/32" }
parameters.SUBDIV_BEATS = { 4, 2, 3 / 2, 1, 2 / 3, 1 / 2, 1 / 3, 1 / 4, 1 / 6, 1 / 8 }

-- A à D comme le Microcosm ; certains effets en ont davantage (bonus)
local VARIATION_LETTERS = { "A", "B", "C", "D", "E", "F", "G", "H" }
local REVERB_NAMES = { "bright room", "dark medium", "large hall", "ambient", "shimmer", "cathedral" }

local function pct(param)
  return util.round(param:get() * 100) .. "%"
end

-- génération du Raspberry Pi (3, 4...), lue dans le modèle de la carte :
-- « Raspberry Pi 4 Model B », « Raspberry Pi 3 Model B Plus »,
-- « Raspberry Pi Compute Module 3 Plus » (norns standard). nil si inconnue.
local function pi_generation()
  local f = io.open("/proc/device-tree/model", "r")
  if not f then return nil end
  local model = f:read("*a") or ""
  f:close()
  return tonumber(model:match("Pi (%d)") or model:match("Compute Module (%d)"))
end

function parameters.add(core, looper, midi_in)
  params:add_separator("macrocosm_sep", "macrocosm")

  -- comme le Microcosm : mono par défaut (une guitare n'arrive que sur le
  -- canal gauche de norns, il est alors envoyé des deux côtés)
  params:add_option("input", "input", { "mono (left)", "stereo" }, 1)
  params:set_action("input", function(i) engine.input_mono(i == 1 and 1 or 0) end)

  -- auto : lite sur un Pi 3 ou plus ancien (et un norns standard)
  local gen = pi_generation()
  local auto_lite = gen ~= nil and gen < 4
  local auto_name = "auto (" .. (gen and ("pi " .. gen .. ": ") or "") .. (auto_lite and "lite" or "full") .. ")"
  params:add_option("cpu_mode", "cpu mode", { auto_name, "full", "lite" }, 1)
  params:set_action("cpu_mode", function(i) core.set_lite(i == 3 or (i == 1 and auto_lite)) end)

  local names = {}
  for i, a in ipairs(core.algos) do names[i] = string.lower(a.name) end
  params:add_option("effect", "effect", names, 1)
  params:set_action("effect", core.select_algo)
  -- nombres et interrupteurs plutôt que listes : matrix ne module pas les listes
  params:add_number("variation", "variation", 1, #VARIATION_LETTERS, 1,
    function() return VARIATION_LETTERS[core.variation()] end)
  params:set_action("variation", core.clamp_variation)
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
  params:set_action("hold", function() core.set_hold(params:get("hold") == 1) end)
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

return parameters
