## 0.2.0

* ✨ **FEAT(windows)**: Windows feature parity. The operations that were previously CUPS-only (macOS/Linux/Android) now work on Windows too via the native spooler + WIC + GDI:
  * **Image printing** — `printImage` / `printFile` decode a JPG/PNG/BMP/GIF/TIFF with the Windows Imaging Component and print it fit-to-page, centered (transparent PNGs are composited onto white). PDFs handed to the same path continue to route through PDFium.
  * **Printer control** — `cupsPause/Resume/Enable/DisablePrinter` map to `SetPrinter(PRINTER_CONTROL_PAUSE/RESUME)` (enable≡resume, disable≡pause on Windows).
  * **Job control** — `cupsHoldJob` / `cupsReleaseJob` (pause/resume the job) and `cupsSetJobPriority` (1–100, mapped to the Windows 1–99 range).
  * **Attribute queries / print counts** — `cupsGetPrinterAttribute(s)` and `cupsGetAllPrinterAttributes` return a curated subset mapped from `PRINTER_INFO_2` (`queued-job-count`, `printer-state`, `printer-info`, `printer-location`, `printer-make-and-model`, `printer-is-accepting-jobs`, `device-uri`).
  * **Per-job page counts** — `PrintJob.pagesPrinted` / `PrintJob.totalPages`, read from the spooler on Windows (`-1` = unknown; also `-1` on CUPS, which avoids an N+1 IPP query).
* ⚠️ **FEAT(windows)**: `cupsAcceptJobs` / `cupsRejectJobs` are best-effort on Windows — they toggle the printer's "work offline" state. New jobs still queue but do not print; Windows cannot truly refuse a submission the way CUPS reject does.
* 🚧 **Not supported on Windows**: `cupsMoveJob` (the spooler cannot move a queued job between printers) and `printFileAndStreamStatus` (Windows renders synchronously; poll `listPrintJobs` instead). Both throw a clear error.
* 🐛 **FIX(windows)**: `printPdf` / `printFile` now honor a requested `priority` on Windows (applied to the spooler job) instead of silently dropping it. `cancelPrintJob` now uses `JOB_CONTROL_DELETE` (the documented call) instead of the deprecated `JOB_CONTROL_CANCEL`.
* ♻️ **REFACTOR**: Extracted shared winspool/GDI helpers (`_win_open_printer`, `_win_set_job_command`, `_win_set_job_priority`, `compute_dest_rect`, `parse_print_alignment`) so job control and the PDF/image print paths no longer duplicate boilerplate.
* 🧪 **TEST**: Added mocked tests for the relaxed Windows guards, priority forwarding, `cupsMoveJob`/`printFileAndStreamStatus` staying unsupported, and a regression test for the `PrintJob` page-count fields. Added a `windows-latest` GitHub Actions job that compiles the native Windows target for the first time, plus a manual smoke-test checklist (`docs/windows-smoke-test.md`).

## 0.1.0

* ✨ **FEAT(android)**: Android is now a supported platform. The plugin bundles a private CUPS server (for network/office IPP printing) and DNP/Citizen dye-sub USB auto-detect, cross-compiled from source (CUPS + Gutenprint + libusb) during the app's Gradle build — no prebuilt binaries are shipped. 📱🖨️
* ✨ **FEAT(android)**: One-call boot — `await PrintingFfi.instance.initializeAndroidCups()` starts the bundled cupsd and DNP USB auto-detect (no-op off Android). Observe progress via `cupsStatus` and detected printers via `dnpPrinters`.
* ✨ **FEAT(android)**: In-app CUPS settings without building any widgets — `openCupsSettings(context)` (admin page) and `openCupsPrinterSettings(context, printerName: ...)` (per-printer page), backed by the bundled `CupsWebView`.
* ✨ **FEAT**: Exposed `cupsServerPort` plus `cupsBaseUrl` / `cupsSettingsUrl` / `cupsPrinterSettingsUrl(name)` so apps can reach the in-app cupsd without tracking the port themselves.
* ✨ **FEAT**: Added `cupsGetAllPrinterAttributes(printerName)` (macOS/Linux/Android) to discover **every** attribute a printer exposes without knowing the names up front — it issues an IPP Get-Printer-Attributes request with `requested-attributes = all` and returns each printer-group attribute as a `PrinterAttribute` (name + value(s), including range/resolution formatting). 🔎
* ✨ **FEAT(android)**: The CUPS IPP read/control operations now work on Android against the bundled cupsd — reading printer attributes and supported options (`cupsGetPrinterAttribute`/`cupsGetPrinterAttributes`/`getSupportedCupsOptions`), job control (hold/release/move/priority), and printer enable/disable/accept/reject. They previously threw "only supported on macOS and Linux". The example gains "Open CUPS settings" and "Read printer attributes" buttons for testing.
* 🐛 **FIX(android)**: The in-app CUPS settings pages (`openCupsSettings` / `openCupsPrinterSettings`) now open on older Android devices instead of failing with `net::ERR_CLEARTEXT_NOT_PERMITTED`. The plugin ships a network security config that permits cleartext to loopback only (`127.0.0.1` / `localhost`, where the bundled cupsd serves its web UI); older Android System WebView builds don't exempt loopback from the cleartext policy the way newer ones do.
* 🐛 **FIX(android)**: DNP printer settings (default media size, quality, etc.) now persist across USB unplug/replug and app restarts — the CUPS queue is kept and reused instead of being deleted and recreated from a fresh PPD.
* 🐛 **FIX(android)**: The CUPS web admin UI now renders in the device locale (a German phone shows German, English fallback) instead of always Russian, and its CSS/images load correctly (docroot files are made world-readable so cupsd will serve them).
* ♻️ **REFACTOR(android)**: All Android glue — the from-source native build, the Kotlin `FlutterPlugin` (USB permission, fd handoff, foreground service, asset extraction), the USB device filter, and the Dart orchestration — now lives in the plugin. A consuming desktop app adds Android with build config, one manifest filter, and one Dart call.
* 🧪 **TEST**: Added mock tests for the CUPS web-UI URL helpers (null-guard + printer-name percent-encoding).
* 📝 **DOCS**: Added `docs/android-migration-guide.md` (a gphoto-style guide for adding the Android target) and `docs/android-plugin-reusability-plan.md` (the locked execution plan, reviewed via `/plan-eng-review` + codex).


