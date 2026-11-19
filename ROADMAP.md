# NHL Legacy native Windows port — status review and roadmap

Review date: 2026-11-16. Reviewed commit: `0852183` (`master`, identical to `upstream/master`).
This was a read-only pass: no code was changed. The only file added is this one.

**Goal for this phase:** the base game fully working as a native Windows build — clean repeatable build, playable start to finish, correct rendering, working audio / keyboard + controller input / saves, stable full-speed frame rate. Upscaling, texture packs and widescreen are out of scope, but must not be blocked.

**How to read the labels**

| Label | Meaning |
|---|---|
| VERIFIED | I confirmed it myself: read it in the code, or ran the command and saw the output. |
| INFERRED | Strong evidence (docs, release notes, bug reports, SDK source) but I did not see it happen. |
| UNKNOWN | Could not be determined without running the game or having the game files. |

**The biggest limit on this review:** the game could not be built or run on this PC (see section 2), so nothing about runtime behaviour is VERIFIED. Every runtime claim below comes from source code, the project's own docs, upstream release notes, or upstream bug reports.

**Short glossary**

- **Static recompilation** — a tool translates the Xbox 360 game's PowerPC machine code into C++ once, ahead of time; that C++ is then compiled into a normal Windows program. Nothing is emulated instruction-by-instruction at run time.
- **Guest / host** — "guest" is the original Xbox 360 game code and memory; "host" is the Windows PC side.
- **ReXGlue SDK** — the toolkit this project is built on. It contains the recompiler and a runtime (`rexruntime.dll`) that stands in for the Xbox 360 operating system, GPU, audio and input. It is derived from the Xenia emulator.
- **XEX** — the Xbox 360 executable file (`default.xex`).
- **EDRAM / resolve** — the 360 GPU draws into a special memory area (EDRAM) and then copies ("resolves") the result into normal memory to use it as a texture.
- **FSI** — "fragment shader interlock", a Vulkan GPU feature. The current renderer uses it to imitate EDRAM exactly. It is a hard requirement.
- **cvar** — a named runtime setting inside the SDK (for example `vsync`).
- **PGO** — profile-guided optimization: build once, play to record which code is hot, rebuild using that recording. Makes the game faster.

---

## 1. Project overview

### What this is

A native PC port of NHL Legacy (Xbox 360), made by static recompilation with the ReXGlue SDK. The repo holds the recompiler configuration, a small host application, a thin game-specific layer over the SDK's Vulkan renderer, an in-game settings overlay, an installer tool, and a large amount of investigation history. It holds no game content. (VERIFIED — `README.md`, `DEV-README.md`, `.gitignore`.)

### How the pipeline works

1. **Recompile.** `rexglue codegen nhllegacy_manifest.toml` reads your `default.xex` and writes about 181 C++ files into `generated/` (not tracked in git). Two files steer it:
   - `nhllegacy_manifest.toml` — where the XEX is, plus the addresses of the game's `setjmp`/`longjmp` (getting these wrong made the game self-destruct at boot, per the comment in that file).
   - `nhllegacy_functions.toml` — over 300 function addresses added by hand because the recompiler's scanner missed them (functions reached only through pointers/tables).
2. **Runtime.** The SDK's `rexruntime.dll` provides everything the game expected from the console: kernel and system calls, file system, audio (XMA decoding, output through SDL), input (SDL or XInput controllers, plus an optional keyboard/mouse-as-controller driver), and the GPU (it reads the game's Xbox 360 GPU commands and replays them on Vulkan).
3. **Host app (`src/`).** `NhllegacyApp` in `src/nhllegacy_app.h` picks the renderer, sets the cvars the game needs, mounts the `cache:` drive, and layers loose files over the game's archives.
4. **Renderer (`renderer/`).** `NhlVkCommandProcessor` in `renderer/core/nhl_vk_backend.cpp` is a small subclass of the SDK's Vulkan renderer. It adds one fix (the goal net) and a frame-rate counter; every other draw is forwarded unchanged. The overlay is `renderer/core/nhl_overlay.cpp`.
5. **SDK patches (`sdk/`).** Game-specific fixes that live inside the SDK source are kept as three patch files, applied on top of one pinned SDK commit (`bd9b5191`).
6. **Packaging (`tools/packager/`, `release/`).** `nhl-legacy-builder` turns a disc image into an install: checks the XEX by SHA-256, extracts the disc, copies the prebuilt port, and unpacks the `.big` archives into loose files.

### Architecture map

| Path | What it is | Used by the current build? |
|---|---|---|
| `nhllegacy_manifest.toml`, `nhllegacy_functions.toml` | Recompiler config and hand-registered functions | Yes |
| `generated/` (untracked) | Recompiled game code | Yes — produced by codegen |
| `src/nhllegacy_app.h` | App setup: renderer choice, cvars, `cache:` mount, loose-file overlay, overlay wiring, exit handling | Yes — the central file |
| `src/kernel_stubs.cpp` | Stubs for the Xbox camera API (reports "no camera") | Yes |
| `src/input_block.cpp` | Replaces the game's controller read so the pad is ignored while the overlay is open | Yes (Vulkan build) |
| `src/vp6_bridge.cpp`, part of `src/diag_hooks.cpp` | Movie fix: swaps in frames decoded by a bundled `ffmpeg.exe` | Yes |
| `src/diag_hooks.cpp` | Crash-context capture plus many switched-off diagnostics | Yes (mostly inert) |
| `src/union_device.cpp`, `src/loose_tree_device.cpp` | Loose-file overlay and `.dds` → `.rx2` texture override | Overlay yes; `.dds` override needs a private library (see 6) |
| `src/cpu_affinity.cpp` | Pins to performance cores on Intel hybrid CPUs | Yes (no effect on an i7-9700) |
| `renderer/core/nhl_vk_backend.*` | Game-specific Vulkan layer | Yes |
| `renderer/core/nhl_overlay.*`, `nhl_settings.h` | In-game overlay (F1 or Guide button), settings saved to `nhl_enhancements.ini` | Yes |
| `renderer/core/nhl_command_processor.cpp` (7,538 lines), `gpu/hooks/`, `gpu/spirv/` | Older D3D12 and "high-cut plume" renderers | Compiled in, but reference-only |
| `sdk/*.patch` | SDK source fixes | Two of three are applied by the setup script (see 2) |
| `scripts/` | Build scripts (`_env.bat`, `setup_sdk.ps1`, `_ffx_*.bat`, `_game_ffx_build.bat`, `_build_vk_*.bat`) and diagnostics | Yes |
| `tools/packager/`, `release/` | Installer and release packaging | Yes |
| `tools/*.py`, `tools/replay/` | Reverse-engineering and GPU-trace tools | Dev only |
| `docs/` | ~60 design/hand-off documents, about 95% renderer history | `current-status.md` and `BOOTSTRAP.md` are the useful ones |

### Where game-specific fixes live

