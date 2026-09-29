/*
 * Meowcraft delta overlay of upstream gl4es src/gl/fog.c (v1.1.7).
 *
 * WHY THIS FILE EXISTS: OptiFine 1.7.10's "Fog: Fast" renders the whole world invisible on
 * our gl4es FPE path (Fog: Off/Fancy are fine) and no GL error is reported. gl4es exports no
 * "trace every GL call" switch, so this overlay adds an env-gated trace of the complete
 * fixed-function fog state. Every fog setter funnels through gl4es_glFogfv() (glFogi/glFogiv
 * in gl4eswraps.c and glFogf below are thin wrappers), so one hook here captures everything
 * OptiFine does, including its per-chunk Fog: Fast updates.
 *
 *   MEOW_FOG_TRACE=1   print each fog STATE CHANGE (capped) + the first few glFogCoord calls
 *
 * Inert (zero output, one getenv) when the variable is unset — safe to keep in the shipped
 * build. Evidence/plan: notes/20-design/launch/Forge-splash-崩溃根因与共享上下文修复.md §9.3.
 */
#include "fog.h"

#include "../glx/hardext.h"
#include "fpe.h"
#include "gl4es.h"
#include "glstate.h"
#include "loader.h"
#include "matrix.h"
#include "matvec.h"
#include "program.h"  /* Meowcraft fog fix: GoUniformfv / program_t */

#include <stdio.h>   /* Meowcraft: fog trace */
#include <stdlib.h>  /* Meowcraft: getenv */

/* Meowcraft fog trace (env MEOW_FOG_TRACE=1). Read once. */
/* Meowcraft workaround（2026-09-29，**默认开启**）：**忽略 App 的距离模式设置，一律按
 * `GL_EYE_RADIAL_NV`（径向）走**。设为 `MEOW_FOG_FORCE_RADIAL=0` 可关（回到忠实实现）。
 *
 * 依据（实机取证，见 notes `20-design/render/gl4es固定管线雾-取证与修复.md`）：
 *  · OptiFine `Fog: Fancy`（RADIAL：`FogSrc = vertex.xyz` + `length()`）画面**正常**；
 *  · OptiFine `Fog: Fast`（PLANE_ABS：`FogSrc = vertex.z` + `abs()`）画面**几何被撕成条** ✗；
 *  · 两者的**唯一**差别就是这个距离模式（OF 字节码：Fancy 设 0x855B、Fast 设 0x855C）；
 *  · gl4es 侧的状态 / 变体选择 / uniform 上传（GL 回读 600/600 一致）/ shader 公式与精度
 *    **全部逐环验证正确** ⇒ 坏的只是"平面那支变体"本身；
 *  · 开启本开关后实测：`forced RADIAL` 6365 次、Fast 下带雾变体 `dist` 全为 0x2、画面正常 ✓。
 * 径向雾与平面雾在同等距离下视觉几乎一致 ⇒ 这是可逆的可用性兜底，而非关闭雾效。 */
static int meow_fog_force_radial(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("MEOW_FOG_FORCE_RADIAL");
        on = (e != NULL && e[0] == '0' && e[1] == '\0') ? 0 : 1;   /* 默认开；显式 "0" 才关 */
    }
    return on;
}

/* ★E1 判别实验（2026-09-29，已做完、**开关已移除**）：曾加过 `MEOW_FOG_FORCE_PLANE=1`（全场景强制平面、
 * 只用**一个**变体）。实机结果：**仍然坏，且错误渲染更稀疏** ⇒ ⇒ **结论 = 坏的是「平面（PLANE_ABS）变体自身」**
 * （生成的 shader / 驱动编译那一层），**不是**"两变体共存/切换"（否则单变体平面就该正常）。
 * 与 E2（关掉我方那段的 uniform 推送 ⇒ 仍坏）合起来 ⇒ 真凶在**平面变体**这条路上，与我方推送无关。
 * ⇒ 该开关已移除（它只会产生坏画面），保留运行期兜底 `MEOW_FOG_FORCE_RADIAL`（默认开）。 */

/* ★部署自证（2026-09-29）：**每次运行只打一次**的运行期版本/开关报告。
 * 动机：我们已被"换了 `libs/**` 里的 .so、但 app 没 clean 重建/两个 HSP 没都装 ⇒ **跑的还是旧件**"
 * 咬过三次（liblwjgl、gl4es×2），而 env 照样会传进去 ⇒ **只看 env 无法判断装机件新旧** ✗。
 * 有了这一行，任何一次 .logs 都能直接回答"设备上到底跑的是哪一版 gl4es、哪些开关是开的"。 */
static int g_meowBuildLogged = 0;
#define MEOW_GL4ES_BUILD_TAG "2026-09-29-fogfix-reentrant"

