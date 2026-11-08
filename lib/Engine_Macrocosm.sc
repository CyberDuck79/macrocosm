// Engine_Macrocosm : moteur commun des scripts macrocosm.
//
// Le moteur ne contient aucun algorithme : il fournit les briques audio, et
// les algorithmes (Mosaic, Haze...) vivent en Lua, qui pilote les têtes de
// lecture au rythme de l'horloge norns.
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
		this.addDefs;

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
		revState = (mode: 2, character: 0.5);
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

	addDefs {
		// Enregistre l'entrée en continu. Hold fige la phase et réécrit le
		// contenu existant, si bien que tout le buffer reste intact.
		SynthDef(\macrocosm_writer, { |inL, inR, buf, phaseBus, duckBus, hold = 0|
			var in = [In.ar(inL), In.ar(inR)];
			var phase = Phasor.ar(0, 1 - hold, 0, BufFrames.kr(buf));
			var keep = BufRd.ar(2, buf, phase, 1, 1);
			BufWr.ar(Select.ar(hold, [in, keep]), buf, phase);
			Out.ar(phaseBus, phase);
			// les bus de contrôle ne se vident pas seuls : remise à zéro à
			// chaque cycle, avant que les têtes n'y écrivent
			ReplaceOut.kr(duckBus, 0);
		}).add;

		// Une attaque = le niveau dépasse `ratio` fois celui d'il y a 30 ms,
		// au-dessus du seuil `thresh`, avec 80 ms d'anti-rebond (réglés par
		// la sensibilité, voir onset_sens). Envoie la position de l'attaque
		// dans le buffer, 4 ms avant. Publie aussi une enveloppe lente du jeu
		// (0..1) pour les têtes qui y réagissent.
		SynthDef(\macrocosm_onset, { |inL, inR, phaseBus, envBus, onsetBus, hold = 0, thresh = 0.004, ratio = 2.5|
			var x = (In.ar(inL) + In.ar(inR)) * 0.5;
			var env = Amplitude.ar(x, 0.001, 0.02);
			var earlier = DelayN.ar(env, 0.05, 0.03);
			var cond = (env > thresh) * (env > ((ratio * earlier) + 0.0003)) * (1 - hold);
			var trig = Trig1.ar(cond, 0.08), lvl;
			SendReply.ar(trig, '/macrocosm/onset', In.ar(phaseBus) - (0.004 * SampleRate.ir));
			lvl = Amplitude.kr(x, 0.01, 0.3).ampdb.linlin(-50, -10, 0, 1);
			Out.kr(envBus, lvl);
			// fond de l'Engine View : une colonne de l'écran tous les 1/32 s
			SendReply.kr(Impulse.kr(32), '/macrocosm/env', lvl);
			Out.kr(onsetBus, A2K.kr(trig));
		}).add;

		// Délais : un SynthDef par mode et par sens, pour ne payer que le
		// traitement utilisé. Modes : 0 aucun, 1 filtre suivant l'enveloppe,
		// 2 passe-bande résonant, 3 taps transposés, 4 taps en fondu avec des
		// grains à l'octave.
		5.do { |mode| [false, true].do { |rev| this.addDelayDef(mode, rev) } };

		// Entrée du moteur : l'entrée audio (en mono, le canal gauche sur les
		// deux côtés, comme une guitare branchée seule), publiée telle quelle
		// pour le looper, puis avec la lecture du looper en pre-FX (lue avec
		// un bloc de retard, elle vient de la fin de la chaîne).
		SynthDef(\macrocosm_in, { |inL, inR, pre, live, out, mono = 1|
			var l = In.ar(inL);
			var sig = [l, Select.ar(mono, [In.ar(inR), l])];
			Out.ar(live, sig);
			Out.ar(out, sig + InFeedback.ar(pre, 2));
		}).add;

		// Phrase Looper. Enregistre la phrase initiale dans a, l'overdub dans b
		// (qu'on peut vider pour l'annuler), et rejoue a + b.
		//   post-FX (pre = 0) : enregistre la sortie du moteur et s'y ajoute ;
		//   pre-FX (pre = 1) : enregistre l'entrée, et sa lecture repart dans
		//   l'effet comme si on jouait.
		// rec : enregistrement de la phrase initiale ; à sa fin, la longueur
		// est fixée et la lecture repart du début. len (images), si > 0,
		// impose la longueur (Quantize, phrase rechargée).
		// Raccord : l'enregistrement continue `tail` s après la fin de la
		// phrase. Au début de chaque passage, cette suite (la traîne des
		// effets, la note qui sonnait encore) est rejouée par-dessus le
		// début et s'éteint en `seam` s, pendant que le début entre en 5 ms :
		// la boucle ne coupe plus net ce qui sonnait à sa fin.
		SynthDef(\macrocosm_looper, { |in, live, out, pre, a, b, route = 0, rec = 0, play = 0, dub = 0,
			len = 0, rate = 1, level = 1, fadeIn = 0.1, fadeOut = 0.1, t_restart = 0, seam = 0.08|
			var frames = BufFrames.kr(a);
			var main = In.ar(in, 2);
			var src = Select.ar(route, [main, In.ar(live, 2)]);
			var stopRec = HPZ1.kr(rec) < 0;
			var tailing = Trig1.kr(stopRec, tailSeconds);
			var recPhase = Phasor.ar(HPZ1.kr(rec) > 0, (rec + tailing).min(1), 0, frames);
			var recorded = Latch.kr(A2K.kr(recPhase), stopRec);
			var loopLen = Select.kr(len > 0, [recorded, len]).max(64);
			var ph = Phasor.ar(t_restart + stopRec, rate * play, 0, loopLen);
			var seamIn = (ph / (0.005 * SampleRate.ir)).clip(0, 1);
			var seamOut = 1 - (ph / (seam.clip(0.005, tailSeconds) * SampleRate.ir)).clip(0, 1);
			var dubAmt = Slew.kr(dub, 100, 100);
			var sig, gain, dubbed;
			// hors enregistrement, les écritures vont sur la dernière image,
			// jamais lue : réécrire en lisant à une vitesse non entière
			// adoucirait la phrase à chaque passage
			BufWr.ar(src, a, Select.ar((rec + tailing).min(1), [K2A.ar(frames - 1), recPhase]));
			dubbed = BufRd.ar(2, b, ph, 1, 2);
			// l'overdub entre et sort en 10 ms
			BufWr.ar(dubbed + (src * play * dubAmt), b, Select.ar(dubAmt > 0.0001, [K2A.ar(frames - 1), ph]));
			sig = (BufRd.ar(2, a, ph, 1, 2) * (seamIn * 0.5pi).sin)
				+ (BufRd.ar(2, a, ph + loopLen, 0, 2) * (seamOut * 0.5pi).sin)
				+ dubbed;
			gain = EnvGen.kr(Env.asr(fadeIn, 1, fadeOut, \sin), play) * level.lag(0.05);
			sig = sig * gain;
			SendReply.kr(stopRec, '/macrocosm/looplen', recorded);
			SendReply.kr(Impulse.kr(15), '/macrocosm/looppos', A2K.kr(ph) / loopLen);
			Out.ar(out, main + (sig * (1 - route)));
			Out.ar(pre, sig * route);
		}).add;

		// Clic de métronome, plus aigu sur le premier temps. Il sort après le
		// looper : il n'est jamais enregistré dans la boucle.
		SynthDef(\macrocosm_click, { |out, accent = 0, amp = 0.25|
			var env = EnvGen.ar(Env.perc(0.001, 0.04), doneAction: 2);
			OffsetOut.ar(out, (SinOsc.ar(Select.kr(accent, [1000, 1600])) * env * amp) ! 2);
		}).add;

		SynthDef(\macrocosm_ping, {
			SendReply.kr(Impulse.kr(0), '/macrocosm/ping');
			Line.kr(0, 1, 0.01, doneAction: 2);
		}).add;

		// Têtes de lecture : une variante par combinaison d'options, pour ne
		// payer le filtre, le bitcrush et la lecture de bouclage que quand on
		// s'en sert.
		[false, true].do { |f| [false, true].do { |c| [false, true].do { |l|
			this.addVoiceDef(this.class.voiceName(f, c, l), f, c, l);
		} } };

		// Réverbe : JPverb, précédée d'un pré-délai et de Bloom (12 départs de
		// plus en plus forts étalés dans le temps, chaque note monte dans
		// l'espace). Shimmer : une copie de la queue limitée en fréquence,
		// montée d'une octave, repart dans la réverbe ; le passe-bas fait
		// qu'elle ne grimpe que d'une ou deux octaves. Tilt : pente autour de
		// 2 kHz (Air, Warmth).
		SynthDef(\macrocosm_rev, { |in, send, ret, fed, buf, space = 0.25, before = 0,
			t60 = 4.5, damp = 0.3, size = 2.5, revMod = 0.3, revFreq = 2, diff = 0.707,
			pre = 0, bloom = 0, tilt = 1, shim = 0, shimCut = 3500|
			var x = In.ar(in, 2);
			var sp = space.lag(0.05), b = before.lag(0.05);
			var src = InFeedback.ar(send, 2) + (x * b);
			var frames = BufFrames.ir(buf), sr = SampleRate.ir;
			var phase = Phasor.ar(0, 1, 0, frames);
			var preNow = pre.lag(0.5), bloomNow = bloom.lag(0.5);
			var tap = { |d| BufRd.ar(2, buf, (phase - (d * sr) - 1).wrap(0, frames), 1, 2) };
			var gains = [0.04, 0.07, 0.10, 0.13, 0.16, 0.19, 0.22, 0.25, 0.28, 0.31, 0.34, 0.37];
			var feed, fb, rev, shimSig, lp, shimNow = shim.lag(0.5);
			BufWr.ar(src, buf, phase);
			feed = XFade2.ar(tap.(preNow),
				Mix.fill(12, { |j| tap.(preNow + (bloomNow * j / 11)) * gains[j] }),
				((bloomNow * 8).clip(0, 1) * 2) - 1);
			fb = LocalIn.ar(2);
			rev = JPverb.ar(feed + fb, t60.lag(0.5), damp.lag(0.5), size, diff.lag(0.5), revMod.lag(0.5), revFreq.lag(0.5));
			shimSig = HPF.ar(LPF.ar(rev.sum * 0.5, shimCut.lag(0.5)), 250);
			shimSig = PitchShift.ar(shimSig, 0.1, 2, 0, 0.01) * shimNow;
			LocalOut.ar([shimSig, shimSig.neg].tanh);
			rev = rev * (0.55 / (0.45 + (0.55 * shimNow)));
			lp = OnePole.ar(rev, exp(-2pi * 2000 / sr));
			rev = lp + (tilt.lag(0.5) * (rev - lp));
			Out.ar(ret, rev);
			Out.ar(fed, (x * (1 + (b * (((1 - sp).max(0) ** 0.5) - 1)))) + (rev * (sp ** 0.5) * b));
		}).add;

		SynthDef(\macrocosm_fx, { |out, inL, inR, wet, mix = 0.5, fxLevel = 1,
			filter = 0, res = 0.2, space = 0.25, revSend, revRet, revEffect = 1, revAfter = 0,
			modDepth = 0, modRate = 1, duckBus, wetOn = 1, drift = 0, lofi = 0, colorAll = 0,
			clean, bypass = 0|
			var dry = [In.ar(inL), In.ar(inR)];
			var w = In.ar(wet, 2);
			var md, lfo, all, dr, lo, wobble, f, lp, hp, freq, rq, rev, sp, keep, pe, pa, send, m, duck, sig;

			// Lo-Fi : convertisseur à basse fréquence (32 kHz → 2,5 kHz) et peu
			// de bits (12 → 7), saturation douce ; les filtres autour suivent la
			// fréquence, comme sur les vieux samplers : plus sombre, pas
			// seulement plus grésillant. Entre en fondu sur les premiers %.
			var lofiFn = { |x, amt|
				var srate = 32000 * ((2500 / 32000) ** amt);
				var levels = 2 ** (11 - (5 * amt));
				var drive = 1 + (2 * amt);
				var fc = (0.42 * srate).min(0.45 * SampleRate.ir);
				var y = Latch.ar(LPF.ar(LPF.ar(x, fc), fc), Impulse.ar(srate));
				y = ((y * drive).tanh / drive * levels).round / levels;
				XFade2.ar(x, LPF.ar(LPF.ar(y, fc), fc) * (1 + (0.15 * amt)), ((amt * 12).min(1) * 2) - 1)
			};

			// Drift et Lo-Fi : sur l'effet seulement (colorAll = 0, comme
			// Tessera) ou sur toute la sortie (1), après le mix et la réverbe.
			all = colorAll.lag(0.05);
			dr = drift.lag(0.05);
			lo = lofi.lag(0.3);

			// Pitch modulation (délai court modulé, du chorus au vibrato
			// désaccordé) et Drift (wow, flutter et dérive lente de bande, un
			// peu différents à gauche et à droite), dans le même délai. Le
			// délai de base (7,5 ms) est constant : tourner les réglages ne
			// décale pas l'effet dans le temps.
			md = modDepth.lag(0.1) * 0.006;
			lfo = SinOsc.kr(modRate.lag(0.1), [0, 0.5pi]);
			wobble = (SinOsc.kr([0.55, 0.61], [0, 1.7]) * 0.0035)
				+ (SinOsc.kr(5.3) * 0.00022)
				+ (LFNoise2.kr([1.4, 1.4]) * 0.0025);
			w = DelayC.ar(w, 0.02, 0.0075 + (md * (lfo + 1) * 0.5) + (dr * (1 - all) * wobble));
			w = lofiFn.(w, lo * (1 - all));

			// Filtre résonant bipolaire en fin de chaîne d'effet (-1..1) :
			// au centre ouvert ; à gauche passe-bas, tout à gauche l'effet est
			// coupé ; à droite passe-haut de 20 Hz à 6 kHz. Zone neutre de ±4 %.
			f = filter.lag(0.05);
			rq = 1 / (0.6 + (7.4 * res.squared));
			lp = ((f + 1) / 0.96).clip(0, 1);
			hp = ((f - 0.04) / 0.96).clip(0, 1);
			freq = (20 * (1000 ** lp)).clip(20, 20000);
			w = XFade2.ar(RLPF.ar(w, freq, rq), w, lp.linlin(0.95, 1, -1, 1));
			w = XFade2.ar(w, RHPF.ar(w, 20 * (300 ** hp), rq), (f * 25).clip(0, 1) * 2 - 1);

			// Space : à fond, ce qui passe par la réverbe est 100 % réverbéré.
			// Position effect only : ici, sur l'effet. Pas de .sqrt : sur ARM
			// il donne NaN à 0.
			rev = In.ar(revRet, 2);
			sp = space.lag(0.05);
			keep = (1 - sp).max(0) ** 0.5;
			sp = sp ** 0.5;
			pe = revEffect.lag(0.05);
			pa = revAfter.lag(0.05);
			send = w * pe;
			w = (w * (1 + (pe * (keep - 1)))) + (rev * sp * pe);

			// Mix : au centre, sec et effet sont tous les deux à fond.
			m = mix.lag(0.05);
			// Interrupt coupe le sec pendant ses rafales, de plus en plus avec
			// Mix : jamais à 0 %, complètement à 100 % (manuel Microcosm).
			// La coupure est retardée comme l'effet (7,5 ms) pour rester calée.
			duck = LagUD.kr(DelayN.kr((In.kr(duckBus) * 1.5).min(1), 0.02, 0.0075), 0.002, 0.02) * m;
			sig = (dry * (2 * (1 - m)).min(1) * (1 - duck)) + (w * (2 * m).min(1) * fxLevel.lag(0.05) * wetOn.lag(0.05));

			// Position after : sur le sec et l'effet ensemble.
			send = send + (sig * pa);
			Out.ar(revSend, send);
			sig = (sig * (1 + (pa * (keep - 1)))) + (rev * sp * pa);

			// Drift et Lo-Fi sur toute la sortie : le sec prend alors 7,5 ms de
			// retard (le délai de Drift). Sur l'effet seulement, le sec passe
			// sans délai.
			sig = XFade2.ar(sig, lofiFn.(DelayC.ar(sig, 0.02, 0.0075 + (dr * all * wobble)), lo * all), (all * 2) - 1);

			// Bypass sans traînes : seule l'entrée propre passe, en fondu court.
			Out.ar(out, LinXFade2.ar(sig, In.ar(clean, 2), (bypass.lag(0.05) * 2) - 1));
		}).add;
	}

	// Multi-taps lisant un buffer circulaire. ACTIVITY (nombre de taps) et
	// SHAPE (pente des niveaux) arrivent de Lua sous forme de gains ;
	// REPEATS = feedback, pris sur le dernier tap actif, filtré et saturé.
	// SHAPE règle aussi comment chaque note entre dans le délai : à gauche
	// seule l'attaque entre, à droite chaque note monte lentement.
	addDelayDef { |mode, reverse|
		var name = ("macrocosm_delay_" ++ mode ++ (if(reverse) { "_r" } { "" })).asSymbol;
		SynthDef(name, { |out, inL, inR, buf, envBus, onsetBus, run = 1, fb = 0, shape = 0.5, hold = 0, lastTap = 0|
			var delays = \delays.kr(0.25 ! 8, 0.1);
			var gains = \gains.kr(0 ! 8, 0.05);
			var sr = SampleRate.ir, frames = BufFrames.kr(buf);
			var wp = Phasor.ar(0, 1, 0, frames);
			var dry = [In.ar(inL), In.ar(inR)];
			var t = Sweep.kr(In.kr(onsetBus), 1);
			var amount = ((0.5 - shape) * 2).clip(0, 1);
			var pluck = (1 - amount) + (amount * (t.neg / amount.linlin(0, 1, 2, 0.06)).exp);
			var swell = ((t / ((shape - 0.5) * 2).clip(0, 1).linlin(0, 1, 0.005, 0.8)).clip(0, 1) * 0.5pi).sin.squared;
			var contour = Select.kr(shape < 0.5, [swell, pluck]).lag(0.01);
			var env = Amplitude.kr(dry.sum * 0.5, 0.002, 0.1);
			var win = 0.2 * sr;
			var taps, fbL, fbR, sum, feedback;

			taps = 8.collect { |i|
				var d = (delays[i] * sr).max(64);
				if(reverse) {
					// deux têtes qui lisent à l'envers, en fondu croisé
					[0, 0.5].collect { |off|
						var ph = (Phasor.ar(0, 1, 0, win) + (off * win)).wrap(0, win);
						BufRd.ar(2, buf, (wp - d - (2 * ph)).wrap(0, frames), 1, 4) * (ph / win * pi).sin
					}.sum
				} {
					BufRd.ar(2, buf, (wp - d).wrap(0, frames), 1, 4)
				}
			};

			// le feedback part du dernier tap actif, avant le traitement des taps
			fbL = Select.ar(lastTap, taps.collect { |tp| tp[0] });
			fbR = Select.ar(lastTap, taps.collect { |tp| tp[1] });
			feedback = HPF.ar(LPF.ar([fbL, fbR], 9000), 60);
			feedback = (feedback * Select.kr(hold, [fb.lag(0.1), 1])).tanh;
			BufWr.ar((dry * contour * (1 - hold) * run.lag(0.05)) + feedback, buf, wp);

			sum = taps.collect { |tp, i|
				var mono = tp.sum * 0.5;
				var side = if(i.even) { -1 } { 1 };
				var pan = side * (0.25 + (0.6 * i / 7));
				var x;
				switch(mode,
					1, {
						var fc = 180 + (9000 * (env * 4 * (0.6 + (0.25 * i))).min(1));
						tp = RLPF.ar(tp, fc.lag(0.02), 0.4);
					},
					2, { tp = BPF.ar(tp, 250 * (1.45 ** i), 1 / 7) * 2.5 },
					3, {
						x = [2, 0.5, 1.5, 0.75, 2, 1.3348, 0.5, 1.5][i];
						tp = PitchShift.ar(mono, 0.09, x) ! 2;
					},
					4, {
						x = SinOsc.kr(0.15 + (0.04 * i), i).range(0, 1);
						tp = (tp * (1 - x)) + ((PitchShift.ar(mono, 0.045, 2) ! 2) * x);
					}
				);
				mono = tp.sum * 0.5;
				// garder une partie de l'image stéréo d'origine
				gains[i] * ((tp * 0.5) + (Pan2.ar(mono, pan) * 0.5))
			}.sum;

			Out.ar(out, sum);
			// arrêté : libérer le synth quand la traîne s'est éteinte (tant que
			// run vaut 1, le décalage ajouté empêche toute détection de silence)
			DetectSilence.ar(sum.sum + run, 0.0001, 1, doneAction: 2);
		}).add;
	}

	// macrocosm_voice, puis _f (filtre), _c (bitcrush), _n (sans bouclage)
	*voiceName { |withFilter, withCrush, withLoop|
		var opts = (if(withFilter) { "f" } { "" }) ++ (if(withCrush) { "c" } { "" });
		^("macrocosm_voice" ++ (if(opts.isEmpty) { "" } { "_" ++ opts }) ++ (if(withLoop) { "" } { "_n" })).asSymbol
	}

	// Coût mesuré sur Pi 4, script en marche (2026-11-09) : 1,3 % par tête
	// avant ; 0,93 % avec l'enveloppe de Shape en contrôle, 0,53 % sans la
	// lecture de bouclage ; filtre et bitcrush ajoutent environ 0,6 %.
	addVoiceDef { |name, withFilter, withCrush, withLoop|
		SynthDef(name, { |out, buf, phaseBus, ago = 1000, segLen = 1000,
			rate = 1, rateEnd = 1, life = 1, xfade = 0.05,
			gain = 0.5, pan = 0, shape = 0.5,
			ftype = 0, f0 = 1000, f1 = 1000, fq = 0.707, lfoRate = 0, lfoDepth = 0,
			bits = 8, crushHold = 1, glideHz = 0, glideWidth = 0.5,
			lenHz = 0, lenDepth = 0, lenEnv = 0, envBus, duck = 0, duckBus|
			var frames = BufFrames.kr(buf);
			var now = Latch.ar(In.ar(phaseBus), Impulse.ar(0));
			var start = now - ago;
			var r0 = rate.abs.max(1e-3), r1 = rateEnd.abs.max(1e-3);
			// Sans glide : glissando exponentiel unique de rate à rateEnd sur la vie.
			// Avec glide : va-et-vient entre les deux, de forme glideWidth
			// (0 = rampe descendante, 0,5 = triangle, 1 = rampe montante).
			var lfo = (VarSaw.kr(glideHz, 0, glideWidth.clip(0.01, 0.99)) * 0.5) + 0.5;
			var r = Select.kr(glideHz > 0, [XLine.kr(r0, r1, life), r0 * ((r1 / r0) ** lfo)]) * rate.sign;
			// Longueur de boucle modulée (Tunnel) : en octaves, par un LFO ou,
			// avec lenEnv, raccourcie par l'enveloppe du jeu puis relâchée.
			var lenMod = Select.kr(lenEnv, [SinOsc.kr(lenHz), In.kr(envBus).lag(0.05).neg]);
			var len = (segLen * (2 ** (lenDepth * lenMod))).max(16);
			var ph = Phasor.ar(0, r, 0, len);
			var pos = start + ph;
			var xLen, w;
			// le temps à l'échantillon près, pour les fondus de 3 ms et la fin
			var age = Line.ar(0, life, life, doneAction: 2);
			var t = Line.kr(0, 1, life);
			var sh2 = shape * 2;
			var attack = (sh2 - 1).clip(0, 1).linlin(0, 1, 0.01, 0.85);
			var k = sh2.clip(0, 1).linlin(0, 1, 5, 0.15);
			var sig, env, edges, fc, tk, lvl, step, angle;

			sig = BufRd.ar(2, buf, pos.wrap(0, frames), 1, 4);
			if(withLoop) {
				// Bouclage sans clic : on fond vers la matière juste avant le début du segment.
				xLen = (xfade * len).max(1);
				w = ((ph - (len - xLen)) / xLen).clip(0, 1);
				sig = (sig * (w * 0.5pi).cos)
					+ (BufRd.ar(2, buf, (pos - len).wrap(0, frames), 1, 4) * (w * 0.5pi).sin);
			};

			// Shape : 0 = percussif, 0,5 = plat, 1 = montée lente. Calculée en
			// contrôle (une valeur par bloc de 64, interpolée) : c'est le plus
			// coûteux de la tête. Les fondus de 3 ms aux bords restent à
			// l'échantillon : ce sont eux qui évitent les clics.
			env = ((t / attack).clip(0, 1) * 0.5pi).sin.squared
				* (1 - ((t - attack) / (1 - attack + 1e-6)).clip(0, 1)).pow(k);
			edges = (age / 0.003).clip(0, 1) * ((life - age) / 0.003).clip(0, 1);

			if(withFilter) {
				tk = Line.kr(0, 1, life);
				fc = f0 * ((f1 / f0) ** tk) * (2 ** (lfoDepth * SinOsc.kr(lfoRate)));
				fc = fc.clip(20, 18000);
				sig = Select.ar(ftype, [RLPF.ar(sig, fc, 1 / fq), BPF.ar(sig, fc, 1 / fq)]);
			};

			if(withCrush) {
				// Quantification relative au niveau du signal, pour qu'une
				// guitare DI faible craque autant qu'un signal chaud.
				lvl = Amplitude.ar(sig, 0, 0.15).max(1e-5);
				step = lvl * 2 / (2 ** bits);
				sig = Latch.ar(sig, Impulse.ar(SampleRate.ir / crushHold)).round(step);
			};

			sig = sig * edges * (env * gain);
			angle = (pan + 1) * 0.25pi;
			// OffsetOut décale la sortie à l'échantillon exact de l'horodatage,
			// au lieu du début du bloc de 64 où scsynth démarre le synth.
			OffsetOut.ar(out, [sig[0] * angle.cos, sig[1] * angle.sin]);
			Out.kr(duckBus, env * duck);
		}).add;
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
		this.addCommand(\space, "f", { |msg| fx.set(\space, msg[1]); revSynth.set(\space, msg[1]) });
		this.addCommand(\reverb_mode, "i", { |msg| revState.mode = msg[1].clip(0, 5); this.setReverb });
		this.addCommand(\reverb_character, "f", { |msg| revState.character = msg[1].clip(0, 1); this.setReverb });
		// 0 sur l'effet, 1 après le mix, 2 avant l'effet
		this.addCommand(\reverb_position, "i", { |msg|
			fx.set(\revEffect, (msg[1] == 0).asInteger, \revAfter, (msg[1] == 1).asInteger);
			revSynth.set(\before, (msg[1] == 2).asInteger);
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
		var name = this.class.voiceName(nextFilter.notNil, nextCrush.notNil, loop > 0);
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

		if(this.activeVoices < maxVoices) {
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

	// L'entrée est coupée et la traîne s'éteint (feedback ramené à 0,5 au
	// plus, Hold relâché), puis le synth se libère.
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

	stopDelay {
		if(delaySynth.notNil) {
			delaySynth.set(\run, 0, \hold, 0, \fb, delayState.fb.min(0.5));
			delaySynth = nil;
		};
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