| Fix | Location | Label |
|---|---|---|
| `setjmp`/`longjmp` addresses | `nhllegacy_manifest.toml` | VERIFIED |
| Scanner-missed functions | `nhllegacy_functions.toml` | VERIFIED |
| Page zero readable, heap zero-filled (`protect_zero=false`, `scribble_heap=false`) | `NhllegacyApp::OnPreSetup` | VERIFIED |
| V-sync forced on (menu animations ran at the wrong speed when uncapped) | `OnPreSetup` | VERIFIED |
| `cache:` drive backed by a real folder (game crashed at boot without it) | `NhllegacyApp::OnPostSetup` | VERIFIED |
| Resolve readback `full` with a 3 MB size gate (equipment textures) | `OnPreSetup` | VERIFIED |
| Audio queue deepened to 16 frames (crackle at high resolution) | `OnPreSetup` | VERIFIED |
| Goal net transparency | `NhlVkCommandProcessor::IssueDraw` | VERIFIED |
| Jersey font, signed normal maps, GPU selection, shadow filtering | `sdk/rexglue-vulkan-nhl-legacy-bd9b519.patch` | VERIFIED (present in patch) |
| Dropped function tails in recompiled code | `sdk/rexglue-codegen-bcctr-tail-fix.patch` | VERIFIED (present in patch) |
| Movie decoding | `src/vp6_bridge.cpp` + `sdk/rexglue-vp6-sharedmem-fixes.patch` | VERIFIED (present); patch is not applied by setup |
| Camera API stubs | `src/kernel_stubs.cpp` | VERIFIED |

---

## 2. Status table

