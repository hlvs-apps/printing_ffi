import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:printing_ffi/printing_ffi_bindings_generated.dart' hide PrinterAttribute;
import 'models/models.dart';
import 'src/cups_android.dart';
import 'src/dnp_usb.dart';

export 'models/models.dart';
// Android web-UI helpers: CupsWebView widget + openCupsSettings() /
// openCupsPrinterSettings() extension on PrintingFfi (in-app cupsd settings pages).
export 'src/cups_web_ui.dart';
// Android DNP dye-sub USB auto-detect: the DnpUsbPrinter model surfaced via
// PrintingFfi.dnpPrinters, plus the DnpUsb orchestration (foreground-service
// helpers used around a print job). Owned + started by the plugin.
export 'src/dnp_usb.dart';

void _remapCupsOptions(Map<String, String> options) {
  if (Platform.isMacOS || Platform.isLinux) {
    bool rotationHandled = false;
    if (options.containsKey('pdf-rotation')) {
      final rotationValue = int.tryParse(options.remove('pdf-rotation') ?? '-1') ?? -1;
      switch (rotationValue) {
        case 0: // none
          options['orientation-requested'] = '3'; // portrait
          rotationHandled = true;
          break;
        case 1: // rotate90
          options['orientation-requested'] = '5'; // reverse-landscape (90 deg clockwise)
          rotationHandled = true;
          break;
        case 2: // rotate180
          options['orientation-requested'] = '6'; // reverse-portrait (180 deg)
          rotationHandled = true;
          break;
        case 3: // rotate270
          options['orientation-requested'] = '4'; // landscape (90 deg counter-clockwise)
          rotationHandled = true;
          break;
        case -1: // auto
        default:
          // Fall through to use the 'orientation' option if present.
          break;
      }
    }

    // The `PdfRotation` option is more specific and takes precedence over the
    // general `orientation` option for CUPS.
    if (rotationHandled) {
      // Remove the basic orientation key to avoid conflicts.
      options.remove('orientation');
    } else if (options.containsKey('orientation')) {
      final orientationValue = options.remove('orientation');
      options['orientation-requested'] = orientationValue == 'landscape' ? '4' : '3';
    }
    if (options.containsKey('color-mode')) {
      final colorValue = options.remove('color-mode');
      options['print-color-mode'] = colorValue!;
    }
    if (options.containsKey('print-quality')) {
      final qualityValue = options.remove('print-quality');
      switch (qualityValue) {
        case 'draft':
        case 'low':
          options['print-quality'] = '3';
          break;
        case 'normal':
          options['print-quality'] = '4';
          break;
        case 'high':
          options['print-quality'] = '5';
          break;
      }
    }

    if (options.containsKey('duplex')) {
      final duplexValue = options.remove('duplex');
      switch (duplexValue) {
        case 'singleSided':
          options['sides'] = 'one-sided';
          break;
        case 'duplexLongEdge':
          options['sides'] = 'two-sided-long-edge';
          break;
        case 'duplexShortEdge':
          options['sides'] = 'two-sided-short-edge';
          break;
      }
    }
  }
}

/// A class that provides a Dart interface to the native printing libraries.
///
/// This class uses FFI to call native functions for listing printers,
/// printing documents, and managing print jobs on macOS, Windows, and Linux.
class PrintingFfi {
  /// A helper to determine if the current platform is Windows, respecting test overrides.
  bool get _isWindows {
    // A non-constant value is required to prevent the compiler from short-circuiting
    // the logic and ignoring the `kDebugMode` check.
    final isTesting = kDebugMode && Platform.environment.containsKey('FLUTTER_TEST');
    if (isTesting) {
      return defaultTargetPlatform == TargetPlatform.windows;
    }
    return Platform.isWindows;
  }

  /// A helper to determine if the current platform is CUPS-based, respecting test overrides.
  ///
  /// Android is CUPS-based too: the plugin boots a bundled cupsd and the libcups
  /// client (the same C used on macOS/Linux) targets it via `cupsSetServer` on the
  /// root isolate and `CUPS_SERVER=127.0.0.1:<port>` (set by [startCupsServer]) for
  /// the helper isolate. So the CUPS IPP ops — reading printer attributes/supported
  /// options, job control, printer enable/disable — work on Android once cupsd is up.
  bool get _isCups {
    final isTesting = kDebugMode && Platform.environment.containsKey('FLUTTER_TEST');
    if (isTesting) {
      return defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.linux ||
          defaultTargetPlatform == TargetPlatform.android;
    }
    return Platform.isMacOS || Platform.isLinux || Platform.isAndroid;
  }

  /// Whether printer/job queue control and attribute queries are available on the
  /// current platform. These were historically CUPS-only (macOS/Linux/Android) but the
  /// Windows `winspool` backend now implements the same operations, so they work on
  /// Windows too. (Only [cupsMoveJob] remains Windows-unsupported — the spooler cannot
  /// move a job between printers.)
  bool get _supportsQueueControl => _isCups || _isWindows;

  /// Internal constructor for creating the singleton instance.
  ///
  static final PrintingFfi instance = PrintingFfi._();

  static const String _libName = 'printing_ffi';

  static final DynamicLibrary _dylib = () {
    if (Platform.isMacOS) {
      // For FFI plugins, the library is named lib<name>.dylib in the test environment,
      // but is embedded in a framework when running in a Flutter app.
      try {
        return DynamicLibrary.open('lib$_libName.dylib');
      } catch (_) {
        // Fallback for app environment
        return DynamicLibrary.open('$_libName.framework/$_libName');
      }
    }
    if (Platform.isLinux) return DynamicLibrary.open('lib$_libName.so');
    if (Platform.isAndroid) return DynamicLibrary.open('lib$_libName.so');
    if (Platform.isWindows) return DynamicLibrary.open('$_libName.dll');
    throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
  }();

  /// The bindings to the native functions. This is final and initialized by the constructors.
  final PrintingFfiBindings _bindings;

  /// The localhost port the bundled Android cupsd is listening on, as returned by
  /// the most recent successful [startCupsServer]. `null` before cupsd is started
  /// (or after [stopCupsServer], or off Android). Backs [cupsServerPort] so the
  /// web-UI helpers ([openCupsSettings]/[openCupsPrinterSettings]) can reach the
  /// server without the app having to hold the port itself.
  int? _cupsServerPort;

  /// Internal constructor for creating the singleton instance.
  PrintingFfi._() : _bindings = PrintingFfiBindings(_dylib); // Private constructor

  /// Constructor for testing purposes.
  @visibleForTesting
  PrintingFfi.forTest(this._bindings, {Future<SendPort>? helperIsolateSendPortFuture}) : _helperIsolateSendPortFuture = helperIsolateSendPortFuture;

  /// A test-only method to allow injecting messages as if they came from the isolate.
  @visibleForTesting
  void handleIsolateMessageForTest(dynamic data) {
    // This assumes the listener has been set up by an async call in the test.
    _handleMessage(data);
  }

  ReceivePort? _mainReceivePort;
  StreamSubscription? _mainPortSubscription;

  void dispose() {
    if (_helperIsolateSendPortFuture != null) {
      _helperIsolateSendPortFuture!
          .then((sendPort) {
            const request = kDebugMode ? DisposeRequest() : _DisposeRequest();
            sendPort.send(request);
          })
          .catchError((_) {
            // Isolate might already be gone, which is fine.
          });
    }
    _mainPortSubscription?.cancel();
    _mainReceivePort?.close();
    _helperIsolateSendPortFuture = null;
    _mainPortSubscription = null;
    _mainReceivePort = null;
    _failAllPendingRequests(IsolateError('PrintingFfi instance disposed.'));
  }

  /// Initializes the bundled PDFium library for Windows.
  ///
  /// This method should be called from the main isolate, preferably in your `main()`
  /// function, before any other PDF-related operations if you are using this
  /// plugin for PDF printing on Windows **and are not using another plugin
  /// that already initializes PDFium (like `pdfrx`)**.
  ///
  /// ```dart
  /// void main() {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   if (Platform.isWindows) {
  ///     // Call this if printing_ffi is your only PDFium-based plugin.
  ///     PrintingFfi.instance.initPdfium();
  ///   }
  ///   runApp(const MyApp());
  /// }
  /// ```
  ///
  /// If you are using `pdfrx` or a similar plugin, you do not need to call this
  /// method, as that plugin will handle the initialization. This optional,
  /// explicit initialization prevents conflicts in apps with multiple PDFium-based plugins.
  void initPdfium() {
    // In debug mode, respect the Flutter test platform override.
    // In release mode, rely on the actual dart:io Platform.
    if (_isWindows) _bindings.init_pdfium_library();
  }

  List<Printer> listPrinters() {
    final printerListPtr = _bindings.get_printers();

    if (printerListPtr == nullptr) {
      return [];
    }

    try {
      final printerList = printerListPtr.ref;
      final printers = <Printer>[];
      for (var i = 0; i < printerList.count; i++) {
        printers.add(_printerFromInfo(printerList.printers[i]));
      }
      return printers;
    } finally {
      _bindings.free_printer_list(printerListPtr);
    }
  }

  Printer? getDefaultPrinter() {
    final printerInfoPtr = _bindings.get_default_printer();

    if (printerInfoPtr == nullptr) {
      return null;
    }

    try {
      return _printerFromInfo(printerInfoPtr.ref);
    } finally {
      _bindings.free_printer_info(printerInfoPtr);
    }
  }

  /// Android only: boots the bundled CUPS scheduler (cupsd) inside the app
  /// sandbox at the app's own uid, and points the libcups client at it so all
  /// the existing CUPS calls ([listPrinters], etc.) talk to it over IPP.
  ///
  /// - [serverRoot]: an app-writable dir for config/spool/logs (e.g. filesDir/cups).
  /// - [nativeLibDir]: `applicationInfo.nativeLibraryDir` (where the bundled
  ///   cupsd/backends/filters were extracted as `lib*.so`).
  /// - [dataDir]: a dir containing `share/cups/{mime,data,templates}` extracted from assets.
  /// - [docRoot]: the web-interface DocumentRoot (static index.html/css/images
  ///   extracted from assets). Pass `null` to run cupsd without the styled web UI.
  ///
  /// Returns the localhost port cupsd is listening on, or throws on failure.
  int startCupsServer({
    required String serverRoot,
    required String nativeLibDir,
    required String dataDir,
    String? docRoot,
  }) {
    if (!Platform.isAndroid) {
      throw PrintingFfiException('startCupsServer is only supported on Android');
    }
    final serverRootPtr = serverRoot.toNativeUtf8();
    final nativeLibDirPtr = nativeLibDir.toNativeUtf8();
    final dataDirPtr = dataDir.toNativeUtf8();
    final docRootPtr = (docRoot ?? '').toNativeUtf8();
    try {
      final port = _bindings.start_cups_server(
        serverRootPtr.cast(),
        nativeLibDirPtr.cast(),
        dataDirPtr.cast(),
        docRootPtr.cast(),
      );
      if (port <= 0) {
        throw PrintingFfiException('Failed to start bundled cupsd: ${_getLastError()}');
      }
      _cupsServerPort = port;
      return port;
    } finally {
      malloc.free(serverRootPtr);
      malloc.free(nativeLibDirPtr);
      malloc.free(dataDirPtr);
      malloc.free(docRootPtr);
    }
  }

  /// Android only: terminates the bundled cupsd started by [startCupsServer].
  ///
  /// Clears [cupsServerPort] (so the web-UI helpers report "not running") and resets
  /// the [initializeAndroidCups] single-flight latch, so a later
  /// [initializeAndroidCups] can boot cupsd again from a clean state.
  void stopCupsServer() {
    if (!Platform.isAndroid) return;
    _bindings.stop_cups_server();
    _cupsServerPort = null;
    CupsAndroidBoot.instance.reset();
  }

  /// Android only: boots the bundled CUPS scheduler and starts DNP USB auto-detect.
  ///
  /// This is the single startup call a consumer app makes to bring up the Android
  /// port. It:
  /// 1. asks the plugin's Kotlin side (`printing_ffi/cups` -> `getCupsPaths`) for the
  ///    extracted asset/native-lib paths,
  /// 2. boots the in-app cupsd via [startCupsServer] (pointing the libcups client at
  ///    it, so [listPrinters] and friends now talk to the bundled server), and
  /// 3. starts the DNP dye-sub USB auto-detect layer, which auto-adds a CUPS queue
  ///    for any attached & permitted DNP printer (observe [dnpPrinters]).
  ///
  /// Progress is published on [cupsStatus] for an optional status banner.
  ///
  /// No-op off Android (safe to call unconditionally in `main`).
  ///
  /// Concurrency (C13): single-flight — concurrent or repeated calls dedupe onto one
  /// in-flight boot; once a boot has completed, subsequent calls return immediately.
  /// After [stopCupsServer] the latch is reset, so a later call re-boots cleanly.
  ///
  /// Threading / ANR (C14): the boot runs SYNCHRONOUS FFI (`start_cups_server`, and,
  /// during DNP auto-add, `add_cups_printer`/`generate_cups_dnp_ppd`) pinned to the
  /// CALLING (root/UI) isolate because libcups keeps its target CUPS server in
  /// thread-local `cupsSetServer` state — this work CANNOT be moved to a helper
  /// isolate without missing the in-app cupsd. `Future<void>` does not make it
  /// non-blocking. Call this at startup (e.g. after the first frame) and expect brief
  /// synchronous work on the UI isolate. The DNP layer deliberately defers its own
  /// initial USB scan a beat after the app is interactive so the synchronous add flow
  /// stays off the startup focus-acquisition window (whose starvation otherwise
  /// caused "Waited 10000ms for FocusEvent" ANRs).
  Future<void> initializeAndroidCups() => CupsAndroidBoot.instance.boot();

