/* SPDX-License-Identifier: GPL-2.0-or-later
 *
 * A small C ABI library for Chapter 6.
 *
 * Windows (MinGW-w64):
 *   gcc -O2 -Wall -Wextra -shared -o probe_native.dll probe_native.c
 * Linux:
 *   gcc -O2 -Wall -Wextra -fPIC -shared -o libprobe_native.so probe_native.c -lm
 * macOS:
 *   cc -O2 -Wall -Wextra -dynamiclib -o libprobe_native.dylib probe_native.c
 */

#include <math.h>
#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#  define PROBE_EXPORT __declspec(dllexport)
#  define PROBE_CALL __cdecl
#else
#  define PROBE_EXPORT __attribute__((visibility("default")))
#  define PROBE_CALL
#endif

#ifdef __cplusplus
extern "C" {
#endif

PROBE_EXPORT uint32_t PROBE_CALL probe_abi_version(void)
{
  return 1u;
}

PROBE_EXPORT int PROBE_CALL probe_scale_verts(float *coords, size_t count, float factor)
{
  if (coords == NULL || count == 0) {
    return -1;
  }
  if (!(factor == factor)) {
    return -1;
  }

  const size_t total = count * 3u;
  for (size_t i = 0; i < total; ++i) {
    coords[i] *= factor;
  }
  return 0;
}

PROBE_EXPORT int PROBE_CALL probe_bounds(const float *coords,
                                         size_t count,
                                         float *out_min,
                                         float *out_max)
{
  if (coords == NULL || count == 0 || out_min == NULL || out_max == NULL) {
    return -1;
  }

  float min_value[3] = {coords[0], coords[1], coords[2]};
  float max_value[3] = {coords[0], coords[1], coords[2]};

  for (size_t i = 1; i < count; ++i) {
    const size_t base = i * 3u;
    for (int axis = 0; axis < 3; ++axis) {
      const float value = coords[base + (size_t)axis];
      if (value < min_value[axis]) {
        min_value[axis] = value;
      }
      if (value > max_value[axis]) {
        max_value[axis] = value;
      }
    }
  }

  for (int axis = 0; axis < 3; ++axis) {
    out_min[axis] = min_value[axis];
    out_max[axis] = max_value[axis];
  }
  return 0;
}

PROBE_EXPORT double PROBE_CALL probe_busy_work(uint64_t iterations)
{
  double result = 0.0;
  for (uint64_t i = 0; i < iterations; ++i) {
    result += sqrt((double)(i % 100000u) + 1.0);
  }
  return result;
}

#ifdef __cplusplus
}
#endif
