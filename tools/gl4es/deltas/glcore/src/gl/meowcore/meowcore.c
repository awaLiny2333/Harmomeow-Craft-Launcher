/*
 * Meowcraft GL3 core backend (GL 3.2/3.3 core -> native GLES 3.2).
 * See meowcore.h. Lives in the gl4es fork delta (tools/gl4es/deltas/glcore).
 *
 * Slice 1: mode selection, GLES resolution, glGetString / glGetStringi /
 *          glGetIntegerv patching, table-driven GetProcAddress.
 * Slice 2: shader translation — intercept glCreateShader/glShaderSource, rewrite
 *          GLSL 150/330 to ESSL 320 via shaderc (glslang) + SPIRV-Cross, both
 *          dlopen()ed at runtime so this library keeps DT_NEEDED = libc only.
 *
 * Self-contained on purpose: it must NOT include gl4es' desktop-GL headers.
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "meowcore.h"
#include "shaderc/shaderc.h"
#include "spirv_cross_c.h"

/* --- minimal GL/GLES types + enums ------------------------------------- */
typedef unsigned int   mc_enum;
typedef unsigned int   mc_uint;
typedef int            mc_int;
typedef unsigned char  mc_ubyte;
typedef const mc_ubyte *mc_string;
typedef char           mc_char;

#define MC_GL_VENDOR                   0x1F00
#define MC_GL_RENDERER                 0x1F01
#define MC_GL_VERSION                  0x1F02
#define MC_GL_EXTENSIONS               0x1F03
#define MC_GL_SHADING_LANGUAGE_VERSION 0x8B8C
#define MC_GL_MAJOR_VERSION            0x821B
#define MC_GL_MINOR_VERSION            0x821C
#define MC_GL_NUM_EXTENSIONS           0x821D

#define MC_GL_VERTEX_SHADER   0x8B31
#define MC_GL_FRAGMENT_SHADER 0x8B30
#define MC_GL_COMPILE_STATUS  0x8B81
#define MC_GL_LINK_STATUS     0x8B82

/* desktop-only enums MC uses that ES does not have (see the emulation below) */
#define MC_GL_PROXY_TEXTURE_2D   0x8064
#define MC_GL_TEXTURE_WIDTH      0x1000
#define MC_GL_TEXTURE_HEIGHT     0x1001
#define MC_GL_TEXTURE_LOD_BIAS   0x8501
#define MC_GL_MAX_TEXTURE_SIZE   0x0D33
#define MC_GL_BUFFER_SIZE        0x8764
#define MC_GL_READ_ONLY          0x88B8
#define MC_GL_WRITE_ONLY         0x88B9
#define MC_GL_READ_WRITE         0x88BA
#define MC_GL_MAP_READ_BIT       0x0001
#define MC_GL_MAP_WRITE_BIT      0x0002

/* ES 3.x only accepts SIZED depth/stencil internalformats. Desktop GL (and some
 * lenient ES drivers) also take the unsized GL_DEPTH_COMPONENT / GL_DEPTH_STENCIL
 * paired with a type. MC's RenderTarget/TextureTarget creates its depth attachment
 * exactly that way -- evidence, javap-class bytecode of 1.17.1 doy.b(IIZ) @160 and
 * dov.b(Ldov$b) @19, 1.19.4 efr/efo likewise:
 *     glTexImage2D(GL_TEXTURE_2D, 0, GL_DEPTH_COMPONENT, w, h, 0,
 *                  GL_DEPTH_COMPONENT, GL_FLOAT, NULL)
 * A strict driver (phone Maleoon, "format, type and internalformat are not a valid
 * combination") rejects it, so the attachment is never allocated and the FBO ends
 * up GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT. Sized internalformats below fix that. */
#define MC_GL_DEPTH_COMPONENT        0x1902
#define MC_GL_DEPTH_STENCIL          0x84F9
#define MC_GL_DEPTH_COMPONENT16      0x81A5
#define MC_GL_DEPTH_COMPONENT24      0x81A6
#define MC_GL_DEPTH_COMPONENT32      0x81A7  /* desktop legacy size; absent from ES */
#define MC_GL_DEPTH_COMPONENT32F     0x8CAC
#define MC_GL_DEPTH24_STENCIL8       0x88F0
#define MC_GL_DEPTH32F_STENCIL8      0x8CAD
#define MC_GL_UNSIGNED_SHORT         0x1403
#define MC_GL_UNSIGNED_INT           0x1405
#define MC_GL_FLOAT                  0x1406
#define MC_GL_UNSIGNED_INT_24_8      0x84FA
#define MC_GL_FLOAT_32_UNSIGNED_INT_24_8_REV 0x8DAD

/* Desktop-only glEnable/glDisable caps MC 1.21.10 sets which do NOT exist in the
 * ES 3.2 glEnable cap set (checked one by one against the ES 3.2 spec). Passing
 * them to the driver yields GL_INVALID_ENUM, and 1.21.10 turns any glGetError into
 * a hard crash. Caps that DO exist in ES 3.2 are deliberately NOT listed:
 * GL_DEBUG_OUTPUT_SYNCHRONOUS (KHR_debug) and GL_FRAMEBUFFER_SRGB (ES 3.0+). */
#define MC_GL_TEXTURE_CUBE_MAP_SEAMLESS 0x884F
#define MC_GL_MULTISAMPLE               0x809D
#define MC_GL_TEXTURE_2D                0x0DE1
#define MC_GL_TEXTURE_1D                0x0DE0
#define MC_GL_TEXTURE_3D                0x806F  /* target, but not an ES enable cap */
#define MC_GL_ALPHA_TEST                0x0BC0
#define MC_GL_LINE_SMOOTH               0x0B20
#define MC_GL_POLYGON_SMOOTH            0x0B41
#define MC_GL_DEPTH_CLAMP               0x864F
#define MC_GL_PRIMITIVE_RESTART         0x8F9D

typedef mc_string (*mc_pfn_GetString)(mc_enum);
typedef mc_string (*mc_pfn_GetStringi)(mc_enum, mc_uint);
typedef void      (*mc_pfn_GetIntegerv)(mc_enum, mc_int *);
typedef mc_uint   (*mc_pfn_CreateShader)(mc_enum);
typedef void      (*mc_pfn_DeleteShader)(mc_uint);
typedef void      (*mc_pfn_ShaderSource)(mc_uint, mc_int, const mc_char *const *, const mc_int *);
typedef void      (*mc_pfn_BindAttribLocation)(mc_uint, mc_int, const mc_char *);
typedef void      (*mc_pfn_TexImage2D)(mc_enum, mc_int, mc_int, mc_int, mc_int, mc_int,
                                       mc_enum, mc_enum, const void *);
typedef void      (*mc_pfn_GetTexLevelParameteriv)(mc_enum, mc_int, mc_enum, mc_int *);
typedef void      (*mc_pfn_GetTexLevelParameterfv)(mc_enum, mc_int, mc_enum, float *);
typedef void      (*mc_pfn_TexParameteri)(mc_enum, mc_enum, mc_int);
typedef void      (*mc_pfn_TexParameterf)(mc_enum, mc_enum, float);
typedef void      (*mc_pfn_ClearDepthf)(float);
typedef void      (*mc_pfn_DrawBuffers)(mc_int, const mc_enum *);
typedef void      (*mc_pfn_GetBufferParameteriv)(mc_enum, mc_enum, mc_int *);
typedef void *    (*mc_pfn_MapBufferRange)(mc_enum, int64_t, int64_t, mc_enum);
typedef void      (*mc_pfn_TexStorage2D)(mc_enum, mc_int, mc_enum, mc_int, mc_int);
typedef void      (*mc_pfn_RenderbufferStorage)(mc_enum, mc_enum, mc_int, mc_int);
typedef void      (*mc_pfn_Enable)(mc_enum);
typedef void      (*mc_pfn_CompileShader)(mc_uint);
typedef void      (*mc_pfn_GetShaderiv)(mc_uint, mc_enum, mc_int *);
typedef void      (*mc_pfn_GetShaderInfoLog)(mc_uint, mc_int, mc_int *, mc_char *);
typedef void      (*mc_pfn_LinkProgram)(mc_uint);
typedef void      (*mc_pfn_GetProgramiv)(mc_uint, mc_enum, mc_int *);
typedef void      (*mc_pfn_GetProgramInfoLog)(mc_uint, mc_int, mc_int *, mc_char *);

/* --- state ------------------------------------------------------------- */
static int  s_active = -1;   /* -1 unknown, 0 off, 1 on */
static int  s_inited = 0;
static void *s_gles = NULL;

static mc_pfn_GetString    s_realGetString;
static mc_pfn_GetStringi   s_realGetStringi;
static mc_pfn_GetIntegerv  s_realGetIntegerv;
static mc_pfn_CreateShader s_realCreateShader;
static mc_pfn_DeleteShader s_realDeleteShader;
static mc_pfn_ShaderSource s_realShaderSource;
static mc_pfn_TexImage2D    s_realTexImage2D;
static mc_pfn_GetTexLevelParameteriv s_realGetTexLevelParameteriv;
static mc_pfn_GetTexLevelParameterfv s_realGetTexLevelParameterfv;
static mc_pfn_TexParameteri s_realTexParameteri;
static mc_pfn_TexParameterf s_realTexParameterf;
static mc_pfn_ClearDepthf    s_realClearDepthf;
static mc_pfn_DrawBuffers    s_realDrawBuffers;
static mc_pfn_GetBufferParameteriv s_realGetBufferParameteriv;
static mc_pfn_MapBufferRange s_realMapBufferRange;
static mc_pfn_TexStorage2D   s_realTexStorage2D;
static mc_pfn_RenderbufferStorage s_realRenderbufferStorage;
static mc_pfn_Enable         s_realEnable;
static mc_pfn_Enable         s_realDisable;
static mc_pfn_CompileShader  s_realCompileShader;
static mc_pfn_GetShaderiv    s_realGetShaderiv;
static mc_pfn_GetShaderInfoLog s_realGetShaderInfoLog;
static mc_pfn_LinkProgram    s_realLinkProgram;
static mc_pfn_GetProgramiv   s_realGetProgramiv;
static mc_pfn_GetProgramInfoLog s_realGetProgramInfoLog;

