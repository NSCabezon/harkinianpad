#pragma once

// Entry point of libSoHEngine.a (soh/src/code/main.c, __VISIONOS__).
// Calls SDL_SetMainReady() and SoH's SDL_main; blocks for the life of the game.
#ifdef __cplusplus
extern "C" {
#endif

int SoHEngine_Main(int argc, char** argv);

#ifdef __cplusplus
}
#endif