  /// Human-readable status of the bundled Android cupsd boot (and its probe), for an
  /// optional status banner. Updated by [initializeAndroidCups]. Off Android it holds
  /// a static "Android only" string.
  ValueNotifier<String> get cupsStatus => CupsAndroidBoot.instance.status;

  /// The DNP dye-sub USB printers currently detected on Android (auto-added CUPS
  /// queues), for an optional device list. Backed by the DNP auto-detect layer that
  /// [initializeAndroidCups] starts; empty off Android or before any device is
  /// plugged in + permitted.
  ValueNotifier<List<DnpUsbPrinter>> get dnpPrinters => CupsAndroidBoot.instance.dnpPrinters;

  /// The localhost port the bundled Android cupsd is listening on, or `null` if it
  /// has not been started yet (or was stopped, or off Android). Set by
  /// [startCupsServer]; consumed by the web-UI helpers so an app never has to track
  /// the port itself.
  int? get cupsServerPort => _cupsServerPort;

  /// Test-only hook to set the cupsd port without booting a real server (which
  /// requires Android + FFI), so the URL helpers can be unit-tested.
  @visibleForTesting
  set debugCupsServerPort(int? port) => _cupsServerPort = port;

  /// Base URL of the bundled cupsd web interface (`http://127.0.0.1:<port>`), or
  /// `null` if cupsd is not running. Append `/admin`, `/printers/<name>`, `/jobs/`,
  /// etc. to reach a specific page.
  String? get cupsBaseUrl {
    final port = _cupsServerPort;
    return port == null ? null : 'http://127.0.0.1:$port';
  }

  /// URL of the bundled cupsd admin/settings page (`/admin`), or `null` if cupsd is
  /// not running. Rendered by [openCupsSettings].
  String? get cupsSettingsUrl {
    final base = cupsBaseUrl;
    return base == null ? null : '$base/admin';
  }

  /// URL of a single printer's properties/maintenance page
  /// (`/printers/<name>`), or `null` if cupsd is not running. Rendered by
  /// [openCupsPrinterSettings].
  String? cupsPrinterSettingsUrl(String printerName) {
    final base = cupsBaseUrl;
    return base == null ? null : '$base/printers/${Uri.encodeComponent(printerName)}';
  }

  /// The canonical AF_UNIX socket path (`<serverRoot>/usbfd.sock`) the USB
  /// fd-server binds and the bundled DNP backend connects to. Available after
  /// [startCupsServer] has run. Returns `null` before that (or off Android).
  ///
  /// Pass this to [startUsbFdServer] so C, the backend env (wired by
  /// [startCupsServer] via a `SetEnv` in cups-files.conf) and Kotlin all agree.
  String? get usbFdSockPath {
    if (!Platform.isAndroid) return null;
    final ptr = _bindings.cups_usb_fd_sock_path();
    if (ptr == nullptr) return null;
    return ptr.cast<Utf8>().toDartString();
  }

  /// Android only: starts the native USB fd-server that hands the app's live USB
  /// file descriptor to the forked Gutenprint DNP backend over an AF_UNIX socket
  /// via SCM_RIGHTS.
  ///
  /// Call this once the app has opened the target DNP device and holds a
  /// long-lived fd (`UsbDeviceConnection.getFileDescriptor()` from Kotlin, after
  /// the user grants USB permission). The server keeps [fd] alive and, on each
  /// backend connection (at job dispatch), sends a `dup(fd)` — libusb closes the
  /// wrapped copy at job end, so the original survives across jobs.
  ///
  /// - [sockPath]: the socket path; use [usbFdSockPath] (`<serverRoot>/usbfd.sock`).
  /// - [fd]: the raw USB file descriptor (owned by Kotlin; this server never
  ///   closes it — only the dups it creates).
  ///
  /// Throws [PrintingFfiException] on failure. Call [stopUsbFdServer] when the
  /// device is detached / permission revoked / the app tears down.
  void startUsbFdServer({required String sockPath, required int fd}) {
    if (!Platform.isAndroid) {
      throw PrintingFfiException('startUsbFdServer is only supported on Android');
    }
    final sockPathPtr = sockPath.toNativeUtf8();
    try {
      final rc = _bindings.start_usb_fd_server(sockPathPtr.cast(), fd);
      if (rc != 0) {
        throw PrintingFfiException('Failed to start USB fd server: ${_getLastError()}');
      }
    } finally {
      malloc.free(sockPathPtr);
    }
  }

  /// Android only: stops the USB fd-server started by [startUsbFdServer]. Does
  /// NOT close the fd passed to [startUsbFdServer] (owned by Kotlin). No-op if no
  /// server is running or off Android.
  void stopUsbFdServer() {
    if (!Platform.isAndroid) return;
    _bindings.stop_usb_fd_server();
  }

  /// Android only: generates (if not already present) a Gutenprint PPD for the given
  /// DNP/Citizen dye-sub [driver] id and returns its absolute on-device path.
  ///
  /// [driver] is the Gutenprint driver name — the same value as the DNP USB "make"
  /// string (e.g. `dnp-dsrx1`, `dnp-ds620`, `dnp-ds820`); it maps directly to
  /// `<printer driver="…"/>` in Gutenprint's `dyesub.xml`.
  ///
  /// Pass the returned path to [addCupsPrinter] as [model]: because it is an absolute
  /// path to a `.ppd`, the native layer uploads the PPD file directly (the
  /// `lpadmin -P` mechanism), avoiding cups-driverd entirely. Requires
  /// [startCupsServer] to have run. Returns `null` on failure (or off Android).
  String? generateDnpPpd(String driver) {
    if (!Platform.isAndroid) return null;
    final driverPtr = driver.toNativeUtf8();
    try {
      final ptr = _bindings.generate_cups_dnp_ppd(driverPtr.cast());
      if (ptr == nullptr) return null;
      return ptr.cast<Utf8>().toDartString();
    } finally {
      malloc.free(driverPtr);
    }
  }

  /// Creates or modifies a CUPS queue via the CUPS-Add-Modify-Printer IPP op.
  ///
  /// Works against whatever CUPS server the client currently targets (on Android,
  /// the in-app cupsd booted by [startCupsServer]). [model] defaults to "raw"
  /// (a raw queue with no PPD).
  ///
  /// If [model] is an absolute path to a readable `.ppd` file (e.g. the value
  /// returned by [generateDnpPpd]), the PPD file is uploaded directly and
  /// cups-driverd is NOT invoked — the fast, reliable path on Android. Otherwise
  /// [model] is treated as a ppd-name resolved server-side. Returns true on success.
  bool addCupsPrinter({
    required String name,
    required String deviceUri,
    String model = 'raw',
  }) {
    final namePtr = name.toNativeUtf8();
    final uriPtr = deviceUri.toNativeUtf8();
    final modelPtr = model.toNativeUtf8();
    try {
      final ok = _bindings.add_cups_printer(
        namePtr.cast(),
        uriPtr.cast(),
        modelPtr.cast(),
      );
      if (!ok) {
        throw PrintingFfiException('Failed to add CUPS printer: ${_getLastError()}');
      }
      return ok;
    } finally {
      malloc.free(namePtr);
      malloc.free(uriPtr);
      malloc.free(modelPtr);
    }
  }

  /// Deletes a CUPS queue via the CUPS-Delete-Printer IPP op.
  ///
  /// Works against whatever CUPS server the client currently targets (on Android,
  /// the in-app cupsd booted by [startCupsServer]). Idempotent: deleting a queue
  /// that no longer exists is treated as success (safe to call on USB detach).
  /// Returns true on success.
  bool removeCupsPrinter({required String name}) {
    final namePtr = name.toNativeUtf8();
    try {
      final ok = _bindings.remove_cups_printer(namePtr.cast());
      if (!ok) {
        throw PrintingFfiException('Failed to remove CUPS printer: ${_getLastError()}');
      }
      return ok;
    } finally {
      malloc.free(namePtr);
    }
  }

  /// Returns the last native error string (from the calling thread).
  String _getLastError() {
    final ptr = _bindings.get_last_error();
    if (ptr == nullptr) return '';
    return ptr.cast<Utf8>().toDartString();
  }

  Printer _printerFromInfo(PrinterInfo info) {
    final model = info.model.cast<Utf8>().toDartString();
    final location = info.location.cast<Utf8>().toDartString();
    final comment = info.comment.cast<Utf8>().toDartString();

    return Printer(
      name: info.name.cast<Utf8>().toDartString(),
      state: info.state,
      url: info.url.cast<Utf8>().toDartString(),
      model: model.isEmpty ? null : model,
      location: location.isEmpty ? null : location,
      comment: comment.isEmpty ? null : comment,
      isDefault: info.is_default,
      isAvailable: info.is_available,
    );
  }

