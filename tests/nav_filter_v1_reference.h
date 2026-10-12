#ifndef MANEATER_PRIVATE_NAV_FILTER_H
#define MANEATER_PRIVATE_NAV_FILTER_H

/*
 * Conservative rejection filter for the verified native portal finder.
 * It emits no links. A possible or uncertain query always uses the original
 * finder. Runtime ownership, memory validation and scoped identity checks live
 * outside this portable core. Mesh inputs here are immutable owned snapshots.
 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <float.h>
#include <xmmintrin.h>

#if defined(__FAST_MATH__)
#error The conservative nav filter requires ordinary scalar SSE semantics.
#endif

#define NAV_MAX_POLYS ((size_t)16384)
#define NAV_MAX_VERTICES ((size_t)65536)
#define NAV_MAX_PORTALS (NAV_MAX_POLYS * (size_t)6)
#define NAV_PORTAL_TOLERANCE_BITS UINT32_C(0x3c23d70a)

typedef struct NavVertex { float xyz[3]; } NavVertex;
typedef struct NavPoly { uint8_t bytes[32]; } NavPoly;

/* Raw endpoint coordinates, rather than bounds precomputed under a possibly
 * different MXCSR. Plane is the FIRST target endpoint, as in native code. */
typedef struct NavPortal {
    float plane;
    float axis_a;
    float axis_b;
    uint32_t side;
} NavPortal;

typedef struct NavIndex {
    const NavPortal *records;
    size_t count;
    uint32_t valid;
} NavIndex;

typedef char nav_float_contract[
    (sizeof(float) == 4 && FLT_RADIX == 2 && FLT_MANT_DIG == 24) ? 1 : -1];
typedef char nav_poly_size_contract[sizeof(NavPoly) == 32 ? 1 : -1];
typedef char nav_vertex_size_contract[sizeof(NavVertex) == 12 ? 1 : -1];
typedef char nav_portal_size_contract[sizeof(NavPortal) == 16 ? 1 : -1];

static uint32_t nav_float_bits(float value)
{
    uint32_t bits;
    memcpy(&bits, &value, sizeof(bits));
    return bits;
}

static float nav_float_from_bits(uint32_t bits)
{
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}

/* Integer classification also avoids evaluating a signaling NaN. */
static int nav_finite(float value)
{
    return (nav_float_bits(value) & UINT32_C(0x7f800000)) !=
           UINT32_C(0x7f800000);
}

static int nav_cardinal_side(uint32_t side)
{
    return side == 0 || side == 2 || side == 4 || side == 6;
}

static uint16_t nav_poly_u16(const NavPoly *poly, size_t offset)
{
    /* The verified native layout is little endian. This explicit read also
     * avoids alignment and strict-aliasing assumptions for copied records. */
    return (uint16_t)((uint16_t)poly->bytes[offset] |
                      ((uint16_t)poly->bytes[offset + 1] << 8));
}