/* GL_PROXY_TEXTURE_2D emulation (ES has no proxy targets): remember the last
 * proxy size MC asked about and answer its glGetTexLevelParameter query from it. */
static mc_int s_proxyW = 0;
static mc_int s_proxyH = 0;
static mc_int s_maxTexSize = 8192;

static void *mc_sym(const char *name)
{
    return s_gles ? dlsym(s_gles, name) : NULL;
}

int meowcore_active(void)
{
    if (s_active < 0) {
        const char *v = getenv("MEOW_GL3");
        s_active = (v && v[0] && !(v[0] == '0' && v[1] == '\0')) ? 1 : 0;
    }
    return s_active;
}

/* --- shaderc / SPIRV-Cross, dlopen'ed -------------------------------- */
typedef struct {
    void *h;
    /* shaderc */
    shaderc_compiler_t        (*compiler_init)(void);
    shaderc_compile_options_t (*options_init)(void);
    void (*options_set_auto_map_locations)(shaderc_compile_options_t, bool);
    void (*options_set_auto_bind_uniforms)(shaderc_compile_options_t, bool);
    void (*options_set_target_env)(shaderc_compile_options_t, shaderc_target_env, uint32_t);
    void (*options_set_optimization_level)(shaderc_compile_options_t, shaderc_optimization_level);
    shaderc_compilation_result_t (*compile_into_spv)(shaderc_compiler_t, const char *, size_t,
                                                     shaderc_shader_kind, const char *, const char *,
                                                     const shaderc_compile_options_t);
    shaderc_compilation_status (*result_status)(const shaderc_compilation_result_t);
    const char *(*result_error)(const shaderc_compilation_result_t);
    const char *(*result_bytes)(const shaderc_compilation_result_t);
    size_t (*result_length)(const shaderc_compilation_result_t);
    void (*result_release)(shaderc_compilation_result_t);
} mc_shaderc_t;

typedef struct {
    void *h;
    spvc_result (*ctx_create)(spvc_context *);
    void (*ctx_destroy)(spvc_context);
    spvc_result (*ctx_parse_spirv)(spvc_context, const SpvId *, size_t, spvc_parsed_ir *);
    spvc_result (*ctx_create_compiler)(spvc_context, spvc_backend, spvc_parsed_ir,
                                       spvc_capture_mode, spvc_compiler *);
    spvc_result (*compiler_create_options)(spvc_compiler, spvc_compiler_options *);
    spvc_result (*options_set_bool)(spvc_compiler_options, spvc_compiler_option, bool);
    spvc_result (*options_set_uint)(spvc_compiler_options, spvc_compiler_option, unsigned);
    spvc_result (*install_options)(spvc_compiler, spvc_compiler_options);
    spvc_result (*compile)(spvc_compiler, const char **);
} mc_spvc_t;

static mc_shaderc_t s_sc;
static mc_spvc_t    s_spvc;
static int          s_tools_tried = 0;
static int          s_tools_ok = 0;
static shaderc_compiler_t  s_compiler;
static shaderc_compile_options_t s_options;      /* target env = OpenGL (proven path) */
static shaderc_compile_options_t s_options_vk;   /* fallback: target env = Vulkan */

#define MC_LOAD(dst, h, sym) do { *(void **)(&(dst)) = dlsym((h), (sym)); \
    if ((dst) == NULL) { fprintf(stderr, "[meowcore] missing symbol %s\n", (sym)); return 0; } } while (0)

/* Our translation libraries ship next to libgl4es.so in the HSP libs dir, but a bare
 * dlopen(name) does NOT find them there (the app's loader namespace does not put that
 * dir on the search path -- measured: "Error loading shared library
 * /system/lib64/libspirv-cross.so: No such file"). Resolve them relative to our own
 * loaded image instead, using dladdr; fall back to the bare name and then /system/lib64. */
static void *mc_dlopen_colocated(const char *name)
{
    Dl_info info;
    char path[1200];
    void *h = dlopen(name, RTLD_NOW | RTLD_LOCAL);
    if (h) return h;
    if (dladdr((void *)&mc_dlopen_colocated, &info) && info.dli_fname != NULL) {
        const char *slash = strrchr(info.dli_fname, '/');
        if (slash != NULL) {
            size_t n = (size_t)(slash - info.dli_fname);
            if (n + 1 + strlen(name) < sizeof(path)) {
                memcpy(path, info.dli_fname, n);
                path[n] = '/';
                strcpy(path + n + 1, name);
                h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
                if (h) {
                    fprintf(stderr, "[meowcore] loaded %s from %s\n", name, path);
                    return h;
                }
                fprintf(stderr, "[meowcore] dlopen %s failed: %s\n", path, dlerror());
            }
        }
    }
    snprintf(path, sizeof(path), "/system/lib64/%s", name);
    return dlopen(path, RTLD_NOW | RTLD_LOCAL);
}

static int mc_tools_init(void)
{
    if (s_tools_tried)
        return s_tools_ok;
    s_tools_tried = 1;

    s_sc.h = mc_dlopen_colocated("libshaderc.so");
    s_spvc.h = mc_dlopen_colocated("libspirv-cross.so");
    if (!s_sc.h || !s_spvc.h) {
        fprintf(stderr, "[meowcore] translator libs unavailable (shaderc=%p spvc=%p): %s\n",
                s_sc.h, s_spvc.h, dlerror());
        return 0;
    }

    MC_LOAD(s_sc.compiler_init, s_sc.h, "shaderc_compiler_initialize");
    MC_LOAD(s_sc.options_init, s_sc.h, "shaderc_compile_options_initialize");
    MC_LOAD(s_sc.options_set_auto_map_locations, s_sc.h, "shaderc_compile_options_set_auto_map_locations");
    MC_LOAD(s_sc.options_set_auto_bind_uniforms, s_sc.h, "shaderc_compile_options_set_auto_bind_uniforms");
    MC_LOAD(s_sc.options_set_target_env, s_sc.h, "shaderc_compile_options_set_target_env");
    MC_LOAD(s_sc.options_set_optimization_level, s_sc.h, "shaderc_compile_options_set_optimization_level");
    MC_LOAD(s_sc.compile_into_spv, s_sc.h, "shaderc_compile_into_spv");
    MC_LOAD(s_sc.result_status, s_sc.h, "shaderc_result_get_compilation_status");
    MC_LOAD(s_sc.result_error, s_sc.h, "shaderc_result_get_error_message");
    MC_LOAD(s_sc.result_bytes, s_sc.h, "shaderc_result_get_bytes");
    MC_LOAD(s_sc.result_length, s_sc.h, "shaderc_result_get_length");
    MC_LOAD(s_sc.result_release, s_sc.h, "shaderc_result_release");

    MC_LOAD(s_spvc.ctx_create, s_spvc.h, "spvc_context_create");
    MC_LOAD(s_spvc.ctx_destroy, s_spvc.h, "spvc_context_destroy");
    MC_LOAD(s_spvc.ctx_parse_spirv, s_spvc.h, "spvc_context_parse_spirv");
    MC_LOAD(s_spvc.ctx_create_compiler, s_spvc.h, "spvc_context_create_compiler");
    MC_LOAD(s_spvc.compiler_create_options, s_spvc.h, "spvc_compiler_create_compiler_options");
    MC_LOAD(s_spvc.options_set_bool, s_spvc.h, "spvc_compiler_options_set_bool");
    MC_LOAD(s_spvc.options_set_uint, s_spvc.h, "spvc_compiler_options_set_uint");
    MC_LOAD(s_spvc.install_options, s_spvc.h, "spvc_compiler_install_compiler_options");
    MC_LOAD(s_spvc.compile, s_spvc.h, "spvc_compiler_compile");

    s_compiler = s_sc.compiler_init();
    s_options = s_sc.options_init();
    s_sc.options_set_auto_map_locations(s_options, true);
    s_sc.options_set_auto_bind_uniforms(s_options, true);
    s_sc.options_set_target_env(s_options, shaderc_target_env_opengl, 0);
    /* Shaderc defaults to the *performance* level, i.e. it runs the whole
     * SPIRV-Tools optimizer for every shader. MC compiles ~30 shaders during
     * startup, all synchronously on the render thread, so that default is a
     * startup stall we cannot afford -> ask for no optimization. */
    s_sc.options_set_optimization_level(s_options, shaderc_optimization_level_zero);

    /* Fallback target: Vulkan SPIR-V (glslang is more permissive about implicit UBO
     * bindings there). SPIRV-Cross turns either into ESSL 320. */
    s_options_vk = s_sc.options_init();
    if (s_options_vk != NULL) {
        s_sc.options_set_auto_map_locations(s_options_vk, true);
        s_sc.options_set_auto_bind_uniforms(s_options_vk, true);
        s_sc.options_set_target_env(s_options_vk, shaderc_target_env_vulkan, 0);
        s_sc.options_set_optimization_level(s_options_vk, shaderc_optimization_level_zero);
    }

    s_tools_ok = (s_compiler != NULL && s_options != NULL) ? 1 : 0;
    fprintf(stderr, "[meowcore] shader translator ready=%d\n", s_tools_ok);
    return s_tools_ok;
}

/* --- shader stage table (glCreateShader -> stage) --------------------- */
#define MC_MAX_SHADERS 2048
static struct { mc_uint id; mc_enum type; } s_stage[MC_MAX_SHADERS];