## 0.0.12

* ✨ **FEAT**: Added `printFileWithDialog` to open the native OS print dialog for any file type, providing a familiar user experience.
* ✨ **FEAT**: Improved error handling for `printFileWithDialog` on macOS/Linux by capturing and returning detailed error messages from the `lpr` command (e.g., "default destination does not exist").
* **REFACTOR**: Renamed `printPdfWithDialog` to `printFileWithDialog` for clarity and to reflect its broader capability.
* **TEST**: Added mock tests for the new `printFileWithDialog` functionality.
* **DOCS**: Updated `README.md` and the example app to demonstrate the new system print dialog feature.


## 0.0.10

* ✨ **FEAT**: Added support for printing multiple copies of PDF documents on Windows. The printer driver now handles copy collation, improving performance and reliability. 🔢
* ✨ **FEAT**: Exposed `initPdfium()` for explicit PDFium library initialization on Windows. This improves compatibility with other PDF plugins (like `pdfrx`) and ensures thread-safe, idempotent initialization.
* ✨ **FEAT**: Added a `PdfRotation` option for PDF printing on Windows, allowing users to override the document's default rotation (e.g., `auto`, `none`, `rotate90`).
* ✨ **FEAT**: Added a comprehensive suite of mock tests using `mocktail` to validate class behavior, including synchronous and asynchronous methods, without requiring a native environment.
* **REFACTOR**: Simplified the Windows PDF printing implementation by removing the manual copy loop. The native `dmCopies` setting in the `DEVMODE` structure is now used, delegating the work to the printer driver for better efficiency. ♻️
* **REFACTOR**: Refactored the `PrintingFfi` class to support dependency injection, significantly improving testability. This includes a new `PrintingFfi.forTest` constructor for injecting mock bindings. 🧪
* ✨ **FEAT(example)**: The example app now includes fields to specify the number of copies and select page rotation for PDF printing.
* ✨ **FEAT(example)**: Enhanced the print job status tracking dialog with more detailed feedback, clearer status transitions, and a synthetic "completed" status for finished jobs.
* **FIX**: Corrected the dynamic library (`.dylib`) loading logic on macOS to work reliably in both test and application environments. 🐛
* **FIX**: Implemented `shutdown_pdfium_library()` to ensure proper cleanup of PDFium resources on Windows, preventing potential resource leaks. 🛠️
* **FIX**: Ensured the `PrintingFfi` private constructor correctly initializes native bindings, preventing potential runtime errors. 🛠️
* **BUILD**: Removed unnecessary `android` and `ios` platform declarations from `pubspec.yaml`.
* **BUILD**: Added `mocktail` as a `dev_dependency` to support the new testing infrastructure.
* **DOCS**: Updated `README.md` with detailed instructions for the new explicit PDFium initialization.

## 0.0.9

* ✨ **FEAT**: Added full support for duplex (double-sided) printing on Windows, macOS, and Linux. Users can now select single-sided, duplex long-edge (book-style), or duplex short-edge (notepad-style) printing. 📖
* ✨ **FEAT(example)**: Refined the example app with `shadcn_ui` components, including a dedicated platform settings card and responsive layouts for a better user experience. 🎨
* **REFACTOR**: Translated generic print options (like `orientation`, `color-mode`, `duplex`) into platform-specific CUPS options (`orientation-requested`, `print-color-mode`, `sides`) within the Dart isolate, simplifying the native C code and improving cross-platform consistency. ♻️
* **DOCS**: Updated `README.md` to include documentation for the new duplex printing feature. 📝

