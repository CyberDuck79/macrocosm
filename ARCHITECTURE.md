# macrocosm: architecture

This document is for people who want to read or change the code. The user manual is [README.md](README.md).

The comments in the code are in French. The names of files, functions and parameters are in English, so this document and a search through the code should be enough to find your way.

## The big idea

**Lua decides, SuperCollider plays.**

- **One audio buffer, many short-lived synths.** The engine records the input all the time into a stereo history buffer of about 21.8 s. Almost every effect is made of *heads*: short synths that each read a small piece of that history at some speed, then free themselves. A Mosaic loop is a head, and so is a Haze grain or an Arp note.
- **The algorithms are in Lua.** Each effect (Mosaic, Haze, Strum…) is a small Lua file. On the norns clock, it decides when to start a head, what to read, at what speed, for how long, and how loud. It calls `core.spawn{...}`, which becomes one `engine.voice(...)` command.
- **The engine has no idea which effect is playing.** It provides the building blocks and nothing else: the history buffer, heads, attack detection, the multi-tap delay, the reverb, the output stage and the phrase looper.

Why split it this way:

- **Lua is easy to read and change.** You can tweak an algorithm and reload the script without restarting SuperCollider, which takes about 20 s on norns.
- **Rhythm is musical logic.** The norns clock, randomness and the variations are easy to express in Lua and awkward in a SynthDef.
- **Heads only cost CPU while they sound.** An effect only pays for the heads it uses.

What does not fit the head model lives in the engine as a synth that runs all the time:

- the multi-tap delay of Pattern and Warp, because its feedback must be sample-accurate;
- the reverb;
- the filter, modulation, Drift and Lo-fi;
- the looper.

## File map

```
macrocosm.lua              entry point: lists the families and effects, forwards keys/encoders/redraw
lib/
  Engine_Macrocosm.sc      the engine: synths, buses, buffers, commands from Lua, timing
  MacrocosmDefs.sc         every SynthDef (27), no state
  core.lua                 clock, heads (core.spawn), Hold, effect selection, init/cleanup
  params.lua               the PARAMETERS menu and its actions to the engine, Pi detection
  ui.lua                   keys, encoders, the main screen
  view.lua                 the Engine View page
  timing.lua               timing constants shared with the engine (LEAD, NOW, SAFETY)
  looper.lua               phrase looper: states, keys, its parameters (audio is in the engine)
  midi_in.lua              the Microcosm's MIDI CC and Program Change map
  splash.lua               start-up animation
  algos/
    mosaic.lua seq.lua glide.lua          micro loop family
    haze.lua tunnel.lua strum.lua         granules family
    multidelay.lua                        shared by Pattern and Warp
    pattern.lua warp.lua                  multidelay family
    blocks.lua interrupt.lua arp.lua      glitch family
```

## Audio chain (SuperCollider)

```
input ─► macrocosm_in ─► macrocosm_rev ─► macrocosm_writer ─► history buffer ◄── heads (macrocosm_voice*) ─► wet bus
              │          (in "before fx"     macrocosm_onset ─► attack poll to Lua         macrocosm_delay_* ─┘
              │           mode, reverbs                                                                        │
              │           the input)                                                                           ▼
              │                                                 dry ─► macrocosm_fx : pitch mod, Drift, Lo-fi, filter,
              │                                                         reverb send/return, mix, bypass
              │                                                                            │
              └──────── live input ─────────────────────────────────► macrocosm_looper ─► output
```

The synths are created in `Engine_Macrocosm.alloc`, in three groups: input, voices, fx.

- **`macrocosm_writer`** writes into the history buffer and publishes the write position on `phaseBus`. Hold freezes that position and writes the buffer's own content back, so nothing is lost.
- **Heads** read the buffer relative to `phaseBus`: `ago` is how far back the segment starts, in samples. They sum into `wetBus`.
- **`macrocosm_onset`** detects attacks. It sends their position in the buffer to Lua through the `onset` poll, which is how Strum, Arp and others react to playing. It also sends a slow input envelope, which draws the Engine View background and drives Tunnel's length.
- **The reverb** is its own synth, placed before the writer. `macrocosm_fx` sends it the effect, or the whole mix, and gets the reverb back one block later. Changing the reverb position only moves the send and the return, so the tail is never cut.
- **The looper** comes last, so it can record the output (post-FX). In pre-FX mode, its playback goes back into the input through `loopPreBus`.

## The life of a head

1. An algorithm runs inside `core.every(div, fn)`. The function wakes up `LEAD` (50 ms) before each grid step, and `core.beat()` gives the exact beat of that step.
2. The algorithm calls `core.spawn{ ago, len, rate, life, loop, shape, ... }`.
3. `core.spawn` then:
   - applies Reverse and Lo-fi slow-down;
   - limits `life` so that the history is not overwritten while it is being read;
   - checks the voice cap;
   - sends any per-head options (`vfilter`, `vcrush`, `vglide`, `vlen`, `vduck`);
   - sends `engine.voice(...)` with `lead`, the number of seconds to the planned instant;
   - records the head for the Engine View.
4. `spawnVoice` in the engine picks a SynthDef variant (see below) and sends the synth as a **timestamped bundle**. Thanks to `OffsetOut`, the head starts on the planned sample, not on the next audio block.

## Timing

The heads land on the grid with sample accuracy. Here is how:

- Lua wakes up early (`timing.LEAD`) and tells the engine the exact instant.
- The engine sends a bundle stamped with that instant. If the instant is too close, it uses at least `safety` (15 ms).
- An event that is not on the grid, such as an attack, uses `latency` (25 ms).

