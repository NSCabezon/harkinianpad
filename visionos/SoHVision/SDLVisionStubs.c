// Symbols SDL2 expects from its UIKit video backend, which is compiled out on
// visionOS (SDL_VIDEO=OFF). SDL.c's SDL_IsTablet() still references it.
// TODO: move into the engine build (SDL patch) and delete this file.
typedef enum { SDLStub_FALSE = 0, SDLStub_TRUE = 1 } SDLStub_bool;

SDLStub_bool SDL_IsIPad(void) {
    return SDLStub_FALSE;
}