static void mc_stage_set(mc_uint id, mc_enum type)
{
    int i, free_i = -1;
    for (i = 0; i < MC_MAX_SHADERS; ++i) {
        if (s_stage[i].id == id) { s_stage[i].type = type; return; }
        if (free_i < 0 && s_stage[i].id == 0) free_i = i;
    }
    if (free_i >= 0) { s_stage[free_i].id = id; s_stage[free_i].type = type; }
}

static mc_enum mc_stage_get(mc_uint id)
{
    int i;
    for (i = 0; i < MC_MAX_SHADERS; ++i)
        if (s_stage[i].id == id) return s_stage[i].type;
    return 0;
}

static void mc_stage_del(mc_uint id)
{
    int i;
    for (i = 0; i < MC_MAX_SHADERS; ++i)
        if (s_stage[i].id == id) { s_stage[i].id = 0; s_stage[i].type = 0; return; }
}

/* --- translation cache ------------------------------------------------- */
#define MC_CACHE_N 512
static struct { unsigned long hash; char *essl; } s_cache[MC_CACHE_N];
static unsigned s_cache_next = 0;

static unsigned long mc_hash(const char *s, int stage)
{
    unsigned long h = 1469598103934665603UL ^ (unsigned long)stage;
    while (*s) { h ^= (unsigned char)*s++; h *= 1099511628211UL; }
    return h;
}

static const char *mc_cache_get(unsigned long h)
{
    unsigned i;
    for (i = 0; i < MC_CACHE_N; ++i)
        if (s_cache[i].hash == h && s_cache[i].essl)
            return s_cache[i].essl;
    return NULL;
}

static void mc_cache_put(unsigned long h, const char *essl)
{
    size_t n = strlen(essl);
    char *copy = (char *)malloc(n + 1);
    if (!copy) return;
    memcpy(copy, essl, n + 1);
    if (s_cache[s_cache_next].essl)
        free(s_cache[s_cache_next].essl);
    s_cache[s_cache_next].hash = h;
    s_cache[s_cache_next].essl = copy;
    s_cache_next = (s_cache_next + 1) % MC_CACHE_N;
}

/* --- GLSL 150/330 -> #version 450 (translator-internal) --------------- */
static char *mc_bump_version(const char *src)
{
    const char *p = strstr(src, "#version");
    size_t pre, rest_len;
    char *out;
    if (!p) {
        /* no #version: prepend one */
        size_t n = strlen(src);
        out = (char *)malloc(n + 16);
        if (!out) return NULL;
        strcpy(out, "#version 450\n");
        strcat(out, src);
        return out;
    }
    pre = (size_t)(p - src);
    {
        const char *nl = strchr(p, '\n');
        const char *digits = p + 8;              /* after "#version" */
        while (*digits == ' ' || *digits == '\t') ++digits;
        rest_len = nl ? strlen(nl) : 0;          /* keep the rest verbatim */
        out = (char *)malloc(pre + 16 + rest_len + 1);
        if (!out) return NULL;
        memcpy(out, src, pre);
        memcpy(out + pre, "#version 450", 12);
        if (nl) memcpy(out + pre + 12, nl, rest_len + 1);
        else out[pre + 12] = '\0';
    }
    return out;
}

/* Whole-word match inside [line, line+len). */
static int mc_line_has_word(const char *line, size_t len, const char *word)
{
    size_t wl = strlen(word), i;
    for (i = 0; i + wl <= len; ++i) {
        if (memcmp(line + i, word, wl) != 0) continue;
        if (i > 0 && ((line[i - 1] >= 'a' && line[i - 1] <= 'z') ||
                      (line[i - 1] >= 'A' && line[i - 1] <= 'Z') ||
                      (line[i - 1] >= '0' && line[i - 1] <= '9') || line[i - 1] == '_')) continue;
        if (i + wl < len && ((line[i + wl] >= 'a' && line[i + wl] <= 'z') ||
                             (line[i + wl] >= 'A' && line[i + wl] <= 'Z') ||
                             (line[i + wl] >= '0' && line[i + wl] <= '9') || line[i + wl] == '_')) continue;
        return 1;
    }
    return 0;
}

/* Remove the "location = N" component of the first layout(...) INSIDE THIS LINE ONLY
 * (bounded by `len`). If the parentheses end up empty, remove the whole "layout(...)" --
 * leaving "layout()" is a syntax error ('0:3(8): syntax error, unexpected )').
 * NOTE: must stay line-bounded: an earlier version walked to the end of the buffer and
 * therefore also stripped attributes/varyings after the first uniform line (measured on
 * device: text missing, blocks black). */
static void mc_drop_location_qualifier(char *line, size_t len)
{
    char *lay = memmem(line, len, "layout", 6);
    char *open = lay ? strchr(lay, '(') : NULL;
    char *close = open ? strchr(open, ')') : NULL;
    char *loc;
    if (lay == NULL || open == NULL || close == NULL) return;
    if ((size_t)(close - line) >= len) return;
    loc = memmem(open + 1, (size_t)(close - open - 1), "location", 8);
    if (loc == NULL) return;
    {
        char *q = loc + 8;
        while (*q == ' ' || *q == '\t') ++q;
        if (*q != '=') return;
        {
            char *t;
            ++q;
            while (*q == ' ' || *q == '\t') ++q;
            while (*q >= '0' && *q <= '9') ++q;
            t = q;
            while (*t == ' ' || *t == '\t') ++t;
            if (*t == ',') { q = t + 1; while (*q == ' ' || *q == '\t') ++q; }
            close -= (q - loc);
            memmove(loc, q, strlen(q) + 1);
            /* If the removed qualifier was the LAST one, a comma dangles before ')'. */
            {
                char *t2 = close;
                while (t2 > open + 1 && (t2[-1] == ' ' || t2[-1] == '\t')) --t2;
                if (t2 > open + 1 && t2[-1] == ',') memmove(t2 - 1, t2, strlen(t2) + 1);
            }
            {
                char *p = open + 1;
                while (p < close && (*p == ' ' || *p == '\t')) ++p;
                if (p == close) {
                    char *after = close + 1;
                    while (*after == ' ' || *after == '\t') ++after;
                    memmove(lay, after, strlen(after) + 1);
                }
            }
        }
    }
}

/* glslang's auto-map-locations also assigns locations to *non-block* uniforms, and it
 * does so per stage. Our vsh and fsh are translated independently, so the two stages
 * get CONFLICTING uniform locations and the program link fails on the device:
 *   "layout qualifier for uniform ColorModulator overlaps previously used location"
 * Plain uniforms do not need explicit locations (in/out do, for SPIR-V generation),
 * so strip only the "location = N" component from uniform declarations. Block uniforms
 * (UBOs) use "binding" and are left untouched. */
static void mc_strip_uniform_locations(char *s)
{
    char *line = s;
    while (line != NULL && *line != '\0') {
        char *nl = strchr(line, '\n');
        size_t len = nl ? (size_t)(nl - line) : strlen(line);
        if (mc_line_has_word(line, len, "uniform") != 0)
            mc_drop_location_qualifier(line, len);
        nl = strchr(line, '\n');
        line = nl ? nl + 1 : NULL;
    }
}

/* Cross-stage varyings (vertex `out` / fragment `in`) must NOT carry explicit locations:
 * glslang assigns them per stage in declaration order, so an output the fragment stage
 * does not consume shifts the other outputs and the stages then disagree. GLES matches
 * interface variables by LOCATION, which produced this device link error:
 *   "vertex shader output `texCoord2' declared as type `vec2', but fragment shader input
 *    declared as type `vec4'"            (loc 4 = vsh vec2 texCoord2 vs fsh vec4 normal)
 * Desktop GL links by NAME and MC's own backend works, so drop the location and let GLES
 * pair by name again. Vertex ATTRIBUTES (vertex `in`) and fragment outputs keep theirs. */
static void mc_strip_varying_locations(char *s, int is_vertex)
{
    char *line = s;
    while (line != NULL && *line != '\0') {
        char *nl = strchr(line, '\n');
        size_t len = nl ? (size_t)(nl - line) : strlen(line);
        if (mc_line_has_word(line, len, "uniform") == 0 &&
            mc_line_has_word(line, len, is_vertex ? "out" : "in") != 0)
            mc_drop_location_qualifier(line, len);
        nl = strchr(line, '\n');
        line = nl ? nl + 1 : NULL;
    }
}

/* --- name-keyed varying locations ------------------------------------- *
 * Desktop GL pairs cross-stage varyings BY NAME. glslang instead assigns explicit
 * locations PER STAGE in declaration order, so when the vertex stage declares an
 * output the fragment stage does not consume, the later outputs shift and the pair
 * disagrees (device: "vertex shader output `texCoord2' declared as type `vec2', but
 * fragment shader input declared as type `vec4'" -- loc4 shifted onto `normal').
 * Removing the locations entirely is NOT rendering-equivalent here (the device's GL
 * is zink-backed; measured: text gone, blocks black), so keep explicit locations but
 * renumber the CROSS-STAGE ones from a process-wide name table: a given name always
 * gets the same index in both stages. Vertex attributes (vertex `in`) and fragment
 * outputs keep glslang's locations -- separate location namespaces, as before. */
#define MC_VAR_MAX 128
static struct { char name[40]; int loc; } s_vars[MC_VAR_MAX];
static int s_vars_n = 0;

/* -1 = table full (caller leaves the declaration untouched, i.e. no corruption). */
static int mc_varying_loc(const char *name)
{
    int i;
    for (i = 0; i < s_vars_n; ++i)
        if (strcmp(s_vars[i].name, name) == 0)
            return s_vars[i].loc;
    if (s_vars_n >= MC_VAR_MAX)
        return -1;
    snprintf(s_vars[s_vars_n].name, sizeof(s_vars[0].name), "%s", name);
    s_vars[s_vars_n].loc = s_vars_n;
    return s_vars[s_vars_n++].loc;
}

