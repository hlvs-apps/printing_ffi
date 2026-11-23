#import "PrintingFfiPlugin.h"
#import <UIKit/UIKit.h>
#include <arpa/inet.h>
#include <dns_sd.h>
#include <errno.h>
#include <math.h>
#include <sys/select.h>
#include "../../src/printing_ffi.h"

@interface PrintingFfiPlugin () <UIDocumentInteractionControllerDelegate, FlutterSceneLifeCycleDelegate>
@end

// The iOS app is a CUPS CLIENT only. It never runs cupsd, opens USB, or spawns
// a process (iOS forbids a sandboxed app from both). It points the in-process
// libcups client at an external CUPS host — a localhost jailbreak daemon, or a
// LAN bridge — and prints to the queue that host offers. Which printers are
// supported is the host's business; the app carries no model list. No USB/IOKit
// code or private entitlements ship in the app.
extern void printing_ffi_ios_configure_server(const char *server);
extern void printing_ffi_ios_configure_credentials(const char *user, const char *password);
extern int32_t printing_ffi_ios_probe(char *queue, size_t queue_cap,
                                      char *model, size_t model_cap);

// The on-device daemon package, embedded by tool/ios/embed_runtime.sh.
static NSString *const kDaemonPackage = @"com.fotobox.cupsd";
// LAN print bridges advertise this DNS-SD type (tool/bridge/); the app's
// Info.plist must list it under NSBonjourServices or iOS denies the browse.
static const char *const kBridgeServiceType = "_fotobox-cups._tcp";
// A bridge's pairing link: fotobox-cups://pair?server=<host:port>&token=<token>,
// printed as a QR code by `fotobox-print-bridge-pair`; the Camera app opens it.
static NSString *const kPairingScheme = @"fotobox-cups";

@implementation PrintingFfiPlugin {
    dispatch_queue_t _worker;
    FlutterMethodChannel *_channel;
    UIDocumentInteractionController *_docController; // retained while the menu is up
    NSDictionary *_pendingPairing; // a pairing link that arrived before Dart asked
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *channel = [FlutterMethodChannel
        methodChannelWithName:@"printing_ffi/ios_cups" binaryMessenger:registrar.messenger];
    PrintingFfiPlugin *plugin = [[PrintingFfiPlugin alloc] init];
    plugin->_worker = dispatch_queue_create("printing_ffi.ios_cups", DISPATCH_QUEUE_SERIAL);
    plugin->_channel = channel;
    [registrar addMethodCallDelegate:plugin channel:channel];
    // Pairing links arrive through the app delegate, or the scene delegate in
    // an app that adopted the UIScene lifecycle.
    [registrar addApplicationDelegate:plugin];
    [registrar addSceneDelegate:plugin];
}

// Point the in-process libcups client at the external CUPS host. "server" is
// "host" or "host:port"; cupsSetServer parses the port. "user"/"token" are the
// credentials a LAN bridge asks for (none for the loopback daemon). Cheap and
// local — it only stores the target, no network I/O.
- (void)configure:(NSDictionary *)arguments {
    NSString *server = arguments[@"server"];
    id user = arguments[@"user"];
    id token = arguments[@"token"];
    printing_ffi_ios_configure_server(server.length ? server.UTF8String : "");
    printing_ffi_ios_configure_credentials(
        [user isKindOfClass:NSString.class] ? [user UTF8String] : "",
        [token isKindOfClass:NSString.class] ? [token UTF8String] : "");
}

// Ask the configured host which queue to print to (its default, else its first).
// Returns {queueName, model} when it offers one, {detail} when it is reachable
// but offers none, or a FlutterError when it is unreachable.
- (id)probe {
    char queue[256];
    char model[256];
    int32_t found = printing_ffi_ios_probe(queue, sizeof(queue), model, sizeof(model));
    if (found > 0) {
        return @{@"queueName": [NSString stringWithUTF8String:queue] ?: @"",
                 @"model": [NSString stringWithUTF8String:model] ?: @""};
    }
    if (found == 0) return @{@"detail": @"host offers no printer queue yet"};
    return [FlutterError errorWithCode:@"unavailable"
        message:[NSString stringWithUTF8String:get_last_error()] ?: @"CUPS host unavailable"
        details:nil];
}

#pragma mark - Finding LAN print bridges (DNS-SD)

