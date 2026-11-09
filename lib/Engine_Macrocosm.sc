// Engine_Macrocosm : le moteur de macrocosm.
//
// Le moteur ne contient aucun algorithme : il fournit les briques audio, et
// les algorithmes (Mosaic, Haze...) vivent en Lua, qui pilote les têtes de
// lecture au rythme de l'horloge norns.
// Les SynthDefs sont dans MacrocosmDefs.sc ; ce fichier crée les synths,
// les bus et les buffers, et répond aux commandes de Lua.
//
//   entrée ─┬─ (réverbe en mode before) ─┬─ writer ──► buffer d'historique ◄── têtes ──► wet
//           ├─ détection d'attaques      └────────────────────── dry ─┐
//           │   ──► poll "onset"                                       ├─ fx : pitch mod ─ filtre ─ space ─ mix ─ (space) ─► sortie
//                                                                wet ──┘
//
// La réverbe tourne dans son propre synth, avant le writer : elle reçoit
// l'effet ou le mix depuis fx (avec un bloc de retard, sans effet audible sur
// une réverbe) et lui rend sa sortie. Changer de position déplace donc ce
// qu'elle reçoit et où elle ressort, sans couper sa queue.
Engine_Macrocosm : CroneEngine {
	classvar <maxVoices = 24;
	// mode lite (Pi 3) : réverbe légère et moins de têtes
	classvar <liteVoices = 10;
	var lite = false, voiceCap = 24;
	// 2^20 images : ~21,8 s à 48 kHz. Au-delà, un index float32 perd sa
	// précision fractionnaire (1/16 d'échantillon ici).
	classvar <historyFrames = 1048576;
	// Les têtes partent en bundles horodatés : scsynth les démarre alors à
	// l'échantillon près, au lieu d'attendre la période JACK suivante.
	// latency = avance d'un événement « maintenant » (attaques : Strum, Arp,
	// Tunnel) ; safety = marge minimale pour qu'un bundle arrive avant son
	// heure. Mesuré sur le norns (2026-11-08) : aucun bundle en retard dès
	// 12 ms d'avance, même chargé ; à 10 ms, un sur trois. On garde le double.
	// Les têtes calées sur la grille ne dépendent pas de latency : Lua se
	// réveille 50 ms avant (LEAD dans core.lua) et donne l'instant exact.
	classvar <latency = 0.025, <safety = 0.015;

	// Les 4 modes de réverbe du Microcosm (A Bright Room, B Dark Medium,
	// C Large Hall, D Ambient), plus Shimmer et Cathedral (bonus).
	classvar reverbModes;

	var historyBuf, phaseBus, wetBus, envBus, onsetBus;
	var revSynth, revState, revBuf, fedBus, revSendBus, revRetBus;
	// Délai multi-taps (famille Multidelay) : un synth qui tourne en continu,
	// remplacé quand le mode change (l'ancien finit sa traîne puis se libère).
	// Deux buffers en alternance : la traîne de l'ancien synth garde le sien.
	var delayBufs, delayUsers, delayIdx = 0, delaySynth, delayState;
	var grpIn, grpVoices, grpFx;
	var writer, onsetSynth, fx;
	var nextFilter, nextCrush, nextGlide, nextLen, nextDuck;
	// Interrupt : les têtes qui coupent le sec y additionnent leur enveloppe.
	var duckBus;
	// Entrée et sortie internes : le looper s'insère avant l'effet (pre-FX,
	// sa lecture rejoint l'entrée) ou après (post-FX, il enregistre la sortie).
	var inBus, liveBus, mainBus, loopPreBus, inSynth;
	// Phrase Looper : phrase initiale + couche d'overdub (pour l'annuler)
	classvar <loopSeconds = 60;
	// enregistré après la fin de la phrase, pour le raccord (voir macrocosm_looper)
	classvar <tailSeconds = 0.5;
	var loopBufs, looper, loopState, loopPosPoll, loopLenPoll, loopFuncs;
	var holding = false;
	// Fin de vie prévue de chaque tête (Main.elapsedTime) : le compte ne
	// dépend pas des notifications du serveur, qui peuvent manquer.
	var voiceEnds;
	// Les horloges de sclang et de scsynth s'accordent-elles ? (voir watchdog)
	var timed = false, watchdog;
	var onsetPoll, onsetFunc;

	*initClass {
		reverbModes = [
			(t60: 0.8, damp: 0.05, size: 0.6, modDepth: 0.1),
			(t60: 2.2, damp: 0.65, size: 1.2, modDepth: 0.2),
			(t60: 4.5, damp: 0.3, size: 2.5, modDepth: 0.3),
			(t60: 14.0, damp: 0.35, size: 4.0, modDepth: 0.7),
			(t60: 10.0, damp: 0.4, size: 3.0, modDepth: 0.5, pre: 0.03, shim: 0.9, tilt: 0.7),
			(t60: 9.0, damp: 0.2, size: 4.25, modDepth: 0.6, pre: 0.06, diff: 0.78)
		];
	}

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	alloc {
		var s = context.server;
		var inL, inR, envPoll;

		voiceEnds = [];
		MacrocosmDefs.add;

		historyBuf = Buffer.alloc(s, historyFrames, 2);
		phaseBus = Bus.audio(s, 1);
		wetBus = Bus.audio(s, 2);
		envBus = Bus.control(s, 1);
		onsetBus = Bus.control(s, 1);
		duckBus = Bus.control(s, 1);
		// 2^18 images : 5,46 s, pour le tap le plus long (26/16 d'une unité
		// TIME de 2,5 s) et les têtes inversées
		delayBufs = 2.collect { Buffer.alloc(s, 262144, 2) };
		delayUsers = [nil, nil];
		delayState = (delays: 0.25 ! 8, gains: 0 ! 8, fb: 0, shape: 0.5, lastTap: 0);
		inBus = Bus.audio(s, 2);
		fedBus = Bus.audio(s, 2);
		revSendBus = Bus.audio(s, 2);
		revRetBus = Bus.audio(s, 2);
		// pré-délai et Bloom de la réverbe
		revBuf = Buffer.alloc(s, s.sampleRate * 2, 2);
		revState = (mode: 2, character: 0.5, space: 0.25, before: 0);
		liveBus = Bus.audio(s, 2);
		mainBus = Bus.audio(s, 2);
		loopPreBus = Bus.audio(s, 2);
		loopBufs = 2.collect { Buffer.alloc(s, s.sampleRate * (loopSeconds + tailSeconds + 0.1), 2) };
		loopState = (pos: 0, len: 0);
		s.sync;
		// ce que reçoivent le buffer et le sec : l'entrée, réverbérée en mode
		// before. Les attaques se détectent sur l'entrée propre.
		inL = fedBus.index;
		inR = fedBus.index + 1;

		grpIn = Group.new(context.xg, \addToHead);
		grpVoices = Group.after(grpIn);
		grpFx = Group.after(grpVoices);

		inSynth = Synth(\macrocosm_in, [\inL, context.in_b[0].index, \inR, context.in_b[1].index,
			\pre, loopPreBus, \live, liveBus, \out, inBus], grpIn);
		revSynth = Synth.after(inSynth, \macrocosm_rev, [\in, inBus, \send, revSendBus, \ret, revRetBus, \fed, fedBus, \buf, revBuf]);
		writer = Synth.after(revSynth, \macrocosm_writer, [\inL, inL, \inR, inR, \buf, historyBuf, \phaseBus, phaseBus, \duckBus, duckBus]);
		onsetSynth = Synth.after(writer, \macrocosm_onset, [\inL, inBus.index, \inR, inBus.index + 1, \phaseBus, phaseBus, \envBus, envBus, \onsetBus, onsetBus]);
		fx = Synth(\macrocosm_fx, [\out, mainBus, \inL, inL, \inR, inR, \clean, inBus, \wet, wetBus, \duckBus, duckBus, \revSend, revSendBus, \revRet, revRetBus], grpFx);
		looper = Synth.after(fx, \macrocosm_looper, [\in, mainBus, \live, liveBus,
			\out, context.out_b.index, \pre, loopPreBus, \a, loopBufs[0], \b, loopBufs[1]]);
		this.setReverb;

		onsetPoll = this.addPoll(\onset, periodic: false);
		this.addPoll(\voices, { this.activeVoices });
		onsetFunc = OSCFunc({ |msg| onsetPoll.update(msg[3]) }, '/macrocosm/onset');
		// looper : position (0..1, 15 fois par seconde) et longueur de la phrase (s)
		loopPosPoll = this.addPoll(\loop_pos, { loopState.pos });
		loopLenPoll = this.addPoll(\loop_len, periodic: false);
		envPoll = this.addPoll(\input_env, periodic: false);
		loopFuncs = [
			OSCFunc({ |msg| envPoll.update(msg[3]) }, '/macrocosm/env'),
			OSCFunc({ |msg| loopState.pos = msg[3] }, '/macrocosm/looppos'),
			OSCFunc({ |msg|
				loopState.len = msg[3];
				loopLenPoll.update(msg[3] / context.server.sampleRate);
			}, '/macrocosm/looplen')
		];

		this.addCommands;
		this.startWatchdog;
	}

	// Les bundles horodatés supposent que sclang et scsynth ont la même
	// heure. Juste après le démarrage du norns, l'heure système est recalée
	// par le réseau et les deux peuvent diverger de plusieurs heures : un
	// bundle part alors trop tôt ou reste en attente indéfiniment. Le
	// watchdog envoie un ping horodaté à +100 ms et regarde quand il revient.
	// En cas d'écart, il vide la file du serveur et passe en envoi immédiat
	// (planifié par sclang) jusqu'à ce que les horloges se retrouvent.
	startWatchdog {
		var s = context.server;
		watchdog = Routine {
			var sent, got, func, ok, good = 0, now;
			loop {
				// Heure avancée d'un coup : SystemClock rejoue tous les tours
				// manqués (22 000 pings pour 10 h). On les traverse sans rien
				// envoyer, et on repart de zéro.
				if((Main.elapsedTime - thisThread.seconds) > 1) {
					good = 0;
					if(timed) { timed = false; "macrocosm: horloge en saut, envoi immédiat".postln };
					1.6.wait;
				} {
					got = nil;
					func = OSCFunc({ got = Main.elapsedTime }, '/macrocosm/ping').oneShot;
					sent = Main.elapsedTime;
					s.makeBundle(0.1, { Synth(\macrocosm_ping, [], grpIn, \addToTail) });
					0.6.wait;
					if(got.isNil) {
						func.free;
						s.sendMsg("/clearSched");
					};
					// Après un saut, l'écart met plusieurs minutes à se résorber et
					// peut traverser zéro : un seul ping correct ne prouve rien.
					ok = got.notNil and: { ((got - sent) - 0.1).abs < 0.03 };
					good = if(ok) { good + 1 } { 0 };
					now = good >= 3;
					if(now != timed) {
						timed = now;
						("macrocosm: bundles horodatés " ++ if(now) { "actifs" } { "suspendus" }).postln;
					};
					if(timed) { 5.wait } { 1.wait };
				};
			}
		}.play(SystemClock);
	}

	activeVoices {
		var now = Main.elapsedTime;
		voiceEnds = voiceEnds.reject { |t| t < now };
		^voiceEnds.size
	}

	addCommands {
		// voice : ago (s), len (s), rate, rateEnd, life (s), loop (0/1),
		// xfade, gain, pan, shape, delay (s), lead (s).
		// lead = dans combien de temps tombe l'instant prévu (Lua se réveille
		// en avance sur la grille ; 0 = « maintenant »). ago = distance du
		// début du segment avant cet instant.
		this.addCommand(\voice, "fffffiffffff", { |msg|
			this.spawnVoice(*msg[1..]);
		});
		// Longueur de boucle modulée pour la prochaine tête (Tunnel) :
		// hz, profondeur (octaves), mode (0 = LFO, 1 = enveloppe du jeu).
		this.addCommand(\vlen, "ffi", { |msg|
			nextLen = [\lenHz, msg[1], \lenDepth, msg[2], \lenEnv, msg[3]];
		});
		// Va-et-vient de vitesse pour la prochaine tête (Glide).
		this.addCommand(\vglide, "ff", { |msg|
			nextGlide = [\glideHz, msg[1], \glideWidth, msg[2]];
		});
		// La prochaine tête coupe le sec tant qu'elle sonne (Interrupt).
		this.addCommand(\vduck, "", { nextDuck = [\duck, 1] });
		// Options de la prochaine tête : filtre (type 0 = LP, 1 = BP) et bitcrush.
		this.addCommand(\vfilter, "ifffff", { |msg|
			nextFilter = [\ftype, msg[1], \f0, msg[2], \f1, msg[3], \fq, msg[4], \lfoRate, msg[5], \lfoDepth, msg[6]];
		});
		this.addCommand(\vcrush, "ii", { |msg|
			nextCrush = [\bits, msg[1], \crushHold, msg[2].max(1)];
		});
		this.addCommand(\stop_voices, "", { grpVoices.freeAll; voiceEnds = [] });

		this.addCommand(\hold, "i", { |msg|
			holding = msg[1] > 0;
			delayState.hold = msg[1];
			if(delaySynth.notNil) { delaySynth.set(\hold, msg[1]) };
			writer.set(\hold, msg[1]);
			onsetSynth.set(\hold, msg[1]);
		});

		[\mix, \fxLevel, \filter, \res, \modDepth, \modRate, \drift, \lofi, \colorAll, \bypass].do { |key|
			this.addCommand(key, "f", { |msg| fx.set(key, msg[1]) });
		};
		this.addCommand(\space, "f", { |msg|
			revState.space = msg[1];
			fx.set(\space, msg[1]);
			revSynth.set(\space, msg[1]);
		});
		// 1 = lite (Pi 3) : réverbe légère, sans Bloom, et moins de têtes.
		// Changer de réverbe coupe sa queue.
		this.addCommand(\lite, "i", { |msg| this.setLite(msg[1] > 0) });
		this.addCommand(\reverb_mode, "i", { |msg| revState.mode = msg[1].clip(0, 5); this.setReverb });
		this.addCommand(\reverb_character, "f", { |msg| revState.character = msg[1].clip(0, 1); this.setReverb });
		// 0 sur l'effet, 1 après le mix, 2 avant l'effet
		this.addCommand(\reverb_position, "i", { |msg|
			fx.set(\revEffect, (msg[1] == 0).asInteger, \revAfter, (msg[1] == 1).asInteger);
			revState.before = (msg[1] == 2).asInteger;
			revSynth.set(\before, revState.before);
		});

		// Entrée : 1 = mono (canal gauche sur les deux côtés), 0 = stéréo.
		this.addCommand(\input_mono, "i", { |msg| inSynth.set(\mono, msg[1]) });

		// Phrase Looper (la logique Rec / Play / Dub est en Lua).
		// loop_rec : marche (1) / fin (0), lead (s) : dans combien de temps,
		// pour démarrer ou fermer pile sur un temps (0 = tout de suite) ;
		// then : à la fin, 0 lecture, 1 overdub, 2 arrêt. L'état suivant part
		// avec la fin : envoyé à part, il passerait avant elle en Quantize.
		this.addCommand(\loop_rec, "ifi", { |msg|
			if(msg[1] > 0) {
				// nouvelle phrase : l'ancien overdub n'a plus de sens
				loopBufs[1].zero;
				this.atLead(msg[2], { looper.set(\len, 0, \play, 0, \dub, 0, \rec, 1) });
			} {
				// fin de la phrase : la lecture repart du début
				this.atLead(msg[2], { looper.set(\rec, 0, \play, (msg[3] < 2).asInteger, \dub, (msg[3] == 1).asInteger) });
			};
		});
		// clic : accent (0/1), niveau, lead (s)
		this.addCommand(\click, "iff", { |msg|
			this.atLead(msg[3], { Synth(\macrocosm_click, [\out, context.out_b.index, \accent, msg[1], \amp, msg[2]], grpFx, \addToTail) });
		});
		this.addCommand(\loop_play, "i", { |msg| looper.set(\play, msg[1], \t_restart, msg[1]) });
		this.addCommand(\loop_dub, "i", { |msg| looper.set(\dub, msg[1]) });
		this.addCommand(\loop_undo, "", { loopBufs[1].zero });
		this.addCommand(\loop_erase, "", {
			looper.set(\rec, 0, \play, 0, \dub, 0, \len, 0);
			loopBufs.do(_.zero);
			loopState.len = 0;
		});
		// longueur imposée (s) : Quantize raccourcit la phrase à un nombre de temps
		this.addCommand(\loop_len, "f", { |msg|
			loopState.len = (msg[1] * context.server.sampleRate).round;
			looper.set(\len, loopState.len);
			loopLenPoll.update(msg[1]);
		});
		this.addCommand(\loop_rate, "f", { |msg| looper.set(\rate, msg[1]) });
		this.addCommand(\loop_level, "f", { |msg| looper.set(\level, msg[1]) });
		this.addCommand(\loop_fade, "ff", { |msg| looper.set(\fadeIn, msg[1].max(0.005), \fadeOut, msg[2].max(0.005)) });
		this.addCommand(\loop_seam, "f", { |msg| looper.set(\seam, msg[1]) });
		this.addCommand(\loop_route, "i", { |msg| looper.set(\route, msg[1]) });
		this.addCommand(\loop_only, "i", { |msg| fx.set(\wetOn, 1 - msg[1]) });
		// sauvegarde avec un preset : chemin sans extension ; deux fichiers
		this.addCommand(\loop_save, "s", { |msg| this.saveLoop(msg[1].asString) });
		this.addCommand(\loop_load, "sf", { |msg| this.loadLoop(msg[1].asString, msg[2]) });

		// Délai multi-taps. delay_on : mode (0..4), sens (0/1) ; remplace le
		// synth courant, qui finit sa traîne. delay_off : arrête l'entrée.
		this.addCommand(\delay_on, "ii", { |msg| this.startDelay(msg[1], msg[2]) });
		this.addCommand(\delay_off, "", { this.stopDelay });
		// Temps des 8 taps (s) et leurs gains (0 = tap inactif).
		this.addCommand(\delay_taps, "ffffffff", { |msg|
			delayState.delays = msg[1..8].clip(0.002, 5.0);
			if(delaySynth.notNil) { delaySynth.setn(\delays, delayState.delays) };
		});
		this.addCommand(\delay_gains, "ffffffff", { |msg|
			delayState.gains = msg[1..8];
			if(delaySynth.notNil) { delaySynth.setn(\gains, delayState.gains) };
		});
		// feedback, shape, index du dernier tap actif (0..7)
		this.addCommand(\delay_set, "ffi", { |msg|
			delayState.fb = msg[1];
			delayState.shape = msg[2];
			delayState.lastTap = msg[3].clip(0, 7);
			if(delaySynth.notNil) { delaySynth.set(\fb, msg[1], \shape, msg[2], \lastTap, delayState.lastTap) };
		});
		// Sensibilité de la détection d'attaques, 0..1 : seuil de -30 à -66 dB
		// et saut de niveau exigé de +12 à +4 dB. 0,5 = -48 dB et +8 dB.
		this.addCommand(\onset_sens, "f", { |msg|
			onsetSynth.set(\thresh, msg[1].linlin(0, 1, -30, -66).dbamp, \ratio, msg[1].linexp(0, 1, 4, 1.6));
		});
	}

	spawnVoice { |ago, len, rate, rateEnd, life, loop, xfade, gain, pan, shape, delay, lead|
		var sr = context.server.sampleRate;
		var name = MacrocosmDefs.voiceName(nextFilter.notNil, nextCrush.notNil, loop > 0);
		// Un événement « maintenant » (lead <= 0) part avec l'avance standard.
		// Un événement prévu part à son instant, tant qu'il reste la marge
		// minimale pour que le bundle arrive à temps. Si la tête part après
		// l'instant prévu, le buffer a avancé d'autant entre-temps, sauf s'il
		// est figé par Hold.
		var startIn = if(lead > 0) { max(lead, safety) } { latency } + delay;
		var offset = if(holding) { 0 } { startIn - lead };
		var args, start;
		args = [
			\out, wetBus, \buf, historyBuf, \phaseBus, phaseBus, \envBus, envBus, \duckBus, duckBus,
			\ago, ((ago + offset) * sr).round, \segLen, (len * sr).max(16), \rate, rate, \rateEnd, rateEnd,
			\life, life, \xfade, xfade, \gain, gain, \pan, pan, \shape, shape
		] ++ (nextFilter ? []) ++ (nextCrush ? []) ++ (nextGlide ? []) ++ (nextLen ? []) ++ (nextDuck ? []);
		nextLen = nil;
		nextDuck = nil;
		nextFilter = nil;
		nextCrush = nil;
		nextGlide = nil;

		if(this.activeVoices < voiceCap) {
			// add renvoie un nouveau tableau quand il est plein : sans la
			// réaffectation, le compte plafonnait à 8
			voiceEnds = voiceEnds.add(Main.elapsedTime + startIn + life + 0.05);
			start = { Synth(name, args, grpVoices, \addToTail) };
			// Horloges accordées : à l'échantillon près. Sinon, planifié par
			// sclang (à ±1,3 ms) en attendant qu'elles se retrouvent.
			if(timed) {
				context.server.makeBundle(startIn, start);
			} {
				SystemClock.sched(startIn, { start.value; nil });
			};
		};
	}

	startDelay { |mode, reverse|
		var name = ("macrocosm_delay_" ++ mode.clip(0, 4) ++ (if(reverse > 0) { "_r" } { "" })).asSymbol;
		var i, syn;
		this.stopDelay;
		// prendre l'autre buffer ; une traîne plus ancienne qui l'occupe encore est coupée
		delayIdx = 1 - delayIdx;
		i = delayIdx;
		if(delayUsers[i].notNil) { delayUsers[i].free; delayUsers[i] = nil };
		delayBufs[i].zero;
		syn = Synth(name, [
			\out, wetBus, \inL, fedBus.index, \inR, fedBus.index + 1,
			\buf, delayBufs[i], \envBus, envBus, \onsetBus, onsetBus,
			\fb, delayState.fb, \shape, delayState.shape, \hold, delayState.hold ? 0,
			\lastTap, delayState.lastTap,
			\delays, delayState.delays, \gains, delayState.gains
		], grpVoices, \addToHead);
		delayUsers[i] = syn;
		syn.onFree { if(delayUsers[i] === syn) { delayUsers[i] = nil } };
		delaySynth = syn;
	}

	// Exécute les messages serveur de func à l'instant prévu (lead > 0, avec
	// la marge minimale) ou tout de suite (lead <= 0).
	atLead { |lead, func|
		if(lead <= 0) { ^func.value };
		if(timed) {
			context.server.makeBundle(max(lead, safety), func);
		} {
			SystemClock.sched(max(lead, safety), { func.value; nil });
		};
	}

	saveLoop { |path|
		// la suite enregistrée après la phrase est gardée pour le raccord
		var n = loopState.len.asInteger;
		var tail = (tailSeconds * context.server.sampleRate).asInteger;
		if(n > 0) {
			n = n + tail;
			loopBufs[0].write(path ++ "-a.wav", "wav", "float", n);
			loopBufs[1].write(path ++ "-b.wav", "wav", "float", n);
		} {
			[path ++ "-a.wav", path ++ "-b.wav"].do { |f| if(File.exists(f)) { File.delete(f) } };
		};
	}

	// recharge une phrase sauvegardée (seconds = sa longueur) ; sans fichier, vide le looper
	loadLoop { |path, seconds|
		var s = context.server;
		looper.set(\rec, 0, \play, 0, \dub, 0);
		loopBufs.do(_.zero);
		loopState.len = 0;
		if(File.exists(path ++ "-a.wav") and: { seconds > 0 }) {
			loopBufs.do { |buf, i| s.sendMsg("/b_read", buf.bufnum, path ++ ["-a.wav", "-b.wav"][i], 0, -1, 0, 0) };
			loopState.len = (seconds * s.sampleRate).round;
			looper.set(\len, loopState.len);
		};
	}

	// L'entrée est coupée et la traîne s'éteint (feedback ramené à 0,5 au
	// plus, Hold relâché), puis le synth se libère.
	stopDelay {
		if(delaySynth.notNil) {
			delaySynth.set(\run, 0, \hold, 0, \fb, delayState.fb.min(0.5));
			delaySynth = nil;
		};
	}

	setLite { |on|
		if(on != lite) {
			lite = on;
			revSynth = Synth.replace(revSynth, if(lite) { \macrocosm_rev_lite } { \macrocosm_rev }, [
				\in, inBus, \send, revSendBus, \ret, revRetBus, \fed, fedBus, \buf, revBuf,
				\space, revState.space, \before, revState.before
			]);
			this.setReverb;
		};
		voiceCap = if(lite) { liteVoices } { maxVoices };
	}

	// Character : un seul réglage, un rôle par mode ; 0,5 = le son standard.
	setReverb {
		var i = revState.mode, c = revState.character, k = (2 * c) - 1;
		var m = reverbModes[i];
		var t60 = m.t60, damp = m.damp, revMod = m.modDepth, revFreq = 2;
		var diff = m.diff ? 0.707, pre = m.pre ? 0, bloom = 0;
		var tilt = m.tilt ? 1, shim = m.shim ? 0, shimCut = 3500;
		// k de -1 à 1 : valeur à gauche, au centre, à droite
		var bend = { |lo, mid, hi| if(k < 0) { mid + ((lo - mid) * k.neg) } { mid + ((hi - mid) * k) } };
		switch(i,
			0, { damp = bend.(0.75, damp, 0); tilt = 2 ** (1.8 * k) },     // Air
			1, { damp = bend.(0.9, damp, 0.25); tilt = 2 ** k },           // Warmth
			2, { t60 = 2 * (5 ** c) },                                     // Decay : 2 à 10 s
			3, { revMod = bend.(0.05, revMod, 1); revFreq = bend.(1, 2, 5) }, // Movement
			4, { shim = shim * (1 + (0.5 * k)); damp = bend.(0.5, damp, 0.3);  // Sparkle
				shimCut = 3500 * (2 ** (0.3 * k)) },
			5, { pre = bend.(0.005, pre, 0.095);                           // Bloom
				diff = bend.(diff, diff, 0.86); bloom = 1.5 * k.max(0) }
		);
		revSynth.set(\t60, t60, \damp, damp, \size, m.size, \revMod, revMod, \revFreq, revFreq,
			\diff, diff, \pre, pre, \bloom, bloom, \tilt, tilt, \shim, shim, \shimCut, shimCut);
	}

	free {
		watchdog.stop;
		onsetFunc.free;
		grpVoices.free;
		[inSynth, revSynth, writer, onsetSynth, fx, looper, grpIn, grpFx].do(_.free);
		loopFuncs.do(_.free);
		[historyBuf, phaseBus, wetBus, envBus, onsetBus, duckBus, inBus, fedBus, revSendBus, revRetBus, revBuf, liveBus, mainBus, loopPreBus].do(_.free);
		loopBufs.do(_.free);
		delayBufs.do(_.free);
	}
}