## 0.0.8

* ✨ **FEAT(example)**: Implemented the entire example app UI using the `shadcn_ui` package for a modern, clean, and responsive user experience.
* ✨ **FEAT(example)**: Enhanced raw data printing with a data type selector (ZPL, ESC/POS, Custom) and provided corresponding example data.
* **FIX**: Corrected conditional compilation for error handling, resolving an issue where `set_last_error` was not defined for all platforms, leading to compilation errors on non-Windows targets. 🐛
* **FIX**: Resolved an 'undefined' compiler error for the `_scale_to_fit` helper function by ensuring it is defined on all platforms. 🛠️

## 0.0.7

* **FEAT**: Added support for collating copies on Windows. 📚
* **FEAT**: Enhanced error handling, providing detailed native error messages and a real-time logging callback for easier debugging. 🕵️‍♂️
* **FEAT**: Enhanced PDF printing on Windows with `Fit to Paper` and `Custom` scaling options. 📄✨
* **FIX**: Resolved PDF rendering issues on Windows, including color distortion and page stretching on high-DPI displays, by using a 32-bit BGRA bitmap format for improved compatibility. 🐛🎨
* **FIX*a*: Improved stability by addressing a memory leak and enhancing resource cleanup during print failures on Windows.
* **REFACTOR**: Improved Windows print driver compatibility by streamlining device setting modifications, reducing the risk of conflicts. ♻️
* **EXAMPLE**: Added PDF file selection and custom scale validation to the example app. 🎨
* **DOCS**: Updated documentation for new features and error handling. 📝

## 0.0.6

* **FEAT**: Added support for opening the native Windows printer properties dialog via `openPrinterProperties`. 🎛️
* **FEAT**: Added support for setting Paper Size, Paper Source, and Orientation on Windows for both PDF and raw data printing. 📄⚙️
* **FEAT**: Added support for passing generic CUPS options to raw data print jobs on macOS and Linux. 🐧🍎
* **REFACTOR**: Refactored the Dart FFI layer to use generated bindings directly, removing manual lookups and improving maintainability. ✨
* **EXAMPLE**: Updated the example app with UI controls for new Windows printing options and a button to show printer properties. 🎨

## 0.0.5

* **FEAT**: Added support for `copies` and `pageRange` when printing PDFs on Windows and CUPS-based systems. 🔢
* **FEAT**: Refactored the `pageRange` parameter to use a type-safe `PageRange` class, improving API clarity and preventing invalid format errors. 🔒
* **DOCS**: Updated documentation for new printing parameters and the `PageRange` class. 📝
* **EXAMPLE**: Added UI controls for setting the number of copies and page range in the example app. 🎨

## 0.0.4

* **DOCS**: Updated `pubspec.yaml` with repository, homepage, issue tracker links,license and relevant topics for better discoverability on pub.dev.

## 0.0.3

* **FEAT**: Added full support for Linux via CUPS. 🚀
* **FEAT**: Added job status tracking streams for PDF and raw data printing. 📊
* **FEAT**: Added `getWindowsPrinterCapabilities` to fetch supported paper sizes and resolutions on Windows. 🖨️
* ✨ **FEAT**: Improved error handling and Windows printer capabilities:
    *   Enhanced isolate communication with robust error responses.
    *   Switched to Unicode (W-series) Windows APIs for full international character support in printer and document names.
    *   Improved memory management and error handling in `get_windows_printer_capabilities`.
    *   Added `NULL` checks for pointers returned by Windows API functions to prevent crashes.
    *   Improved logging for easier debugging.
* **DOCS**: Updated README with Linux setup instructions and new features. 📝

## 0.0.2

* **FIX**: Resolved a crash on Windows when printing by correctly quoting the printer name for the shell API.
* **FIX**: Updated the Windows build script to use the correct URL and latest version of the `pdfium` library, resolving download errors.
* **FEAT**: Added `PdfPrintScaling` option to the `printPdf` function on Windows to control scaling ('Fit to Page' vs 'Actual Size').
* **FIX**: Replaced unreliable `ShellExecute` PDF printing on Windows with a robust, self-contained solution using the `pdfium` library for rendering. This removes the dependency on external PDF applications.
* **FIX**: Correctly specified "raw" printing option for CUPS on macOS/Linux to ensure raw data is sent to the printer without modification.
* **FEAT**: Added extensive logging to the native C code, enabled in debug builds, to simplify troubleshooting.
* **FEAT**: Added `printPdf` function to print PDF files directly to a specified printer.

## 0.0.1

* **Initial Release**
* Added support for listing printers on macOS (via CUPS) and Windows (via winspool), including offline printers.
* Implemented raw data printing for sending formats like ZPL and ESC/POS directly to printers.
* Included print job management features: list, pause, resume, and cancel jobs.
* Utilizes FFI for direct native API communication, ensuring high performance.
