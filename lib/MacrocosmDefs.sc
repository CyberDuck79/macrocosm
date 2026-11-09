// MacrocosmDefs : les SynthDefs de macrocosm.
//
// Toutes les briques audio du moteur (voir Engine_Macrocosm pour la chaîne
// et le pilotage) : entrée, enregistrement de l'historique, détection
// d'attaques, têtes de lecture, délais, réverbe, effets de sortie, Phrase
// Looper. Engine_Macrocosm appelle MacrocosmDefs.add au démarrage.
MacrocosmDefs {
	*add {
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
			var tailing = Trig1.kr(stopRec, Engine_Macrocosm.tailSeconds);
			var recPhase = Phasor.ar(HPZ1.kr(rec) > 0, (rec + tailing).min(1), 0, frames);
			var recorded = Latch.kr(A2K.kr(recPhase), stopRec);
			var loopLen = Select.kr(len > 0, [recorded, len]).max(64);
			var ph = Phasor.ar(t_restart + stopRec, rate * play, 0, loopLen);
			var seamIn = (ph / (0.005 * SampleRate.ir)).clip(0, 1);
			var seamOut = 1 - (ph / (seam.clip(0.005, Engine_Macrocosm.tailSeconds) * SampleRate.ir)).clip(0, 1);
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
			this.addVoiceDef(this.voiceName(f, c, l), f, c, l);
		} } };

		// Réverbe : la complète (JPverb) et la légère (mode lite, Pi 3).
		this.addRevDef(\macrocosm_rev, false);
		this.addRevDef(\macrocosm_rev_lite, true);

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

	// Réverbe : JPverb, précédée d'un pré-délai et de Bloom (12 départs de
	// plus en plus forts étalés dans le temps, chaque note monte dans
	// l'espace). Shimmer : une copie de la queue limitée en fréquence,
	// montée d'une octave, repart dans la réverbe ; le passe-bas fait
	// qu'elle ne grimpe que d'une ou deux octaves. Tilt : pente autour de
	// 2 kHz (Air, Warmth).
	// Légère (lite) : FreeVerb (1,1 % sur Pi 4 contre 12 % pour JPverb), sans
	// Bloom ; t60 donne le feedback de ses filtres en peigne (plafonné vers
	// 10 s), et un délai modulé donne Movement. Size et diffusion n'y ont
	// pas d'équivalent. Le niveau suit la longueur : FreeVerb sort plus fort
	// quand la queue s'allonge (mesuré contre JPverb, 2026-11-09).
	*addRevDef { |name, light|
		SynthDef(name, { |in, send, ret, fed, buf, space = 0.25, before = 0,
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
			fb = LocalIn.ar(2);
			if(light) {
				var room = (((10 ** (-0.09 / t60.lag(0.5))) - 0.7) / 0.28).clip(0, 1);
				feed = tap.(preNow) + fb;
				rev = FreeVerb2.ar(feed[0], feed[1], 1, room, damp.lag(0.5));
				rev = DelayC.ar(rev, 0.01, 0.004 + (SinOsc.kr(revFreq.lag(0.5) * 0.5, [0, 0.5pi]) * revMod.lag(0.5) * 0.002));
				rev = rev * (1.3 - (0.75 * room.cubed));
			} {
				feed = XFade2.ar(tap.(preNow),
					Mix.fill(12, { |j| tap.(preNow + (bloomNow * j / 11)) * gains[j] }),
					((bloomNow * 8).clip(0, 1) * 2) - 1);
				rev = JPverb.ar(feed + fb, t60.lag(0.5), damp.lag(0.5), size, diff.lag(0.5), revMod.lag(0.5), revFreq.lag(0.5));
			};
			shimSig = HPF.ar(LPF.ar(rev.sum * 0.5, shimCut.lag(0.5)), 250);
			shimSig = PitchShift.ar(shimSig, 0.1, 2, 0, 0.01) * shimNow;
			LocalOut.ar([shimSig, shimSig.neg].tanh);
			rev = rev * (0.55 / (0.45 + (0.55 * shimNow)));
			lp = OnePole.ar(rev, exp(-2pi * 2000 / sr));
			rev = lp + (tilt.lag(0.5) * (rev - lp));
			Out.ar(ret, rev);
			Out.ar(fed, (x * (1 + (b * (((1 - sp).max(0) ** 0.5) - 1)))) + (rev * (sp ** 0.5) * b));
		}).add;
	}

	// Multi-taps lisant un buffer circulaire. ACTIVITY (nombre de taps) et
	// SHAPE (pente des niveaux) arrivent de Lua sous forme de gains ;
	// REPEATS = feedback, pris sur le dernier tap actif, filtré et saturé.
	// SHAPE règle aussi comment chaque note entre dans le délai : à gauche
	// seule l'attaque entre, à droite chaque note monte lentement.
	*addDelayDef { |mode, reverse|
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
	*addVoiceDef { |name, withFilter, withCrush, withLoop|
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
}
