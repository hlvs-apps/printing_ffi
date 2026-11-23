#import "PrintingFfiPlugin.h"
#include "../../src/printing_ffi.h"
#include <cups/cups.h>
#include <string.h>

// The iOS app is a CUPS CLIENT only. It never runs cupsd, opens USB, or spawns
// a process (iOS forbids a sandboxed app from both). It points the in-process
// libcups client at an external CUPS host — a localhost jailbreak daemon, or a
// LAN bridge — and submits over IPP. No USB/IOKit code or private entitlements
// ship in the app.
extern void printing_ffi_ios_select_server(void);
extern void printing_ffi_ios_configure_server(const char *server);

// Supported Gutenprint DNP / Citizen dye-sub drivers. The host names each queue
// "<driver>_<serial>"; the client accepts a queue carrying one of these driver
// ids and never a raw or wrong-model fallback. Mirrors the daemon's set and the
// driver list the old on-device discovery used.
static const char *const kSupportedDrivers[] = {
    "citizen-cw-01", "citizen-cw-02", "citizen-cx-02", "citizen-cx-02w",
    "citizen-cz-01", "dnp-ds40",      "dnp-ds80",      "dnp-ds80dx",
    "dnp-dsrx1",     "dnp-ds620",     "dnp-ds820",     "dnp-qw410",
    NULL,
};

@implementation PrintingFfiPlugin {
    dispatch_queue_t _worker;
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

// Ask the configured host which supported DNP queue it exposes. The host ran USB
// discovery and created the queue "<driver>_<serial>"; the client reads it back
// over IPP. Returns {queueName, driver} for a supported queue, {detail} when the
// host is reachable but exposes none, or a FlutterError when it is unreachable.
- (id)probe {
    printing_ffi_ios_select_server();
    http_t *http = httpConnect2(cupsServer(), ippPort(), NULL, AF_UNSPEC,
        HTTP_ENCRYPTION_IF_REQUESTED, 1, 3000, NULL);
    if (!http) {
        return [FlutterError errorWithCode:@"unavailable"
            message:[NSString stringWithFormat:@"CUPS host %s:%d unreachable",
                cupsServer(), ippPort()]
            details:nil];
    }
    httpSetTimeout(http, 3.0, NULL, NULL);
    cups_dest_t *dests = NULL;
    int count = cupsGetDests2(http, &dests);
    ipp_status_t error = cupsLastError();
    NSString *queueName = nil;
    NSString *driver = nil;
    for (int i = 0; i < count && !queueName; i++) {
        const char *name = dests[i].name;
        if (!name) continue;
        for (const char *const *d = kSupportedDrivers; *d; d++) {
            size_t len = strlen(*d);
            // "<driver>_..." — the host's queue-naming scheme.
            if (strncmp(name, *d, len) == 0 && name[len] == '_') {
                queueName = [NSString stringWithUTF8String:name];
                driver = [NSString stringWithUTF8String:*d];
                break;
            }
        }
    }
    if (count > 0) cupsFreeDests(count, dests);
    httpClose(http);
    if (queueName) return @{@"queueName": queueName, @"driver": driver};
    if (count < 0 || error >= IPP_STATUS_ERROR_BAD_REQUEST) {
        return [FlutterError errorWithCode:@"unavailable"
            message:@"CUPS host query failed" details:nil];
    }
    return @{@"detail": @"no supported DNP queue on host"};
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
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
