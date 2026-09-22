/*
 * Meowcraft delta over upstream ref/gl4es/src/gl/build_info.c
 *
 * Why: upstream bakes __DATE__ / __TIME__ into the binary here, which makes the
 * artifact non-reproducible (byte-identical rebuilds are impossible; clang also
 * ignores SOURCE_DATE_EPOCH for those builtins). We print a pinned string
 * instead so the recipe is deterministic. See notes:
 *   notes/20-design/render/GL33到GLES32-后端-方案.md (M8)
 *
 * This file REPLACES the upstream one (same name/path) so the set of source
 * files referenced by the build -- and thus DWARF-- is unchanged.
 */
#include <stdio.h>
#include "build_info.h"
#include "logs.h"
#include "../../version.h"

void print_build_infos()
{
	SHUT_LOGD("v%d.%d.%d (meowcraft)\n", MAJOR, MINOR, REVISION);
}