/* Rewrite the location of ONE cross-stage varying declaration, if this line is one. */
static void mc_remap_one_varying(char *line, size_t len, int is_vertex, char *limit)
{
    char *lay, *open, *close, *loc, *semi, *q, *digits, *e, *p, name[40];
    size_t nlen, oldw;
    int newloc, n;
    char tmp[8];

    if (mc_line_has_word(line, len, "uniform") != 0) return;
    if (mc_line_has_word(line, len, is_vertex ? "out" : "in") == 0) return;
    lay = memmem(line, len, "layout", 6);
    open = lay ? strchr(lay, '(') : NULL;
    close = open ? strchr(open, ')') : NULL;
    semi = memchr(line, ';', len);
    if (open == NULL || close == NULL || semi == NULL) return;
    if ((size_t)(close - line) >= len || close > semi) return;
    loc = memmem(open + 1, (size_t)(close - open - 1), "location", 8);
    if (loc == NULL) return;
    q = loc + 8;
    while (*q == ' ' || *q == '\t') ++q;
    if (*q != '=') return;
    ++q;
    while (*q == ' ' || *q == '\t') ++q;
    digits = q;
    while (*digits >= '0' && *digits <= '9') ++digits;
    if (digits == q) return;                       /* no digits: leave untouched */
    /* the declared name = identifier immediately before ';' */
    e = semi;
    while (e > close && (e[-1] == ' ' || e[-1] == '\t')) --e;
    p = e;
    while (p > close && ((p[-1] >= 'a' && p[-1] <= 'z') || (p[-1] >= 'A' && p[-1] <= 'Z') ||
                         (p[-1] >= '0' && p[-1] <= '9') || p[-1] == '_')) --p;
    nlen = (size_t)(e - p);
    if (nlen == 0 || nlen >= sizeof(name)) return;
    memcpy(name, p, nlen);
    name[nlen] = '\0';
    newloc = mc_varying_loc(name);
    if (newloc < 0) return;                        /* table full: leave untouched */
    n = snprintf(tmp, sizeof(tmp), "%d", newloc);
    oldw = (size_t)(digits - q);
    if ((size_t)n <= oldw) {
        memcpy(q, tmp, (size_t)n);
        if ((size_t)n < oldw) memset(q + n, ' ', oldw - (size_t)n);   /* keep length */
    } else {                                       /* needs more room: shift the tail */
        size_t diff = (size_t)n - oldw;
        size_t tail = strlen(digits) + 1;
        /* The caller's buffer only has bounded slack: NEVER write past `limit`
         * (that would be a heap overflow). If it would not fit, leave the original
         * location -- the source stays valid. */
        if (digits + diff + tail - 1 > limit) return;
        memmove(digits + diff, digits, tail);
        memcpy(q, tmp, (size_t)n);
    }
}

static void mc_remap_varying_locations(char *s, int is_vertex, size_t cap)
{
    char *limit = s + cap - 1;
    char *line = s;
    while (line != NULL && *line != '\0') {
        char *nl = strchr(line, '\n');
        size_t len = nl ? (size_t)(nl - line) : strlen(line);
        mc_remap_one_varying(line, len, is_vertex, limit);
        nl = strchr(line, '\n');
        line = nl ? nl + 1 : NULL;
    }
}

/* --- name-keyed UBO bindings ------------------------------------------ *
 * glslang's auto_bind_uniforms numbers uniform BLOCKS per stage, in first-use order,
 * so the SAME block can land on a different "binding =" in the vsh and the fsh. The
 * device linker then sees two different block definitions sharing one binding and
 * rejects the whole program:
 *   "buffer block with binding `1' has mismatching definitions"
 * (measured on 1.21.10 core/terrain: vsh binding1 = Projection{mat4 ProjMat}, fsh
 * binding1 = DynamicTransforms{mat4 ModelViewMat; vec4 ColorModulator; ...}).
 * MC never reads the declared binding: it binds each block itself with
 * glUniformBlockBinding before upload, so renumber the blocks from a process-wide
 * name table -- the same name gets the same binding in both stages. Different names
 * always get different bindings, so no binding is ever shared by two definitions.
 * std140 and every member (name/type/order) are untouched, so MC's std140 offsets
 * stay valid. This mirrors the varying-location remap above. */
#define MC_BLOCK_MAX 24          /* GL_MAX_UNIFORM_BUFFER_BINDINGS min in ES 3.x is 24 */
static struct { char name[48]; int binding; } s_blocks[MC_BLOCK_MAX];
static int s_blocks_n = 0;

/* -1 = table full (caller leaves the declaration untouched, i.e. no corruption). */
static int mc_block_binding(const char *name)
{
    int i;
    for (i = 0; i < s_blocks_n; ++i)
        if (strcmp(s_blocks[i].name, name) == 0)
            return s_blocks[i].binding;
    if (s_blocks_n >= MC_BLOCK_MAX)
        return -1;
    snprintf(s_blocks[s_blocks_n].name, sizeof(s_blocks[0].name), "%s", name);
    s_blocks[s_blocks_n].binding = s_blocks_n;
    return s_blocks[s_blocks_n++].binding;
}

/* Rewrite the binding of ONE uniform-block declaration (a line that names a block and
 * whose line carries no ';'; plain uniforms/samplers end with ';' and are skipped). */
static void mc_remap_one_block_binding(char *line, size_t len, char *limit)
{
    char *lay, *open, *close, *loc, *uni, *q, *digits, *p, *e, name[48];
    size_t nlen, oldw;
    int newb, n;
    char tmp[8];

    if (mc_line_has_word(line, len, "uniform") == 0) return;
    if (memchr(line, ';', len) != NULL) return;          /* plain uniform / sampler */
    lay = memmem(line, len, "layout", 6);
    open = lay ? strchr(lay, '(') : NULL;
    close = open ? strchr(open, ')') : NULL;
    if (open == NULL || close == NULL) return;
    if ((size_t)(close - line) >= len) return;
    loc = memmem(open + 1, (size_t)(close - open - 1), "binding", 7);
    if (loc == NULL) return;
    /* the block name = identifier right after the "uniform" keyword */
    uni = memmem(line, len, "uniform", 7);
    if (uni == NULL) return;
    p = uni + 7;
    e = line + len;
    while (p < e && (*p == ' ' || *p == '\t')) ++p;
    q = p;
    while (q < e && ((*q >= 'a' && *q <= 'z') || (*q >= 'A' && *q <= 'Z') ||
                     (*q >= '0' && *q <= '9') || *q == '_')) ++q;
    nlen = (size_t)(q - p);
    if (nlen == 0 || nlen >= sizeof(name)) return;
    memcpy(name, p, nlen);
    name[nlen] = '\0';
    newb = mc_block_binding(name);
    if (newb < 0) return;
    q = loc + 7;
    while (*q == ' ' || *q == '\t') ++q;
    if (*q != '=') return;
    ++q;
    while (*q == ' ' || *q == '\t') ++q;
    digits = q;
    while (*digits >= '0' && *digits <= '9') ++digits;
    if (digits == q) return;                             /* no digits: leave untouched */
    n = snprintf(tmp, sizeof(tmp), "%d", newb);
    oldw = (size_t)(digits - q);
    if ((size_t)n <= oldw) {
        memcpy(q, tmp, (size_t)n);
        if ((size_t)n < oldw) memset(q + n, ' ', oldw - (size_t)n);   /* keep length */
    } else {                                             /* needs more room: shift the tail */
        size_t diff = (size_t)n - oldw;
        size_t tail = strlen(digits) + 1;
        if (digits + diff + tail - 1 > limit) return;    /* never write past the buffer */
        memmove(digits + diff, digits, tail);
        memcpy(q, tmp, (size_t)n);
    }
}

static void mc_remap_block_bindings(char *s, size_t cap)
{
    char *limit = s + cap - 1;
    char *line = s;
    while (line != NULL && *line != '\0') {
        char *nl = strchr(line, '\n');
        size_t len = nl ? (size_t)(nl - line) : strlen(line);
        mc_remap_one_block_binding(line, len, limit);
        nl = strchr(line, '\n');
        line = nl ? nl + 1 : NULL;
    }
}

/* --- name-keyed opaque-uniform (sampler/image) bindings --------------- *
 * Same defect as the UBO bindings above, one namespace over: glslang's
 * auto_bind_uniforms numbers opaque uniforms (samplers/images) per stage in
 * first-use order, so the shared sampler `Sampler2` lands on a different
 * `layout(binding=)` in the vsh and the fsh and the linker rejects the whole program.
 * Reproduced on this 2in1's GLES 3.2 with the product chain + probe_local:
 *   VS: layout(binding = 2) uniform highp sampler2D Sampler2;
 *   FS: layout(binding = 0) uniform highp sampler2D Sampler2;
 *   link: FAIL L0001 The fragment sampler variable Sampler2 does not match the
 *         vertex variable Sampler2.  The binding does not match.
 * Texture-image-unit bindings are a SEPARATE namespace from UBO binding points, so
 * this keeps its own name table (never shares numbers with s_blocks). MC binds every
 * sampler itself with glUniform1i and never reads the declared binding, and the class
 * of the uniform (type/name/array-ness) is untouched, so renumbering by name is safe.
 * Plain numeric uniforms are not opaque and are skipped (their location strip is the
 * existing mc_strip_uniform_locations path). */
#define MC_UNI_MAX 128
static struct { char name[48]; int binding; } s_unis[MC_UNI_MAX];
static int s_unis_n = 0;

