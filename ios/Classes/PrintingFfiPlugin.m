#import "PrintingFfiPlugin.h"
#include "../../src/printing_ffi.h"
#include <cups/cups.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <signal.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

extern char **environ;
extern int printing_ffi_ios_running(void);
extern void printing_ffi_ios_select_server(void);

@implementation PrintingFfiPlugin {
    dispatch_queue_t _worker;
    NSString *_discovery;
    NSString *_runtime;
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *channel = [FlutterMethodChannel
        methodChannelWithName:@"printing_ffi/ios_cups" binaryMessenger:registrar.messenger];
    PrintingFfiPlugin *plugin = [[PrintingFfiPlugin alloc] init];
    plugin->_worker = dispatch_queue_create("printing_ffi.ios_cups", DISPATCH_QUEUE_SERIAL);
    NSBundle *bundle = [NSBundle bundleForClass:self];
    plugin->_runtime = [bundle pathForResource:@"CupsRuntime" ofType:@"bundle"] ?:
        [[NSBundle mainBundle] pathForResource:@"CupsRuntime" ofType:@"bundle"];
    [registrar addMethodCallDelegate:plugin channel:channel];
}

// No shell, jailbreak-name checks, root daemon, or loading private USB symbols
// into Runner. A stock sandbox rejects this spawn and the app remains usable.
- (NSString *)discover:(NSString **)reason {
    if (printing_ffi_ios_running()) {
        // A serial GCD queue can still execute its blocks on different threads.
        // Refresh libcups' thread-local endpoint after a scheduler restart.
        printing_ffi_ios_select_server();
        // Do not claim a printer while CUPS owns an active job. Once idle,
        // rediscover so replacing RX1 with DS620 selects the new model's PPD.
        http_t *connection = httpConnect2(cupsServer(), ippPort(), NULL, AF_UNSPEC,
            HTTP_ENCRYPTION_IF_REQUESTED, 1, 1000, NULL);
        if (!connection) { *reason = @"CUPS health check failed"; return nil; }
        httpSetTimeout(connection, 2.0, NULL, NULL);
        cups_job_t *jobs = NULL;
        int count = cupsGetJobs2(connection, &jobs, NULL, 0, CUPS_WHICHJOBS_ACTIVE);
        ipp_status_t error = cupsLastError();
        httpClose(connection);
        if (count > 0) { cupsFreeJobs(count, jobs); return _discovery; }
        if (count < 0 || error >= IPP_STATUS_ERROR_BAD_REQUEST) {
            *reason = @"CUPS health check failed"; return nil;
        }
    } else {
        _discovery = nil;
    }
    NSString *backend = [_runtime stringByAppendingPathComponent:@"bin/libcupsbe_gutenprint53usb.so"];
    if (!_runtime) {
        *reason = [NSString stringWithFormat:@"CUPS runtime bundle not found in %@ or %@",
            [NSBundle bundleForClass:[self class]].bundlePath, [NSBundle mainBundle].bundlePath];
        return nil;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:backend]) {
        *reason = [NSString stringWithFormat:@"Bundled USB backend file is missing: %@", backend];
        return nil;
    }
    // Attempt the launch itself. An execute-access preflight is not a spawn:
    // jailbreak launch hooks can establish executable trust during posix_spawn.
    // Returning here on isExecutableFileAtPath would bypass those hooks.
    char output[PATH_MAX];
    snprintf(output, sizeof(output), "%sprinting-cups-XXXXXX", NSTemporaryDirectory().fileSystemRepresentation);
    int fd = mkstemp(output);
    if (fd < 0) { *reason = @"Cannot create USB discovery output"; return nil; }
    unlink(output);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fd, STDOUT_FILENO);
    // Preserve libusb/dyld diagnostics as well as discovery records. The Dart
    // parser accepts only lines beginning with "direct".
    posix_spawn_file_actions_adddup2(&actions, fd, STDERR_FILENO);
    // The backend's new URI form identifies the precise Gutenprint model.
    // Explicit environment avoids inherited DEVICE_URI/test-mode variables.
    char *const env[] = {"PATH=/usr/bin:/bin", "LANG=C", "OLD_URI_SCHEME=0", NULL};
    char *const argv[] = {(char *)backend.fileSystemRepresentation, NULL};
    pid_t pid = -1;
    int error = posix_spawn(&pid, argv[0], &actions, NULL, argv, env);
    posix_spawn_file_actions_destroy(&actions);
    if (error) {
        close(fd);
        struct stat info;
        NSString *permissions = stat(argv[0], &info) == 0 ?
            [NSString stringWithFormat:@"mode %04o, owner %u:%u",
                (unsigned)(info.st_mode & 07777), (unsigned)info.st_uid, (unsigned)info.st_gid] :
            @"file attributes unavailable";
        *reason = [NSString stringWithFormat:
            @"USB helper posix_spawn failed: %s (errno %d; %@; app uid %u, euid %u)",
            strerror(error), error, permissions, (unsigned)getuid(), (unsigned)geteuid()];
        return nil;
    }
    int status = 0;
    pid_t done = 0;
    for (int i = 0; i < 100 && done == 0; ++i) {
        done = waitpid(pid, &status, WNOHANG);
        if (done == 0) usleep(100000);
    }
    if (done != pid || !WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        if (done == 0) { kill(pid, SIGKILL); waitpid(pid, NULL, 0); }
        char diagnostic[4096];
        ssize_t size = pread(fd, diagnostic, sizeof(diagnostic) - 1, 0);
        diagnostic[size > 0 ? size : 0] = '\0';
        close(fd);
        NSString *termination = done == 0 ? @"timed out" :
            (done < 0 ? @"wait failed" :
             (WIFSIGNALED(status) ? [NSString stringWithFormat:@"signal %d", WTERMSIG(status)] :
              [NSString stringWithFormat:@"exit %d", WEXITSTATUS(status)]));
        *reason = [NSString stringWithFormat:@"USB discovery %@: %s", termination, diagnostic];
        return nil;
    }
    char bytes[65537];
    ssize_t length = pread(fd, bytes, sizeof(bytes), 0);
    close(fd);
    if (length < 0 || length == sizeof(bytes)) {
        *reason = @"Invalid USB discovery response";
        return nil;
    }
    _discovery = [[NSString alloc] initWithBytes:bytes length:(NSUInteger)length encoding:NSUTF8StringEncoding];
    return _discovery;
}

