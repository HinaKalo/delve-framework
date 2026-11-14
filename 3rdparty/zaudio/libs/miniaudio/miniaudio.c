/* Patched for Delve: enables Ogg Vorbis decoding via stb_vorbis. See ../../VENDORED.md. */
#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

/* stb_vorbis implementation must come after miniaudio so its macros (L, R, C, ...) don't clash. */
#undef STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"