static int meow_fog_trace(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("MEOW_FOG_TRACE");
        on = (e != NULL && e[0] != '\0' && !(e[0] == '0' && e[1] == '\0')) ? 1 : 0;
    }
    return on;
}

/* Print at most MEOW_FOG_TRACE_MAX state changes, then one summary line. OptiFine's
 * Fog: Fast re-sets GL_FOG_START/END per chunk, so an uncapped print would flood hilog. */
#define MEOW_FOG_TRACE_MAX 4000
static int g_meowFogPrints = 0;
static const char *meow_fog_pname_str(GLenum pname) {
    switch (pname) {
        case GL_FOG_MODE:             return "MODE";
        case GL_FOG_DENSITY:          return "DENSITY";
        case GL_FOG_START:            return "START";
        case GL_FOG_END:              return "END";
        case GL_FOG_INDEX:            return "INDEX";
        case GL_FOG_COLOR:            return "COLOR";
        case GL_FOG_COORD_SRC:        return "COORD_SRC";
        case GL_FOG_DISTANCE_MODE_NV: return "DISTANCE_MODE_NV";
        default:                      return "?";
    }
}

/* ------------------------------------------------------------------------- *
 * ★ 已删除（2026-09-29）：曾经存在的"雾变化时推送 FPE 雾 uniform"机制 ★
 *
 * 【当初为什么存在】当时的现象是"世界不见 / 被涂成雾色"，推断"显示列表回放不经过
 *   `realize_glenv()` ⇒ 地形变体拿不到雾 uniform（end=0, scale=0 ⇒ FogF=0 ⇒
 *   mix(fogColor,color,0)=fogColor）"，于是加了"在 `glFogfv` / 列表回放时主动把当前雾值推进
 *   （当时绑定着的）FPE 变体"的补丁 —— `fpe_UploadFogUniforms()`（fog.c 侧）+ `meow_fpe_fog_push()`
 *   （fpe.c 侧，见那边同段留档），并由 `MEOW_FOG_FIX` 控制。
 *
 * 【为什么丢掉】三条独立证据都指向它不该存在：
 *   ① **前提是错的**：`loader.h:205-211` 的 `LOAD_GLES_FPE` 在 ES2 下把
 *      `gles_glDrawArrays/Elements` 直接指向 `fpe_glDrawArrays/Elements` ⇒ 显示列表回放
 *      **本来就会**走 `realize_glenv()`、每次绘制都上传雾 uniform（另有对已装机 .so 的
 *      反汇编实证；见 notes `20-design/render/gl4es固定管线雾-取证与修复.md`）。
 *   ② **它本身有害**：`GoUniformfv()`（`uniform.c:163-209`）不绑定程序，写的是"此刻绑定的那个
 *      程序"；一旦此刻绑的不是目标程序，就会把雾值写进**别的程序的同号 uniform**（第一版正是
 *      这样踩出"巨大黑面片"）。
 *   ③ **判别实验 E2 判定它无罪也无用**：关掉它、退回纯上游行为（`Fog: Fast`）⇒ 画面**依旧坏**
 *      ⇒ 它既不是真凶、也治不了病（真凶见上：**平面雾变体自身**）。
 *   ⇒ 故**整段删除**：`MEOW_FOG_FIX` 开关、`[fogfix] active` 日志标记、`fpe_UploadFogUniforms`
 *     与 `meow_fpe_fog_push` 全部随之消失。
 * ------------------------------------------------------------------------- */

/* Meowcraft experiment (2026-09-29): OptiFine's "Fog: Fast" switches the NV distance mode
 * to GL_EYE_RADIAL_NV (measured: DISTANCE_MODE_NV p0=0x855B). gl4es then takes the RADIAL
 * path (vertex shader `FogSrc = vertex.xyz`, fragment `length(FogSrc)`), while vanilla leaves
 * the default GL_EYE_PLANE_ABSOLUTE_NV (`vertex.z`). Set MEOW_FOG_NO_NV_DISTANCE=1 to IGNORE
 * the app's distance-mode change and keep the vanilla plane behavior -- a one-line A/B that
 * tells us whether the radial path is the culprit. */
static int meow_fog_no_nv_distance(void) {
    static int on = -1;
    if (on < 0) {
        const char *e = getenv("MEOW_FOG_NO_NV_DISTANCE");
        on = (e != NULL && e[0] == '1' && e[1] == '\0') ? 1 : 0;
    }
    return on;
}

