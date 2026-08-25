/*
 * This codebase predates GCC 5+ and only ships compiler-gccN.h shims up
 * to GCC 4. The feature-detection macros in compiler-gcc4.h are all
 * still valid on modern GCC, so reuse it as-is rather than maintaining
 * a new per-version file for every later compiler release.
 */
#include "compiler-gcc4.h"