  Future<PrinterPropertiesResult> openPrinterProperties(String printerName, {int hwnd = 0}) async {
    if (!_isWindows) {
      // This function is Windows-specific.
      return PrinterPropertiesResult.error;
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextOpenPrinterPropertiesRequestId++;
    final request = kDebugMode ? OpenPrinterPropertiesRequest(requestId, printerName, hwnd) : _OpenPrinterPropertiesRequest(requestId, printerName, hwnd);
    final completer = Completer<PrinterPropertiesResult>();
    _openPrinterPropertiesRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  Future<bool> rawDataToPrinter(
    String printerName,
    Uint8List data, {
    String docName = 'Flutter Document',
    List<PrintOption> options = const [],
  }) async {
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextPrintRequestId++;
    final optionsMap = buildOptions(options);

    final request = kDebugMode ? PrintRequest(requestId, printerName, data, docName, optionsMap) : _PrintRequest(requestId, printerName, data, docName, optionsMap);
    final Completer<bool> completer = Completer<bool>();
    _printRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  Future<bool> printPdf(
    String printerName,
    String pdfFilePath, {
    String docName = 'Flutter PDF Document',
    PdfPrintScaling scaling = PdfPrintScaling.fitToPrintableArea,
    int? copies,
    PageRange? pageRange,
    int? priority,
    List<PrintOption> options = const [],
  }) async {
    if (priority != null && (priority < 1 || priority > 100)) {
      throw PrintingFfiException('Priority must be between 1 and 100');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextPrintPdfRequestId++;
    final optionsMap = buildOptions(options);
    final pageRangeValue = pageRange?.toValue();
    final alignment = optionsMap.remove('alignment') ?? 'center';
    final finalOptions = {...optionsMap};
    if (scaling is PdfPrintScalingCustom) {
      finalOptions['custom-scale-factor'] = scaling.scale.toString();
    }
    // job-priority is honored on CUPS (submit-time) and on Windows (applied to the
    // spooler job right after StartDoc).
    if (priority != null) {
      finalOptions['job-priority'] = priority.toString();
    }

    final request = kDebugMode
        ? PrintPdfRequest(requestId, printerName, pdfFilePath, docName, finalOptions, scaling.nativeValue, copies ?? 1, pageRangeValue, alignment)
        : _PrintPdfRequest(
            requestId,
            printerName,
            pdfFilePath,
            docName,
            finalOptions,
            scaling.nativeValue,
            copies ?? 1,
            pageRangeValue,
            alignment,
          );
    final Completer<bool> completer = Completer<bool>();
    _printPdfRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Opens the system's native print dialog to print a file.
  ///
  /// This provides a standard, user-friendly way to print, allowing the user
  /// to select a printer and configure print settings from the OS dialog.
  ///
  /// - On **Windows**, it uses `ShellExecute` which relies on the default PDF
  ///   application's printing capabilities.
  /// - On **macOS** and **Linux**, it uses the `lpr` command, which interfaces
  ///   with CUPS to show the print dialog.
  ///
  /// [filePath] is the local path to the file to be printed. The [docName]
  /// will be used as the job title in the print queue.
  ///
  /// Returns `true` if the print dialog was successfully invoked.
  Future<bool> printFileWithDialog(
    String filePath, {
    String docName = 'Flutter Document',
  }) async {
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextPrintFileWithDialogRequestId++;
    final request = kDebugMode ? PrintFileWithDialogRequest(requestId, filePath, docName) : _PrintFileWithDialogRequest(requestId, filePath, docName);
    final completer = Completer<bool>();
    _printPdfWithDialogRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  Stream<PrintJob> rawDataToPrinterAndStreamStatus(
    String printerName,
    Uint8List data, {
    String docName = 'Flutter Raw Data',
    Duration pollInterval = const Duration(seconds: 2),
    List<PrintOption> options = const [],
  }) {
    return _streamJobStatus(
      printerName: printerName,
      pollInterval: pollInterval,
      submitJob: () => _sendRawDataJobRequest(
        printerName,
        data,
        docName: docName,
        options: buildOptions(options),
      ),
    );
  }

  Stream<PrintJob> printPdfAndStreamStatus(
    String printerName,
    String pdfFilePath, {
    String docName = 'Flutter PDF Document',
    PdfPrintScaling scaling = PdfPrintScaling.fitToPrintableArea,
    int? copies,
    PageRange? pageRange,
    int? priority,
    List<PrintOption> options = const [],
    Duration pollInterval = const Duration(seconds: 2),
  }) {
    if (_isCups && priority != null && (priority < 1 || priority > 100)) {
      throw PrintingFfiException('Priority must be between 1 and 100');
    }
    return _streamJobStatus(
      printerName: printerName,
      pollInterval: pollInterval,
      submitJob: () {
        final optionsMap = buildOptions(options);
        final alignment = optionsMap.remove('alignment') ?? 'center';
        final finalOptions = {...optionsMap};
        if (scaling is PdfPrintScalingCustom) {
          finalOptions['custom-scale-factor'] = scaling.scale.toString();
        }
        if (_isCups && priority != null) {
          finalOptions['job-priority'] = priority.toString();
        }
        return _sendPdfJobRequest(
          printerName,
          pdfFilePath,
          docName: docName,
          scalingMode: scaling.nativeValue,
          copies: copies,
          pageRange: pageRange,
          options: finalOptions,
          alignment: alignment,
        );
      },
    );
  }

  /// Submits an arbitrary file to a CUPS printer, letting the server auto-detect
  /// the document format (MIME type) from the file contents.
  ///
  /// Unlike [printPdf], this does NOT render or transform the document. It simply
  /// hands the file to CUPS with no forced `document-format`, so images
  /// (image/jpeg, image/png, ...), PDFs, and any other type CUPS understands are
  /// all accepted. Whether the printer actually renders the format depends on the
  /// server's installed filters.
  ///
  /// NOTE (image rendering): converting an image to printer raster requires the
  /// cups-filters / Gutenprint image filters. On the bundled Android cupsd these
  /// are not present yet, so submitting an image to a *raw* queue sends the file
  /// bytes unfiltered. This method establishes the submit path; rendering support
  /// arrives with the DNP/Gutenprint work.
  ///
  /// On **CUPS** (macOS / Linux / Android) the file is handed to the server, which
  /// auto-detects the format. On **Windows** there is no server-side rasterizer, so the
  /// file is routed by content: a PDF prints through the built-in PDFium path, and an
  /// image (jpg/png/bmp/gif/tiff/...) is decoded with the Windows Imaging Component and
  /// printed to the page (fit-to-page, centered). Unsupported file types return an error.
  ///
  /// Returns the job id (> 0) on success. Throws [PrintingFfiException] on failure.
  Future<int> printFile(
    String printerName,
    String filePath, {
    String docName = 'Flutter Document',
    int? priority,
    List<PrintOption> options = const [],
  }) async {
    if (priority != null && (priority < 1 || priority > 100)) {
      throw PrintingFfiException('Priority must be between 1 and 100');
    }
    final optionsMap = buildOptions(options);
    // Alignment/scaling are PDF-render concepts; drop anything that doesn't
    // apply to a plain file submit.
    optionsMap.remove('alignment');
    // job-priority is honored on CUPS (submit-time) and on Windows (applied to the
    // spooler job right after it is created).
    if (priority != null) {
      optionsMap['job-priority'] = priority.toString();
    }
    return _sendFileJobRequest(printerName, filePath, docName: docName, options: optionsMap);
  }

  /// Convenience wrapper around [printFile] for images.
  ///
  /// Submits an image file (jpg/png/etc.). On **Windows** the image is decoded and
  /// printed to the page (fit-to-page, centered). On **CUPS** it is handed to the server;
  /// see [printFile] for the rendering caveat (a raw/unfiltered queue sends the image
  /// as-is until image filters are available).
  Future<int> printImage({
    required String printerName,
    required String imagePath,
    String docName = 'Flutter Image',
    int? priority,
    List<PrintOption> options = const [],
  }) {
    return printFile(printerName, imagePath, docName: docName, priority: priority, options: options);
  }

  /// Submits an arbitrary file and streams job status updates (CUPS-only).
  ///
  /// See [printFile] for the MIME auto-detection behavior and the image
  /// rendering caveat.
  Stream<PrintJob> printFileAndStreamStatus(
    String printerName,
    String filePath, {
    String docName = 'Flutter Document',
    int? priority,
    List<PrintOption> options = const [],
    Duration pollInterval = const Duration(seconds: 2),
  }) {
    if (_isWindows) {
      // Windows renders synchronously and blocks until the document is fully spooled
      // (EndDoc), so a status poller started afterward would miss the job. Use
      // printImage / printFile / printPdf on Windows and poll listPrintJobs if needed.
      throw PrintingFfiException('printFileAndStreamStatus is not supported on Windows.');
    }
    if (_isCups && priority != null && (priority < 1 || priority > 100)) {
      throw PrintingFfiException('Priority must be between 1 and 100');
    }
    return _streamJobStatus(
      printerName: printerName,
      pollInterval: pollInterval,
      submitJob: () {
        final optionsMap = buildOptions(options);
        optionsMap.remove('alignment');
        if (_isCups && priority != null) {
          optionsMap['job-priority'] = priority.toString();
        }
        return _sendFileJobRequest(printerName, filePath, docName: docName, options: optionsMap);
      },
    );
  }

  Map<String, String> buildOptions(List<PrintOption> options) {
    final Map<String, String> optionsMap = {};
    for (final option in options) {
      switch (option) {
        case WindowsPaperSizeOption(id: final id):
          optionsMap['paper-size-id'] = id.toString();
        case WindowsPaperSourceOption(id: final id):
          optionsMap['paper-source-id'] = id.toString();
        case OrientationOption(orientation: final orientation):
          optionsMap['orientation'] = orientation.name;
        case GenericCupsOption(name: final name, value: final value):
          optionsMap[name] = value;
        case ColorModeOption(mode: final mode):
          optionsMap['color-mode'] = mode.name;
        case PrintQualityOption(quality: final quality):
          optionsMap['print-quality'] = quality.name;
        case WindowsMediaTypeOption(id: final id):
          optionsMap['media-type-id'] = id.toString();
        case AlignmentOption(alignment: final alignment):
          optionsMap['alignment'] = alignment.name;
        case CollateOption(collate: final collate):
          optionsMap['collate'] = collate.toString();
        case DuplexOption(mode: final mode):
          optionsMap['duplex'] = mode.name;
        case PdfRotationOption(rotation: final rotation):
          optionsMap['pdf-rotation'] = rotation.nativeValue.toString();
      }
    }
    return optionsMap;
  }

  Stream<PrintJob> _streamJobStatus({
    required String printerName,
    required Duration pollInterval,
    required Future<int> Function() submitJob,
  }) {
    late StreamController<PrintJob> controller;
    Timer? poller;
    PrintJob? lastJobState;

    PrintJob? findJobById(List<PrintJob> jobs, int jobId) {
      for (final job in jobs) {
        if (job.id == jobId) return job;
      }
      return null;
    }

    Future<void> poll(int jobId) async {
      if (controller.isClosed) {
        poller?.cancel();
        return;
      }

      try {
        final jobs = await listPrintJobs(printerName);
        final currentJob = findJobById(jobs, jobId);

        if (currentJob != null) {
          // Job is still in the queue.
          // Only emit an update if the status has changed.
          if (currentJob.rawStatus != lastJobState?.rawStatus) {
            controller.add(currentJob);
          }
          lastJobState = currentJob;

          // If the job has reached a terminal state, stop polling.
          final status = currentJob.status;
          if (status == PrintJobStatus.completed || status == PrintJobStatus.printed || status == PrintJobStatus.canceled || status == PrintJobStatus.aborted || status == PrintJobStatus.error) {
            poller?.cancel();
            await controller.close();
          }
        } else {
          // Job is no longer in the queue. This usually means it has completed.
          // If we have a last known state and it wasn't already in a terminal state,
          // we can emit a final "printed" or "completed" status before closing the stream.
          const terminalStates = {
            PrintJobStatus.completed,
            PrintJobStatus.printed,
            PrintJobStatus.canceled,
            PrintJobStatus.aborted,
            PrintJobStatus.error,
          };
          if (lastJobState != null && !terminalStates.contains(lastJobState!.status)) {
            // Create a synthetic 'printed'/'completed' job status.
            // We use the most common success state for each platform.
            final finalRawStatus = Platform.isWindows
                ? 128 // JOB_STATUS_PRINTED
                : 9; // IPP_JOB_COMPLETED
            final finalJob = PrintJob(
              lastJobState!.id,
              lastJobState!.title,
              finalRawStatus,
              pagesPrinted: lastJobState!.pagesPrinted,
              totalPages: lastJobState!.totalPages,
            );

            // Only add if the status is actually different.
            if (finalJob.rawStatus != lastJobState!.rawStatus) {
              controller.add(finalJob);
            }
          }
          // The job is gone, so we stop polling and close the stream.
          poller?.cancel();
          await controller.close();
        }
      } catch (e, s) {
        if (!controller.isClosed) {
          controller.addError(e, s);
          poller?.cancel();
          await controller.close();
        }
      }
    }

    controller = StreamController<PrintJob>(
      onListen: () async {
        submitJob()
            .then((jobId) {
              // Got a job ID, start polling.
              // An initial poll is done right away to get the first status.
              poll(jobId);
              poller = Timer.periodic(pollInterval, (_) => poll(jobId));
            })
            .catchError((Object e, StackTrace s) {
              // The job submission failed.
              if (!controller.isClosed) {
                controller.addError(e, s);
                controller.close();
              }
            });
      },
      onCancel: () {
        poller?.cancel();
      },
    );

    return controller.stream;
  }

  Future<List<CupsOptionModel>> getSupportedCupsOptions(String printerName) async {
    if (!_isCups) {
      return [];
    }

    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextGetCupsOptionsRequestId++;
    final request = kDebugMode ? GetCupsOptionsRequest(requestId, printerName) : _GetCupsOptionsRequest(requestId, printerName);
    final Completer<List<CupsOptionModel>> completer = Completer<List<CupsOptionModel>>();
    _getCupsOptionsRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  Future<WindowsPrinterCapabilitiesModel?> getWindowsPrinterCapabilities(String printerName) async {
    if (!_isWindows) {
      return null;
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextGetWindowsCapsRequestId++;
    final request = kDebugMode ? GetWindowsCapsRequest(requestId, printerName) : _GetWindowsCapsRequest(requestId, printerName);
    final completer = Completer<WindowsPrinterCapabilitiesModel?>();
    _getWindowsCapsRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  Future<List<PrintJob>> listPrintJobs(String printerName) async {
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextPrintJobsRequestId++;
    final request = kDebugMode ? PrintJobsRequest(requestId, printerName) : _PrintJobsRequest(requestId, printerName);
    final Completer<List<PrintJob>> completer = Completer<List<PrintJob>>();
    _printJobsRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  Stream<List<PrintJob>> listPrintJobsStream(
    String printerName, {
    Duration pollInterval = const Duration(seconds: 2),
  }) {
    late StreamController<List<PrintJob>> controller;
    Timer? timer;

    void startPolling() {
      if (timer?.isActive ?? false) return;
      timer = Timer.periodic(pollInterval, (_) async {
        if (controller.isClosed) {
          timer?.cancel();
          return;
        }
        try {
          final jobs = await listPrintJobs(printerName);
          if (!controller.isClosed) {
            controller.add(jobs);
          }
        } catch (e, s) {
          if (!controller.isClosed) {
            controller.addError(e, s);
          }
        }
      });
    }

    void stopPolling() {
      timer?.cancel();
      timer = null;
    }

    controller = StreamController<List<PrintJob>>(
      onListen: () {
        listPrintJobs(printerName)
            .then((jobs) {
              if (!controller.isClosed) {
                controller.add(jobs);
              }
              startPolling();
            })
            .catchError((e, s) {
              if (!controller.isClosed) {
                controller.addError(e, s);
              }
            });
      },
      onPause: stopPolling,
      onResume: startPolling,
      onCancel: stopPolling,
    );

    return controller.stream;
  }

  Future<bool> pausePrintJob(String printerName, int jobId) async {
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextPrintJobActionRequestId++;
    final request = kDebugMode ? PrintJobActionRequest(requestId, printerName, jobId, 'pause') : _PrintJobActionRequest(requestId, printerName, jobId, 'pause');
    final Completer<bool> completer = Completer<bool>();
    _printJobActionRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  Future<bool> resumePrintJob(String printerName, int jobId) async {
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextPrintJobActionRequestId++;
    final request = kDebugMode ? PrintJobActionRequest(requestId, printerName, jobId, 'resume') : _PrintJobActionRequest(requestId, printerName, jobId, 'resume');
    final Completer<bool> completer = Completer<bool>();
    _printJobActionRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  Future<bool> cancelPrintJob(String printerName, int jobId) async {
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextPrintJobActionRequestId++;
    final request = kDebugMode ? PrintJobActionRequest(requestId, printerName, jobId, 'cancel') : _PrintJobActionRequest(requestId, printerName, jobId, 'cancel');
    final Completer<bool> completer = Completer<bool>();
    _printJobActionRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Pauses the specified printer (CUPS only - macOS/Linux).
  ///
  /// This prevents new jobs from being processed by the printer.
  /// Jobs already in progress may continue. To pause individual jobs, use [pausePrintJob].
  ///
  /// [printerName]: The name of the printer to pause.
  /// [username]: Optional username for authentication (admin rights may be required).
  /// [password]: Optional password for authentication.
  ///
  /// Returns `true` if the operation succeeded, `false` otherwise.
  /// Throws [PrintingFfiException] on error.
  Future<bool> cupsPausePrinter(String printerName, {String? username, String? password}) async {
    if (!_supportsQueueControl) {
      throw PrintingFfiException('cupsPausePrinter is not supported on this platform');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextCupsPrinterControlRequestId++;
    final request = kDebugMode ? CupsPrinterControlRequest(requestId, printerName, 'pause', null, username, password) : _CupsPrinterControlRequest(requestId, printerName, 'pause', null, username, password);
    final Completer<bool> completer = Completer<bool>();
    _cupsPrinterControlRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Resumes the specified printer (CUPS only - macOS/Linux).
  ///
  /// This allows the printer to process jobs again after being paused.
  ///
  /// [printerName]: The name of the printer to resume.
  /// [username]: Optional username for authentication (admin rights may be required).
  /// [password]: Optional password for authentication.
  ///
  /// Returns `true` if the operation succeeded, `false` otherwise.
  /// Throws [PrintingFfiException] on error.
  Future<bool> cupsResumePrinter(String printerName, {String? username, String? password}) async {
    if (!_supportsQueueControl) {
      throw PrintingFfiException('cupsResumePrinter is not supported on this platform');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextCupsPrinterControlRequestId++;
    final request = kDebugMode ? CupsPrinterControlRequest(requestId, printerName, 'resume', null, username, password) : _CupsPrinterControlRequest(requestId, printerName, 'resume', null, username, password);
    final Completer<bool> completer = Completer<bool>();
    _cupsPrinterControlRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Enables the specified printer (CUPS only - macOS/Linux).
  ///
  /// This makes the printer available for accepting jobs.
  /// This is different from [cupsResumePrinter] - enable/disable controls
  /// whether the printer can accept jobs, while pause/resume controls job processing.
  ///
  /// [printerName]: The name of the printer to enable.
  /// [username]: Optional username for authentication (admin rights may be required).
  /// [password]: Optional password for authentication.
  ///
  /// Returns `true` if the operation succeeded, `false` otherwise.
  /// Throws [PrintingFfiException] on error.
  Future<bool> cupsEnablePrinter(String printerName, {String? username, String? password}) async {
    if (!_supportsQueueControl) {
      throw PrintingFfiException('cupsEnablePrinter is not supported on this platform');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextCupsPrinterControlRequestId++;
    final request = kDebugMode ? CupsPrinterControlRequest(requestId, printerName, 'enable', null, username, password) : _CupsPrinterControlRequest(requestId, printerName, 'enable', null, username, password);
    final Completer<bool> completer = Completer<bool>();
    _cupsPrinterControlRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Disables the specified printer (CUPS only - macOS/Linux).
  ///
  /// This prevents the printer from accepting new jobs.
  /// Jobs already queued will remain in the queue but won't be processed
  /// until the printer is enabled again.
  ///
  /// [printerName]: The name of the printer to disable.
  /// [reason]: Optional reason for disabling the printer (displayed to users).
  /// [username]: Optional username for authentication (admin rights may be required).
  /// [password]: Optional password for authentication.
  ///
  /// Returns `true` if the operation succeeded, `false` otherwise.
  /// Throws [PrintingFfiException] on error.
  Future<bool> cupsDisablePrinter(String printerName, {String? reason, String? username, String? password}) async {
    if (!_supportsQueueControl) {
      throw PrintingFfiException('cupsDisablePrinter is not supported on this platform');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextCupsPrinterControlRequestId++;
    final request = kDebugMode ? CupsPrinterControlRequest(requestId, printerName, 'disable', reason, username, password) : _CupsPrinterControlRequest(requestId, printerName, 'disable', reason, username, password);
    final Completer<bool> completer = Completer<bool>();
    _cupsPrinterControlRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Configures the printer to accept new jobs (CUPS only - macOS/Linux).
  ///
  /// This is the opposite of [cupsRejectJobs]. When a printer is accepting jobs,
  /// new print jobs can be submitted to its queue.
  ///
  /// [printerName]: The name of the printer.
  /// [username]: Optional username for authentication (admin rights may be required).
  /// [password]: Optional password for authentication.
  ///
  /// Returns `true` if the operation succeeded, `false` otherwise.
  /// Throws [PrintingFfiException] on error.
  Future<bool> cupsAcceptJobs(String printerName, {String? username, String? password}) async {
    if (!_supportsQueueControl) {
      throw PrintingFfiException('cupsAcceptJobs is not supported on this platform');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextCupsPrinterControlRequestId++;
    final request = kDebugMode ? CupsPrinterControlRequest(requestId, printerName, 'accept', null, username, password) : _CupsPrinterControlRequest(requestId, printerName, 'accept', null, username, password);
    final Completer<bool> completer = Completer<bool>();
    _cupsPrinterControlRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Configures the printer to reject new jobs (CUPS only - macOS/Linux).
  ///
  /// When a printer is rejecting jobs, users cannot submit new print jobs.
  /// Existing jobs in the queue remain and can still be processed.
  ///
  /// [printerName]: The name of the printer.
  /// [reason]: Optional reason for rejecting jobs (displayed to users).
  /// [username]: Optional username for authentication (admin rights may be required).
  /// [password]: Optional password for authentication.
  ///
  /// Returns `true` if the operation succeeded, `false` otherwise.
  /// Throws [PrintingFfiException] on error.
  Future<bool> cupsRejectJobs(String printerName, {String? reason, String? username, String? password}) async {
    if (!_supportsQueueControl) {
      throw PrintingFfiException('cupsRejectJobs is not supported on this platform');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextCupsPrinterControlRequestId++;
    final request = kDebugMode ? CupsPrinterControlRequest(requestId, printerName, 'reject', reason, username, password) : _CupsPrinterControlRequest(requestId, printerName, 'reject', reason, username, password);
    final Completer<bool> completer = Completer<bool>();
    _cupsPrinterControlRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Holds a specific job in the print queue (CUPS only - macOS/Linux).
  ///
  /// A held job will not be printed until it is released with [cupsReleaseJob].
  /// This is different from [pausePrintJob] which temporarily pauses processing.
  ///
  /// [printerName]: The name of the printer.
  /// [jobId]: The ID of the job to hold.
  /// [username]: Optional username for authentication.
  /// [password]: Optional password for authentication.
  ///
  /// Returns `true` if the operation succeeded, `false` otherwise.
  /// Throws [PrintingFfiException] on error.
  Future<bool> cupsHoldJob(String printerName, int jobId, {String? username, String? password}) async {
    if (!_supportsQueueControl) {
      throw PrintingFfiException('cupsHoldJob is not supported on this platform');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextCupsJobControlRequestId++;
    final request = kDebugMode ? CupsJobControlRequest(requestId, printerName, jobId, 'hold', null, 0, username, password) : _CupsJobControlRequest(requestId, printerName, jobId, 'hold', null, 0, username, password);
    final Completer<bool> completer = Completer<bool>();
    _cupsJobControlRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Releases a held job in the print queue (CUPS only - macOS/Linux).
  ///
  /// This allows a previously held job to be processed and printed.
  ///
  /// [printerName]: The name of the printer.
  /// [jobId]: The ID of the job to release.
  /// [username]: Optional username for authentication.
  /// [password]: Optional password for authentication.
  ///
  /// Returns `true` if the operation succeeded, `false` otherwise.
  /// Throws [PrintingFfiException] on error.
  Future<bool> cupsReleaseJob(String printerName, int jobId, {String? username, String? password}) async {
    if (!_supportsQueueControl) {
      throw PrintingFfiException('cupsReleaseJob is not supported on this platform');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextCupsJobControlRequestId++;
    final request = kDebugMode ? CupsJobControlRequest(requestId, printerName, jobId, 'release', null, 0, username, password) : _CupsJobControlRequest(requestId, printerName, jobId, 'release', null, 0, username, password);
    final Completer<bool> completer = Completer<bool>();
    _cupsJobControlRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Moves a job from one printer to another (CUPS only - macOS/Linux).
  ///
  /// This transfers a print job from the source printer's queue to the
  /// destination printer's queue. Useful for load balancing or when a printer
  /// becomes unavailable.
  ///
  /// [sourcePrinter]: The name of the printer where the job currently resides.
  /// [jobId]: The ID of the job to move.
  /// [destPrinter]: The name of the destination printer.
  /// [username]: Optional username for authentication (admin rights may be required).
  /// [password]: Optional password for authentication.
  ///
  /// Returns `true` if the operation succeeded, `false` otherwise.
  /// Throws [PrintingFfiException] on error.
  Future<bool> cupsMoveJob(String sourcePrinter, int jobId, String destPrinter, {String? username, String? password}) async {
    if (!_isCups) {
      throw PrintingFfiException('cupsMoveJob is only supported on macOS, Linux, and Android');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextCupsJobControlRequestId++;
    final request = kDebugMode ? CupsJobControlRequest(requestId, sourcePrinter, jobId, 'move', destPrinter, 0, username, password) : _CupsJobControlRequest(requestId, sourcePrinter, jobId, 'move', destPrinter, 0, username, password);
    final Completer<bool> completer = Completer<bool>();
    _cupsJobControlRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Changes the priority of a print job (CUPS only - macOS/Linux).
  ///
  /// Priority determines the order in which jobs are printed, with higher
  /// values indicating higher priority. CUPS priority ranges from 1 (lowest)
  /// to 100 (highest), with 50 being the default.
  ///
  /// [printerName]: The name of the printer.
  /// [jobId]: The ID of the job to modify.
  /// [priority]: The new priority (1-100, default is 50).
  /// [username]: Optional username for authentication.
  /// [password]: Optional password for authentication.
  ///
  /// Returns `true` if the operation succeeded, `false` otherwise.
  /// Throws [PrintingFfiException] on error.
  Future<bool> cupsSetJobPriority(String printerName, int jobId, int priority, {String? username, String? password}) async {
    if (!_supportsQueueControl) {
      throw PrintingFfiException('cupsSetJobPriority is not supported on this platform');
    }
    if (priority < 1 || priority > 100) {
      throw PrintingFfiException('Priority must be between 1 and 100');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextCupsJobControlRequestId++;
    final request = kDebugMode ? CupsJobControlRequest(requestId, printerName, jobId, 'priority', null, priority, username, password) : _CupsJobControlRequest(requestId, printerName, jobId, 'priority', null, priority, username, password);
    final Completer<bool> completer = Completer<bool>();
    _cupsJobControlRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Queries a single attribute from a CUPS printer (CUPS only - macOS/Linux).
  ///
  /// This allows you to retrieve specific printer attributes like 'printer-state',
  /// 'printer-make-and-model', 'printer-location', etc. For a list of standard
  /// IPP attributes, see the IPP specification.
  ///
  /// Common attributes include:
  /// - `printer-state`: Current state (3=idle, 4=processing, 5=stopped)
  /// - `printer-state-reasons`: Reasons for the current state
  /// - `printer-make-and-model`: Manufacturer and model
  /// - `printer-location`: Physical location
  /// - `printer-info`: Human-readable description
  /// - `printer-uri-supported`: Supported URIs
  /// - `device-uri`: Device URI
  /// - `printer-is-accepting-jobs`: Whether accepting new jobs
  ///
  /// [printerName]: The name of the printer.
  /// [attributeName]: The name of the attribute to query.
  /// [username]: Optional username for authentication.
  /// [password]: Optional password for authentication.
  ///
  /// Returns a [PrinterAttribute] with the attribute value(s), or `null` if not found.
  /// Throws [PrintingFfiException] on error.
  Future<PrinterAttribute?> cupsGetPrinterAttribute(String printerName, String attributeName, {String? username, String? password}) async {
    if (!_supportsQueueControl) {
      throw PrintingFfiException('cupsGetPrinterAttribute is not supported on this platform');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextCupsAttributeRequestId++;
    final request = kDebugMode ? CupsAttributeRequest(requestId, printerName, [attributeName], username, password) : _CupsAttributeRequest(requestId, printerName, [attributeName], username, password);
    final Completer<PrinterAttribute?> completer = Completer<PrinterAttribute?>();
    _cupsAttributeRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Queries multiple attributes from a CUPS printer (CUPS only - macOS/Linux).
  ///
  /// This is more efficient than calling [cupsGetPrinterAttribute] multiple times
  /// as it makes a single IPP request for all attributes.
  ///
  /// [printerName]: The name of the printer.
  /// [attributeNames]: List of attribute names to query.
  /// [username]: Optional username for authentication.
  /// [password]: Optional password for authentication.
  ///
  /// Returns a list of [PrinterAttribute] objects, one for each requested attribute.
  /// If an attribute is not found, it will still be included with an empty value.
  /// Throws [PrintingFfiException] on error.
  Future<List<PrinterAttribute>> cupsGetPrinterAttributes(String printerName, List<String> attributeNames, {String? username, String? password}) async {
    if (!_supportsQueueControl) {
      throw PrintingFfiException('cupsGetPrinterAttributes is not supported on this platform');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextCupsAttributeRequestId++;
    final request = kDebugMode ? CupsAttributeRequest(requestId, printerName, attributeNames, username, password) : _CupsAttributeRequest(requestId, printerName, attributeNames, username, password);
    final Completer<List<PrinterAttribute>> completer = Completer<List<PrinterAttribute>>();
    _cupsAttributesRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  /// Queries **all** attributes a CUPS printer exposes (CUPS only - macOS/Linux/Android).
  ///
  /// Unlike [cupsGetPrinterAttribute]/[cupsGetPrinterAttributes], you do not need
  /// to know the attribute names in advance: this sends an IPP Get-Printer-Attributes
  /// request with `requested-attributes = all` and returns every attribute in the
  /// printer group, each as a [PrinterAttribute] carrying its name and value(s).
  ///
  /// Use it to discover the supported attribute names for a printer, e.g.:
  /// ```dart
  /// final attrs = await printingFfi.cupsGetAllPrinterAttributes('My_Printer');
  /// for (final a in attrs) {
  ///   print(a.name); // 'printer-state', 'media-supported', 'printer-resolution-supported', ...
  /// }
  /// ```
  ///
  /// [printerName]: The name of the printer.
  /// [username]: Optional username for authentication.
  /// [password]: Optional password for authentication.
  ///
  /// Returns the full list of [PrinterAttribute] objects (empty if the printer
  /// reports none). Throws [PrintingFfiException] on error.
  Future<List<PrinterAttribute>> cupsGetAllPrinterAttributes(String printerName, {String? username, String? password}) async {
    if (!_supportsQueueControl) {
      throw PrintingFfiException('cupsGetAllPrinterAttributes is not supported on this platform');
    }
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextCupsAttributeRequestId++;
    final request = kDebugMode ? CupsAllAttributesRequest(requestId, printerName, username, password) : _CupsAllAttributesRequest(requestId, printerName, username, password);
    final Completer<List<PrinterAttribute>> completer = Completer<List<PrinterAttribute>>();
    _cupsAttributesRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  Future<int> _sendRawDataJobRequest(
    String printerName,
    Uint8List data, {
    String docName = 'Flutter Document',
    Map<String, String> options = const {},
  }) async {
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextSubmitRawDataJobRequestId++;
    final request = kDebugMode ? SubmitRawDataJobRequest(requestId, printerName, data, docName, options) : _SubmitRawDataJobRequest(requestId, printerName, data, docName, options);
    final completer = Completer<int>();
    _submitRawDataJobRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  Future<int> _sendPdfJobRequest(
    String printerName,
    String pdfFilePath, {
    String docName = 'Flutter PDF Document',
    required int scalingMode,
    int? copies,
    PageRange? pageRange,
    Map<String, String> options = const {},
    String alignment = 'center',
  }) async {
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextSubmitPdfJobRequestId++;
    final pageRangeValue = pageRange?.toValue();
    final request = kDebugMode
        ? SubmitPdfJobRequest(requestId, printerName, pdfFilePath, docName, options, scalingMode, copies ?? 1, pageRangeValue, alignment)
        : _SubmitPdfJobRequest(
            requestId,
            printerName,
            pdfFilePath,
            docName,
            options,
            scalingMode,
            copies ?? 1,
            pageRangeValue,
            alignment,
          );
    final completer = Completer<int>();
    _submitPdfJobRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  Future<int> _sendFileJobRequest(
    String printerName,
    String filePath, {
    String docName = 'Flutter Document',
    Map<String, String> options = const {},
  }) async {
    final SendPort helperIsolateSendPort = await _helperIsolateSendPort;
    final int requestId = _nextSubmitFileJobRequestId++;
    final request = kDebugMode
        ? SubmitFileJobRequest(requestId, printerName, filePath, docName, options)
        : _SubmitFileJobRequest(requestId, printerName, filePath, docName, options);
    final completer = Completer<int>();
    _submitFileJobRequests[requestId] = completer;
    helperIsolateSendPort.send(request);
    return completer.future;
  }

  int _nextPrintRequestId = 0;
  int _nextPrintJobsRequestId = 0;
  int _nextPrintJobActionRequestId = 0;
  int _nextPrintPdfRequestId = 0;
  int _nextGetCupsOptionsRequestId = 0;
  int _nextGetWindowsCapsRequestId = 0;
  int _nextOpenPrinterPropertiesRequestId = 0;
  int _nextSubmitRawDataJobRequestId = 0;
  int _nextSubmitPdfJobRequestId = 0;
  int _nextSubmitFileJobRequestId = 0;
  int _nextPrintFileWithDialogRequestId = 0;
  int _nextCupsPrinterControlRequestId = 0;
  int _nextCupsJobControlRequestId = 0;
  int _nextCupsAttributeRequestId = 0;

  final Map<int, Completer<bool>> _printRequests = <int, Completer<bool>>{};
  final Map<int, Completer<List<PrintJob>>> _printJobsRequests = <int, Completer<List<PrintJob>>>{};
  final Map<int, Completer<bool>> _printJobActionRequests = <int, Completer<bool>>{};
  final Map<int, Completer<bool>> _printPdfRequests = <int, Completer<bool>>{};
  final Map<int, Completer<List<CupsOptionModel>>> _getCupsOptionsRequests = <int, Completer<List<CupsOptionModel>>>{};
  final Map<int, Completer<WindowsPrinterCapabilitiesModel?>> _getWindowsCapsRequests = <int, Completer<WindowsPrinterCapabilitiesModel?>>{};
  final Map<int, Completer<PrinterPropertiesResult>> _openPrinterPropertiesRequests = <int, Completer<PrinterPropertiesResult>>{};
  final Map<int, Completer<int>> _submitRawDataJobRequests = <int, Completer<int>>{};
  final Map<int, Completer<int>> _submitPdfJobRequests = <int, Completer<int>>{};
  final Map<int, Completer<int>> _submitFileJobRequests = <int, Completer<int>>{};
  final Map<int, Completer<bool>> _printPdfWithDialogRequests = <int, Completer<bool>>{};
  final Map<int, Completer<bool>> _cupsPrinterControlRequests = <int, Completer<bool>>{};
  final Map<int, Completer<bool>> _cupsJobControlRequests = <int, Completer<bool>>{};
  final Map<int, Completer<PrinterAttribute?>> _cupsAttributeRequests = <int, Completer<PrinterAttribute?>>{};
  final Map<int, Completer<List<PrinterAttribute>>> _cupsAttributesRequests = <int, Completer<List<PrinterAttribute>>>{};

  Future<SendPort>? _helperIsolateSendPortFuture;

  void _failAllPendingRequests(Object error, [StackTrace? stackTrace]) {
    final allCompleters = [
      ..._printRequests.values,
      ..._printJobsRequests.values,
      ..._printJobActionRequests.values,
      ..._printPdfRequests.values,
      ..._getCupsOptionsRequests.values,
      ..._getWindowsCapsRequests.values,
      ..._openPrinterPropertiesRequests.values,
      ..._submitRawDataJobRequests.values,
      ..._submitPdfJobRequests.values,
      ..._submitFileJobRequests.values,
      ..._printPdfWithDialogRequests.values,
      ..._cupsPrinterControlRequests.values,
      ..._cupsJobControlRequests.values,
      ..._cupsAttributeRequests.values,
      ..._cupsAttributesRequests.values,
    ];

    for (final completer in allCompleters) {
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }

    _printRequests.clear();
    _printJobsRequests.clear();
    _printJobActionRequests.clear();
    _printPdfRequests.clear();
    _getCupsOptionsRequests.clear();
    _getWindowsCapsRequests.clear();
    _openPrinterPropertiesRequests.clear();
    _submitRawDataJobRequests.clear();
    _submitPdfJobRequests.clear();
    _submitFileJobRequests.clear();
    _printPdfWithDialogRequests.clear();
    _cupsPrinterControlRequests.clear();
    _cupsJobControlRequests.clear();
    _cupsAttributeRequests.clear();
    _cupsAttributesRequests.clear();
  }

  Future<SendPort> get _helperIsolateSendPort async {
    if (_helperIsolateSendPortFuture != null) {
      return _helperIsolateSendPortFuture!;
    }

    final Completer<SendPort> completer = Completer<SendPort>();
    _mainReceivePort = ReceivePort();

    _mainPortSubscription = _mainReceivePort!.listen((message) => _handleMessage(message, completer: completer));

    try {
      await Isolate.spawn(
        _helperIsolateEntryPoint,
        _mainReceivePort!.sendPort,
      );
    } catch (error, stack) {
      if (!completer.isCompleted) {
        completer.completeError(error, stack);
      }
    }

    _helperIsolateSendPortFuture = completer.future;
    return _helperIsolateSendPortFuture!;
  }

  Completer<T>? _takeRequestCompleter<T>(
    Map<int, Completer<T>> requests,
    int id,
    String responseType,
  ) {
    final completer = requests.remove(id);
    if (completer == null) {
      debugPrint('printing_ffi: ignoring stale $responseType for request id $id');
    }
    return completer;
  }

  void _handleMessage(dynamic data, {Completer<SendPort>? completer}) {
    if (data is SendPort) {
      if (completer != null && !completer.isCompleted) {
        completer.complete(data);
      }
      return;
    }

    if (data is List && data.length == 2 && data[0] is String) {
      final error = IsolateError('Uncaught exception in helper isolate: ${data[0]}');
      final stack = StackTrace.fromString(data[1].toString());
      if (completer != null && !completer.isCompleted) {
        completer.completeError(error, stack);
      }
      _failAllPendingRequests(error, stack);
      _mainPortSubscription?.cancel();
      _mainReceivePort?.close();
      _mainPortSubscription = null;
      _mainReceivePort = null;
      return;
    }

    if (data == null) {
      final error = IsolateError('Helper isolate exited unexpectedly.');
      if (completer != null && !completer.isCompleted) {
        completer.completeError(error);
      }
      _failAllPendingRequests(error);
      _mainPortSubscription?.cancel();
      _mainReceivePort?.close();
      _mainPortSubscription = null;
      _mainReceivePort = null;
      return;
    }

    if (data is _PrintResponse) {
      final requestCompleter = _takeRequestCompleter(_printRequests, data.id, '_PrintResponse');
      requestCompleter?.complete(data.result);
      return;
    }
    if (data is _PrintJobsResponse) {
      final requestCompleter = _takeRequestCompleter(_printJobsRequests, data.id, '_PrintJobsResponse');
      requestCompleter?.complete(data.jobs);
      return;
    }
    if (data is _PrintJobActionResponse) {
      final requestCompleter = _takeRequestCompleter(_printJobActionRequests, data.id, '_PrintJobActionResponse');
      requestCompleter?.complete(data.result);
      return;
    }
    if (data is _PrintPdfResponse) {
      final requestCompleter = _takeRequestCompleter(_printPdfRequests, data.id, '_PrintPdfResponse');
      requestCompleter?.complete(data.result);
      return;
    }
    if (data is _GetCupsOptionsResponse) {
      final requestCompleter = _takeRequestCompleter(_getCupsOptionsRequests, data.id, '_GetCupsOptionsResponse');
      requestCompleter?.complete(data.options);
      return;
    }
    if (data is _GetWindowsCapsResponse) {
      final requestCompleter = _takeRequestCompleter(_getWindowsCapsRequests, data.id, '_GetWindowsCapsResponse');
      requestCompleter?.complete(data.capabilities);
      return;
    }
    if (data is _OpenPrinterPropertiesResponse) {
      final requestCompleter = _takeRequestCompleter(
        _openPrinterPropertiesRequests,
        data.id,
        '_OpenPrinterPropertiesResponse',
      );
      requestCompleter?.complete(data.result);
      return;
    }
    if (data is _SubmitJobResponse) {
      if (_submitRawDataJobRequests.containsKey(data.id)) {
        _submitRawDataJobRequests.remove(data.id)!.complete(data.jobId);
      } else if (_submitPdfJobRequests.containsKey(data.id)) {
        _submitPdfJobRequests.remove(data.id)!.complete(data.jobId);
      } else if (_submitFileJobRequests.containsKey(data.id)) {
        _submitFileJobRequests.remove(data.id)!.complete(data.jobId);
      }
      return;
    }
    if (data is _PrintFileWithDialogResponse) {
      final requestCompleter = _takeRequestCompleter(
        _printPdfWithDialogRequests,
        data.id,
        '_PrintFileWithDialogResponse',
      );
      requestCompleter?.complete(data.result);
      return;
    }
    if (data is _CupsPrinterControlResponse) {
      final requestCompleter = _takeRequestCompleter(
        _cupsPrinterControlRequests,
        data.id,
        '_CupsPrinterControlResponse',
      );
      requestCompleter?.complete(data.result);
      return;
    }
    if (data is _CupsJobControlResponse) {
      final requestCompleter = _takeRequestCompleter(_cupsJobControlRequests, data.id, '_CupsJobControlResponse');
      requestCompleter?.complete(data.result);
      return;
    }
    if (data is _CupsAttributeResponse) {
      final requestCompleter = _takeRequestCompleter(_cupsAttributeRequests, data.id, '_CupsAttributeResponse');
      requestCompleter?.complete(data.attribute);
      return;
    }
    if (data is _CupsAttributesResponse) {
      final requestCompleter = _takeRequestCompleter(_cupsAttributesRequests, data.id, '_CupsAttributesResponse');
      requestCompleter?.complete(data.attributes);
      return;
    }
    if (data is _ErrorResponse) {
      Completer? requestCompleter;
      final allRequestMaps = [
        _printRequests,
        _printJobsRequests,
        _printJobActionRequests,
        _printPdfRequests,
        _getCupsOptionsRequests,
        _getWindowsCapsRequests,
        _openPrinterPropertiesRequests,
        _submitRawDataJobRequests,
        _submitPdfJobRequests,
        _submitFileJobRequests,
        _printPdfWithDialogRequests,
        _cupsPrinterControlRequests,
        _cupsJobControlRequests,
        _cupsAttributeRequests,
        _cupsAttributesRequests,
      ];
      for (final map in allRequestMaps) {
        if (map.containsKey(data.id)) {
          requestCompleter = map.remove(data.id);
          break;
        }
      }
      requestCompleter?.completeError(data.error, data.stackTrace);
      return;
    }
    throw UnsupportedError('Unsupported message type: ${data.runtimeType}');
  }
}

// Helper classes for isolate communication

class _PrintRequest {
  final int id;
  final String printerName;
  final Uint8List data;
  final String docName;
  final Map<String, String>? options;

  const _PrintRequest(this.id, this.printerName, this.data, this.docName, this.options);
}

class _PrintJobsRequest {
  final int id;
  final String printerName;

  const _PrintJobsRequest(this.id, this.printerName);
}

class _PrintJobActionRequest {
  final int id;
  final String printerName;
  final int jobId;
  final String action;

  const _PrintJobActionRequest(this.id, this.printerName, this.jobId, this.action);
}

class _PrintPdfRequest {
  final int id;
  final String printerName;
  final String pdfFilePath;
  final String docName;
  final Map<String, String>? options;
  final int scalingMode;
  final int copies;
  final String? pageRange;
  final String alignment;

  const _PrintPdfRequest(this.id, this.printerName, this.pdfFilePath, this.docName, this.options, this.scalingMode, this.copies, this.pageRange, this.alignment);
}

class _GetCupsOptionsRequest {
  final int id;
  final String printerName;

  const _GetCupsOptionsRequest(this.id, this.printerName);
}

class _GetWindowsCapsRequest {
  final int id;
  final String printerName;

  const _GetWindowsCapsRequest(this.id, this.printerName);
}

class _OpenPrinterPropertiesRequest {
  final int id;
  final String printerName;
  final int hwnd;

  const _OpenPrinterPropertiesRequest(this.id, this.printerName, this.hwnd);
}

class _SubmitRawDataJobRequest {
  final int id;
  final String printerName;
  final Uint8List data;
  final String docName;
  final Map<String, String>? options;

  const _SubmitRawDataJobRequest(this.id, this.printerName, this.data, this.docName, this.options);
}

class _SubmitPdfJobRequest {
  final int id;
  final String printerName;
  final String pdfFilePath;
  final String docName;
  final Map<String, String>? options;
  final int scalingMode;
  final int copies;
  final String? pageRange;
  final String alignment;

  const _SubmitPdfJobRequest(this.id, this.printerName, this.pdfFilePath, this.docName, this.options, this.scalingMode, this.copies, this.pageRange, this.alignment);
}

class _SubmitFileJobRequest {
  final int id;
  final String printerName;
  final String filePath;
  final String docName;
  final Map<String, String>? options;

  const _SubmitFileJobRequest(this.id, this.printerName, this.filePath, this.docName, this.options);
}

class _PrintFileWithDialogRequest {
  final int id;
  final String filePath;
  final String docName;

  const _PrintFileWithDialogRequest(this.id, this.filePath, this.docName);
}

class _PrintResponse {
  final int id;
  final bool result;

  const _PrintResponse(this.id, this.result);
}

class _PrintJobsResponse {
  final int id;
  final List<PrintJob> jobs;

  const _PrintJobsResponse(this.id, this.jobs);
}

class _PrintJobActionResponse {
  final int id;
  final bool result;

  const _PrintJobActionResponse(this.id, this.result);
}

class _PrintPdfResponse {
  final int id;
  final bool result;

  const _PrintPdfResponse(this.id, this.result);
}

class _GetCupsOptionsResponse {
  final int id;
  final List<CupsOptionModel> options;

  const _GetCupsOptionsResponse(this.id, this.options);
}

class _GetWindowsCapsResponse {
  final int id;
  final WindowsPrinterCapabilitiesModel? capabilities;

  const _GetWindowsCapsResponse(this.id, this.capabilities);
}

class _OpenPrinterPropertiesResponse {
  final int id;
  final PrinterPropertiesResult result;

  const _OpenPrinterPropertiesResponse(this.id, this.result);
}

class _SubmitJobResponse {
  final int id;
  final int jobId;

  const _SubmitJobResponse(this.id, this.jobId);
}

class _PrintFileWithDialogResponse {
  final int id;
  final bool result;

  const _PrintFileWithDialogResponse(this.id, this.result);
}

class _ErrorResponse {
  final int id;
  final String errorMessage;
  final bool isPrintingFfiException;
  final String? serializedStackTrace;

  _ErrorResponse(this.id, Object error, StackTrace? stackTrace) : errorMessage = error is PrintingFfiException ? error.message : error.toString(), isPrintingFfiException = error is PrintingFfiException, serializedStackTrace = stackTrace?.toString();

  Object get error => isPrintingFfiException ? PrintingFfiException(errorMessage) : Exception(errorMessage);

  StackTrace? get stackTrace => serializedStackTrace == null ? null : StackTrace.fromString(serializedStackTrace!);
}

class _DisposeRequest {
  const _DisposeRequest();
}

class _CupsPrinterControlRequest {
  final int id;
  final String printerName;
  final String action; // 'pause', 'resume', 'enable', 'disable', 'accept', 'reject'
  final String? reason;
  final String? username;
  final String? password;

  const _CupsPrinterControlRequest(this.id, this.printerName, this.action, this.reason, this.username, this.password);
}

class _CupsPrinterControlResponse {
  final int id;
  final bool result;

  const _CupsPrinterControlResponse(this.id, this.result);
}

class _CupsJobControlRequest {
  final int id;
  final String printerName;
  final int jobId;
  final String action; // 'hold', 'release', 'move', 'priority'
  final String? destPrinter; // For move operation
  final int priority; // For priority operation
  final String? username;
  final String? password;

  const _CupsJobControlRequest(this.id, this.printerName, this.jobId, this.action, this.destPrinter, this.priority, this.username, this.password);
}

class _CupsJobControlResponse {
  final int id;
  final bool result;

  const _CupsJobControlResponse(this.id, this.result);
}

class _CupsAttributeRequest {
  final int id;
  final String printerName;
  final List<String> attributeNames;
  final String? username;
  final String? password;

  const _CupsAttributeRequest(this.id, this.printerName, this.attributeNames, this.username, this.password);
}

class _CupsAllAttributesRequest {
  final int id;
  final String printerName;
  final String? username;
  final String? password;

  const _CupsAllAttributesRequest(this.id, this.printerName, this.username, this.password);
}

class _CupsAttributeResponse {
  final int id;
  final PrinterAttribute? attribute;

  const _CupsAttributeResponse(this.id, this.attribute);
}

class _CupsAttributesResponse {
  final int id;
  final List<PrinterAttribute> attributes;

  const _CupsAttributesResponse(this.id, this.attributes);
}

/// The entry point for the helper isolate.
void _helperIsolateEntryPoint(SendPort sendPort) {
  runZonedGuarded(
    () {
      if (Platform.isWindows) {
        // Initialize COM for the current thread. This is crucial for some Windows APIs,
        // especially those related to printing and shell services, which may be
        // used by printer drivers. Without this, calls can hang, fail, or perform
        // very slowly when run from a background isolate.
        // COINIT_APARTMENTTHREADED is a common requirement for UI-related components
        // that printer drivers might interact with.
        try {
          final ole32 = DynamicLibrary.open('ole32.dll');
          final coInitializeEx = ole32.lookup<NativeFunction<Int32 Function(Pointer, Uint32)>>('CoInitializeEx');
          final coInitializeExFunc = coInitializeEx.asFunction<int Function(Pointer, int)>();
          // Revert to STA (Single-Threaded Apartment) as some printer drivers
          // have strict requirements for it. To prevent the thread from hanging,
          // we will manually pump the Windows message queue from the native C code
          // during long-running operations.
          const coinitApartmentthreaded = 0x2;
          coInitializeExFunc(nullptr, coinitApartmentthreaded);
          // We don't check the HRESULT. It's okay if it's already initialized (S_FALSE).
          // We just need to ensure it's been called once for this thread.
        } catch (e) {
          // If CoInitializeEx is not available or fails, we'll proceed without it,
          // but this might be the cause of the reported performance issues.
        }
      }
      final dylib = () {
        if (Platform.isMacOS) {
          return DynamicLibrary.open('${PrintingFfi._libName}.framework/${PrintingFfi._libName}');
        }
        if (Platform.isLinux) return DynamicLibrary.open('lib${PrintingFfi._libName}.so');
        if (Platform.isAndroid) return DynamicLibrary.open('lib${PrintingFfi._libName}.so');
        if (Platform.isWindows) return DynamicLibrary.open('${PrintingFfi._libName}.dll');
        throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
      }();

      final bindings = PrintingFfiBindings(dylib);
      final getLastError = dylib.lookup<NativeFunction<Pointer<Utf8> Function()>>('get_last_error').asFunction<Pointer<Utf8> Function()>();

      final helperReceivePort = ReceivePort();
      helperReceivePort.listen((dynamic data) {
        if (data is _DisposeRequest) {
          if (Platform.isWindows) {
            // Clean up the PDFium library before the isolate exits.
            bindings.shutdown_pdfium_library();
          }
          helperReceivePort.close();
          return;
        }
        if (data is _PrintRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8();
            final docNamePtr = data.docName.toNativeUtf8();
            final dataPtr = malloc<Uint8>(data.data.length);
            dataPtr.asTypedList(data.data.length).setAll(0, data.data);
            try {
              final options = {...?data.options};
              _remapCupsOptions(options);
              final int numOptions = options.length;
              Pointer<Pointer<Utf8>> keysPtr = nullptr;
              Pointer<Pointer<Utf8>> valuesPtr = nullptr;

              try {
                if (numOptions > 0) {
                  keysPtr = malloc<Pointer<Utf8>>(numOptions);
                  valuesPtr = malloc<Pointer<Utf8>>(numOptions);
                  int i = 0;
                  for (var entry in options.entries) {
                    keysPtr[i] = entry.key.toNativeUtf8();
                    valuesPtr[i] = entry.value.toNativeUtf8();
                    i++;
                  }
                }

                final bool result = bindings.raw_data_to_printer(
                  namePtr.cast(),
                  dataPtr,
                  data.data.length,
                  docNamePtr.cast(),
                  numOptions,
                  keysPtr.cast(),
                  valuesPtr.cast(),
                );
                if (result) {
                  sendPort.send(_PrintResponse(data.id, true));
                } else {
                  final errorMsg = getLastError().toDartString();
                  sendPort.send(_ErrorResponse(data.id, PrintingFfiException(errorMsg), StackTrace.current));
                }
              } finally {
                if (numOptions > 0) {
                  for (var i = 0; i < numOptions; i++) {
                    malloc.free(keysPtr[i]);
                    malloc.free(valuesPtr[i]);
                  }
                  malloc.free(keysPtr);
                  malloc.free(valuesPtr);
                }
              }
            } finally {
              malloc.free(namePtr);
              malloc.free(docNamePtr);
              malloc.free(dataPtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _PrintJobsRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8();
            try {
              final jobListPtr = bindings.get_print_jobs(namePtr.cast());
              final jobs = <PrintJob>[];
              if (jobListPtr != nullptr) {
                try {
                  final jobList = jobListPtr.ref;
                  for (var i = 0; i < jobList.count; i++) {
                    final jobInfo = jobList.jobs[i];
                    jobs.add(
                      PrintJob(
                        jobInfo.id,
                        jobInfo.title.cast<Utf8>().toDartString(),
                        jobInfo.status,
                        pagesPrinted: jobInfo.pages_printed,
                        totalPages: jobInfo.total_pages,
                      ),
                    );
                  }
                } finally {
                  bindings.free_job_list(jobListPtr);
                }
              }
              sendPort.send(_PrintJobsResponse(data.id, jobs));
            } finally {
              malloc.free(namePtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _PrintJobActionRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8();
            try {
              bool result = false;
              if (data.action == 'pause') {
                result = bindings.pause_print_job(namePtr.cast(), data.jobId);
              } else if (data.action == 'resume') {
                result = bindings.resume_print_job(namePtr.cast(), data.jobId);
              } else if (data.action == 'cancel') {
                result = bindings.cancel_print_job(namePtr.cast(), data.jobId);
              }
              sendPort.send(_PrintJobActionResponse(data.id, result));
            } finally {
              malloc.free(namePtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _GetCupsOptionsRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8();
            try {
              final optionListPtr = bindings.get_supported_cups_options(namePtr.cast());
              final options = <CupsOptionModel>[];
              if (optionListPtr != nullptr) {
                try {
                  final optionList = optionListPtr.ref;
                  for (var i = 0; i < optionList.count; i++) {
                    final optionInfo = optionList.options[i];
                    final supportedValues = <CupsOptionChoiceModel>[];
                    final choiceList = optionInfo.supported_values;
                    for (var j = 0; j < choiceList.count; j++) {
                      final choiceInfo = choiceList.choices[j];
                      supportedValues.add(
                        CupsOptionChoiceModel(
                          choice: choiceInfo.choice.cast<Utf8>().toDartString(),
                          text: choiceInfo.text.cast<Utf8>().toDartString(),
                        ),
                      );
                    }
                    options.add(
                      CupsOptionModel(
                        name: optionInfo.name.cast<Utf8>().toDartString(),
                        defaultValue: optionInfo.default_value.cast<Utf8>().toDartString(),
                        supportedValues: supportedValues,
                      ),
                    );
                  }
                } finally {
                  bindings.free_cups_option_list(optionListPtr);
                }
              }
              sendPort.send(_GetCupsOptionsResponse(data.id, options));
            } finally {
              malloc.free(namePtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _GetWindowsCapsRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8();
            try {
              final capsPtr = bindings.get_windows_printer_capabilities(namePtr.cast());
              if (capsPtr == nullptr) {
                sendPort.send(_GetWindowsCapsResponse(data.id, null));
              } else {
                try {
                  final caps = capsPtr.ref;
                  final paperSizes = <WindowsPaperSize>[];
                  for (var i = 0; i < caps.paper_sizes.count; i++) {
                    final size = caps.paper_sizes.papers[i];
                    paperSizes.add(
                      WindowsPaperSize(
                        id: size.id,
                        name: size.name.cast<Utf8>().toDartString(),
                        widthMillimeters: size.width_mm,
                        heightMillimeters: size.height_mm,
                      ),
                    );
                  }

                  final paperSources = <WindowsPaperSource>[];
                  for (var i = 0; i < caps.paper_sources.count; i++) {
                    final source = caps.paper_sources.sources[i];
                    paperSources.add(
                      WindowsPaperSource(
                        id: source.id,
                        name: source.name.cast<Utf8>().toDartString(),
                      ),
                    );
                  }

                  final mediaTypes = <WindowsMediaType>[];
                  for (var i = 0; i < caps.media_types.count; i++) {
                    final type = caps.media_types.types[i];
                    mediaTypes.add(
                      WindowsMediaType(
                        id: type.id,
                        name: type.name.cast<Utf8>().toDartString(),
                      ),
                    );
                  }

                  final resolutions = <WindowsResolution>[];
                  for (var i = 0; i < caps.resolutions.count; i++) {
                    final res = caps.resolutions.resolutions[i];
                    resolutions.add(WindowsResolution(xdpi: res.x_dpi, ydpi: res.y_dpi));
                  }

                  final model = WindowsPrinterCapabilitiesModel(
                    paperSizes: paperSizes,
                    paperSources: paperSources,
                    mediaTypes: mediaTypes,
                    resolutions: resolutions,
                    isColorSupported: caps.is_color_supported,
                    isMonochromeSupported: caps.is_monochrome_supported,
                    supportsLandscape: caps.supports_landscape,
                  );
                  sendPort.send(_GetWindowsCapsResponse(data.id, model));
                } finally {
                  bindings.free_windows_printer_capabilities(capsPtr);
                }
              }
            } finally {
              malloc.free(namePtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _OpenPrinterPropertiesRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8();
            try {
              final result = bindings.open_printer_properties(namePtr.cast(), data.hwnd);
              final responseResult = switch (result) {
                1 => PrinterPropertiesResult.ok,
                2 => PrinterPropertiesResult.cancel,
                _ => PrinterPropertiesResult.error,
              };
              sendPort.send(_OpenPrinterPropertiesResponse(data.id, responseResult));
            } finally {
              malloc.free(namePtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _PrintPdfRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8();
            final pathPtr = data.pdfFilePath.toNativeUtf8();
            final docNamePtr = data.docName.toNativeUtf8();
            final pageRangeValue = data.pageRange;
            final alignmentPtr = data.alignment.toNativeUtf8();
            final pageRangePtr = pageRangeValue?.toNativeUtf8() ?? nullptr;
            try {
              final options = {...?data.options};
              if (Platform.isMacOS || Platform.isLinux) {
                if (data.copies > 1) options['copies'] = data.copies.toString();
                if (pageRangeValue != null && pageRangeValue.isNotEmpty) options['page-ranges'] = pageRangeValue;
              }
              _remapCupsOptions(options);

              final int numOptions = options.length;
              Pointer<Pointer<Utf8>> keysPtr = nullptr;
              Pointer<Pointer<Utf8>> valuesPtr = nullptr;

              if (numOptions > 0) {
                keysPtr = malloc<Pointer<Utf8>>(numOptions);
                valuesPtr = malloc<Pointer<Utf8>>(numOptions);
                int i = 0;
                for (var entry in options.entries) {
                  keysPtr[i] = entry.key.toNativeUtf8();
                  valuesPtr[i] = entry.value.toNativeUtf8();
                  i++;
                }
              }

              final bool result = bindings.print_pdf(
                namePtr.cast(),
                pathPtr.cast(),
                docNamePtr.cast(),
                data.scalingMode,
                data.copies,
                pageRangePtr.cast(),
                numOptions,
                keysPtr.cast(),
                valuesPtr.cast(),
                alignmentPtr.cast(),
              );
              if (result) {
                sendPort.send(_PrintPdfResponse(data.id, true));
              } else {
                final errorMsg = getLastError().toDartString();
                sendPort.send(_ErrorResponse(data.id, PrintingFfiException(errorMsg), StackTrace.current));
              }

              if (numOptions > 0) {
                for (var i = 0; i < numOptions; i++) {
                  malloc.free(keysPtr[i]);
                  malloc.free(valuesPtr[i]);
                }
                malloc.free(keysPtr);
                malloc.free(valuesPtr);
              }
            } finally {
              malloc.free(namePtr);
              malloc.free(pathPtr);
              malloc.free(docNamePtr);
              if (pageRangePtr != nullptr) malloc.free(pageRangePtr);
              malloc.free(alignmentPtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _SubmitRawDataJobRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8();
            final docNamePtr = data.docName.toNativeUtf8();
            final dataPtr = malloc<Uint8>(data.data.length);
            dataPtr.asTypedList(data.data.length).setAll(0, data.data);
            try {
              final options = {...?data.options};
              _remapCupsOptions(options);
              final int numOptions = options.length;
              Pointer<Pointer<Utf8>> keysPtr = nullptr;
              Pointer<Pointer<Utf8>> valuesPtr = nullptr;

              try {
                if (numOptions > 0) {
                  keysPtr = malloc<Pointer<Utf8>>(numOptions);
                  valuesPtr = malloc<Pointer<Utf8>>(numOptions);
                  int i = 0;
                  for (var entry in options.entries) {
                    keysPtr[i] = entry.key.toNativeUtf8();
                    valuesPtr[i] = entry.value.toNativeUtf8();
                    i++;
                  }
                }

                final int jobId = bindings.submit_raw_data_job(
                  namePtr.cast(),
                  dataPtr,
                  data.data.length,
                  docNamePtr.cast(),
                  numOptions,
                  keysPtr.cast(),
                  valuesPtr.cast(),
                );
                if (jobId > 0) {
                  sendPort.send(_SubmitJobResponse(data.id, jobId));
                } else {
                  final errorMsg = getLastError().toDartString();
                  sendPort.send(_ErrorResponse(data.id, PrintingFfiException(errorMsg), StackTrace.current));
                }
              } finally {
                if (numOptions > 0) {
                  for (var i = 0; i < numOptions; i++) {
                    malloc.free(keysPtr[i]);
                    malloc.free(valuesPtr[i]);
                  }
                  malloc.free(keysPtr);
                  malloc.free(valuesPtr);
                }
              }
            } finally {
              malloc.free(namePtr);
              malloc.free(docNamePtr);
              malloc.free(dataPtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _SubmitPdfJobRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8();
            final pathPtr = data.pdfFilePath.toNativeUtf8();
            final docNamePtr = data.docName.toNativeUtf8();
            final pageRangeValue = data.pageRange;
            final alignmentPtr = data.alignment.toNativeUtf8();
            final pageRangePtr = pageRangeValue?.toNativeUtf8() ?? nullptr;
            try {
              final options = {...?data.options};
              if (Platform.isMacOS || Platform.isLinux) {
                if (data.copies > 1) options['copies'] = data.copies.toString();
                if (pageRangeValue != null && pageRangeValue.isNotEmpty) options['page-ranges'] = pageRangeValue;
              }
              _remapCupsOptions(options);

              final int numOptions = options.length;
              Pointer<Pointer<Utf8>> keysPtr = nullptr;
              Pointer<Pointer<Utf8>> valuesPtr = nullptr;

              if (numOptions > 0) {
                keysPtr = malloc<Pointer<Utf8>>(numOptions);
                valuesPtr = malloc<Pointer<Utf8>>(numOptions);
                int i = 0;
                for (var entry in options.entries) {
                  keysPtr[i] = entry.key.toNativeUtf8();
                  valuesPtr[i] = entry.value.toNativeUtf8();
                  i++;
                }
              }

              final int jobId = bindings.submit_pdf_job(
                namePtr.cast(),
                pathPtr.cast(),
                docNamePtr.cast(),
                data.scalingMode,
                data.copies,
                pageRangePtr.cast(),
                numOptions,
                keysPtr.cast(),
                valuesPtr.cast(),
                alignmentPtr.cast(),
              );
              if (jobId > 0) {
                sendPort.send(_SubmitJobResponse(data.id, jobId));
              } else {
                final errorMsg = getLastError().toDartString();
                sendPort.send(_ErrorResponse(data.id, PrintingFfiException(errorMsg), StackTrace.current));
              }

              if (numOptions > 0) {
                for (var i = 0; i < numOptions; i++) {
                  malloc.free(keysPtr[i]);
                  malloc.free(valuesPtr[i]);
                }
                malloc.free(keysPtr);
                malloc.free(valuesPtr);
              }
            } finally {
              malloc.free(namePtr);
              malloc.free(pathPtr);
              malloc.free(docNamePtr);
              if (pageRangePtr != nullptr) malloc.free(pageRangePtr);
              malloc.free(alignmentPtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _SubmitFileJobRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8();
            final pathPtr = data.filePath.toNativeUtf8();
            final docNamePtr = data.docName.toNativeUtf8();
            try {
              final options = {...?data.options};
              _remapCupsOptions(options);
              final int numOptions = options.length;
              Pointer<Pointer<Utf8>> keysPtr = nullptr;
              Pointer<Pointer<Utf8>> valuesPtr = nullptr;

              try {
                if (numOptions > 0) {
                  keysPtr = malloc<Pointer<Utf8>>(numOptions);
                  valuesPtr = malloc<Pointer<Utf8>>(numOptions);
                  int i = 0;
                  for (var entry in options.entries) {
                    keysPtr[i] = entry.key.toNativeUtf8();
                    valuesPtr[i] = entry.value.toNativeUtf8();
                    i++;
                  }
                }

                final int jobId = bindings.submit_file_job(
                  namePtr.cast(),
                  pathPtr.cast(),
                  docNamePtr.cast(),
                  numOptions,
                  keysPtr.cast(),
                  valuesPtr.cast(),
                );
                if (jobId > 0) {
                  sendPort.send(_SubmitJobResponse(data.id, jobId));
                } else {
                  final errorMsg = getLastError().toDartString();
                  sendPort.send(_ErrorResponse(data.id, PrintingFfiException(errorMsg), StackTrace.current));
                }
              } finally {
                if (numOptions > 0) {
                  for (var i = 0; i < numOptions; i++) {
                    malloc.free(keysPtr[i]);
                    malloc.free(valuesPtr[i]);
                  }
                  malloc.free(keysPtr);
                  malloc.free(valuesPtr);
                }
              }
            } finally {
              malloc.free(namePtr);
              malloc.free(pathPtr);
              malloc.free(docNamePtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _PrintFileWithDialogRequest) {
          try {
            final pathPtr = data.filePath.toNativeUtf8().cast<Char>();
            final docNamePtr = data.docName.toNativeUtf8().cast<Char>();
            try {
              final bool result = bindings.print_file_with_dialog(pathPtr, docNamePtr);
              if (result) {
                sendPort.send(_PrintFileWithDialogResponse(data.id, true));
              } else {
                final errorMsg = getLastError().toDartString();
                sendPort.send(_ErrorResponse(data.id, PrintingFfiException('Failed to open print dialog: $errorMsg'), StackTrace.current));
              }
            } finally {
              malloc.free(pathPtr);
              malloc.free(docNamePtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _CupsPrinterControlRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8().cast<Char>();
            final reasonPtr = data.reason?.toNativeUtf8().cast<Char>() ?? nullptr;
            final usernamePtr = data.username?.toNativeUtf8().cast<Char>() ?? nullptr;
            final passwordPtr = data.password?.toNativeUtf8().cast<Char>() ?? nullptr;
            try {
              bool result = false;
              switch (data.action) {
                case 'pause':
                  result = bindings.cups_pause_printer(namePtr, usernamePtr, passwordPtr);
                  break;
                case 'resume':
                  result = bindings.cups_resume_printer(namePtr, usernamePtr, passwordPtr);
                  break;
                case 'enable':
                  result = bindings.cups_enable_printer(namePtr, usernamePtr, passwordPtr);
                  break;
                case 'disable':
                  result = bindings.cups_disable_printer(namePtr, reasonPtr, usernamePtr, passwordPtr);
                  break;
                case 'accept':
                  result = bindings.cups_accept_jobs(namePtr, usernamePtr, passwordPtr);
                  break;
                case 'reject':
                  result = bindings.cups_reject_jobs(namePtr, reasonPtr, usernamePtr, passwordPtr);
                  break;
              }
              if (result) {
                sendPort.send(_CupsPrinterControlResponse(data.id, true));
              } else {
                final errorMsg = getLastError().toDartString();
                sendPort.send(_ErrorResponse(data.id, PrintingFfiException(errorMsg), StackTrace.current));
              }
            } finally {
              malloc.free(namePtr);
              if (reasonPtr != nullptr) malloc.free(reasonPtr);
              if (usernamePtr != nullptr) malloc.free(usernamePtr);
              if (passwordPtr != nullptr) malloc.free(passwordPtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _CupsJobControlRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8().cast<Char>();
            final destPrinterPtr = data.destPrinter?.toNativeUtf8().cast<Char>() ?? nullptr;
            final usernamePtr = data.username?.toNativeUtf8().cast<Char>() ?? nullptr;
            final passwordPtr = data.password?.toNativeUtf8().cast<Char>() ?? nullptr;
            try {
              bool result = false;
              switch (data.action) {
                case 'hold':
                  result = bindings.cups_hold_job(namePtr, data.jobId, usernamePtr, passwordPtr);
                  break;
                case 'release':
                  result = bindings.cups_release_job(namePtr, data.jobId, usernamePtr, passwordPtr);
                  break;
                case 'move':
                  result = bindings.cups_move_job(namePtr, data.jobId, destPrinterPtr, usernamePtr, passwordPtr);
                  break;
                case 'priority':
                  result = bindings.cups_set_job_priority(namePtr, data.jobId, data.priority, usernamePtr, passwordPtr);
                  break;
              }
              if (result) {
                sendPort.send(_CupsJobControlResponse(data.id, true));
              } else {
                final errorMsg = getLastError().toDartString();
                // Some CUPS servers do not allow changing job-priority for active jobs.
                // Treat this as an unsupported operation rather than a hard exception.
                final isUnsupportedPriorityChange =
                    data.action == 'priority' && errorMsg.contains('client-error-not-possible');
                if (isUnsupportedPriorityChange) {
                  sendPort.send(_CupsJobControlResponse(data.id, false));
                } else {
                  sendPort.send(_ErrorResponse(data.id, PrintingFfiException(errorMsg), StackTrace.current));
                }
              }
            } finally {
              malloc.free(namePtr);
              if (destPrinterPtr != nullptr) malloc.free(destPrinterPtr);
              if (usernamePtr != nullptr) malloc.free(usernamePtr);
              if (passwordPtr != nullptr) malloc.free(passwordPtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _CupsAttributeRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8().cast<Char>();
            final usernamePtr = data.username?.toNativeUtf8().cast<Char>() ?? nullptr;
            final passwordPtr = data.password?.toNativeUtf8().cast<Char>() ?? nullptr;

            try {
              if (data.attributeNames.length == 1) {
                // Single attribute request
                final attrNamePtr = data.attributeNames[0].toNativeUtf8().cast<Char>();
                try {
                  final attrPtr = bindings.cups_get_printer_attribute(namePtr, attrNamePtr, usernamePtr, passwordPtr);
                  if (attrPtr == nullptr) {
                    final errorMsg = getLastError().toDartString();
                    sendPort.send(_ErrorResponse(data.id, PrintingFfiException(errorMsg), StackTrace.current));
                  } else {
                    try {
                      final attr = attrPtr.ref;
                      final name = attr.attribute_name.cast<Utf8>().toDartString();
                      final valueCount = attr.value_count;

                      String? singleValue;
                      List<String>? arrayValues;

                      if (valueCount == 1 && attr.attribute_value != nullptr) {
                        singleValue = attr.attribute_value.cast<Utf8>().toDartString();
                      } else if (valueCount > 1 && attr.array_values != nullptr) {
                        arrayValues = [];
                        for (int i = 0; i < valueCount; i++) {
                          final valuePtr = attr.array_values[i];
                          if (valuePtr != nullptr) {
                            arrayValues.add(valuePtr.cast<Utf8>().toDartString());
                          }
                        }
                      }

                      final printerAttr = PrinterAttribute(
                        name: name,
                        value: singleValue,
                        values: arrayValues,
                        valueCount: valueCount,
                      );
                      sendPort.send(_CupsAttributeResponse(data.id, printerAttr));
                    } finally {
                      bindings.free_printer_attribute(attrPtr);
                    }
                  }
                } finally {
                  malloc.free(attrNamePtr);
                }
              } else {
                // Multiple attributes request
                final int numAttributes = data.attributeNames.length;
                final attrNamesPtr = malloc<Pointer<Char>>(numAttributes);
                try {
                  for (int i = 0; i < numAttributes; i++) {
                    attrNamesPtr[i] = data.attributeNames[i].toNativeUtf8().cast<Char>();
                  }

                  final attrListPtr = bindings.cups_get_printer_attributes(namePtr, attrNamesPtr.cast(), numAttributes, usernamePtr, passwordPtr);

                  if (attrListPtr == nullptr) {
                    final errorMsg = getLastError().toDartString();
                    sendPort.send(_ErrorResponse(data.id, PrintingFfiException(errorMsg), StackTrace.current));
                  } else {
                    try {
                      final attrList = attrListPtr.ref;
                      final attributes = <PrinterAttribute>[];

                      for (int i = 0; i < attrList.count; i++) {
                        final attr = attrList.attributes[i];
                        final name = attr.attribute_name.cast<Utf8>().toDartString();
                        final valueCount = attr.value_count;

                        String? singleValue;
                        List<String>? arrayValues;

                        if (valueCount == 1 && attr.attribute_value != nullptr) {
                          singleValue = attr.attribute_value.cast<Utf8>().toDartString();
                        } else if (valueCount > 1 && attr.array_values != nullptr) {
                          arrayValues = [];
                          for (int j = 0; j < valueCount; j++) {
                            final valuePtr = attr.array_values[j];
                            if (valuePtr != nullptr) {
                              arrayValues.add(valuePtr.cast<Utf8>().toDartString());
                            }
                          }
                        }

                        attributes.add(
                          PrinterAttribute(
                            name: name,
                            value: singleValue,
                            values: arrayValues,
                            valueCount: valueCount,
                          ),
                        );
                      }

                      sendPort.send(_CupsAttributesResponse(data.id, attributes));
                    } finally {
                      bindings.free_printer_attribute_list(attrListPtr);
                    }
                  }
                } finally {
                  for (int i = 0; i < numAttributes; i++) {
                    malloc.free(attrNamesPtr[i]);
                  }
                  malloc.free(attrNamesPtr);
                }
              }
            } finally {
              malloc.free(namePtr);
              if (usernamePtr != nullptr) malloc.free(usernamePtr);
              if (passwordPtr != nullptr) malloc.free(passwordPtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        } else if (data is _CupsAllAttributesRequest) {
          try {
            final namePtr = data.printerName.toNativeUtf8().cast<Char>();
            final usernamePtr = data.username?.toNativeUtf8().cast<Char>() ?? nullptr;
            final passwordPtr = data.password?.toNativeUtf8().cast<Char>() ?? nullptr;

            try {
              final attrListPtr = bindings.cups_get_all_printer_attributes(namePtr, usernamePtr, passwordPtr);

              if (attrListPtr == nullptr) {
                final errorMsg = getLastError().toDartString();
                sendPort.send(_ErrorResponse(data.id, PrintingFfiException(errorMsg), StackTrace.current));
              } else {
                try {
                  final attrList = attrListPtr.ref;
                  final attributes = <PrinterAttribute>[];

                  for (int i = 0; i < attrList.count; i++) {
                    final attr = attrList.attributes[i];
                    final name = attr.attribute_name.cast<Utf8>().toDartString();
                    final valueCount = attr.value_count;

                    String? singleValue;
                    List<String>? arrayValues;

                    if (valueCount == 1 && attr.attribute_value != nullptr) {
                      singleValue = attr.attribute_value.cast<Utf8>().toDartString();
                    } else if (valueCount > 1 && attr.array_values != nullptr) {
                      arrayValues = [];
                      for (int j = 0; j < valueCount; j++) {
                        final valuePtr = attr.array_values[j];
                        if (valuePtr != nullptr) {
                          arrayValues.add(valuePtr.cast<Utf8>().toDartString());
                        }
                      }
                    }

                    attributes.add(
                      PrinterAttribute(
                        name: name,
                        value: singleValue,
                        values: arrayValues,
                        valueCount: valueCount,
                      ),
                    );
                  }

                  sendPort.send(_CupsAttributesResponse(data.id, attributes));
                } finally {
                  bindings.free_printer_attribute_list(attrListPtr);
                }
              }
            } finally {
              malloc.free(namePtr);
              if (usernamePtr != nullptr) malloc.free(usernamePtr);
              if (passwordPtr != nullptr) malloc.free(passwordPtr);
            }
          } catch (e, s) {
            sendPort.send(_ErrorResponse(data.id, e, s));
          }
        }
      });

      sendPort.send(helperReceivePort.sendPort);
    },
    (error, stack) {
      sendPort.send([error.toString(), stack.toString()]);
    },
  );
}

/// These classes are not part of the public API but need to be accessible
/// by the test file for mocking isolate communication.
@visibleForTesting
class PrintJobsRequest extends _PrintJobsRequest {
  const PrintJobsRequest(super.id, super.printerName);
}

@visibleForTesting
class PrintJobsResponse extends _PrintJobsResponse {
  const PrintJobsResponse(super.id, super.jobs);
}

@visibleForTesting
class PrintPdfRequest extends _PrintPdfRequest {
  const PrintPdfRequest(
    super.id,
    super.printerName,
    super.pdfFilePath,
    super.docName,
    super.options,
    super.scalingMode,
    super.copies,
    super.pageRange,
    super.alignment,
  );
}

@visibleForTesting
class PrintPdfResponse extends _PrintPdfResponse {
  const PrintPdfResponse(super.id, super.result);
}

@visibleForTesting
class PrintRequest extends _PrintRequest {
  const PrintRequest(super.id, super.printerName, super.data, super.docName, super.options);
}

@visibleForTesting
class PrintResponse extends _PrintResponse {
  const PrintResponse(super.id, super.result);
}

@visibleForTesting
class ErrorResponse extends _ErrorResponse {
  ErrorResponse(super.id, super.error, [super.stackTrace]);
}

@visibleForTesting
class GetCupsOptionsRequest extends _GetCupsOptionsRequest {
  const GetCupsOptionsRequest(super.id, super.printerName);
}

@visibleForTesting
class GetWindowsCapsRequest extends _GetWindowsCapsRequest {
  const GetWindowsCapsRequest(super.id, super.printerName);
}

@visibleForTesting
class OpenPrinterPropertiesRequest extends _OpenPrinterPropertiesRequest {
  const OpenPrinterPropertiesRequest(super.id, super.printerName, super.hwnd);
}

@visibleForTesting
class PrintJobActionRequest extends _PrintJobActionRequest {
  const PrintJobActionRequest(super.id, super.printerName, super.jobId, super.action);
}

@visibleForTesting
class PrintJobActionResponse extends _PrintJobActionResponse {
  const PrintJobActionResponse(super.id, super.result);
}

@visibleForTesting
class SubmitRawDataJobRequest extends _SubmitRawDataJobRequest {
  const SubmitRawDataJobRequest(super.id, super.printerName, super.data, super.docName, super.options);
}

@visibleForTesting
class SubmitPdfJobRequest extends _SubmitPdfJobRequest {
  const SubmitPdfJobRequest(super.id, super.printerName, super.pdfFilePath, super.docName, super.options, super.scalingMode, super.copies, super.pageRange, super.alignment);
}

@visibleForTesting
class SubmitFileJobRequest extends _SubmitFileJobRequest {
  const SubmitFileJobRequest(super.id, super.printerName, super.filePath, super.docName, super.options);
}

@visibleForTesting
class SubmitJobResponse extends _SubmitJobResponse {
  const SubmitJobResponse(super.id, super.jobId);
}

@visibleForTesting
class DisposeRequest extends _DisposeRequest {
  const DisposeRequest();
}

@visibleForTesting
class GetWindowsCapsResponse extends _GetWindowsCapsResponse {
  const GetWindowsCapsResponse(super.id, super.capabilities);
}

@visibleForTesting
class GetCupsOptionsResponse extends _GetCupsOptionsResponse {
  const GetCupsOptionsResponse(super.id, super.options);
}

@visibleForTesting
class OpenPrinterPropertiesResponse extends _OpenPrinterPropertiesResponse {
  const OpenPrinterPropertiesResponse(super.id, super.result);
}

@visibleForTesting
class PrintFileWithDialogRequest extends _PrintFileWithDialogRequest {
  const PrintFileWithDialogRequest(super.id, super.filePath, super.docName);
}

@visibleForTesting
class PrintFileWithDialogResponse extends _PrintFileWithDialogResponse {
  const PrintFileWithDialogResponse(super.id, super.result);
}

@visibleForTesting
class CupsPrinterControlRequest extends _CupsPrinterControlRequest {
  const CupsPrinterControlRequest(super.id, super.printerName, super.action, super.reason, super.username, super.password);
}

@visibleForTesting
class CupsPrinterControlResponse extends _CupsPrinterControlResponse {
  const CupsPrinterControlResponse(super.id, super.result);
}

@visibleForTesting
class CupsJobControlRequest extends _CupsJobControlRequest {
  const CupsJobControlRequest(super.id, super.printerName, super.jobId, super.action, super.destPrinter, super.priority, super.username, super.password);
}

@visibleForTesting
class CupsJobControlResponse extends _CupsJobControlResponse {
  const CupsJobControlResponse(super.id, super.result);
}

@visibleForTesting
class CupsAttributeRequest extends _CupsAttributeRequest {
  const CupsAttributeRequest(super.id, super.printerName, super.attributeNames, super.username, super.password);
}

@visibleForTesting
class CupsAllAttributesRequest extends _CupsAllAttributesRequest {
  const CupsAllAttributesRequest(super.id, super.printerName, super.username, super.password);
}

@visibleForTesting
class CupsAttributeResponse extends _CupsAttributeResponse {
  const CupsAttributeResponse(super.id, super.attribute);
}

@visibleForTesting
class CupsAttributesResponse extends _CupsAttributesResponse {
  const CupsAttributesResponse(super.id, super.attributes);
}