void APIENTRY_GL4ES gl4es_glFogfv(GLenum pname, const GLfloat* params) {
    /*
     * ★可重入修正（2026-09-29）：强制距离模式用的改写缓冲曾写作 `static GLfloat s_forceMode[4]`。
     * 它是**每次调用都要重写**的临时值，却放在静态存储 ⇒ 函数不再可重入：第二个线程同时进
     * glFogfv 就会互相踩对方 `params` 指向的缓冲。现行假设「GL 调用只在渲染线程下发」**不变**
     * （gl4es 前提是同一时刻只有一个 GL 使用者；见 egl_gl.c 的 meow_allow_shared_ctx()），但状态
     * 移出静态存储后，即便假设被打破也只是各用各的副本 ⇒ 行为不再依赖调用顺序。语义不变。
     * 声明放在**函数作用域**（不能放进下方那个 `{ }` 块）：`params` 在块结束之后仍被下方
     * switch 与 `gles_glFogfv()` 读取 ⇒ 缓冲的生命期必须覆盖整个函数体。
     */
    GLfloat forceMode[4];

    /* ★一次性运行报告：确认设备上跑的到底是哪一版 gl4es、哪些开关生效（见文件顶部说明）。 */
    if (!g_meowBuildLogged) {
        g_meowBuildLogged = 1;
        fprintf(stderr, "[meow-gl4es] build=%s force_radial=%d\n",
            MEOW_GL4ES_BUILD_TAG, meow_fog_force_radial());
    }

    if (glstate->list.active)
        if (glstate->list.compiling) {
                /* Meowcraft diagnostic（H4）：显示列表**编译期**的雾调用 —— 现有 [fogtrace] 在这里会静默，
                 * 所以"OF 是否在列表内设雾"以前无法回答。列表回放只按 GL_FOG_COLOR 重放一个 op
                 * （listrl.c:398-406 + listdraw.c:417-419）⇒ 列表内的 START/END/MODE 永不生效。 */
                if (meow_fog_trace()) {
                    fprintf(stderr, "[fogtrace-list] pname=0x%04X p0=%g (recorded into a display list)\n",
                        (unsigned)pname, params ? params[0] : 0.f);
                }
                NewStage(glstate->list.active, STAGE_FOG);
                rlFogOp(glstate->list.active, pname, params);
                return;
            }
        else gl4es_flush();
    noerrorShim();
    /* Meowcraft workaround（见上方 meow_fog_force_radial 注释）：把 `GL_FOG_DISTANCE_MODE_NV` 的传入值
     * 直接改写成 `GL_EYE_RADIAL_NV`，这样**状态层**（`glstate->fog.distance`）与**转发调用**
     * （ES2 下 `gles_glFogfv` == `fpe_glFogfv`，负责填 `fpe_state->fogdist`）拿到的都是 RADIAL
     * ⇒ 实际选用的变体就是"实测可用"的那条（`FogSrc = vertex.xyz` + `length()`）。 */
    {
        /* forceMode 声明在函数顶部（那里有可重入说明，以及为何不能是本块局部）。 */
        GLenum want = 0;
        if (meow_fog_force_radial()) {
            want = GL_EYE_RADIAL_NV;   /* 可用性兜底（默认开）：平面变体在本栈上坏，见上方 E1 结论 */
        }
        if (want != 0 && pname == GL_FOG_DISTANCE_MODE_NV && (GLenum)params[0] != want) {
            forceMode[0] = (GLfloat)want;
            params = forceMode;
            if (meow_fog_trace()) {
                fprintf(stderr, "[fogtrace] DISTANCE_MODE_NV -> forced 0x%X (%s)\n",
                    (unsigned)want, (want == GL_EYE_RADIAL_NV) ? "RADIAL" : "PLANE");
            }
        }
    }
    #define GO(A,name, size) if(memcmp(A glstate->fog.name, params, size)==0) return; else memcpy(A glstate->fog.name, params, size);
    #define GOI(name) if(glstate->fog.name==params[0]) return; else glstate->fog.name=params[0];
    switch (pname) {
        case GL_FOG_MODE:
            GOI(mode)
            break;
        case GL_FOG_DENSITY:
            if(*params<0.f) {
                errorShim(GL_INVALID_VALUE);
                return;
            }
            GO(&, density, sizeof(GLfloat))
            break;
        case GL_FOG_START:
            GO(&, start, sizeof(GLfloat))
            break;
        case GL_FOG_END:
            GO(&, end, sizeof(GLfloat))
            break;
        case GL_FOG_INDEX:
            GO(&, index, sizeof(GLfloat))
            return; // unsupported for now
        case GL_FOG_COLOR:
#if defined(__GNUC__) && (__GNUC__ > 7)
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wstringop-overflow"
#endif
            // GCC 8.1 warn about reading 16 bytes from a 4 bytes value, but params is not (in that case) a 4 bytes value
            GO(, color, 4*sizeof(GLfloat))
#if defined(__GNUC__) && (__GNUC__ > 7)
#pragma GCC diagnostic pop
#endif
            break;
        case GL_FOG_COORD_SRC:
            GOI(coord_src)
            if(hardext.esversion==1)
                return; // unsupported on GLES1.1
            break;
        case GL_FOG_DISTANCE_MODE_NV:
            if (meow_fog_no_nv_distance()) {
                if (meow_fog_trace()) {
                    fprintf(stderr, "[fogtrace] DISTANCE_MODE_NV ignored (MEOW_FOG_NO_NV_DISTANCE=1)\n");
                }
                return;
            }
            GOI(distance)
            if(hardext.esversion==1)
                return; // unsupported on GLES1.1
            break;
        default:
            errorShim(GL_INVALID_ENUM);
            return;
    }
    #undef GO
    #undef GOI
    /* Meowcraft: reached only when the state actually CHANGED (the GO/GOI macros return on a
     * no-op), so this is OptiFine's real fog traffic, not every call. */
    if(meow_fog_trace()) {
        if(g_meowFogPrints < MEOW_FOG_TRACE_MAX) {
            ++g_meowFogPrints;
            fprintf(stderr, "[fogtrace] #%d %s pname=0x%04X p0=%g p1=%g p2=%g p3=%g | mode=0x%X start=%g end=%g density=%g coord_src=0x%X dist=0x%X\n",
                g_meowFogPrints, meow_fog_pname_str(pname), (unsigned)pname,
                params?params[0]:0.f, params?params[1]:0.f, params?params[2]:0.f, params?params[3]:0.f,
                (unsigned)glstate->fog.mode, glstate->fog.start, glstate->fog.end,
                glstate->fog.density, (unsigned)glstate->fog.coord_src,
                (unsigned)glstate->fog.distance);
        } else if(g_meowFogPrints == MEOW_FOG_TRACE_MAX) {
            ++g_meowFogPrints;
            fprintf(stderr, "[fogtrace] cap reached (%d state changes); further changes not printed\n", MEOW_FOG_TRACE_MAX);
        }
    }
    LOAD_GLES_FPE(glFogfv);
    gles_glFogfv(pname, params);
    errorGL();
}

