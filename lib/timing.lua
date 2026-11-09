-- macrocosm : les constantes de temps partagées avec l'engine
--
-- Les têtes et le looper partent en bundles horodatés. Lua se réveille
-- LEAD secondes avant chaque instant calé sur l'horloge et donne à l'engine
-- l'instant exact : les départs tombent pile dessus.
-- NOW et SAFETY doivent rester égaux à Engine_Macrocosm.latency et .safety :
--   NOW    : avance d'un événement « maintenant » (une attaque)
--   SAFETY : avance minimale d'un bundle pour arriver à l'heure
-- (inclus sans état : chaque module peut l'inclure)

return {
  LEAD = 0.05,
  NOW = 0.025,
  SAFETY = 0.015,
  -- durée du buffer d'historique (Engine_Macrocosm.historyFrames à 48 kHz) :
  -- au-delà, la matière lue serait réécrite pendant la lecture
  HISTORY_SECONDS = 1048576 / 48000,
}
