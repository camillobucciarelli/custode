// KeePass AES-KDF transform on hardware AES: data (two 16-byte blocks) is
// encrypted with AES-256-ECB under key, rounds times. The final SHA-256 runs
// in Dart. Returns KDBX_AES_KDF_UNSUPPORTED when the CPU has no AES
// instructions, so the caller falls back to the Dart implementation.
//
// The key schedule is portable C with a table S-box: the key is the KDF seed,
// stored in clear in the file header. The secret (data) only goes through the
// AES instructions.

#include <stdint.h>
#include <string.h>

#if defined(_WIN32)
#define KDBX_EXPORT __declspec(dllexport)
#else
#define KDBX_EXPORT __attribute__((visibility("default")))
#endif

#define KDBX_AES_KDF_OK 0
#define KDBX_AES_KDF_UNSUPPORTED 1

#if defined(__x86_64__) || defined(_M_X64)
#define KDBX_AES_X86 1
#include <wmmintrin.h>
#if defined(_MSC_VER) && !defined(__clang__)
#include <intrin.h>
#define KDBX_TARGET_AES
#else
#include <cpuid.h>
#define KDBX_TARGET_AES __attribute__((target("aes,sse2")))
#endif
#elif defined(__aarch64__) || defined(_M_ARM64)
#define KDBX_AES_ARM 1
#if defined(_MSC_VER) && !defined(__clang__)
#include <arm64_neon.h>
#include <windows.h>
#define KDBX_TARGET_AES
#else
#include <arm_neon.h>
#if defined(__clang__)
#define KDBX_TARGET_AES __attribute__((target("aes")))
#else
#define KDBX_TARGET_AES __attribute__((target("+crypto")))
#endif
#if defined(__linux__) || defined(__ANDROID__)
#include <sys/auxv.h>
#ifndef HWCAP_AES
#define HWCAP_AES (1 << 3)
#endif
#endif
#endif
#endif

#if defined(KDBX_AES_X86) || defined(KDBX_AES_ARM)

static const uint8_t kSbox[256] = {
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5, 0x30, 0x01, 0x67, 0x2b,
    0xfe, 0xd7, 0xab, 0x76, 0xca, 0x82, 0xc9, 0x7d, 0xfa, 0x59, 0x47, 0xf0,
    0xad, 0xd4, 0xa2, 0xaf, 0x9c, 0xa4, 0x72, 0xc0, 0xb7, 0xfd, 0x93, 0x26,
    0x36, 0x3f, 0xf7, 0xcc, 0x34, 0xa5, 0xe5, 0xf1, 0x71, 0xd8, 0x31, 0x15,
    0x04, 0xc7, 0x23, 0xc3, 0x18, 0x96, 0x05, 0x9a, 0x07, 0x12, 0x80, 0xe2,
    0xeb, 0x27, 0xb2, 0x75, 0x09, 0x83, 0x2c, 0x1a, 0x1b, 0x6e, 0x5a, 0xa0,
    0x52, 0x3b, 0xd6, 0xb3, 0x29, 0xe3, 0x2f, 0x84, 0x53, 0xd1, 0x00, 0xed,
    0x20, 0xfc, 0xb1, 0x5b, 0x6a, 0xcb, 0xbe, 0x39, 0x4a, 0x4c, 0x58, 0xcf,
    0xd0, 0xef, 0xaa, 0xfb, 0x43, 0x4d, 0x33, 0x85, 0x45, 0xf9, 0x02, 0x7f,
    0x50, 0x3c, 0x9f, 0xa8, 0x51, 0xa3, 0x40, 0x8f, 0x92, 0x9d, 0x38, 0xf5,
    0xbc, 0xb6, 0xda, 0x21, 0x10, 0xff, 0xf3, 0xd2, 0xcd, 0x0c, 0x13, 0xec,
    0x5f, 0x97, 0x44, 0x17, 0xc4, 0xa7, 0x7e, 0x3d, 0x64, 0x5d, 0x19, 0x73,
    0x60, 0x81, 0x4f, 0xdc, 0x22, 0x2a, 0x90, 0x88, 0x46, 0xee, 0xb8, 0x14,
    0xde, 0x5e, 0x0b, 0xdb, 0xe0, 0x32, 0x3a, 0x0a, 0x49, 0x06, 0x24, 0x5c,
    0xc2, 0xd3, 0xac, 0x62, 0x91, 0x95, 0xe4, 0x79, 0xe7, 0xc8, 0x37, 0x6d,
    0x8d, 0xd5, 0x4e, 0xa9, 0x6c, 0x56, 0xf4, 0xea, 0x65, 0x7a, 0xae, 0x08,
    0xba, 0x78, 0x25, 0x2e, 0x1c, 0xa6, 0xb4, 0xc6, 0xe8, 0xdd, 0x74, 0x1f,
    0x4b, 0xbd, 0x8b, 0x8a, 0x70, 0x3e, 0xb5, 0x66, 0x48, 0x03, 0xf6, 0x0e,
    0x61, 0x35, 0x57, 0xb9, 0x86, 0xc1, 0x1d, 0x9e, 0xe1, 0xf8, 0x98, 0x11,
    0x69, 0xd9, 0x8e, 0x94, 0x9b, 0x1e, 0x87, 0xe9, 0xce, 0x55, 0x28, 0xdf,
    0x8c, 0xa1, 0x89, 0x0d, 0xbf, 0xe6, 0x42, 0x68, 0x41, 0x99, 0x2d, 0x0f,
    0xb0, 0x54, 0xbb, 0x16};