| Subsystem | Status | Evidence | Label |
|---|---|---|---|
| **Build on this PC** | Works (2026-11-17), with an F:-only toolchain and local step scripts, not yet with the repo's own scripts | SDK, codegen and game all built with exit code 0; the dev build booted to the menus at 30 fps. Earlier attempt with the repo's script: `[env] ERROR: Vulkan SDK not found`. See "First build on this PC" under Milestone 1. | VERIFIED |
| Build prerequisites | Mostly missing | No Vulkan SDK (`C:\VulkanSDK` absent), no LLVM/Clang, no CMake or Ninja on PATH, no `third_party/`, no `generated/`. Only Visual Studio **18** Build Tools is installed; `scripts/_env.bat` only searches `...\Microsoft Visual Studio\2022\...` and `scripts/_ffx_dll_build.bat` asks for the `Visual Studio 17 2022` generator. VS 18 does bundle CMake 4.3.1 and Ninja 1.13.2. | VERIFIED |
| Build process in general | Documented, six steps, fragile | `BOOTSTRAP.md` says it was checked from a clean machine on 2026-07-06. Fragile points are listed in section 4. | INFERRED (their claim) / VERIFIED (fragile points) |
| Recompiler input | Not ready | `nhllegacy_manifest.toml` points at `c:/users/alex/downloads/...`; no `default.xex` has been extracted on this PC | VERIFIED |
| Game dump | Supported | `F:\Emulation\Downloads\Xbox 360\NHL Legacy Edition (USA, Europe) (En,Fr,De,Ru).iso` (8.7 GB). Checked 2026-11-16 with upstream v0.6.0: `nhl-legacy-builder verify --iso` reported "default.xex matches NHL Legacy (vanilla)", SHA-256 `d818eb15775c1fee34b057b0fc494b211535d07123230ee45bd7d40991c55624`, 171 files, 6.01 GB game partition. | VERIFIED |
| Boot | Works in upstream releases | Five releases, latest v0.6.0; bug reports describe menus working | INFERRED |
| Recompiled code | Works on tested paths; crash risk on untested paths | A call to a function the recompiler never registered is fatal ("Call to invalid or unregistered function" → abort; described at the top of `src/diag_hooks.cpp`). Over 300 such functions were already found and added by hand. Open report of a crash after tutorial step 1 ([puckhead73/nhl-legacy-recomp#3](https://github.com/puckhead73/nhl-legacy-recomp/issues/3)). | INFERRED |
| Graphics — renderer | Vulkan "fsi" path is the baseline | `docs/current-status.md`; `OnPreSetup` forces `render_target_path_vulkan=fsi` | VERIFIED |
| Graphics — GPU requirement | Met on this PC | `vulkaninfo` lists `VK_EXT_fragment_shader_interlock` on the RTX 2070. GPUs without it get a black screen in matches ([puckhead73/nhl-legacy-recomp#9](https://github.com/puckhead73/nhl-legacy-recomp/issues/9)). | VERIFIED |
| Graphics — correctness | Believed good; two items disputed | Net, equipment, jersey font fixes are in code/patches. Jersey numbers and lighting/gamma are "fixed and user-verified" in `docs/vulkan-rov-backend-spike-findings.md` but still "open" in `docs/current-status.md` and `docs/vulkan-migration-plan.md`. | INFERRED / UNKNOWN for the two disputed items |
| Textures | Depend on a size-based workaround | Goalie/player equipment is composited at run time and must be read back from the GPU; `OnPreSetup` sets `readback_resolve=full` and `NHL_VK_READBACK_MAX_LEN=3000000`. Above 2x supersampling they turn black, so the slider is capped at 2x. | VERIFIED (code) / INFERRED (visual result) |
| Movies | Worked around, not fixed | The recompiled VP6 decoder is wrong; `src/vp6_bridge.cpp` replaces its output with `ffmpeg.exe` frames (on by default). It needs `ffmpeg.exe`, loose movie files, and an SDK patch that `scripts/setup_sdk.ps1` does not apply. | VERIFIED (code) / INFERRED (a from-source build shows corrupted movies) |
| Audio | No documented testing | SDK has XMA decoding and SDL output. The only project evidence is the crackle fix. One user reports stuttery movie playback. | UNKNOWN |
| Input — controller | Expected to work | SDK defaults to the SDL backend, XInput optional (`input_backend` cvar); `docs/linux.md` says Xbox pads work | INFERRED |
| Input — keyboard | Not usable for play | SDK's keyboard driver is off by default (`mnk_mode` = false in `src/input/mnk/mnk_input_driver.cpp` at the pinned commit) and nothing in this repo turns it on. Its default bindings put the right stick on the mouse. Only F1 (overlay) is handled. | VERIFIED (source) |
| Saves | Probably work; never documented as tested | SDK implements save create/open/delete on host folders (`src/system/xam/content_manager.cpp`). `docs/linux.md` says saves live in `Documents/nhllegacy`. `docs/vp6-fork-investigation.md` notes a force-killed run left half-written `BEAPRO…`/`PROFILE…` entries. | INFERRED |
| Shutdown | Hard kill | "Exit Game" calls `TerminateProcess` because a normal quit hangs (comment in `OnCreateDialogs`, `on_exit`) | VERIFIED |
| Performance | Hardware-dependent; unknown here | Dev box (Ryzen 5800X + RTX 4080 SUPER): about 48–84 fps in dense play. RTX 3070 user: about 40 fps at 1,700 draws/frame. i7-6700 + GTX 1060 does not hold 60 ([puckhead73/nhl-legacy-recomp#10](https://github.com/puckhead73/nhl-legacy-recomp/issues/10)). Bottleneck is one "GPU Commands" thread, about 41% of it waiting on the readback (`docs/cpu-perf-optimization-plan.md`). | INFERRED; UNKNOWN for i7-9700 + RTX 2070 |
| Game-mode coverage | Thin | Docs record the title screen, attract demo, create-a-player and on-ice play. No record of a full game, a season, Be A Pro, GM mode or shootouts. | UNKNOWN |

---

## 3. Blockers to playability

In priority order. The first two block everything else.

1. ~~**No working build environment on this PC.**~~ **Resolved 2026-11-17 (VERIFIED)** with portable tools under `F:\devtools` and local step scripts in `F:\devtools\sticktoss`. The repo's own scripts still assume Visual Studio 2022 and C:\ paths; folding the working setup back into the repo is tasks 1.2–1.8.
2. ~~**The disc image has not been validated.**~~ **Resolved 2026-11-16 (VERIFIED).** The image passes the upstream builder's hash check, so the addresses in `nhllegacy_functions.toml` and every hook apply to this copy of the game.
3. **Fatal aborts on unregistered functions in untested code paths.** (INFERRED) This is the most likely cause of mid-game crashes, and plausibly the tutorial crash in [puckhead73/nhl-legacy-recomp#3](https://github.com/puckhead73/nhl-legacy-recomp/issues/3). The root cause is structural: the recompiler finds functions by scanning, and functions reached only through pointers are invisible to it until something calls them. Only menus and on-ice play have been exercised, so deeper modes are where the remaining ones hide.
4. **Save integrity is unproven, and the exit path can cut a save in half.** (INFERRED) Saving is implemented in the SDK, but no save → quit → reload cycle is recorded anywhere, and the only way out of the game is a process kill.
5. **No end-to-end playthrough has been recorded.** (UNKNOWN) Softlocks and progression blockers cannot be ruled out for full games, playoffs, Be A Pro or GM mode.
6. **Keyboard cannot play the game.** (VERIFIED in source) A stated goal requirement. Not a crash, but a hard gap.
7. **Frame rate on this hardware falls short of 60 fps in gameplay.** (VERIFIED 2026-11-16 with upstream v0.6.0: per-minute gameplay averages mostly 35–40 fps, menus locked at 30; see "Baseline play test" in section 5.) The cause is INFERRED: single-thread CPU speed plus a per-frame GPU wait, on an i7-9700 that is slower per core than the dev machine. First-time shader compilation adds multi-second freezes in the first minutes of the first game.

Polish rather than blockers: movie playback in from-source builds, the disputed jersey-number/lighting items, shadow aliasing, clean shutdown, a clear message on GPUs without FSI.

---

## 4. Full gap list

### Build

- `scripts/_env.bat` finds only Visual Studio 2022; `scripts/_ffx_dll_build.bat` hard-codes the `Visual Studio 17 2022` generator. (VERIFIED)
- `scripts/setup_sdk.ps1` applies two patches; `sdk/rexglue-vp6-sharedmem-fixes.patch` is not in its list and is not referenced anywhere in the repo. That patch carries the hook the movie fix depends on (`NHL_VP6_LAST_OPEN`) and shared-memory race fixes. Whether it applies cleanly on top of the other two is UNKNOWN. (VERIFIED that it is skipped)
- `nhllegacy_manifest.toml` contains another person's absolute paths; every developer must edit a tracked file. (VERIFIED)
- `CMakeLists.txt` unconditionally builds the retired renderers: `add_subdirectory(third_party/plume)`, a `FetchContent` download of glslang that is then patched in place, plume shader compilation, and `gpu/spirv/*`. The shipping build depends on code it does not use. (VERIFIED)
- `CMakeLists.txt` defaults `RX2FFI_LIB` to `E:/Repositories/nhl-database-studio/...`, a private repo; without it the build warns and disables loose `.dds` overrides. (VERIFIED)
- The canonical build has no CMake preset; it exists only as a `.bat` file. (VERIFIED)
- FidelityFX must be built separately with a different generator and staged by hand; the first SDK configure is expected to fail. (VERIFIED — `BOOTSTRAP.md` steps 2–4)
- The colour-grade overlay section does nothing in a from-source build (`src/present_grade_compat.cpp`; the SDK-side pass is in no patch). Out of scope, but it is a visible dead control. (VERIFIED)
- Two files show as modified right after cloning because of line endings (`scripts/_build_vkffx_incr.bat`, `scripts/_c5renderdoc.ps1`). (VERIFIED)
- No automated check that a build boots (`tools/smoke_boot.ps1` exists but is manual). (VERIFIED)
- PGO profiles are not in the repo, so a local build is slower than the upstream release until a profile is recorded. (VERIFIED — `.gitignore`, `BOOTSTRAP.md`)

### Boot and recompiled code

- Remaining unregistered functions (see blocker 3). Tools exist: `tools/find_missing_indirect_targets.py`, `tools/find_missing_materialized_targets.py`, `tools/missing_targets.toml`. (INFERRED)
- One confirmed recompiler arithmetic bug (the VP6 movie decoder's vector math) is bypassed, not fixed; the same class of bug could exist in gameplay code. (INFERRED — `docs/vp6-fork-investigation.md`)
- Tutorial crash is unexplained. (UNKNOWN)

### Graphics and textures

- Jersey numbers and lighting/gamma: status disputed between docs. (UNKNOWN)
- Equipment textures rely on a byte-size threshold to decide what to read back. Anything composited above 3 MB would silently break. (VERIFIED code / INFERRED risk)
- Shadows are aliased; softening options exist but default off. (INFERRED — v0.4.0 release notes)
- Boot shows green/red frames around 40–45 s. (INFERRED — `docs/vulkan-rov-backend-spike-findings.md`)
- Cached shaders can go stale after renderer changes. (INFERRED — `docs/vulkan-migration-plan.md`)
- GPUs without FSI get a black 3D scene with no explanation. Not a problem on the RTX 2070. (INFERRED)
- Crowd, ice reflections, replays, arena scoreboard: no evidence either way. (UNKNOWN)

### Movies

- Root cause open; bridge depends on `ffmpeg.exe`, loose files and the unapplied patch; one movie format (packed CrYCbY) is not covered. (VERIFIED / INFERRED)
- User report of stuttery movies with V-sync off. (INFERRED)

### Audio

- No test record for music, commentary, crowd, menu sounds, or long-session stability. (UNKNOWN)
- Audio starves when the render thread stalls; fixed by a deeper queue (more latency), not at the source. (VERIFIED code)

### Input

- Keyboard play is off and unmapped for hockey. (VERIFIED)
- Controller behaviour (hot-plug, second controller, vibration, non-Xbox pads) undocumented. (UNKNOWN)
- The overlay blocks the pad while open but there is no equivalent path for a keyboard-as-controller. (VERIFIED — `src/input_block.cpp` only zeroes controller state; the keyboard driver feeds the same call, so this may already be covered — needs a test)

### Saves

- No recorded save/load test for settings, profile, rosters, Be A Pro, GM mode. (UNKNOWN)
- Exit kills the process; a save in progress can be truncated. (INFERRED)
- Leftover half-written saves change boot behaviour (language select reappears). (INFERRED)

### Stability

- Normal shutdown hangs. (VERIFIED — code comment)
- No soak testing (hours-long sessions, memory growth). (UNKNOWN)

### Performance

- Single-thread ceiling in the GPU command thread. (INFERRED)
- Per-resolve GPU wait from full readback. (INFERRED)
- V-sync is forced on because menu timing is tied to frame rate. (VERIFIED)
- Earlier attempts (descriptor reuse, sampler cache, tuning flags, index cache) made no difference; multi-threaded recording was deferred. (INFERRED — `docs/cpu-perf-optimization-plan.md`, `docs/mt-command-recording-handoff.md`)

---

## 5. Roadmap

Difficulty: S = hours, M = days, L = a week or more. "Verify" is how you know the task is done.

### Milestone 0 — Find out where the game really stands (no building)

| Task | Files / tools | Diff. | Risk | Verify |
|---|---|---|---|---|
| 0.1 Validate the disc image against the upstream v0.6.0 release — **DONE 2026-11-16** (release unpacked under `out\baseline\v0.6.0\`, which git ignores) | Upstream release zip, `nhl-legacy-builder verify --iso` | S | Image may not match; then a matching dump is needed | Builder reports the XEX as supported — it did |
| 0.2 Install the upstream release and play it on this PC — **DONE 2026-11-16: installed and one full game played to the final horn, no crash.** `nhl-legacy-builder install` finished with exit code 0 in 3.6 minutes ("13 extracted, 0 skipped, 0 failed"). Install is at `F:\Games\NHL Legacy` (18.6 GB, 44,779 files); installed `nhllegacy.exe` matches the manifest hash `f6398c98…bfc037`. Before installing, Windows Defender scanned the release folder (no detections) and the zip matched GitHub's published SHA-256. | `nhl-legacy-builder install` | S | Took 18.6 GB, not the ~10 GB first estimated | Game reaches a match — it did, and finished one |
| 0.3 Record a baseline: fps (overlay perf panel), visual problems, audio problems, crashes — **FIRST SESSION DONE 2026-11-16** (see "Baseline play test" below). Still missing: screenshots, and a second session to see what changes once shaders are cached. | Screenshots + the game's log file | S | None | A written list with a screenshot per issue |
| 0.4 Extract `default.xex` for later use — **DONE 2026-11-16.** It is at `F:\Games\NHL Legacy\game\default.xex` (10,448,896 bytes, SHA-256 `d818eb15…c55624`, the supported build). Never copy it into the repo. | The install's `game\` folder | S | None | File exists outside the repo — it does |

This milestone costs an afternoon and replaces most of the UNKNOWN rows in section 2 with facts before any toolchain work.

#### Baseline play test — 2026-11-16 (upstream v0.6.0, one exhibition game, controller)

Sources: the player's notes, plus the game's own log and movie-bridge log, copied to `out\baseline\v0.6.0\session1\` (git-ignored). The log prints one `[nhl-vk-fps]` line per second, so frame rates below are measured, not estimated. Session ran 20:39–21:13; the game itself is not from this repo's source, so these are facts about upstream's build on this PC.

**What worked (VERIFIED):** boot, menus, a complete game start to finish, no crash, no softlock. Renderer picked the RTX 2070 on the `fsi` path.

**Frame rate (VERIFIED from 1,984 log samples):**

| Where | Measured |
|---|---|
| Menus and post-game screens | Locked at 30.0 fps |
| Gameplay, per-minute average | Mostly 35–40 fps; best minute 50, worst 23 |
| Share of all samples at 58 fps or more | 7% |
| Share of all samples at 29–31 fps | 45% (includes menus) |
| Last ~50 seconds of game time (21:10:40–21:11:30) | 20–28 fps, against 30–45 earlier with a similar draw count |

So gameplay never holds 60 fps on this PC. The pattern of bouncing between about 30 and 45–60 fits V-sync halving the rate whenever a frame takes longer than one screen refresh (INFERRED; the display's refresh rate is not confirmed).

| What the player saw | Evidence | Likely cause | Label | Roadmap task |
|---|---|---|---|---|
| Freezes when the arena loads, players take the ice, pregame, first puck drop, first goal against (1–2 s), stick break (<1 s); later goals did not freeze | 15 gaps of 1.7–8.7 s between fps lines, all between 20:44:24 and 20:49:07, and every one contains `Creating graphics pipeline state` lines (2 to 96 per gap). 570 of the session's 616 pipelines were built in those five minutes; small batches at 20:53, 20:59, 21:02 and 21:04 fit the later short hitches. | First-time shader compilation: the game stalls while the graphics driver builds each new shader combination. Seen once per combination, which is why the second goal was smooth. | VERIFIED correlation, INFERRED cause | New task 6.6 below |
| Will the freezes come back next session? | Log line `Initializing shader storage for title 454109EC...`; the pinned SDK's `src/graphics/vulkan/pipeline_cache.cpp` (`InitializeShaderStorage`) writes pipeline descriptions to `<cache root>\shaders\shareable\454109EC.fsi.vk.xpso`, and the log gives the cache root as `Documents\nhllegacy\cache`. | They should mostly not: stored pipelines are meant to be rebuilt at startup. | INFERRED — test by playing a second game | 0.3 follow-up |
| Short freeze / black screen at launch and when starting the game | 16 pipelines built at 20:39; 18–19 fps dips at 20:44:07–11 during loading | Loading plus the first shader builds | INFERRED | 6.6 |
| "EA" spinning-logo wipe around replays looks glitched, every time | `vp6_bridge.txt`: `transition_eas.vp6` decoded 15 times and `transition_replayout.vp6` 10 times, each by starting a fresh `ffmpeg.exe` | The host movie bridge (`src/vp6_bridge.cpp`). It starts a new ffmpeg process per wipe, shows the game's own (known-broken) frame whenever ffmpeg has not delivered yet (`underrun` path, line 323), and asks ffmpeg for `yuv420p`, which carries no transparency. Which of these is visible is not yet known. | INFERRED | 4.4 |
| Goal-cam replays look low-resolution | Source comment in `renderer/core/nhl_command_processor.h:151` refers to the game's "half-res replay passes" | The game may render replays at half resolution by design; whether the PC result is worse than a real console is not established | UNKNOWN — needs a reference comparison | 4.2 |
| Low frame rate for roughly the last minute of game time | fps table above; draw count per frame was not higher than earlier | Not known. Could be game state (late-game situations), heat, or a slow build-up over the session | UNKNOWN — see if it repeats | 6.1 |
| Slight tick sounds when moving through menus with the d-pad | None in the log | Not known; could be the game's own menu sound or an audio glitch | UNKNOWN — needs a reference comparison | 5.1 (listen for it during test games) |

#### Second session — 2026-11-16, 21:25–21:32 (same teams, about five minutes of play, quit early)

Logs copied to `out\baseline\v0.6.0\session2\`.

| Question | Result | Label |
|---|---|---|
| Did the shader cache work? | Yes. Startup log: `Created 324 graphics pipelines from Vulkan storage (324 requested)`, in about one second. No new pipelines were built during play, and there was no gap over 1.6 s between fps lines (session one had 15, totalling 55 s). | VERIFIED |
| Then why did it feel worse? | The player reported more stutter and micro-freezing, with audio stutter early in play. The log shows the frame rate changing almost every second between about 30 and 60 fps (for example 30, 20, 23, 56, 57, 58, 60, 58, 44 in consecutive seconds). 35% of in-game seconds sat between 45 and 58 fps, against 14% in session one. A rate in that band means some frames last 1/60 s and others 1/30 s, which the eye reads as stutter even though the average (40.4 fps, up from 35.8) is higher. | VERIFIED numbers, INFERRED explanation |
| What causes the swinging? | The game paces itself to the console's 60 Hz tick (`vsync` cvar forced on in `src/nhllegacy_app.h:255`); a frame that misses the tick waits for the next one. This PC produces frames in roughly 17–25 ms, right at the edge, so it flips between the two. Supersampling is not the cause: no `nhl_enhancements.ini` exists, so the scale is the default 1x. | INFERRED |
| Audio stutter in play | Fits the port's own comment that uneven frame pacing starves the audio queue (`src/nhllegacy_app.h:224`, "pops/crackle"). No audio warnings are logged. | INFERRED |
| Menu scroll sound wrong | Reported again, more firmly. Nothing in the log. Now treated as a real defect rather than a maybe. | VERIFIED symptom, UNKNOWN cause |
| Save | A rule setting was changed and saved. The log shows the game first reaching the save functions (`XamContentCreateInternal`) at 21:26:11. Whether the setting survives a relaunch was not checked. | UNKNOWN |

What this changes in the plan: steady frame pacing matters more than a higher average. A locked 30 fps would feel better than an average of 40 that swings. That moves task 6.4 (separate game timing from display rate) and a possible in-game frame cap ahead of raw speed work, and makes task 6.1 measure frame-time consistency, not only the average.

#### Third session — 2026-11-17, from 22:22 (same teams, V-Sync off for this launch only via `NHL_VK_NO_VSYNC=1`)

Log: `F:\Games\NHL Legacy\logs\nhllegacy_003.log` (figures below taken while the game was still running, at 22:40).

| Question | Result | Label |
|---|---|---|
| Startup | Rebuilding the 324 saved pipelines took about 38 s (22:22:37 → 22:23:15) against about 1 s the day before; Windows briefly marked the window "not responding". | VERIFIED; cause UNKNOWN (possibly the driver's own cache was cleared) |
| Menus | Uncapped at about 480–670 fps. | VERIFIED |
| First period | Player: no stutter, normal game speed. Log: per-minute averages 54–63 fps, worst single seconds 21–52 fps, two short stalls (1.7 s, 1.8 s) right at the start. | VERIFIED |
| Second period | Player: lag and steady hiccups, "almost unplayable". Log: per-minute averages fell to 49–59 fps and worst seconds to 21–41 fps, with no stall over 1.6 s. The per-second log is milder than what the player felt. | VERIFIED |
| Is it heat? | At 22:40, mid-lag: GPU 51 °C, 48% busy, 1860 MHz, no throttle reasons reported by `nvidia-smi`. CPU temperature not measured. | VERIFIED for the GPU at that moment |
| Is another program competing? | Over 5 s: the game used about 5 of 8 CPU cores; nothing else used more than 0.75 of a core. Total CPU 61–77%. | VERIFIED |
| Memory | Game at 1.7 GB working set after 18 minutes; 36 GB of system RAM free. One sample only, so growth is unknown. | VERIFIED snapshot, growth UNKNOWN |
| Saves | Player: the rule setting changed in session two was still set after relaunching. | VERIFIED by the player |
| Audio | Blips and bleeps during play, and clearly when scrolling menu options. Present with V-Sync on and off, so it is not only a frame-pacing effect. | VERIFIED symptom, cause UNKNOWN |

What this suggests (INFERRED, to be tested):
- V-Sync on/off is not the root problem; switching it off removed the 30/60 flip and made the first period smooth.
- The game appears to run its simulation in step with frames. Below 60 fps it may run in slow motion rather than skip frames, which would feel like "lag" even when the fps number looks acceptable. That would make holding 60 fps the real requirement.
- Both full-length sessions got worse late in the game (session one in its last minute, session three in the second period). Something may build up over a game: memory, replay data, or growing per-frame work. The per-second log averages hide hitches shorter than a second, so the next measurement needs per-frame times.

Not yet covered by any session: keyboard play, any mode other than a single exhibition game, on-screen fps from the overlay, screenshots, per-frame timing, memory growth over a full game, CPU temperature.

#### Fourth session — 2026-11-18, 22:06–22:32 (release exe, fresh save/cache folders on F:, V-Sync on, full game)

Launched with `F:\devtools\sticktoss\7_run_release_fdata.bat` (original v0.6.0 exe and runtime; `--user_data_root` / `--cache_root` under `F:\devtools\abtest\data-E-release-fdata`). Log: `F:\Games\NHL Legacy\logs\nhllegacy_004.log` (written only when the game closes).

| Question | Result | Label |
|---|---|---|
| Intro EA logo | Clean, no flashing. Our own build flashes here with the same fresh setup, so the flashing comes from our build, not the setup (see Milestone 1 problems table). | VERIFIED by the player |
| Whole game | Played to the end. Fine until late in the third period, then stutter grew until "pretty unplayable" — the same late-game pattern as sessions one and three. | VERIFIED by the player |
| Frame rate | V-Sync on: per-minute averages 29–50 fps all game (30/60 flipping, as in session two). | VERIFIED |
| Late-game hitches | From 22:28 on, single seconds drop to 2.6–13.6 fps (stalls of 85–386 ms) **about every 31–35 s** (22:28:53, 22:29:24, 22:29:54, 22:30:33, 22:31:09, 22:31:45), with extra ones in between. No log message coincides with them, and shader-pipeline creation is not involved (only 10 built in that whole minute). | VERIFIED timing, cause UNKNOWN |
| Memory | 2.0 GB private / 1.7 GB working set after 26 minutes; 61 threads, 1392 handles. | VERIFIED snapshot |
| Movie helper | No leftover ffmpeg processes; 25 spawns over the session. Not a process leak. | VERIFIED |
| Replay data | The game's cache file `highlights.sav` ended the session at 51 MB (`cache\guest\`). Whether it is written repeatedly during play — and grows — is not known. | VERIFIED size, role UNKNOWN |

What this suggests (INFERRED): the late-game problem is a periodic stall (~every 30 s) that appears or worsens as a game goes on — something the game repeats on a timer whose cost grows (candidates: highlight/replay recording into `highlights.sav`, a growing in-memory list, a periodic flush in the runtime). Next measurement: a passive monitor run alongside a full game that samples every second the game's disk read/write bytes, CPU, memory and `highlights.sav` size/time, then line it up against the per-second fps log.

### Milestone 1 — Builds reliably

| Task | Files | Diff. | Risk | Verify |
|---|---|---|---|---|
| 1.1 Install LLVM/Clang 20+, the Vulkan SDK, and either VS 2022 Build Tools or adapt the scripts to VS 18 | `BOOTSTRAP.md` | S | C: has ~21 GB free; install to another drive where possible | `clang --version`, `cmake --version`, `ninja --version` work in a new terminal |
| 1.2 Make `_env.bat` locate Visual Studio with `vswhere` (any version) and make the FidelityFX generator configurable | `scripts/_env.bat`, `scripts/_ffx_dll_build.bat` | S–M | FidelityFX's own build may not accept a newer VS | `scripts\_env.bat` succeeds; FidelityFX DLL builds |
| 1.3 Add the third SDK patch to setup, after checking it applies | `scripts/setup_sdk.ps1`, `sdk/rexglue-vp6-sharedmem-fixes.patch` | M | It may conflict with the main patch and need regenerating | `setup_sdk.ps1` prints "applied" for all three |
| 1.4 Stop hard-coding the XEX path in a tracked file (environment variable or an untracked local file) | `nhllegacy_manifest.toml`, `scripts/`, `.gitignore` | S | Depends on what the codegen tool accepts | Codegen runs with no edits to tracked files |
| 1.5 First full build, following `BOOTSTRAP.md`; save the complete log | all `scripts/_ffx_*.bat`, `scripts/_game_ffx_build.bat` | M | Long compile (millions of generated lines); new errors on a newer compiler | `out\build\win-amd64-vk-ffx\nhllegacy.exe` exists and boots to the menu |
| 1.6 Fix the line-ending noise | `.gitattributes`, the two script files | S | None | `git status` is clean after a fresh clone |
| 1.7 Make the retired renderers optional and off by default | `CMakeLists.txt` | M | The D3D12 fallback shares code with them | Build succeeds with `third_party/plume` absent |
| 1.8 One bootstrap script and a CMake preset for the canonical build; update the docs | `scripts/`, `CMakePresets.json`, `BOOTSTRAP.md`, `DEV-README.md` | M | Low | A second clean clone builds from one command |
| 1.9 Optimized and PGO builds | `scripts/_build_vk_opt.bat`, `_build_vk_pgogen.bat`, `_build_vk_pgo.bat` | M | Profile must be re-recorded after changes | fps matches or beats the upstream release in the same scene |

#### First build on this PC — 2026-11-17 (tasks 1.1, 1.3 and 1.5 done in a local form)

The dev build (`out\build\win-amd64-vk-ffx\nhllegacy.exe`, RelWithDebInfo) compiled, booted on the RTX 2070 with the `fsi` path, and ran the menus at 30.0 fps, matching the release. VERIFIED from the logs below.

**Constraint from the owner:** nothing installed on, or scanned from, C:. So the toolchain avoids Visual Studio and the LunarG Vulkan SDK entirely:

| Piece | What is used | Where |
|---|---|---|
| Compiler, linker, resource compiler | LLVM 22.1.8 official release archive (clang, lld, llvm-rc) | `F:\devtools\llvm` |
| C/C++ runtime + Windows SDK headers and libraries | Fetched from Microsoft by `xwin` 0.10.0 (Microsoft license accepted by the owner 2026-11-17) | `F:\devtools\msvc` (809 MB) |
| CMake / Ninja | 3.31.11 / 1.13.2 portable | `F:\devtools\cmake`, `F:\devtools\ninja` |
| Python (glslang and SPIRV-Tools generate code with it) | 3.12.10 embeddable | `F:\devtools\python` |
| Vulkan SDK | Not needed: the SDK vendors Vulkan headers and only checks for the LunarG SDK on non-Windows (`cmake/rexglue_fidelityfx.cmake`) | — |
| FidelityFX DLL | The v0.6.0 release's `amd_fidelityfx_vk.dll` plus an import library made with `llvm-dlltool` (5 exports: `ffxConfigure`, `ffxCreateContext`, `ffxDestroyContext`, `ffxDispatch`, `ffxQuery`). Avoids the Visual Studio generator the FFX build requires. | `third_party\rexglue-sdk\out\ffx-prebuilt\vk` |
| Libraries CMake would download with Git | Pre-cloned at the pinned versions (glslang 14.3.0, FidelityFX `eee08db`, plume's `dxc-bin` `7810655`) and passed as `FETCHCONTENT_SOURCE_DIR_*`, so CMake needs no Git | `F:\devtools\src` |
| Environment | `F:\devtools\env.bat`: clean PATH (F:\devtools plus Windows system folders), `INCLUDE`/`LIB` pointing at `F:\devtools\msvc`, `TEMP`/`TMP` at `F:\devtools\tmp` | — |
| Step scripts | `F:\devtools\sticktoss\1_sdk_configure.bat`, `2_sdk_build_install.bat`, `3_codegen.bat`, `4_game_build.bat`, `5_run_dev.bat` (mirror the repo's `scripts\_ffx_*` / `_game_ffx_build.bat` with the changes above) | — |

Timings on the i7-9700: SDK Release + RelWithDebInfo build and install 19.5 min; codegen 14.9 min (186 files, 373 MB); game build 8.6 min (284 steps). Defender scan of `F:\devtools`: no detections. Full logs in `F:\devtools\sticktoss\*.log`.

**Problems found on the way, and their fixes (made in the working tree 2026-11-18, not committed):**

| Problem | Evidence | Fix made | Label |
|---|---|---|---|
| A fresh clone of the SDK does not contain the pinned commit | `fatal: reference is not a tree: bd9b5191…`; the SDK's default branch is now at v0.11.0 and no branch or tag contains the pin. `git fetch origin <sha>` still works. | `scripts/setup_sdk.ps1` fetches the pin by SHA when it is missing | VERIFIED problem; fix tested only on an existing checkout |
| SDK patches fail to apply after a normal Windows clone | `git apply --check` fails on all three; the `.patch` files are checked out with CRLF (`core.autocrlf=true`). The LF blobs from git apply cleanly. | `.gitattributes`: `*.patch -text`; `setup_sdk.ps1` also applies an LF-normalized copy (in `out\sdk-patches-lf`) | VERIFIED |
| `setup_sdk.ps1` aborts instead of reporting under Windows PowerShell 5.1 | `git apply --check $p 2>$null` with `$ErrorActionPreference = "Stop"` turns git's stderr into a terminating error | Probe calls go through `Invoke-GitQuiet`, which relaxes the error preference and returns the exit code. Re-run reports all three patches "already applied - OK". | VERIFIED |
| Third patch (`rexglue-vp6-sharedmem-fixes.patch`) conflicts with the title patch | It is a superset of the title patch for five files. Its extra content: `NHL_VP6_LAST_OPEN` in `xboxkrnl_io.cpp` (needed by the movie bridge), two shared-memory files, a `TRANSFER_DST` buffer flag for movie textures, and an `NHL_VP6_TAP` debug log. | New `sdk/rexglue-vp6-bridge-delta.patch` (5 files, 13 hunks) generated on top of pin + title patch + bcctr fix; `setup_sdk.ps1` applies it third (task 1.3). The old file is kept for history. | VERIFIED |
| Builds needed Visual Studio 2022 and the Vulkan SDK on C: | `scripts/_env.bat` searched only VS 2022 paths and `C:\VulkanSDK` | New `scripts/setup_toolchain.ps1` (portable toolchain in one folder, SHA-256-checked downloads, `-AcceptMicrosoftLicense` for xwin) writes git-ignored `scripts/_env.local.bat`; `_env.bat` then uses the portable toolchain and sets `EXTRA_CMAKE_ARGS`, which every configure script now appends. The Visual Studio route is unchanged. | VERIFIED (re-run against existing `F:\devtools`; a fresh-folder run is not yet tested) |
| FidelityFX needed the Visual Studio generator | `scripts/_ffx_dll_build.bat` hard-codes `Visual Studio 17 2022` | New `scripts/_ffx_import_prebuilt.bat <dll>` stages an existing DLL and makes its import library with LLVM | VERIFIED |
| XEX path hard-coded in the tracked manifest (task 1.4) | `nhllegacy_manifest.toml` pointed at `c:/users/alex/...` | New `scripts/_codegen.bat` writes git-ignored `nhllegacy_manifest.local.toml` from `NHL_GAME_DIR` and runs codegen on it. The tracked manifest is back to its original content. | VERIFIED |
| The dev build exits at launch with "amd_fidelityfx_vk.dll was not found" | Windows error dialog on first run | `CMakeLists.txt` copies the DLL next to the exe after each link | VERIFIED (the optimized build got the DLL automatically) |
| **Every UI string in the dev build used the wrong glyphs** (e.g. the autosave notice read "O22N HONO EL…") | A/B boots 2026-11-17 with fresh profiles: release exe + release runtime = correct; release exe + our runtime = correct; our exe = garbled. So the fault is in the game executable. Its generated code was compiled with `-O2 … -msse4.1` only; the SDK compiles itself with `-fno-strict-aliasing -ffp-model=strict` but `add_compile_options` does not reach the consumer project. | `CMakeLists.txt`: `target_compile_options(nhllegacy PRIVATE -fno-strict-aliasing -ffp-model=strict)` | VERIFIED symptom, A/B and fix (2026-11-18: the player confirmed normal text in the optimized build). |
| **Intro EA logo flashes / glitches in our builds** (dev and optimized, every launch) | Same code as v0.6.0 (`master` = tag `v0.6.0` = `0852183`). Release exe + release runtime with fresh F: data = clean (2026-11-18, fourth session), so the setup is not the cause. The movie bridge decodes identically in both (`vp6_bridge.txt` frame counts match). Both SDK movie fixes (in-place page-state clear, upload re-copy loop) are in our runtime. The release `rexruntime.dll` was built from the original developer's private SDK tree (it has `NHL_SSAO*`, `NHL_SHADER_TINT*`, `NHL_RIM_*`, `NHL_DEPTH_*` settings ours lacks), so the runtimes differ substantially. A/B boots 2026-11-18 (release exe throughout, fresh F: data): release runtime = clean; our runtime = flashes; our runtime with the three newer movie changes switched back to v0.6.0 behaviour = clean; with only the per-frame page-state reset switched back = flashes; with only the upload **re-copy loop** off = clean. So the culprit is the "re-copy until two passes match" loop in `VulkanSharedMemory::UploadRanges` (it also read back from GPU-visible upload memory on every upload). | `sdk/rexglue-vp6-bridge-delta.patch` regenerated without the loop (single copy, as in v0.6.0; the env-gated `NHL_VP6_SM` torn-upload diagnostic is kept). Runtime and optimized build rebuilt 2026-11-18. | VERIFIED cause by A/B; fix VERIFIED (player saw a clean logo in the rebuilt optimized build, 2026-11-18) |
| Flashing during the first boot | Seen in all three A/B boots, including the untouched release | Most likely the empty shader cache in each fresh test profile (pipelines are built while drawing). Should stop on the second launch of the same profile. | INFERRED |
| SDK version shows as `0.8.0.0-dev.unknown` instead of `0.8.1.31-dev.gbd9b519` | Window title; codegen rewrites `sdk_version` in the manifest it reads. Cause: no Git inside the CMake environment, so `rex_version.cmake` falls back. Cosmetic. | Not fixed. Options: portable Git in the toolchain folder, or pass the version | VERIFIED cause |
| The SDK install writes a CMake "user package registry" value | `cmake/rexglue_install.cmake` runs `reg add HKCU\Software\Kitware\CMake\Packages\rexglue` unconditionally (no CMake option turns it off) | Not fixed; documented in `BOOTSTRAP.md` | VERIFIED |
| `tdb-rx2-ffi` missing | CMake warning; loose `.dds` texture overrides disabled. Expected per `BOOTSTRAP.md`. | None needed for the phase-1 goal | VERIFIED |

**Builds made with the repo's own scripts (2026-11-18, 24 min end to end):** `_ffx_import_prebuilt` → `_ffx_sdk_configure` → `_ffx_sdk_build_install` → `_codegen` → `_build_vk_opt configure` → `_build_vk_opt`. Output: `out\build\win-amd64-vk-opt\nhllegacy.exe` (-O3, `-march=x86-64-v3`, ThinLTO, plus the two safety flags; links the Release `rexruntime.dll`). Not yet launched. Not PGO, so it may still be slower than the v0.6.0 release (INFERRED).

The dev build (`out\build\win-amd64-vk-ffx`, RelWithDebInfo) keeps its saves and shader cache in `F:\devtools\devbuild-data`; the optimized build's run script (`F:\devtools\sticktoss\6_run_opt.bat`) uses `F:\devtools\optbuild-data`. Both via `--user_data_root` / `--cache_root`.

### Milestone 2 — Boots and plays

| Task | Files | Diff. | Risk | Verify |
|---|---|---|---|---|
| 2.1 Write a test checklist covering every menu and mode | new `docs/test-matrix.md` | S | None | Checklist exists and is filled in once |
| 2.2 Turn on crash capture | `tools/enable_crash_dumps.ps1`, `tools/parse_minidump.py`, `nullcall_ctx.txt` output from `src/diag_hooks.cpp` | S | None | A forced crash produces a dump and a context file |
| 2.3 Reproduce and fix the tutorial crash | `nhllegacy_functions.toml`, `tools/annotate_guest_stacks.py` | M | Cause unknown until reproduced | Tutorial completes |
| 2.4 Sweep for unregistered functions before they crash | `tools/find_missing_indirect_targets.py`, `tools/find_missing_materialized_targets.py`, `tools/missing_targets.toml`, `nhllegacy_functions.toml` | M | False positives register non-functions | Tools report no new candidates; game still boots |
| 2.5 Add a diagnostic mode that logs an unregistered call and continues, for finding several in one session | SDK patch | M | Must never be on in a release build | One play session lists all misses instead of dying on the first |
| 2.6 Scripted boot check | `tools/smoke_boot.ps1` | S | Low | Script returns success on a good build and failure on a broken one |

### Milestone 3 — Input and saves

| Task | Files | Diff. | Risk | Verify |
|---|---|---|---|---|
| 3.1 Controller test: Xbox pad, second pad, unplug/replug, vibration | none (test only), `input_backend` cvar | S | None | All pass, or each failure is written up |
| 3.2 Keyboard play: enable the SDK driver, design hockey bindings (the game leans on the right stick for shots and dekes, so it needs keys, not the mouse), add an overlay section, save to the settings file | `src/nhllegacy_app.h`, `renderer/core/nhl_overlay.cpp`, `renderer/core/nhl_settings.h`, `src/input_block.cpp` | M | Analog skill-stick moves are awkward on keys; some may stay impractical | A full period played on keyboard only |
| 3.3 Save test: settings, profile, roster edit, Be A Pro, GM mode — save, exit, relaunch, load | none (test only) | S | None | Every save type round-trips |
| 3.4 Make exiting safe: refuse or delay "Exit Game" while a save is being written, or fix the hang in normal shutdown | `src/nhllegacy_app.h` (`on_exit`), SDK content code | M–L | The shutdown hang is inside the SDK | Exiting during a save never leaves a partial file |
| 3.5 Document where saves live and how to back them up | `README.md` | S | None | Instructions tested by restoring a backup |

### Milestone 4 — Graphics, textures and movies correct

| Task | Files | Diff. | Risk | Verify |
|---|---|---|---|---|
| 4.1 Settle the jersey-number and lighting items with side-by-side screenshots against a reference | `docs/current-status.md` | S | Needs a trusted reference (console capture or emulator) | Docs agree with each other and with the screenshots |
| 4.2 Visual sweep of every arena, team, camera, replay and menu | `scripts/_vkshot.ps1`, `tools/parity_diff.py` | M | Time-consuming | No missing, black or corrupted textures in the checklist |
| 4.3 Replace the size-based readback rule with one keyed on what the surface is | `src/nhllegacy_app.h`, `sdk/` patch (Vulkan resolve path) | L | Easy to regress equipment textures | Equipment correct at 1x and 2x; no size threshold in the code |
| 4.4 Movies correct in a from-source build | task 1.3, `src/vp6_bridge.cpp`, `release/fetch_ffmpeg.ps1` | S–M | Uncovered movie format | Intro, menus and arena scoreboard play cleanly |
| 4.5 Clear error on GPUs without FSI | `src/nhllegacy_app.h` or `renderer/core/nhl_vk_backend.cpp` | S | Low | Message box instead of a black rink |
| 4.6 Fix the recompiler's movie-decoder arithmetic bug at the source | SDK codegen | L | Deep recompiler work | Movies correct with `NHL_VP6_BRIDGE=0` |

### Milestone 5 — Full playthrough stable

| Task | Files | Diff. | Risk | Verify |
|---|---|---|---|---|
| 5.1 Complete games: regulation, overtime, shootout | test matrix | M | Finds new crashes (feeds 2.4) | Three full games with no crash |
| 5.2 Long modes: a simulated season in GM mode, a Be A Pro stretch, playoffs | test matrix | L | Calendar time | Each reaches its end screen |
| 5.3 Soak test: four hours, watch memory and frame time | overlay perf panel, Task Manager | S | None | No growth trend, no crash |
| 5.4 Clean shutdown | SDK | L | Inside the SDK | Closing the window exits without a kill and without a hang |

### Milestone 6 — Performance

| Task | Files | Diff. | Risk | Verify |
|---|---|---|---|---|
| 6.1 Measure on this PC in fixed scenes (menu, faceoff, scrum in front of the net, replay) | `scripts/_vkfps.ps1`, `[nhl-vk-fps]` log lines | S | None | Table of fps and draws per frame |
| 6.2 Record a PGO profile on this PC | task 1.9 | M | Stale after code changes | Gain measured in the same scenes |
| 6.3 Cut the readback wait | builds on 4.3 | L | Texture regressions | Lower frame time with equipment still correct |
| 6.4 Separate game timing from display rate so V-sync is a choice, not a requirement | `src/nhllegacy_app.h`, guest timing code | L | Guest-side reverse engineering | Menus animate at normal speed with V-sync off |
| 6.5 Multi-threaded command recording | SDK | L | Previously deferred as high-risk | Only if 6.2–6.3 are not enough |
| 6.6 Remove first-run shader freezes (added 2026-11-16 from the baseline test). First confirm with a second session that stored pipelines are rebuilt at startup. If first-run freezes still matter, options are: ship a pre-recorded pipeline list with the install, or check why the SDK's background pipeline threads (`vulkan_pipeline_creation_threads`) do not prevent the stall | SDK `src/graphics/vulkan/pipeline_cache.cpp`, `src/nhllegacy_app.h` | S to confirm, M–L to fix | A shipped list goes stale when shaders change | A fresh install plays its first game with no gap over 0.5 s between `[nhl-vk-fps]` lines |

**Done for this phase** = milestones 1–5 pass their checks, and milestone 6 holds 60 fps in the dense scene on the i7-9700 + RTX 2070 at native resolution.

---

## 6. Future-proofing notes

Nothing here is to be built in this phase. These are choices to make carefully while doing the work above.

| Area | What makes later work harder | How to keep the path open |
|---|---|---|
| Resolution scaling | The equipment-texture workaround decides by byte size (3 MB), which only makes sense at 720p. Above 2x the scaled buffer exceeds a 4 GB GPU limit and equipment goes black, hence the 2x cap in `OnPreSetup`. | Task 4.3: identify the composited surfaces by identity, not size. Keep the scale factor in one place. |
| Resolution scaling | Scale is whole numbers only (`draw_resolution_scale_x/y`), and the window default of 1920×1080 is written into `OnPreSetup`. | Move window size and scale into the settings file; do not add more fixed sizes. |
| Renderer path | The accurate "fsi" path does per-pixel work that grows with resolution, and the cheaper host-render-target path draws the 3D scene black. | Treat fixing the host-render-target path as a future option; do not add fixes that only work on fsi without noting it. |
| Widescreen / ultrawide | No aspect-ratio handling exists. The game is 16:9 already; wider needs changes to the game's own camera and HUD code. | Put any guest-code patch in its own small hook with its address in one table, switchable at run time. |
| Frame rate | Menu timing is tied to display rate, which is why V-sync is forced. | Task 6.4. Do not add other fixes that assume 60 Hz. |
| Texture replacement | The loose-file layer exists (`UnionDevice`, `LooseTreeDevice`), but `.dds` conversion needs a library from a private repo, and the hash-based texture matching (`src/injection_registry.cpp`) was only wired to the retired D3D12 path. | Keep the loose-file overlay working in every build; plan to replace or publish the converter; when touching the texture cache, leave a hook point where a texture's identity is known. |
| Texture replacement | Equipment textures are assembled on the GPU at run time, so there is no single file to swap. | Replace the source layers, not the result; note this limit in mod docs. |
| Archives | `.big` files cannot be repacked. | The loose overlay is the modding route; do not depend on repacking. |
| SDK coupling | Three patch files against one pinned commit, one of them not applied. Every SDK update risks all three. | Keep the SDK changes as a fork branch with separate commits per fix, and offer generic fixes upstream. |
| Shader cache | Cached shaders can be stale after translator changes. | Bump the cache version whenever a shader-affecting patch changes; document how to clear the cache. |
| Dead code | Two retired renderers still compile into the exe. | Task 1.7. |
| Settings | Several settings need a restart and live in a file beside the exe. | Fine for now; avoid adding more restart-only settings without need. |

---

## 7. Quick wins

1. Validate the disc image with the upstream builder (task 0.1). Minutes, and it settles the largest unknown.
2. Play the upstream v0.6.0 release and write down what is wrong (tasks 0.2–0.3).
3. Fix the line-ending noise (task 1.6).
4. Add the missing patch to `scripts/setup_sdk.ps1` once it is confirmed to apply (task 1.3).
5. Make `scripts/_env.bat` find any Visual Studio version (task 1.2).
6. Stop requiring edits to `nhllegacy_manifest.toml` (task 1.4).
7. Try keyboard play today with no code change by launching with `--mnk_mode=true` (INFERRED: cvars are accepted on the command line the same way `--game_data_root` is). This shows how far the SDK's driver gets before any design work.
8. Update `docs/current-status.md` so it stops contradicting the other docs (jersey numbers, lighting, movie status, which build is canonical).
9. Add an FSI check with a clear message (task 4.5).
10. Delete the stray `build_out.txt` and `guest_stacks.txt` from the repo root, or move them under `docs/`.

---

## 8. Open questions

1. ~~May the upstream v0.6.0 release zip be downloaded to validate your disc image?~~ Answered and done 2026-11-16; the image is supported.
2. ~~Where should the baseline install of the upstream release go?~~ Answered 2026-11-16: installed to `F:\Games\NHL Legacy` (18.6 GB).
3. Install Visual Studio 2022 Build Tools alongside VS 18, or adapt the scripts to VS 18? The first is the low-risk route; the second avoids another large install on a nearly full C: drive.
4. Which drive should hold the toolchain and build output? C: has about 21 GB free; F: has about 141 GB.
5. What does "full speed" mean to you: 60 fps like the menus, or the original console's rate during play? What display resolution and refresh rate?
6. Which controller do you use, and how important is keyboard play in practice (full parity, or just "possible")?
7. Which modes matter most for "start to finish": a single game, a season, Be A Pro, GM mode?
8. Do you have a way to capture reference footage (a real Xbox 360, or the PS3 copy already on this PC running under an emulator) for visual comparisons?
9. Should fixes be offered back to `puckhead73/nhl-legacy-recomp`, or kept in this fork?
