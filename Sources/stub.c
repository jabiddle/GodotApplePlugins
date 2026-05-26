#include <stdint.h>

// Minimal Godot GDExtension export macro for Windows
#if defined(_WIN32)
#define GDE_EXPORT __declspec(dllexport)
#else
#define GDE_EXPORT
#endif

// This forces the compiler to use C-style naming, preventing name mangling
#ifdef __cplusplus
extern "C" {
#endif

// The function name must exactly match 'godot_apple_plugins_start'
uint8_t GDE_EXPORT godot_apple_plugins_start(void *p_get_proc_address, void *p_library, void *r_initialization) {
    return 1; // Tell Godot the initialization was "successful"
}

#ifdef __cplusplus
}
#endif