/* -1 = table full (caller leaves the declaration untouched, i.e. no corruption). */
static int mc_opaque_binding(const char *name)
{
    int i;
    for (i = 0; i < s_unis_n; ++i)
        if (strcmp(s_unis[i].name, name) == 0)
            return s_unis[i].binding;
    if (s_unis_n >= MC_UNI_MAX)
        return -1;
    snprintf(s_unis[s_unis_n].name, sizeof(s_unis[0].name), "%s", name);
    s_unis[s_unis_n].binding = s_unis_n;
    return s_unis[s_unis_n++].binding;
}

/* Read the identifier at/after *pp (bounded by end) and advance *pp past it.
 * Returns its length (0 = none). Copies up to bufsz-1 chars + NUL into buf. */
static size_t mc_take_ident(const char **pp, const char *end, char *buf, size_t bufsz)
{
    const char *p = *pp, *q;
    size_t n;
    while (p < end && (*p == ' ' || *p == '\t')) ++p;
    q = p;
    while (q < end && ((*q >= 'a' && *q <= 'z') || (*q >= 'A' && *q <= 'Z') ||
                       (*q >= '0' && *q <= '9') || *q == '_')) ++q;
    n = (size_t)(q - p);
    *pp = q;
    if (n == 0 || n >= bufsz) return 0;
    memcpy(buf, p, n);
    buf[n] = '\0';
    return n;
}

/* Rewrite the binding of ONE opaque-uniform declaration: a ';'-terminated uniform
 * line whose declared type is a sampler/image. UBO lines carry no ';' (different
 * table) and plain numeric uniforms have no sampler/image type, so both are skipped. */
static void mc_remap_one_opaque_binding(char *line, size_t len, char *limit)
{
    char *lay, *open, *close, *loc, *uni, *semi, *q, *digits;
    const char *p;
    char type[48], name[48];
    size_t oldw;
    int newb, n;
    char tmp[8];

    if (mc_line_has_word(line, len, "uniform") == 0) return;
    semi = memchr(line, ';', len);
    if (semi == NULL) return;                            /* UBO declaration: other table */
    lay = memmem(line, len, "layout", 6);
    open = lay ? strchr(lay, '(') : NULL;
    close = open ? strchr(open, ')') : NULL;
    if (open == NULL || close == NULL) return;
    if ((size_t)(close - line) >= len || close > semi) return;
    loc = memmem(open + 1, (size_t)(close - open - 1), "binding", 7);
    if (loc == NULL) return;
    uni = memmem(line, len, "uniform", 7);
    if (uni == NULL) return;
    /* type = token after "uniform", skipping an optional precision qualifier */
    p = uni + 7;
    if (mc_take_ident(&p, line + len, type, sizeof(type)) == 0) return;
    if (strcmp(type, "lowp") == 0 || strcmp(type, "mediump") == 0 ||
        strcmp(type, "highp") == 0) {
        if (mc_take_ident(&p, line + len, type, sizeof(type)) == 0) return;
    }
    if (strstr(type, "sampler") == NULL && strstr(type, "image") == NULL) return;
    if (mc_take_ident(&p, line + len, name, sizeof(name)) == 0) return;
    newb = mc_opaque_binding(name);
    if (newb < 0) return;
    q = loc + 7;
    while (*q == ' ' || *q == '\t') ++q;
    if (*q != '=') return;
    ++q;
    while (*q == ' ' || *q == '\t') ++q;
    digits = q;
    while (*digits >= '0' && *digits <= '9') ++digits;
    if (digits == q) return;                             /* no digits: leave untouched */
    n = snprintf(tmp, sizeof(tmp), "%d", newb);
    oldw = (size_t)(digits - q);
    if ((size_t)n <= oldw) {
        memcpy(q, tmp, (size_t)n);
        if ((size_t)n < oldw) memset(q + n, ' ', oldw - (size_t)n);   /* keep length */
    } else {                                             /* needs more room: shift the tail */
        size_t diff = (size_t)n - oldw;
        size_t tail = strlen(digits) + 1;
        if (digits + diff + tail - 1 > limit) return;    /* never write past the buffer */
        memmove(digits + diff, digits, tail);
        memcpy(q, tmp, (size_t)n);
    }
}

static void mc_remap_opaque_bindings(char *s, size_t cap)
{
    char *limit = s + cap - 1;
    char *line = s;
    while (line != NULL && *line != '\0') {
        char *nl = strchr(line, '\n');
        size_t len = nl ? (size_t)(nl - line) : strlen(line);
        mc_remap_one_opaque_binding(line, len, limit);
        nl = strchr(line, '\n');
        line = nl ? nl + 1 : NULL;
    }
}

/* --- translation timing (startup stall evidence) ---------------------- */
static double s_tms_total = 0.0;
static unsigned s_tms_count = 0;

static double mc_now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec * 1000.0 + (double)ts.tv_nsec / 1000000.0;
}

/* --- translate one shader source -------------------------------------- */
static char *mc_translate(const char *src, mc_enum stage)
{
    char *bumped;
    shaderc_shader_kind kind;
    shaderc_compilation_result_t res = NULL;
    spvc_context ctx = NULL;
    spvc_compiler comp = NULL;
    spvc_compiler_options opts = NULL;
    const char *essl = NULL;
    char *out = NULL;
    unsigned long h;

    if (!mc_tools_init())
        return NULL;
    double t0 = mc_now_ms();
    fprintf(stderr, "[meowcore] translate: stage=%d srcLen=%zu\n", (int)stage, strlen(src));

    h = mc_hash(src, (int)stage);
    {
        const char *hit = mc_cache_get(h);
        if (hit) return strdup(hit);   /* hand the caller its own copy (caller frees) */
    }

    bumped = mc_bump_version(src);
    if (!bumped) return NULL;

    kind = (stage == MC_GL_VERTEX_SHADER) ? shaderc_glsl_vertex_shader : shaderc_glsl_fragment_shader;

    res = s_sc.compile_into_spv(s_compiler, bumped, strlen(bumped), kind, "mc", "main", s_options);
    if (res != NULL && s_sc.result_status(res) != shaderc_compilation_status_success) {
        const char *e = s_sc.result_error(res);
        fprintf(stderr, "[meowcore] glsl->spirv (opengl target) FAILED: %s\n", e ? e : "(no message)");
        s_sc.result_release(res);
        res = NULL;
    }
    if (res == NULL && s_options_vk != NULL) {
        res = s_sc.compile_into_spv(s_compiler, bumped, strlen(bumped), kind, "mc", "main", s_options_vk);
        if (res != NULL && s_sc.result_status(res) != shaderc_compilation_status_success) {
            const char *e = s_sc.result_error(res);
            fprintf(stderr, "[meowcore] glsl->spirv (vulkan fallback) FAILED too: %s\n", e ? e : "(no message)");
            s_sc.result_release(res);
            res = NULL;
        } else if (res != NULL) {
            fprintf(stderr, "[meowcore] glsl->spirv: accepted via vulkan target\n");
        }
    }
    free(bumped);
    if (res == NULL) {
        fprintf(stderr, "[meowcore] glsl->spirv: no target accepted the shader\n");
        return NULL;
    }

    if (s_spvc.ctx_create(&ctx) != SPVC_SUCCESS || ctx == NULL) {
        fprintf(stderr, "[meowcore] spvc_context_create FAILED (ctx=%p)\n", (void *)ctx);
        s_sc.result_release(res);
        return NULL;
    }
    {
        const void *spv = (const void *)s_sc.result_bytes(res);
        size_t words = s_sc.result_length(res) / 4;
        spvc_parsed_ir parsed = NULL;
        spvc_result rc = s_spvc.ctx_parse_spirv(ctx, (const SpvId *)spv, words, &parsed);
        if (rc != SPVC_SUCCESS || parsed == NULL) {
            fprintf(stderr, "[meowcore] spvc_context_parse_spirv FAILED rc=%d words=%zu\n",
                    (int)rc, words);
            s_sc.result_release(res);
            s_spvc.ctx_destroy(ctx);
            return NULL;
        }
        /* SPIRV-Cross made its own copy of the IR: the shaderc result can go now
         * (it used to be leaked for every shader on every successful path). */
        s_sc.result_release(res);
        res = NULL;
        /* NOTE: the 3rd argument is the parsed-IR handle -- passing the raw SPIR-V
         * pointer here returns SPVC_ERROR_INVALID_ARGUMENT (-4). */
        rc = s_spvc.ctx_create_compiler(ctx, SPVC_BACKEND_GLSL, parsed,
                                        SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &comp);
        if (rc != SPVC_SUCCESS || comp == NULL) {
            fprintf(stderr, "[meowcore] spvc_context_create_compiler FAILED rc=%d words=%zu\n",
                    (int)rc, words);
            s_spvc.ctx_destroy(ctx);
            return NULL;
        }
    }
    if (s_spvc.compiler_create_options(comp, &opts) == SPVC_SUCCESS && opts != NULL) {
        s_spvc.options_set_bool(opts, SPVC_COMPILER_OPTION_GLSL_ES, true);
        s_spvc.options_set_uint(opts, SPVC_COMPILER_OPTION_GLSL_VERSION, 320u);
        s_spvc.install_options(comp, opts);
    } else {
        fprintf(stderr, "[meowcore] spvc_compiler_create_compiler_options FAILED (defaults used)\n");
    }
    {
        spvc_result rc = s_spvc.compile(comp, &essl);
        if (rc != SPVC_SUCCESS || essl == NULL) {
            fprintf(stderr, "[meowcore] spirv->essl FAILED rc=%d\n", (int)rc);
        } else {
            size_t n = strlen(essl);
            size_t cap = n + 256;                  /* slack for the varying remap */
            char *tmp = (char *)malloc(cap + 1);
            if (tmp != NULL) {
                memcpy(tmp, essl, n + 1);
                mc_strip_uniform_locations(tmp);
                mc_remap_varying_locations(tmp, stage == MC_GL_VERTEX_SHADER, cap + 1);
                mc_remap_block_bindings(tmp, cap + 1);
                mc_remap_opaque_bindings(tmp, cap + 1);
                mc_cache_put(h, tmp);
                free(tmp);
                out = (char *)mc_cache_get(h);
            }
        }
    }
    s_spvc.ctx_destroy(ctx);
    if (out != NULL) out = strdup(out);
    {
        double dt = mc_now_ms() - t0;
        s_tms_total += dt;
        s_tms_count++;
        fprintf(stderr, "[meowcore] translate ok=%d stage=%d ms=%.1f total_ms=%.0f n=%u\n",
                out != NULL, (int)stage, dt, s_tms_total, s_tms_count);
    }
    return out;
}