// FIPS-197 AES-256 key expansion: 15 round keys, 240 bytes, in the byte order
// both AESENC and AESE expect.
static void expand_key_256(const uint8_t key[32], uint8_t rk[240]) {
  static const uint8_t rcon[7] = {0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40};
  memcpy(rk, key, 32);
  for (int i = 8; i < 60; i++) {
    uint8_t t[4];
    memcpy(t, rk + 4 * (i - 1), 4);
    if (i % 8 == 0) {
      const uint8_t first = t[0];
      t[0] = kSbox[t[1]] ^ rcon[i / 8 - 1];
      t[1] = kSbox[t[2]];
      t[2] = kSbox[t[3]];
      t[3] = kSbox[first];
    } else if (i % 8 == 4) {
      for (int j = 0; j < 4; j++) t[j] = kSbox[t[j]];
    }
    for (int j = 0; j < 4; j++) rk[4 * i + j] = rk[4 * (i - 8) + j] ^ t[j];
  }
}

#endif

#if defined(KDBX_AES_X86)

static int has_aes(void) {
#if defined(_MSC_VER) && !defined(__clang__)
  int info[4];
  __cpuid(info, 1);
  return (info[2] >> 25) & 1;
#else
  unsigned int a, b, c, d;
  if (!__get_cpuid(1, &a, &b, &c, &d)) return 0;
  return (c >> 25) & 1;
#endif
}

KDBX_TARGET_AES
static void transform(const uint8_t rkb[240], uint8_t data[32],
                      uint64_t rounds) {
  __m128i rk[15];
  for (int i = 0; i < 15; i++) {
    rk[i] = _mm_loadu_si128((const __m128i *)(rkb + 16 * i));
  }
  __m128i a = _mm_loadu_si128((const __m128i *)data);
  __m128i b = _mm_loadu_si128((const __m128i *)(data + 16));
  for (uint64_t r = 0; r < rounds; r++) {
    a = _mm_xor_si128(a, rk[0]);
    b = _mm_xor_si128(b, rk[0]);
    for (int i = 1; i < 14; i++) {
      a = _mm_aesenc_si128(a, rk[i]);
      b = _mm_aesenc_si128(b, rk[i]);
    }
    a = _mm_aesenclast_si128(a, rk[14]);
    b = _mm_aesenclast_si128(b, rk[14]);
  }
  _mm_storeu_si128((__m128i *)data, a);
  _mm_storeu_si128((__m128i *)(data + 16), b);
}

#elif defined(KDBX_AES_ARM)

static int has_aes(void) {
#if defined(__APPLE__)
  return 1;  // Every Apple arm64 CPU has the ARMv8 crypto extension.
#elif defined(_WIN32)
  return IsProcessorFeaturePresent(PF_ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE) !=
         0;
#elif defined(__linux__) || defined(__ANDROID__)
  return (getauxval(AT_HWCAP) & HWCAP_AES) != 0;
#else
  return 0;
#endif
}

KDBX_TARGET_AES
static void transform(const uint8_t rkb[240], uint8_t data[32],
                      uint64_t rounds) {
  uint8x16_t rk[15];
  for (int i = 0; i < 15; i++) rk[i] = vld1q_u8(rkb + 16 * i);
  uint8x16_t a = vld1q_u8(data);
  uint8x16_t b = vld1q_u8(data + 16);
  for (uint64_t r = 0; r < rounds; r++) {
    for (int i = 0; i < 13; i++) {
      a = vaesmcq_u8(vaeseq_u8(a, rk[i]));
      b = vaesmcq_u8(vaeseq_u8(b, rk[i]));
    }
    a = veorq_u8(vaeseq_u8(a, rk[13]), rk[14]);
    b = veorq_u8(vaeseq_u8(b, rk[13]), rk[14]);
  }
  vst1q_u8(data, a);
  vst1q_u8(data + 16, b);
}

#endif

KDBX_EXPORT int32_t kdbx_aes_kdf(const uint8_t *key, uint8_t *data,
                                 uint64_t rounds) {
#if defined(KDBX_AES_X86) || defined(KDBX_AES_ARM)
  if (!has_aes()) return KDBX_AES_KDF_UNSUPPORTED;
  uint8_t rk[240];
  expand_key_256(key, rk);
  transform(rk, data, rounds);
  return KDBX_AES_KDF_OK;
#else
  (void)key;
  (void)data;
  (void)rounds;
  return KDBX_AES_KDF_UNSUPPORTED;
#endif
}
