// --------------------------------------------------------
// Dragon
// Copyright(c) 2017 SeetaTech
// Written by Ting Pan
// --------------------------------------------------------

#ifndef DRAGON_UTILS_CAST_H_
#define DRAGON_UTILS_CAST_H_

#include <cstring>
#include "core/types.h"

namespace dragon {

template <typename DestType, typename SrcType>
DestType dragon_cast(SrcType val);

template<> inline int dragon_cast<int, float>(float val) {
    return static_cast<int>(val);
}

template<> inline float dragon_cast<float, float>(float val) {
    return val;
}

template<> inline float16 dragon_cast<float16, float>(float val) {
    float16 ret;
    unsigned* xp = reinterpret_cast<unsigned int*>(&val);
    unsigned x = *xp;
    unsigned u = (x & 0x7fffffff), remainder, shift, lsb, lsb_s1, lsb_m1;
    unsigned sign, exponent, mantissa;
    // Get rid of +NaN/-NaN case first.
    if (u > 0x7f800000) {
        ret.x = 0x7fffU;
        return ret;
    }
    sign = ((x >> 16) & 0x8000);
    // Get rid of +Inf/-Inf, +0/-0.
    if (u > 0x477fefff) {
        ret.x = sign | 0x7c00U;
        return ret;
    }
    if (u < 0x33000001) {
        ret.x = (sign | 0x0000);
        return ret;
    }
    exponent = ((u >> 23) & 0xff);
    mantissa = (u & 0x7fffff);
    if (exponent > 0x70) {
        shift = 13;
        exponent -= 0x70;
    } else {
        shift = 0x7e - exponent;
        exponent = 0;
        mantissa |= 0x800000;
    }
    lsb = (1 << shift);
    lsb_s1 = (lsb >> 1);
    lsb_m1 = (lsb - 1);
    // Round to nearest even.
    remainder = (mantissa & lsb_m1);
    mantissa >>= shift;
    if (remainder > lsb_s1 || (remainder == lsb_s1 && (mantissa & 0x1))) {
        ++mantissa;
        if (!(mantissa & 0x3ff)) {
            ++exponent;
            mantissa = 0;
        }
    }
    ret.x = (sign | (exponent << 10) | mantissa);
    return ret;
}

template<> inline float dragon_cast<float, float16>(float16 val) {
    unsigned sign = ((val.x >> 15) & 1);
    unsigned exponent = ((val.x >> 10) & 0x1f);
    unsigned mantissa = ((val.x & 0x3ff) << 13);

    if (exponent == 0x1f) { /* NaN or Inf */
        mantissa = (mantissa ? (sign = 0, 0x7fffff) : 0);
        exponent = 0xff;
    } else if (!exponent) { /* Denorm or Zero */
        if (mantissa) {
            unsigned int msb;
            exponent = 0x71;
            do {
                msb = (mantissa & 0x400000);
                mantissa <<= 1; /* normalize */
                --exponent;
            } while (!msb);
            mantissa &= 0x7fffff; /* 1.mantissa is implicit */
        }
    } else {
        exponent += 0x70;
    }

    unsigned i = ((sign << 31) | (exponent << 23) | mantissa);
    float ret;
    memcpy(&ret, &i, sizeof(i));
    return ret;
}

template<> inline float32 dragon_cast<float32, float16>(float16 val) {
    float32 ret;
    unsigned short* dst = reinterpret_cast<unsigned short*>(&ret);
    unsigned short* src = reinterpret_cast<unsigned short*>(&val);
    for (int i = 0; i < 2; ++i) dst[i] = src[0];
    return ret;
}

template<> inline float32 dragon_cast<float32, float>(float val) {
    float16 t = dragon_cast<float16, float>(val);
    return dragon_cast<float32, float16>(t);
}


}    // namespace dragon

#endif    // DRAGON_UTILS_CAST_H_