static void browse_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interface,
                         DNSServiceErrorType error, const char *name, const char *type,
                         const char *domain, void *context) {
    if (error != kDNSServiceErr_NoError || !(flags & kDNSServiceFlagsAdd)) return;
    NSMutableArray *found = (__bridge NSMutableArray *)context;
    [found addObject:@{@"name": @(name), @"type": @(type), @"domain": @(domain),
                       @"interface": @(interface)}];
}

static void resolve_reply(DNSServiceRef ref, DNSServiceFlags flags, uint32_t interface,
                          DNSServiceErrorType error, const char *fullname,
                          const char *host, uint16_t port, uint16_t txtLen,
                          const unsigned char *txt, void *context) {
    if (error != kDNSServiceErr_NoError || !host) return;
    NSMutableDictionary *result = (__bridge NSMutableDictionary *)context;
    NSString *name = @(host);
    // "booth-pi.local." -> "booth-pi.local"
    if ([name hasSuffix:@"."]) name = [name substringToIndex:name.length - 1];
    result[@"host"] = name;
    result[@"port"] = @(ntohs(port));
}

// Feed DNS-SD replies to `ref`'s callbacks until `done` or `seconds` pass.
static void pump(DNSServiceRef ref, NSTimeInterval seconds, BOOL (^done)(void)) {
    int fd = DNSServiceRefSockFD(ref);
    if (fd < 0) return;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (!done() && deadline.timeIntervalSinceNow > 0) {
        NSTimeInterval left = deadline.timeIntervalSinceNow;
        struct timeval timeout = {(time_t)left, (suseconds_t)((left - floor(left)) * 1e6)};
        fd_set ready;
        FD_ZERO(&ready);
        FD_SET(fd, &ready);
        int n = select(fd + 1, &ready, NULL, NULL, &timeout);
        if (n > 0) {
            if (DNSServiceProcessResult(ref) != kDNSServiceErr_NoError) return;
        } else if (n < 0 && errno != EINTR) {
            return;
        }
    }
}

// Look for print bridges on the LAN for `seconds`. Returns [{name, host, port}],
// one per bridge, or a FlutterError when iOS refuses to browse (Local Network
// permission denied, or the type missing from NSBonjourServices).
- (id)browse:(NSTimeInterval)seconds {
    NSMutableArray *services = [NSMutableArray array];
    DNSServiceRef browser = NULL;
    DNSServiceErrorType error = DNSServiceBrowse(&browser, 0, kDNSServiceInterfaceIndexAny,
        kBridgeServiceType, NULL, browse_reply, (__bridge void *)services);
    if (error != kDNSServiceErr_NoError) {
        return [FlutterError errorWithCode:@"browse"
            message:[NSString stringWithFormat:@"DNS-SD browse failed (%d)", error] details:nil];
    }
    pump(browser, seconds, ^BOOL { return NO; });
    DNSServiceRefDeallocate(browser);

    NSMutableArray *bridges = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *service in services) {
        // The same bridge shows up once per interface it is reachable on.
        if ([seen containsObject:service[@"name"]]) continue;
        NSMutableDictionary *resolved = [NSMutableDictionary dictionary];
        DNSServiceRef resolver = NULL;
        if (DNSServiceResolve(&resolver, 0, [service[@"interface"] unsignedIntValue],
                              [service[@"name"] UTF8String], [service[@"type"] UTF8String],
                              [service[@"domain"] UTF8String], resolve_reply,
                              (__bridge void *)resolved) != kDNSServiceErr_NoError) {
            continue;
        }
        pump(resolver, 3.0, ^BOOL { return resolved[@"host"] != nil; });
        DNSServiceRefDeallocate(resolver);
        if (!resolved[@"host"]) continue;
        [seen addObject:service[@"name"]];
        [bridges addObject:@{@"name": service[@"name"], @"host": resolved[@"host"],
                             @"port": resolved[@"port"]}];
    }
    return bridges;
}

#pragma mark - Pairing links

// fotobox-cups://pair?server=<host:port>&token=<token> -> {server, token}, or
// nil for any other URL.
static NSDictionary *pairing_from_url(NSURL *url) {
    if (![url.scheme.lowercaseString isEqualToString:kPairingScheme]) return nil;
    NSURLComponents *components = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *server = nil;
    NSString *token = nil;
    for (NSURLQueryItem *item in components.queryItems) {
        if ([item.name isEqualToString:@"server"]) server = item.value;
        if ([item.name isEqualToString:@"token"]) token = item.value;
    }
    if (!server.length) return nil;
    return @{@"server": server, @"token": token ?: @""};
}