/* --- shader compile/link diagnostics (low-frequency, de-duplicated) ---- *
 * The device hands our ESSL to zink/Mesa, which can reject a stage with a message MC
 * never prints (it only says "vertex shader minecraft:core/gui was invalid"). To make
 * the next device log self-diagnosing we emit -- ONLY on failure -- the stage's info
 * log plus identifiers that can be lined up with MC's source: the stage enum, the
 * original (MC-supplied, moj_import-expanded) source length and its first 40 bytes,
 * and the translated ESSL length. Identical log text is printed once per process,
 * and the success path stays silent. */
#define MC_SINFO_N 64
static struct {
    mc_uint id;
    mc_enum stage;
    size_t  src_len;
    size_t  essl_len;
    char    head[44];
} s_sinfo[MC_SINFO_N];
static unsigned s_sinfo_next = 0;

/* Remember the last-seen source for `id` so a later compile/link failure can name it.
 * MC sources then compiles a shader back-to-back, so a small ring is enough. */
static void mc_shader_note(mc_uint id, mc_enum stage, size_t src_len, size_t essl_len,
                           const char *src)
{
    unsigned i;
    size_t k;
    for (i = 0; i < MC_SINFO_N; ++i)
        if (s_sinfo[i].id == id) break;
    if (i == MC_SINFO_N) i = s_sinfo_next;      /* untracked id: claim the next slot */
    s_sinfo[i].id = id;
    s_sinfo[i].stage = stage;
    s_sinfo[i].src_len = src_len;
    s_sinfo[i].essl_len = essl_len;
    for (k = 0; k < sizeof(s_sinfo[i].head) - 1 && src && src[k] != '\0'; ++k) {
        char c = src[k];
        s_sinfo[i].head[k] = (c == '\n' || c == '\r' || c == '\t') ? ' ' : c;
    }
    s_sinfo[i].head[k] = '\0';
    s_sinfo_next = (i + 1) % MC_SINFO_N;
}

static int mc_shader_info(mc_uint id, mc_enum *stage, size_t *src_len, size_t *essl_len,
                          const char **head)
{
    unsigned i;
    for (i = 0; i < MC_SINFO_N; ++i)
        if (s_sinfo[i].id == id) {
            *stage = s_sinfo[i].stage; *src_len = s_sinfo[i].src_len;
            *essl_len = s_sinfo[i].essl_len; *head = s_sinfo[i].head;
            return 1;
        }
    return 0;
}

/* Same failure text printed once per process (MC recompiles identical shaders on every
 * resource reload / window resize). */
#define MC_LOGHASH_N 8
static unsigned long s_loghash[MC_LOGHASH_N];
static unsigned s_loghash_next = 0;

static int mc_log_is_new(const char *s)
{
    unsigned long h = 1469598103934665603UL;
    unsigned i;
    const unsigned char *p = (const unsigned char *)s;
    while (*p) { h ^= *p++; h *= 1099511628211UL; }
    for (i = 0; i < MC_LOGHASH_N; ++i)
        if (s_loghash[i] == h) return 0;
    s_loghash[s_loghash_next] = h;
    s_loghash_next = (s_loghash_next + 1) % MC_LOGHASH_N;
    return 1;
}

static void mc_note_shader_failure(mc_uint shader)
{
    mc_int ok = 1;
    mc_enum stage = 0;
    size_t src_len = 0, essl_len = 0;
    const char *head = "(untracked)";
    char log[2048];

    if (s_realGetShaderiv) s_realGetShaderiv(shader, MC_GL_COMPILE_STATUS, &ok);
    if (ok) return;                                     /* success path: silent */
    log[0] = '\0';
    if (s_realGetShaderInfoLog)
        s_realGetShaderInfoLog(shader, (mc_int)sizeof(log), NULL, log);
    if (!mc_log_is_new(log)) return;
    mc_shader_info(shader, &stage, &src_len, &essl_len, &head);
    fprintf(stderr, "[meowcore] shader compile FAILED stage=0x%x srcLen=%zu esslLen=%zu "
                    "head=\"%.40s\": %s\n", (unsigned)stage, src_len, essl_len, head,
            log[0] ? log : "(empty log)");
}

static void mc_note_program_failure(mc_uint program)
{
    mc_int ok = 1;
    char log[2048];

    if (s_realGetProgramiv) s_realGetProgramiv(program, MC_GL_LINK_STATUS, &ok);
    if (ok) return;
    log[0] = '\0';
    if (s_realGetProgramInfoLog)
        s_realGetProgramInfoLog(program, (mc_int)sizeof(log), NULL, log);
    if (!mc_log_is_new(log)) return;
    fprintf(stderr, "[meowcore] program link FAILED: %s\n", log[0] ? log : "(empty log)");
}

/* --- patched entry points --------------------------------------------- */
static mc_string mc_glGetString(mc_enum name)
{
    switch (name) {
        case MC_GL_VERSION:  return (mc_string)"3.3 Meowcraft (GLES 3.2 backend)";
        case MC_GL_SHADING_LANGUAGE_VERSION: return (mc_string)"3.30";
        default: break;
    }
    return s_realGetString ? s_realGetString(name) : NULL;
}

static mc_string mc_glGetStringi(mc_enum name, mc_uint index)
{
    /* Slice 2: still pass the real ES extension list through. The curated list
     * (ARB flag synthesis, "report missing") lands later. */
    return s_realGetStringi ? s_realGetStringi(name, index) : NULL;
}

static void mc_glGetIntegerv(mc_enum pname, mc_int *out)
{
    if (!out) return;
    switch (pname) {
        case MC_GL_MAJOR_VERSION: *out = 3; return;
        case MC_GL_MINOR_VERSION: *out = 3; return;
        default: break;
    }
    if (s_realGetIntegerv) s_realGetIntegerv(pname, out);
}

static mc_uint mc_glCreateShader(mc_enum type)
{
    mc_uint id = s_realCreateShader ? s_realCreateShader(type) : 0;
    if (id) mc_stage_set(id, type);
    return id;
}

static void mc_glDeleteShader(mc_uint id)
{
    mc_stage_del(id);
    if (s_realDeleteShader) s_realDeleteShader(id);
}

static void mc_glShaderSource(mc_uint shader, mc_int count, const mc_char *const *string,
                              const mc_int *length)
{
    mc_enum type;
    char *joined = NULL;
    size_t total = 0;
    int i;
    char *essl = NULL;
    const mc_char *pass[1];
    mc_int pass_len[1];

    if (!string || count <= 0) {
        if (s_realShaderSource) s_realShaderSource(shader, count, string, length);
        return;
    }

    /* join the (possibly multi-part) source */
    for (i = 0; i < count; ++i) {
        size_t n = (length && length[i] >= 0) ? (size_t)length[i] : (string[i] ? strlen(string[i]) : 0);
        total += n;
    }
    joined = (char *)malloc(total + 1);
    if (!joined) {
        if (s_realShaderSource) s_realShaderSource(shader, count, string, length);
        return;
    }
    total = 0;
    for (i = 0; i < count; ++i) {
        size_t n = (length && length[i] >= 0) ? (size_t)length[i] : (string[i] ? strlen(string[i]) : 0);
        if (n && string[i]) { memcpy(joined + total, string[i], n); total += n; }
    }
    joined[total] = '\0';

    type = mc_stage_get(shader);
    essl = mc_translate(joined, type);
    /* remember what the driver is about to compile, for the failure diagnostic */
    mc_shader_note(shader, type, total, essl ? strlen(essl) : 0, joined);
    free(joined);

    if (essl) {
        pass[0] = essl;
        pass_len[0] = (mc_int)strlen(essl);
        if (s_realShaderSource) s_realShaderSource(shader, 1, pass, pass_len);
        free(essl);
    } else {
        fprintf(stderr, "[meowcore] shader %u: translation unavailable -> passing original "
                        "(compile will likely fail; this is visible to MC)\n", shader);
        if (s_realShaderSource) s_realShaderSource(shader, count, string, length);
    }
}

/* Thin pass-throughs that make compile/link failures visible. On failure only, the
 * info log is emitted once (see mc_note_shader_failure / mc_note_program_failure).
 * The glGetShaderiv / glGetProgramiv hooks catch failures even when the compile/link
 * call itself went through a path we did not wrap, and stay silent when the status
 * query succeeds. */
static void mc_glCompileShader(mc_uint shader)
{
    if (s_realCompileShader) s_realCompileShader(shader);
    mc_note_shader_failure(shader);
}

static void mc_glGetShaderiv(mc_uint shader, mc_enum pname, mc_int *params)
{
    if (s_realGetShaderiv) s_realGetShaderiv(shader, pname, params);
    if (pname == MC_GL_COMPILE_STATUS && params && *params == 0)
        mc_note_shader_failure(shader);
}

static void mc_glGetShaderInfoLog(mc_uint shader, mc_int bufSize, mc_int *length,
                                  mc_char *infoLog)
{
    if (s_realGetShaderInfoLog) s_realGetShaderInfoLog(shader, bufSize, length, infoLog);
}