static int nav_build_index(const NavPoly *polys, size_t npoly,
                           const NavVertex *vertices, size_t nverts,
                           NavPortal *records, size_t capacity,
                           NavIndex *index)
{
    size_t i, j, count = 0;
    if (!index) return 0;
    index->records = records;
    index->count = 0;
    index->valid = 0;

    if (npoly > NAV_MAX_POLYS || nverts > NAV_MAX_VERTICES ||
        capacity > NAV_MAX_PORTALS || (npoly && !polys) ||
        (nverts && !vertices) || (capacity && !records)) return 0;

    for (i = 0; i < nverts; ++i) {
        if (!nav_finite(vertices[i].xyz[0]) ||
            !nav_finite(vertices[i].xyz[1]) ||
            !nav_finite(vertices[i].xyz[2])) return 0;
    }

    for (i = 0; i < npoly; ++i) {
        const NavPoly *poly = &polys[i];
        const size_t nv = poly->bytes[30];
        if (nv > 6) return 0;
        for (j = 0; j < nv; ++j) {
            if ((size_t)nav_poly_u16(poly, 4 + j * 2) >= nverts) return 0;
        }
        for (j = 0; j < nv; ++j) {
            const uint16_t flag = nav_poly_u16(poly, 16 + j * 2);
            uint32_t side;
            size_t first, second, axis, plane_axis;
            NavPortal *portal;
            if (flag != UINT16_C(0x8000) && flag != UINT16_C(0x8002) &&
                flag != UINT16_C(0x8004) && flag != UINT16_C(0x8006)) continue;
            if (count >= capacity || !records) return 0;
            side = (uint32_t)(flag & UINT16_C(7));
            first = nav_poly_u16(poly, 4 + j * 2);
            second = nav_poly_u16(poly, 4 + ((j + 1) % nv) * 2);
            axis = (side == 0 || side == 4) ? 2 : 0;
            plane_axis = (side == 0 || side == 4) ? 0 : 2;
            portal = &records[count++];
            portal->plane = vertices[first].xyz[plane_axis];
            portal->axis_a = vertices[first].xyz[axis];
            portal->axis_b = vertices[second].xyz[axis];
            portal->side = side;
        }
    }
    index->count = count;
    index->valid = 1;
    return 1;
}

static void nav_order_axis(float a, float b, __m128 *low, __m128 *high)
{
    const __m128 first = _mm_set_ss(a);
    const __m128 second = _mm_set_ss(b);
    /* Native endpoint sorting compares first < second. Equal endpoints use
     * the second as low and first as high, including their signed-zero bits. */
    if (_mm_comilt_ss(first, second)) {
        *low = first;
        *high = second;
    } else {
        *low = second;
        *high = first;
    }
}

/* 0 means every indexed edge fails an original necessary condition.
 * 1 means possible OR uncertain: the caller must invoke the original finder. */
static int nav_may_connect(const NavIndex *index, const float va[3],
                           const float vb[3], uint32_t side)
{
    size_t i, axis, plane_axis;
    __m128 source_low, source_high, source_plane, tolerance;
    if (!index || index->valid != 1 || index->count > NAV_MAX_PORTALS ||
        (index->count && !index->records) || !va || !vb ||
        !nav_cardinal_side(side)) return 1;
    for (i = 0; i < 3; ++i) {
        if (!nav_finite(va[i]) || !nav_finite(vb[i])) return 1;
    }
    axis = (side == 0 || side == 4) ? 2 : 0;
    plane_axis = (side == 0 || side == 4) ? 0 : 2;
    nav_order_axis(va[axis], vb[axis], &source_low, &source_high);
    source_plane = _mm_set_ss(va[plane_axis]);
    tolerance = _mm_set_ss(nav_float_from_bits(NAV_PORTAL_TOLERANCE_BITS));

    for (i = 0; i < index->count; ++i) {
        const NavPortal *portal = &index->records[i];
        __m128 delta, target_low, target_high, overlap;
        float scalar;
        if (!nav_cardinal_side(portal->side) || !nav_finite(portal->plane) ||
            !nav_finite(portal->axis_a) || !nav_finite(portal->axis_b)) return 1;
        if (portal->side != side) continue;

        delta = _mm_sub_ss(source_plane, _mm_set_ss(portal->plane));
        scalar = _mm_cvtss_f32(delta);
        if (!nav_finite(scalar)) return 1;
        delta = _mm_set_ss(nav_float_from_bits(
            nav_float_bits(scalar) & UINT32_C(0x7fffffff)));
        if (_mm_comigt_ss(delta, tolerance)) continue;

        nav_order_axis(portal->axis_a, portal->axis_b,
                       &target_low, &target_high);
        overlap = _mm_sub_ss(_mm_min_ss(target_high, source_high),
                              _mm_max_ss(target_low, source_low));
        scalar = _mm_cvtss_f32(overlap);
        if (!nav_finite(scalar)) return 1;
        if (_mm_comilt_ss(overlap, tolerance)) continue;
        return 1;
    }
    return 0;
}

#endif
