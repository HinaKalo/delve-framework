# Vendored zaudio

- Upstream: https://github.com/zig-gamedev/zaudio.git
- Commit: `8d0d7ebffe9008019134b3d202eabc5476aca3a4` (package `zaudio-0.11.0-dev`)
- License: MIT (zaudio, miniaudio is public domain / MIT-0, stb_vorbis is public domain / MIT)
- Copied: `build.zig`, `build.zig.zon`, `README.md`, `libs/`, `src/` (unchanged except below).

## Local patches

1. `libs/miniaudio/miniaudio.c` now wraps the miniaudio implementation with stb_vorbis, using
   miniaudio's documented pattern (stb_vorbis header first, then miniaudio implementation, then the
   stb_vorbis implementation). Upstream only had `#define MINIAUDIO_IMPLEMENTATION` + include, so
   `MA_HAS_VORBIS` was never defined and only WAV/FLAC/MP3 decoded. Now Ogg Vorbis (`.ogg`) decodes too.
2. `libs/miniaudio/stb_vorbis.c` added (stb_vorbis v1.24, from https://github.com/nothings/stb,
   public domain / MIT). Lives next to miniaudio.c so no extra include path is needed.

`build.zig` is unchanged. The `system_sdk` dependency in `build.zig.zon` is only used (lazily) for macOS builds.

## Updating

Re-copy the upstream package, then re-apply patches 1 and 2.