- (id)start:(NSDictionary *)arguments {
    NSString *uri = arguments[@"uri"];
    NSString *driver = arguments[@"driver"];
    NSString *queue = arguments[@"queueName"];
    // start is accepted only for a device this exact bundled backend opened.
    NSString *prefix = [NSString stringWithFormat:@"direct %@ ", uri];
    BOOL discovered = NO;
    for (NSString *line in [_discovery componentsSeparatedByString:@"\n"]) {
        if ([line hasPrefix:prefix]) discovered = YES;
    }
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"] invertedSet];
    if (!discovered || !driver.length || !queue.length || queue.length > 127 ||
        [driver rangeOfCharacterFromSet:invalid].location != NSNotFound ||
        [queue rangeOfCharacterFromSet:invalid].location != NSNotFound) {
        return [FlutterError errorWithCode:@"unavailable" message:@"Printer access was not established" details:nil];
    }
    NSString *root = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory,
        NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"printing_ffi/cups"];
    NSString *bin = [_runtime stringByAppendingPathComponent:@"bin"];
    NSString *doc = [_runtime stringByAppendingPathComponent:@"share/doc/cups"];
    int port = start_cups_server(root.fileSystemRepresentation, bin.fileSystemRepresentation,
        _runtime.fileSystemRepresentation, doc.fileSystemRepresentation);
    if (port <= 0) return [FlutterError errorWithCode:@"unavailable"
        message:[NSString stringWithUTF8String:get_last_error()] details:nil];

    cups_dest_t *existing = cupsGetNamedDest(NULL, queue.UTF8String, NULL);
    BOOL configured = existing != NULL;
    if (existing) {
        const char *current = cupsGetOption("device-uri", existing->num_options, existing->options);
        configured = current && strcmp(current, uri.UTF8String) == 0;
        cupsFreeDests(1, existing);
    }
    if (!configured) {
        const char *ppd = generate_cups_dnp_ppd(driver.UTF8String);
        configured = ppd && add_cups_printer(queue.UTF8String, uri.UTF8String, ppd);
    }
    if (!configured) {
        NSString *message = [NSString stringWithUTF8String:get_last_error()];
        stop_cups_server();
        return [FlutterError errorWithCode:@"unavailable" message:message details:nil];
    }
    return @{@"port": @(port)};
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if (![call.method isEqualToString:@"discover"] && ![call.method isEqualToString:@"start"]) {
        result(FlutterMethodNotImplemented);
        return;
    }
    dispatch_async(_worker, ^{
        id value;
        if ([call.method isEqualToString:@"discover"]) {
            NSString *reason = @"USB printer access unavailable";
            value = [self discover:&reason] ?: [FlutterError errorWithCode:@"unavailable" message:reason details:nil];
        } else {
            value = [self start:call.arguments];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ result(value); });
    });
}
@end