void APIENTRY_GL4ES gl4es_glFogf(GLenum pname, GLfloat param) {
    gl4es_glFogfv(pname, &param);
}

void APIENTRY_GL4ES gl4es_glFogCoordd(GLdouble coord) {
    gl4es_glFogCoordf(coord);
}
void APIENTRY_GL4ES gl4es_glFogCoorddv(const GLdouble *coord) {
    gl4es_glFogCoordf(*coord);
}
void APIENTRY_GL4ES gl4es_glFogCoordfv(const GLfloat *coord) {
    gl4es_glFogCoordf(*coord);
}
void APIENTRY_GL4ES gl4es_glFogCoordf(GLfloat coord) {
    /* Meowcraft: the first few fog-coord values tell us whether the app supplies per-vertex
     * fog coordinates at all (i.e. whether GL_FOG_COORD_SRC is ever meaningful here). */
    if(meow_fog_trace()) {
        static int n = 0;
        if(n < 8) {
            ++n;
            fprintf(stderr, "[fogtrace] glFogCoordf #%d coord=%g\n", n, coord);
        }
    }
    if (glstate->list.active) {
        if(glstate->list.pending)
            gl4es_flush();
        else
        {
            rlFogCoordf(glstate->list.active, coord);
            glstate->list.active->lastFogCoord = coord;
        }
        noerrorShim();
    } else {
        noerrorShim();
    }
    // change the state last thing
    glstate->fogcoord[0] = coord;
}


AliasExport(void,glFogfv,,(GLenum pname, const GLfloat* params));
AliasExport(void,glFogf,,(GLenum pname, GLfloat param));
AliasExport_D(void,glFogCoordd,,(GLdouble coord));
AliasExport(void,glFogCoorddv,,(const GLdouble *coord));
AliasExport(void,glFogCoordf,,(GLfloat coord));
AliasExport(void,glFogCoordfv,,(const GLfloat *coord));

AliasExport(void,glFogfv,EXT,(GLenum pname, const GLfloat* params));
AliasExport(void,glFogf,EXT,(GLenum pname, GLfloat param));
AliasExport_D(void,glFogCoordd,EXT,(GLdouble coord));
AliasExport(void,glFogCoorddv,EXT,(const GLdouble *coord));
AliasExport(void,glFogCoordf,EXT,(GLfloat coord));
AliasExport(void,glFogCoordfv,EXT,(const GLfloat *coord));
