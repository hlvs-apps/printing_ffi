"""Adapt pinned upstream sources for iOS, without Android compatibility shims."""
from pathlib import Path
import sys
import re


def patch(root):
    root = Path(root)
    if (root / '.ios-patched').exists():
        return
    # CUPS' macOS integrations use desktop-only Security/IOKit/sandbox APIs.
    # Keep its portable POSIX/IPP implementation and posix_spawn scheduler.
    for p in (root / 'cups').rglob('*'):
        if p.suffix not in ('.c', '.h', '.cxx') or p.name in (
                'http.h', 'http-private.h', 'getifaddrs-internal.h', 'hash.c'):
            continue
        s = p.read_text()
        s = re.sub(r'#\s*ifdef __APPLE__', '#if 0 /* iOS: no macOS integration */', s)
        s = re.sub(r'#\s*ifndef __APPLE__', '#if 1 /* iOS: portable integration */', s)
        s = s.replace('defined(__APPLE__)', '0 /* iOS: no macOS integration */')
        p.write_text(s)
    # The app owns cupsd's foreground process; daemonizing with fork is not an
    # iOS operation. cups-deviced/driverd pipe helpers use posix_spawn too.
    p = root / 'cups/scheduler/main.c'
    s = p.read_text()
    begin = s.index('  if (!fg)\n', s.index('* Run in the background as needed'))
    end = s.index('  cupsdSetBusyState(1);', begin)
    s = s[:begin] + '  if (!fg) return (1); /* iOS requires -f */\n\n' + s[end:]
    # Tie the scheduler to its app and prevent two app launches from consuming
    # the same durable spool. The lock survives app death until cupsd exits.
    s = '#include <sys/file.h>\n' + s
    s = s.replace('  struct rlimit\t\tlimit;',
                  '  const pid_t printing_owner = getppid();\n  int printing_lock;\n  char printing_lock_path[1024];\n  struct rlimit\t\tlimit;', 1)
    s = s.replace('  cupsdStartServer();', """  snprintf(printing_lock_path, sizeof(printing_lock_path), "%s/printing_ffi.lock", StateDir);
  printing_lock = open(printing_lock_path, O_CREAT | O_RDWR | O_CLOEXEC, 0600);
  if (printing_lock < 0 || flock(printing_lock, LOCK_EX | LOCK_NB)) return (1);
  cupsdStartServer();""", 1)
    s = s.replace('  while (!stop_scheduler)\n  {',
                  '  while (!stop_scheduler)\n  {\n    if (getppid() != printing_owner) break;', 1)
    s = s.replace('(timeout = select_timeout(fds)) > 1 && LastEvent',
                  '(timeout = select_timeout(fds)) > 1')
    p.write_text(s)
    p = root / 'cups/scheduler/util.c'
    s = p.read_text()
    begin = s.index('  if ((*pid = fork()) < 0)')
    end = s.index('  close(fds[1]);', s.index('* Parent comes here', begin))
    s = s[:begin] + """  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0);
  posix_spawn_file_actions_adddup2(&actions, fds[1], 1);
  pid_t child;
  int error = posix_spawn(&child, command, &actions, NULL, argv, environ);
  posix_spawn_file_actions_destroy(&actions);
  if (error) {
    close(fds[0]); close(fds[1]); *pid = 0; errno = error; return NULL;
  }
  *pid = child;
""" + s[end:]
    s = '#include <spawn.h>\nextern char **environ;\n' + s
    p.write_text(s)
    p = root / 'cups/configure'
    s = p.read_text().replace('-weak_framework ApplicationServices', '').replace('-framework IOKit', '')
    p.write_text(s)
    # Equivalent to Procursus' libusb availability patch, using the same
    # Darwin USB interface on iOS without macOS deployment-version macros.
    p = root / 'usb/libusb/os/darwin_usb.c'
    s = p.read_text()
    s = s.replace('#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060 && MAC_OS_X_VERSION_MIN_REQUIRED < 101200', '#if 0')
    for check in ('MAC_OS_X_VERSION_MIN_REQUIRED >= 1060',
                  'MAC_OS_X_VERSION_MAX_ALLOWED >= 1080',
                  'MAC_OS_X_VERSION_MAX_ALLOWED >= 101000',
                  'MAC_OS_X_VERSION_MAX_ALLOWED >= 101200'):
        s = s.replace('#if ' + check, '#if 1')
    p.write_text(s)
    # iOS has no macOS authorization UI. Normal USB open/claim still probes the
    # caller's actual access; a kernel-owned device cannot use this desktop path.
    s = p.read_text().replace(
        'IOServiceAuthorize (dpriv->service, kIOServiceInteractionAllowed)',
        'kIOReturnUnsupported /* macOS authorization UI is unavailable on iOS */')
    p.write_text(s)
    # Do not run an iOS extract-strings binary on the build host. The source
    # distribution already includes this header; translations are disabled.
    p = root / 'gutenprint/src/xml/Makefile.in'
    s = p.read_text()
    begin = s.index('xmli18n-tmp.h: xml-stamp extract-strings')
    end = s.index('\ndist-hook:', begin)
    s = s[:begin] + 'xmli18n-tmp.h:\n\t@test -f $@\n' + s[end:]
    p.write_text(s)
    (root / '.ios-patched').touch()


if __name__ == '__main__':
    patch(sys.argv[1])