static void mc_glLinkProgram(mc_uint program)
{
    if (s_realLinkProgram) s_realLinkProgram(program);
    mc_note_program_failure(program);
}

static void mc_glGetProgramiv(mc_uint program, mc_enum pname, mc_int *params)
{
    if (s_realGetProgramiv) s_realGetProgramiv(program, pname, params);
    if (pname == MC_GL_LINK_STATUS && params && *params == 0)
        mc_note_program_failure(program);
}

static void mc_glGetProgramInfoLog(mc_uint program, mc_int bufSize, mc_int *length,
                                   mc_char *infoLog)
{
    if (s_realGetProgramInfoLog) s_realGetProgramInfoLog(program, bufSize, length, infoLog);
}

/* The translated shaders carry explicit layout(location=...) (auto-mapped by
 * glslang). MC still calls glBindAttribLocation before linking; on GLES a bind
 * that contradicts a declared layout is a link error, and MC queries the real
 * location anyway -> make it a no-op so our baked locations stay authoritative. */
static void mc_glBindAttribLocation(mc_uint program, mc_int index, const mc_char *name)
{
    (void)program; (void)index; (void)name;
}

/* --- desktop-only texture entry points MC relies on ------------------- */

/* Map an unsized depth/stencil internalformat to the ES-legal sized one that
 * matches the requested type. Already-sized (or non-depth) formats pass through
 * untouched, so valid combinations keep their exact behaviour. */
static mc_int mc_es_depth_internalformat(mc_int internalformat, mc_enum format, mc_enum type)
{
    (void)format;
    /* GL_DEPTH_COMPONENT32 is the desktop legacy *sized* constant (0x81A7) that has
     * no ES counterpart: ES knows 16/24/32F only. MC 1.21.10 asks for
     * (ifmt=0x81A7, fmt=GL_DEPTH_COMPONENT, type=GL_FLOAT), which the driver rejects
     * with GL_INVALID_OPERATION. Fold it into the same type-directed rule as the
     * unsized 0x1902 above. */
    if (internalformat == MC_GL_DEPTH_COMPONENT || internalformat == MC_GL_DEPTH_COMPONENT32) {
        if (type == MC_GL_FLOAT)          return MC_GL_DEPTH_COMPONENT32F;
        if (type == MC_GL_UNSIGNED_INT)   return MC_GL_DEPTH_COMPONENT24;
        if (type == MC_GL_UNSIGNED_SHORT) return MC_GL_DEPTH_COMPONENT16;
    } else if (internalformat == MC_GL_DEPTH_STENCIL) {
        if (type == MC_GL_UNSIGNED_INT_24_8)                return MC_GL_DEPTH24_STENCIL8;
        if (type == MC_GL_FLOAT_32_UNSIGNED_INT_24_8_REV)   return MC_GL_DEPTH32F_STENCIL8;
    }
    return internalformat;
}

/* Diagnostics must not repeat: MC recreates its render targets on resize and mod
 * reload, so the same remap combination is hit over and over. Emit one line per
 * (kind, ifmt, fmt, type) combination per process. Returns 1 only the first time.
 * kind: 0 = texImage2D, 1 = texStorage2D, 2 = renderbufferStorage. */
#define MC_DIAG_MAX 32
static struct { int kind; mc_int a; mc_enum b; mc_enum c; } s_diags[MC_DIAG_MAX];
static int s_diags_n = 0;

static int mc_diag_once(int kind, mc_int a, mc_enum b, mc_enum c)
{
    int i;
    for (i = 0; i < s_diags_n; ++i)
        if (s_diags[i].kind == kind && s_diags[i].a == a && s_diags[i].b == b && s_diags[i].c == c)
            return 0;                       /* already logged this combination */
    if (s_diags_n >= MC_DIAG_MAX)
        return 0;                           /* table full: stay silent rather than spam */
    s_diags[s_diags_n].kind = kind;
    s_diags[s_diags_n].a = a;
    s_diags[s_diags_n].b = b;
    s_diags[s_diags_n].c = c;
    ++s_diags_n;
    return 1;
}

/* glTexStorage2D/glRenderbufferStorage have no format/type to disambiguate the
 * sized format, so the default sized variant is chosen for an unsized request. */
static mc_enum mc_es_storage_internalformat(mc_enum internalformat)
{
    if (internalformat == MC_GL_DEPTH_COMPONENT) return MC_GL_DEPTH_COMPONENT24;
    if (internalformat == MC_GL_DEPTH_STENCIL)   return MC_GL_DEPTH24_STENCIL8;
    return internalformat;
}

static void mc_glTexImage2D(mc_enum target, mc_int level, mc_int internalformat, mc_int width,
                            mc_int height, mc_int border, mc_enum format, mc_enum type,
                            const void *pixels)
{
    mc_int legal;
    if (target == MC_GL_PROXY_TEXTURE_2D) {   /* not a real upload: it is MC's size probe */
        s_proxyW = width;
        s_proxyH = height;
        return;
    }
    legal = mc_es_depth_internalformat(internalformat, format, type);
    if (legal != internalformat) {
        if (mc_diag_once(0, internalformat, format, type))
            fprintf(stderr, "[meowcore] texImage2D remap: target=0x%x ifmt=0x%x fmt=0x%x "
                            "type=0x%x -> 0x%x\n", target, internalformat, format, type, legal);
        internalformat = legal;
    }
    if (s_realTexImage2D)
        s_realTexImage2D(target, level, internalformat, width, height, border, format, type, pixels);
}

static void mc_glTexStorage2D(mc_enum target, mc_int levels, mc_enum internalformat,
                              mc_int width, mc_int height)
{
    mc_enum legal = mc_es_storage_internalformat(internalformat);
    if (legal != internalformat) {
        if (mc_diag_once(1, internalformat, 0, 0))
            fprintf(stderr, "[meowcore] texStorage2D remap: target=0x%x ifmt=0x%x -> 0x%x\n",
                    target, internalformat, legal);
        internalformat = legal;
    }
    if (s_realTexStorage2D)
        s_realTexStorage2D(target, levels, internalformat, width, height);
}

static void mc_glRenderbufferStorage(mc_enum target, mc_enum internalformat,
                                     mc_int width, mc_int height)
{
    mc_enum legal = mc_es_storage_internalformat(internalformat);
    if (legal != internalformat) {
        if (mc_diag_once(2, internalformat, 0, 0))
            fprintf(stderr, "[meowcore] renderbufferStorage remap: ifmt=0x%x -> 0x%x\n",
                    internalformat, legal);
        internalformat = legal;
    }
    if (s_realRenderbufferStorage)
        s_realRenderbufferStorage(target, internalformat, width, height);
}

static void mc_glGetTexLevelParameteriv(mc_enum target, mc_int level, mc_enum pname, mc_int *params)
{
    if (target == MC_GL_PROXY_TEXTURE_2D) {
        if (!params) return;
        if (level != 0) { *params = 0; return; }
        if (pname == MC_GL_TEXTURE_WIDTH)       *params = (s_proxyW <= s_maxTexSize) ? s_proxyW : 0;
        else if (pname == MC_GL_TEXTURE_HEIGHT) *params = (s_proxyH <= s_maxTexSize) ? s_proxyH : 0;
        else                                    *params = 0;
        return;
    }
    if (s_realGetTexLevelParameteriv)
        s_realGetTexLevelParameteriv(target, level, pname, params);
}

static void mc_glGetTexLevelParameterfv(mc_enum target, mc_int level, mc_enum pname, float *params)
{
    if (target == MC_GL_PROXY_TEXTURE_2D) {
        mc_int v = 0;
        mc_glGetTexLevelParameteriv(target, level, pname, &v);
        if (params) *params = (float)v;
        return;
    }
    if (s_realGetTexLevelParameterfv)
        s_realGetTexLevelParameterfv(target, level, pname, params);
}

/* ES has no GL_TEXTURE_LOD_BIAS: MC sets it unconditionally -> swallow it. */
static void mc_glTexParameteri(mc_enum target, mc_enum pname, mc_int param)
{
    if (pname == MC_GL_TEXTURE_LOD_BIAS) return;
    if (s_realTexParameteri) s_realTexParameteri(target, pname, param);
}

static void mc_glTexParameterf(mc_enum target, mc_enum pname, float param)
{
    if (pname == MC_GL_TEXTURE_LOD_BIAS) return;
    if (s_realTexParameterf) s_realTexParameterf(target, pname, param);
}

/* --- desktop-only glEnable/glDisable caps ----------------------------- *
 * These wrappers exist only on the core-backend surface (meowcore_GetProcAddress),
 * which the legacy gl4es fixed-function path never reaches -- so GL_TEXTURE_2D &c.
 * stay valid caps for legacy. Explicit whitelist: only caps proven absent from the
 * ES 3.2 glEnable set are dropped; anything else is forwarded verbatim. */
static int mc_cap_desktop_only(mc_enum cap)
{
    switch (cap) {
        case MC_GL_TEXTURE_CUBE_MAP_SEAMLESS: return 1;
        case MC_GL_MULTISAMPLE:               return 1;
        case MC_GL_TEXTURE_2D:                return 1;
        case MC_GL_TEXTURE_1D:                return 1;
        case MC_GL_TEXTURE_3D:                return 1;
        case MC_GL_ALPHA_TEST:                return 1;
        case MC_GL_LINE_SMOOTH:               return 1;
        case MC_GL_POLYGON_SMOOTH:            return 1;
        case MC_GL_DEPTH_CLAMP:               return 1;
        case MC_GL_PRIMITIVE_RESTART:         return 1;
        default:                              return 0;
    }
}

/* One low-frequency diagnostic line per swallowed cap per process. */
static mc_enum s_swallowed_caps[16];
static int     s_swallowed_n = 0;