// Hand a pairing to Dart, and keep it for a Dart side that is not listening
// yet (the link launched the app); Dart collects it with takePairing.
- (BOOL)handleURL:(NSURL *)url {
    NSDictionary *pairing = pairing_from_url(url);
    if (!pairing) return NO;
    _pendingPairing = pairing;
    [_channel invokeMethod:@"paired" arguments:pairing result:^(id outcome) {
        // Delivered: Dart applied it. Not implemented: nobody listens yet.
        if (outcome != FlutterMethodNotImplemented && self->_pendingPairing == pairing)
            self->_pendingPairing = nil;
    }];
    return YES;
}

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
            options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *)options {
    return [self handleURL:url];
}

- (BOOL)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions {
    BOOL handled = NO;
    for (UIOpenURLContext *context in connectionOptions.URLContexts)
        handled = [self handleURL:context.URL] || handled;
    return handled;
}

- (BOOL)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)URLContexts {
    BOOL handled = NO;
    for (UIOpenURLContext *context in URLContexts)
        handled = [self handleURL:context.URL] || handled;
    return handled;
}

#pragma mark - Installing the on-device daemon

// The frontmost view controller to present the open-in menu from.
- (UIViewController *)topViewController {
    UIViewController *root = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if ([scene isKindOfClass:UIWindowScene.class] &&
            scene.activationState == UISceneActivationStateForegroundActive) {
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) { root = window.rootViewController; break; }
            }
        }
        if (root) break;
    }
    while (root.presentedViewController) root = root.presentedViewController;
    return root;
}

// The daemon .deb shipped in the app. With use_frameworks! (the Flutter
// default) a pod's resources land in its framework, not the main bundle, so
// look there first.
- (NSString *)daemonPackagePath {
    for (NSBundle *bundle in @[[NSBundle bundleForClass:[self class]], [NSBundle mainBundle]]) {
        NSString *path = [bundle pathForResource:kDaemonPackage ofType:@"deb"];
        if (path && [[NSFileManager defaultManager] fileExistsAtPath:path]) return path;
    }
    return nil;
}

// Hand the bundled daemon .deb to whatever jailbreak package manager is
// installed via the iOS open-in menu. Store-agnostic: Sileo and Zebra both
// register as Viewer for org.debian.deb-archive. The app never installs
// anything itself — it only presents the file; the manager (root) runs dpkg +
// postinst. Returns "presented", "missing-package" (the build shipped no .deb)
// "no-package-manager" (nothing on the device opens a .deb) or "no-window".
- (NSString *)installDaemon {
    NSString *path = [self daemonPackagePath];
    if (!path) return @"missing-package";
    UIViewController *top = [self topViewController];
    if (!top) return @"no-window";
    _docController = [UIDocumentInteractionController
        interactionControllerWithURL:[NSURL fileURLWithPath:path]];
    _docController.delegate = self;
    _docController.UTI = @"org.debian.deb-archive";
    BOOL presented = [_docController presentOpenInMenuFromRect:CGRectMake(
        top.view.bounds.size.width / 2, top.view.bounds.size.height - 1, 1, 1)
        inView:top.view animated:YES];
    if (!presented) _docController = nil;
    return presented ? @"presented" : @"no-package-manager";
}

- (void)documentInteractionControllerDidDismissOpenInMenu:(UIDocumentInteractionController *)controller {
    _docController = nil;
}

#pragma mark - Method channel

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"installDaemon"]) {
        // UIKit must run on the main thread.
        dispatch_async(dispatch_get_main_queue(), ^{ result([self installDaemon]); });
        return;
    }
    if ([call.method isEqualToString:@"takePairing"]) {
        result(_pendingPairing);
        _pendingPairing = nil;
        return;
    }
    if ([call.method isEqualToString:@"browse"]) {
        NSNumber *seconds = [call.arguments isKindOfClass:NSDictionary.class]
            ? call.arguments[@"seconds"] : nil;
        // Off the probe worker: a browse takes seconds and must not hold up
        // the printing status poll.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            id value = [self browse:seconds ? seconds.doubleValue : 3.0];
            dispatch_async(dispatch_get_main_queue(), ^{ result(value); });
        });
        return;
    }
    if (![call.method isEqualToString:@"configure"] &&
        ![call.method isEqualToString:@"probe"]) {
        result(FlutterMethodNotImplemented);
        return;
    }
    dispatch_async(_worker, ^{
        id value;
        if ([call.method isEqualToString:@"configure"]) {
            [self configure:call.arguments];
            value = nil;
        } else {
            value = [self probe];
        }
        dispatch_async(dispatch_get_main_queue(), ^{ result(value); });
    });
}
@end
