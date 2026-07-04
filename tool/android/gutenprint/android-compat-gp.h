/* ---------------------------------------------------------------------------
 * android-compat-gp.h  — force-included (-include) shim for the Gutenprint
 * cross build on Android/bionic. Mirrors tool/android/android-compat.h (the
 * CUPS shim) but for the gaps Gutenprint hits.
 *
 * GAP: iconv. bionic's <iconv.h> DEFINES the iconv_t type at every API level,
 * but DECLARES iconv_open()/iconv()/iconv_close() only __INTRODUCED_IN(28).
 * Gutenprint's src/cups/i18n.c (#include <iconv.h>) calls all three at API 24,
 * so at our API (24) they are hidden -> implicit-int declaration ->
 *   error: incompatible integer to pointer conversion ... iconv_open(...)
 *
 * i18n.c only uses iconv to transcode .po message catalogs (charset=...) to
 * UTF-8, and it ALREADY has a fully-working fallback: if iconv_open() returns
 * (iconv_t)-1 it sets ic = 0 and uses the source string verbatim. We build
 * --disable-nls (no localized catalogs), and .po charsets are virtually always
 * UTF-8 anyway, so the verbatim path is correct here. Therefore on Android
 * API < 28 we provide static-inline stubs that make iconv_open() report
 * "unsupported" ((iconv_t)-1, errno=EINVAL) -> i18n.c takes its safe
 * no-transcode path. iconv()/iconv_close() are provided too (never reached when
 * open fails, but defined for completeness / any other caller).
 *
 * static inline => no new link symbols, no Makefile edits. Active ONLY on
 * __ANDROID__ with __ANDROID_API__ < 28.
 * ------------------------------------------------------------------------- */
#ifndef ANDROID_COMPAT_GP_H
#define ANDROID_COMPAT_GP_H

#if defined(__ANDROID__) && defined(__ANDROID_API__) && (__ANDROID_API__ < 28)

#include <iconv.h>   /* provides the iconv_t typedef (available at all APIs) */
#include <errno.h>
#include <stddef.h>

/* Map the real symbol names to our stubs so callers in i18n.c resolve to
 * these instead of the API28-gated (hidden) libc declarations. */
#define iconv_open  __android_gp_iconv_open
#define iconv       __android_gp_iconv
#define iconv_close __android_gp_iconv_close

static inline iconv_t
__android_gp_iconv_open(const char *to, const char *from)
{
  (void)to; (void)from;
  errno = EINVAL;          /* report "no converter" -> i18n.c falls back */
  return (iconv_t)-1;
}

static inline size_t
__android_gp_iconv(iconv_t cd, char **inbuf, size_t *inbytesleft,
                   char **outbuf, size_t *outbytesleft)
{
  (void)cd; (void)inbuf; (void)inbytesleft; (void)outbuf; (void)outbytesleft;
  errno = EBADF;
  return (size_t)-1;       /* never reached: open above always fails */
}

static inline int
__android_gp_iconv_close(iconv_t cd)
{
  (void)cd;
  return 0;
}

#endif /* __ANDROID__ && __ANDROID_API__ < 28 */

#endif /* ANDROID_COMPAT_GP_H */