static void mc_note_swallowed(mc_enum cap)
{
    int i;
    for (i = 0; i < s_swallowed_n; ++i)
        if (s_swallowed_caps[i] == cap) return;      /* already reported */
    if (s_swallowed_n < (int)(sizeof(s_swallowed_caps) / sizeof(s_swallowed_caps[0]))) {
        s_swallowed_caps[s_swallowed_n++] = cap;
        fprintf(stderr, "[meowcore] glEnable swallowed (desktop-only): 0x%x\n", cap);
    }
}

static void mc_glEnable(mc_enum cap)
{
    if (mc_cap_desktop_only(cap)) { mc_note_swallowed(cap); return; }
    if (s_realEnable) s_realEnable(cap);
}

static void mc_glDisable(mc_enum cap)
{
    if (mc_cap_desktop_only(cap)) return;
    if (s_realDisable) s_realDisable(cap);
}

/* --- class B: desktop-only names MC calls that ES has under another form --- */
static void mc_glClearDepth(double depth)
{
    if (s_realClearDepthf) s_realClearDepthf((float)depth);
}

static void mc_glDrawBuffer(mc_enum buf)
{
    if (s_realDrawBuffers) s_realDrawBuffers(1, &buf);
}

static void *mc_glMapBuffer(mc_enum target, mc_enum access)
{
    mc_int size = 0;
    mc_enum flags = 0;
    if (!s_realMapBufferRange) return NULL;
    if (s_realGetBufferParameteriv) s_realGetBufferParameteriv(target, MC_GL_BUFFER_SIZE, &size);
    if (access == MC_GL_READ_ONLY)       flags = MC_GL_MAP_READ_BIT;
    else if (access == MC_GL_WRITE_ONLY) flags = MC_GL_MAP_WRITE_BIT;
    else                                 flags = MC_GL_MAP_READ_BIT | MC_GL_MAP_WRITE_BIT;
    return s_realMapBufferRange(target, (int64_t)0, (int64_t)size, flags);
}

/* --- class C: desktop-only, no ES equivalent -> swallow (never call the FPE) --- */
static void mc_glPolygonMode(mc_enum face, mc_enum mode) { (void)face; (void)mode; }
static void mc_glDrawPixels(mc_int w, mc_int h, mc_enum fmt, mc_enum ty, const void *px)
{ (void)w; (void)h; (void)fmt; (void)ty; (void)px; }
static void mc_glGetTexImage(mc_enum t, mc_int l, mc_enum f, mc_enum ty, void *px)
{ (void)t; (void)l; (void)f; (void)ty; (void)px; }

/* Safe fallback for any other name LWJGL asks about: returning NULL would make
 * LWJGL dlsym() it on our own library and land on gl4es' *FPE* implementation,
 * which is NOT initialized on this path (that crash was measured:
 * libgl4es.so(glClearDepthf+48) @0x48). A no-op keeps us in charge. */
static void mc_safe_noop(void) { }

/* --- init + table-driven GetProcAddress ------------------------------- */
int meowcore_init(void)
{
    if (!meowcore_active()) return 0;
    if (s_inited) return s_gles ? 1 : 0;
    s_inited = 1;

    s_gles = dlopen("/system/lib64/libGLESv3.so", RTLD_NOW | RTLD_LOCAL);
    if (!s_gles) s_gles = dlopen("libGLESv3.so", RTLD_NOW | RTLD_LOCAL);
    if (!s_gles) {
        fprintf(stderr, "[meowcore] dlopen libGLESv3.so failed: %s\n", dlerror());
        return 0;
    }

    s_realGetString     = (mc_pfn_GetString)(void *)mc_sym("glGetString");
    s_realGetStringi    = (mc_pfn_GetStringi)(void *)mc_sym("glGetStringi");
    s_realGetIntegerv   = (mc_pfn_GetIntegerv)(void *)mc_sym("glGetIntegerv");
    s_realCreateShader  = (mc_pfn_CreateShader)(void *)mc_sym("glCreateShader");
    s_realDeleteShader  = (mc_pfn_DeleteShader)(void *)mc_sym("glDeleteShader");
    s_realShaderSource  = (mc_pfn_ShaderSource)(void *)mc_sym("glShaderSource");
    s_realTexImage2D    = (mc_pfn_TexImage2D)(void *)mc_sym("glTexImage2D");
    s_realGetTexLevelParameteriv = (mc_pfn_GetTexLevelParameteriv)(void *)mc_sym("glGetTexLevelParameteriv");
    s_realGetTexLevelParameterfv = (mc_pfn_GetTexLevelParameterfv)(void *)mc_sym("glGetTexLevelParameterfv");
    s_realTexParameteri = (mc_pfn_TexParameteri)(void *)mc_sym("glTexParameteri");
    s_realTexParameterf = (mc_pfn_TexParameterf)(void *)mc_sym("glTexParameterf");
    s_realClearDepthf   = (mc_pfn_ClearDepthf)(void *)mc_sym("glClearDepthf");
    s_realDrawBuffers   = (mc_pfn_DrawBuffers)(void *)mc_sym("glDrawBuffers");
    s_realGetBufferParameteriv = (mc_pfn_GetBufferParameteriv)(void *)mc_sym("glGetBufferParameteriv");
    s_realMapBufferRange = (mc_pfn_MapBufferRange)(void *)mc_sym("glMapBufferRange");
    s_realTexStorage2D = (mc_pfn_TexStorage2D)(void *)mc_sym("glTexStorage2D");
    s_realRenderbufferStorage = (mc_pfn_RenderbufferStorage)(void *)mc_sym("glRenderbufferStorage");
    s_realEnable        = (mc_pfn_Enable)(void *)mc_sym("glEnable");
    s_realDisable       = (mc_pfn_Enable)(void *)mc_sym("glDisable");
    s_realCompileShader = (mc_pfn_CompileShader)(void *)mc_sym("glCompileShader");
    s_realGetShaderiv   = (mc_pfn_GetShaderiv)(void *)mc_sym("glGetShaderiv");
    s_realGetShaderInfoLog = (mc_pfn_GetShaderInfoLog)(void *)mc_sym("glGetShaderInfoLog");
    s_realLinkProgram   = (mc_pfn_LinkProgram)(void *)mc_sym("glLinkProgram");
    s_realGetProgramiv  = (mc_pfn_GetProgramiv)(void *)mc_sym("glGetProgramiv");
    s_realGetProgramInfoLog = (mc_pfn_GetProgramInfoLog)(void *)mc_sym("glGetProgramInfoLog");

    if (s_realGetIntegerv) {
        mc_int m = 0;
        s_realGetIntegerv(MC_GL_MAX_TEXTURE_SIZE, &m);
        if (m > 0) s_maxTexSize = m;
    }

    fprintf(stderr, "[meowcore] core backend init: gles=%p shaderSource=%p maxTex=%d tag=%s\n",
            s_gles, (void *)s_realShaderSource, s_maxTexSize, MC_BUILD_TAG);
    return (s_realGetString && s_realGetIntegerv && s_realShaderSource) ? 1 : 0;
}

struct mc_entry {
    const char *name;
    void       *fn;
};

static const struct mc_entry mc_entries[] = {
    { "glGetString",    (void *)mc_glGetString },
    { "glGetStringi",   (void *)mc_glGetStringi },
    { "glGetIntegerv",  (void *)mc_glGetIntegerv },
    { "glCreateShader", (void *)mc_glCreateShader },
    { "glDeleteShader", (void *)mc_glDeleteShader },
    { "glShaderSource", (void *)mc_glShaderSource },
    { "glCompileShader", (void *)mc_glCompileShader },
    { "glGetShaderiv", (void *)mc_glGetShaderiv },
    { "glGetShaderInfoLog", (void *)mc_glGetShaderInfoLog },
    { "glLinkProgram", (void *)mc_glLinkProgram },
    { "glGetProgramiv", (void *)mc_glGetProgramiv },
    { "glGetProgramInfoLog", (void *)mc_glGetProgramInfoLog },
    { "glBindAttribLocation", (void *)mc_glBindAttribLocation },
    { "glTexImage2D", (void *)mc_glTexImage2D },
    { "glTexStorage2D", (void *)mc_glTexStorage2D },
    { "glRenderbufferStorage", (void *)mc_glRenderbufferStorage },
    { "glGetTexLevelParameteriv", (void *)mc_glGetTexLevelParameteriv },
    { "glGetTexLevelParameterfv", (void *)mc_glGetTexLevelParameterfv },
    { "glTexParameteri", (void *)mc_glTexParameteri },
    { "glTexParameterf", (void *)mc_glTexParameterf },
    { "glEnable", (void *)mc_glEnable },
    { "glDisable", (void *)mc_glDisable },
    { "glClearDepth", (void *)mc_glClearDepth },
    { "glDrawBuffer", (void *)mc_glDrawBuffer },
    { "glMapBuffer", (void *)mc_glMapBuffer },
    { "glPolygonMode", (void *)mc_glPolygonMode },
    { "glDrawPixels", (void *)mc_glDrawPixels },
    { "glGetTexImage", (void *)mc_glGetTexImage },
};

void *meowcore_GetProcAddress(const char *name)
{
    unsigned i;
    void *p;
    if (!name) return NULL;
    if (!s_inited) meowcore_init();

    for (i = 0; i < sizeof(mc_entries) / sizeof(mc_entries[0]); ++i) {
        if (strcmp(mc_entries[i].name, name) == 0)
            return mc_entries[i].fn;
    }
    p = mc_sym(name);
    /* Never NULL: see mc_safe_noop's comment -- a NULL here lets LWJGL fall back to
     * dlsym on libgl4es.so and run uninitialized FPE code. */
    return p ? p : (void *)mc_safe_noop;
}