`NOW` and `SAFETY` in `timing.lua` must keep the same values as `latency` and `safety` in `Engine_Macrocosm.sc`. Lua uses them to know when each head really starts, for the voice count and the Engine View.

**The watchdog** (`startWatchdog`) handles clock problems. Timestamped bundles assume that sclang and scsynth agree on the time. Just after boot, the system clock jumps when the network sets it. The watchdog pings the server, and while the clocks disagree, it falls back to sclang scheduling, accurate to about ±1.3 ms.

**Heads are counted on both sides** from the expected end of each head (`voiceEnds` in the engine, `voice_ends` in Lua). Server notifications are not used, because they can be lost.

## Technical choices

| Choice | Why |
|---|---|
| Algorithms in Lua, heads in SC | See *The big idea*. A change to an algorithm only needs a script reload. |
| One shared history buffer | Every effect reads what you played without its own recording. Hold freezes everything at once. The 2^20 frames keep a float32 index precise to 1/16 of a sample. |
| 8 SynthDef variants for heads (`_f` filter, `_c` crush, `_n` no loop) | You only pay for what a head uses. A plain one-shot head costs 0.53 % CPU on a Pi 4, a looping one 0.93 %. |
| Shape envelope at control rate, 3 ms edge fades at audio rate | The envelope was the most expensive part of a head. The edges stay sample-accurate, because they are what prevents clicks. |
| Multi-tap delay as one continuous synth per mode | Taps, feedback and per-tap processing must share one buffer and run at sample rate. When the mode changes, a new synth replaces the old one, which keeps its tail on its own buffer until it falls silent. |
| Reverb in its own synth, before the writer | It can sit after the effect, after the mix or before the effect without cutting its tail. |
| `lite` reverb (FreeVerb) and a 10-voice cap | JPverb alone costs about 12 % on a Pi 4. Lite keeps every effect under 25 % on a Pi 4, which is the usual rule of thumb for a Pi 3. The board is detected in `params.lua`. |
| Variation and Hold are numbers and binaries, not options | The `matrix` mod cannot modulate option parameters. |
| Each stateful Lua module is included once, in `core.lua` | On norns, `include` is `dofile`, with no cache. Including `looper.lua` twice would give two separate loopers. The modules are passed around instead. |

## Where to change things

**A variation of an existing effect**

- In `lib/algos/<effect>.lua`, add its description to `variations` and the matching behaviour. It is usually one more line in a table indexed by `core.variation()`, for example `SPEEDS` in `mosaic.lua`.
- Variations E to H are allowed: `VARIATION_LETTERS` in `params.lua` goes up to 8.

**A new effect**

- Copy a short algorithm, such as `mosaic.lua`.
- It needs `name`, `variations` and `start(core)`. Add `onset(core)` if it reacts to attacks, and `stop(core)` if it has something to stop in the engine.
- Add it to a family in `macrocosm.lua`. The effect parameter and the screen follow.
- To reach it with a MIDI Program Change, add its `name` to `PROGRAM_ORDER` in `midi_in.lua`.
- Useful helpers on `core`: `every`, `run`, `spawn`, `unit`, `beat`, `buffer_beat`, `ago_of`, `recent_onset`, `active_count`, `max_life`, `lerp`, `uniform`, `chance`, `pick`.

**A new Pattern or Warp style delay**

- Use `multidelay.make{ name, variations, times, modes, trims }`.
- `times` are tap positions in 16ths of the TIME unit.
- `modes` pick the tap processing from `MacrocosmDefs.addDelayDef`: 0 none, 1 envelope filter, 2 band-pass, 3 pitched taps, 4 octave grains.

**What a head can do**

- Edit `MacrocosmDefs.addVoiceDef` for the SynthDef.
- Update `spawnVoice` and the `voice` command in `Engine_Macrocosm.sc` for the arguments.
- Update `core.spawn` on the Lua side.

**A reverb mode or Character**

- `reverbModes` in `Engine_Macrocosm.*initClass` holds the base settings.
- `setReverb` decides what Character changes for each mode.
- `REVERB_NAMES` (`params.lua`) and `CHARACTER_NAMES` (`ui.lua`) hold the names.

**The output stage** (filter, mix, modulation, Drift, Lo-fi, bypass) is in `MacrocosmDefs`, SynthDef `macrocosm_fx`.

**A parameter**

- Add it in `params.lua`.
- If it should be on a page, add it to `PAGES` in `ui.lua`.
- If it needs the engine, add a command in `Engine_Macrocosm.addCommands`.

**The screen**: `ui.redraw` draws the main page and `view.draw` the Engine View.

**MIDI**: the CC and Program Change tables are at the top of `midi_in.lua`.

**The looper**

- Its states and keys are in `looper.lua`.
- The audio is in the `macrocosm_looper` SynthDef.
- The save and load of phrases are in `saveLoop` and `loadLoop` in the engine.
- MIDI Start and Stop arrive through `clock.transport.start` and `clock.transport.stop`, set in `looper.init`.

**CPU**

- `FULL_VOICES` and `LITE_VOICES` are in `core.lua`, with the matching `maxVoices` and `liteVoices` in the engine.
- The lite reverb is the `light` branch of `MacrocosmDefs.addRevDef`.

## Working on the norns

**Applying a change**

- A Lua change only needs the script to be reloaded.
- A change to a `.sc` file needs **SYSTEM > RESTART**, so that SuperCollider recompiles the classes.

**Debugging and measuring**

- To try things live, use the maiden REPL: `engine.voice(...)` and `params:set(...)` in matron, `Crone.context.server` in SuperCollider.
- To measure CPU, average `Server.avgCPU` over a few seconds while a test signal plays and the script runs. The engine's SynthDefs are removed when the script stops, so measure with the script loaded.
