#import "PrintingFfiPlugin.h"
#import <UIKit/UIKit.h>
#include "../../src/printing_ffi.h"

@interface PrintingFfiPlugin () <UIDocumentInteractionControllerDelegate>
@end

// The iOS app is a CUPS CLIENT only. It never runs cupsd, opens USB, or spawns
// a process (iOS forbids a sandboxed app from both). It points the in-process
// libcups client at an external CUPS host — a localhost jailbreak daemon, or a
// LAN bridge — and prints to the queue that host offers. Which printers are
// supported is the host's business; the app carries no model list. No USB/IOKit
// code or private entitlements ship in the app.
extern void printing_ffi_ios_configure_server(const char *server);
extern int32_t printing_ffi_ios_probe(char *queue, size_t queue_cap,
                                      char *model, size_t model_cap);

// The on-device daemon package, embedded by tool/ios/embed_runtime.sh.
static NSString *const kDaemonPackage = @"com.fotobox.cupsd";

@implementation PrintingFfiPlugin {
    dispatch_queue_t _worker;
    UIDocumentInteractionController *_docController; // retained while the menu is up
}

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    FlutterMethodChannel *channel = [FlutterMethodChannel
        methodChannelWithName:@"printing_ffi/ios_cups" binaryMessenger:registrar.messenger];
    PrintingFfiPlugin *plugin = [[PrintingFfiPlugin alloc] init];
    plugin->_worker = dispatch_queue_create("printing_ffi.ios_cups", DISPATCH_QUEUE_SERIAL);
    [registrar addMethodCallDelegate:plugin channel:channel];
}

// Point the in-process libcups client at the external CUPS host. "server" is
// "host" or "host:port"; cupsSetServer parses the port. Cheap and local — it
// only stores the target, no network I/O.
- (void)configure:(NSDictionary *)arguments {
    NSString *server = arguments[@"server"];
    printing_ffi_ios_configure_server(server.length ? server.UTF8String : "");
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

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
    if ([call.method isEqualToString:@"installDaemon"]) {
        // UIKit must run on the main thread.
        dispatch_async(dispatch_get_main_queue(), ^{ result([self installDaemon]); });
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
