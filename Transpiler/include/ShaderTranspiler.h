#ifndef SHADER_TRANSPILER_H
#define SHADER_TRANSPILER_H

#ifdef __cplusplus
extern "C" {
#endif

/// Initializes the glslang process. Call once before compiling. Returns 0 on success.
int st_initialize(void);

/// Tears down the glslang process.
void st_finalize(void);

/// Compiles a GLSL 450 (Vulkan flavor) fragment shader to Metal Shading Language.
///
/// On success returns 0, sets *out_msl to the MSL source and
/// *out_reflection_json to a JSON description of the shader's resources:
///
///   {
///     "entryPoint": "main0",
///     "textures": [
///       {"name": "uPrev", "binding": 0, "mslTexture": 0, "mslSampler": 0, "dim": "2d"}
///     ],
///     "uniformBlocks": [
///       {"name": "Params", "binding": 3, "mslBuffer": 1, "size": 16,
///        "members": [{"name": "amount", "type": "float", "offset": 0}]}
///     ]
///   }
///
/// mslTexture / mslSampler / mslBuffer are the automatically assigned Metal
/// argument indices; a value of -1 means the resource was optimized away and
/// must not be bound.
///
/// On failure returns nonzero and sets *out_log to the compiler log
/// (glslang format, e.g. "ERROR: 0:12: ..." where 12 is a 1-based line number).
///
/// All returned strings must be released with st_string_free.
int st_compile_fragment(const char* glsl_source,
                        char** out_msl,
                        char** out_reflection_json,
                        char** out_log);

/// Shader stages accepted by st_compile.
enum {
    ST_STAGE_FRAGMENT = 0,
    ST_STAGE_VERTEX = 1,
};

/// Same as st_compile_fragment, for the stage given by `stage`
/// (ST_STAGE_FRAGMENT or ST_STAGE_VERTEX). The reflection JSON has the same
/// shape; its Metal indices refer to that stage's argument tables.
int st_compile(const char* glsl_source,
               int stage,
               char** out_msl,
               char** out_reflection_json,
               char** out_log);

void st_string_free(char* str);

#ifdef __cplusplus
}
#endif

#endif /* SHADER_TRANSPILER_H */
