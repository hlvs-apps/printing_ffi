/*
 * android-compat.h — force-included (-include) shim for cross-compiling CUPS
 * 2.4.x against the Android NDK at API 24.
 *
 * Bionic gates several libc account-database functions at API >= 26
 * (getpwent/setpwent/endpwent, getgrent/setgrent/endgrent) and ships NO
 * crypt() at all. CUPS's scheduler (cupsd) calls endpwent()/endgrent() (as
 * cleanup) and crypt() (only in the Basic-auth password compare). On Android
 * there is no /etc/passwd or /etc/shadow, so these are meaningless; Basic auth
 * is not used at runtime (we run cupsd locally over a unix socket).
 *
 * Providing these as static-inline stubs here means:
 *   - the implicit-declaration / int-to-pointer compile errors go away,
 *   - no new objects / Makefile edits are needed,
 *   - no undefined symbols at link time.
 *
 * This header is injected via CFLAGS/CXXFLAGS "-include .../android-compat.h"
 * and only activates on __ANDROID__. Keep it minimal.
 */
#ifndef CUPS_ANDROID_COMPAT_H
#define CUPS_ANDROID_COMPAT_H

#ifdef __ANDROID__
#  include <android/api-level.h>

#  if __ANDROID_API__ < 26
/* Pull in the real declarations first so our stubs match struct types. */
#    include <pwd.h>
#    include <grp.h>

/* Account-database iterators: no /etc/passwd|group on Android -> no-ops.
 * Declared static inline so each TU that includes this gets its own copy and
 * there is no link-time symbol clash. */
static inline void endpwent(void) {}
static inline void setpwent(void) {}
static inline struct passwd *getpwent(void) { return (struct passwd *)0; }

static inline void endgrent(void) {}
static inline void setgrent(void) {}
static inline struct group *getgrent(void) { return (struct group *)0; }
#  endif /* __ANDROID_API__ < 26 */

/* crypt(): absent from bionic entirely. CUPS only uses it to compare a
 * client-supplied password against pw_passwd in the Basic-auth path. Returning
 * NULL makes that comparison always fail (auth denied), which is the safe
 * default for a spike build that does not use Basic auth. */
#  ifndef _CUPS_ANDROID_HAVE_CRYPT
#    define _CUPS_ANDROID_HAVE_CRYPT 1
static inline char *crypt(const char *key, const char *salt)
{
  (void)key;
  (void)salt;
  return (char *)0;
}
#  endif /* _CUPS_ANDROID_HAVE_CRYPT */

#endif /* __ANDROID__ */

#endif /* CUPS_ANDROID_COMPAT_H */
