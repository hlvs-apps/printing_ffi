// --- Header Includes ---
// The order of includes is important, especially on Windows.

// 2. Standard C library headers
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>
#include <stdarg.h>
#include <limits.h>

// 3. Platform-specific printing and system headers
#ifdef _WIN32
    #include <winspool.h>
    #include <shellapi.h>
    #include <synchapi.h>
    #include <wingdi.h>
    #include <winuser.h>
#endif

// 4. Local project header (which includes windows.h on Windows)
#include "printing_ffi.h"

#ifdef _WIN32
    #define strdup _strdup
#else // macOS, Linux, Android (arm64-v8a with bundled static CUPS)
    #include <cups/cups.h>
    #include <cups/ppd.h>
    // POSIX bits used by the portable CUPS admin helpers (add_cups_printer's
    // PPD-file upload path needs access()/stat() to tell a PPD file from a bare
    // model name). Kept out of the __ANDROID__-only block below so macOS/Linux
    // builds get them too.
    #include <unistd.h>
    #include <sys/stat.h>
#endif

// Android-specific headers for the bundled cupsd launcher (start/stop server).
#ifdef __ANDROID__
    #include <sys/types.h>
    #include <sys/stat.h>
    #include <sys/socket.h>
    #include <sys/wait.h>
    #include <netinet/in.h>
    #include <arpa/inet.h>
    #include <fcntl.h>
    #include <signal.h>
    #include <errno.h>
    #include <android/log.h>
    #undef LOG
    #define ANDROID_LOG_TAG "PrintingFfiCups"
    #define LOG(...) __android_log_print(ANDROID_LOG_INFO, ANDROID_LOG_TAG, __VA_ARGS__)
#endif

// 5. PDFium headers (only for Windows implementation)
#ifdef _WIN32
// Include the main Pdfium header. This is located by CMake.
#include "fpdfview.h"
#include "fpdf_edit.h"

// --- PDFium Dynamic Loading ---
// Define function pointer types for all used PDFium functions.
typedef void (*FPDF_InitLibraryWithConfig_t)(const FPDF_LIBRARY_CONFIG *config);
typedef FPDF_DOCUMENT (*FPDF_LoadDocument_t)(FPDF_STRING file_path, FPDF_BYTESTRING password);
typedef unsigned long (*FPDF_GetLastError_t)(void);
typedef void (*FPDF_CloseDocument_t)(FPDF_DOCUMENT document);
typedef int (*FPDF_GetPageCount_t)(FPDF_DOCUMENT document);
typedef FPDF_PAGE (*FPDF_LoadPage_t)(FPDF_DOCUMENT document, int page_index);
typedef float (*FPDF_GetPageWidthF_t)(FPDF_PAGE page);
typedef float (*FPDF_GetPageHeightF_t)(FPDF_PAGE page);
typedef int (*FPDFPage_GetRotation_t)(FPDF_PAGE page);
typedef void (*FPDF_ClosePage_t)(FPDF_PAGE page);
typedef void (*FPDF_DestroyLibrary_t)(void);
// Type for direct rendering to a device context.
typedef void (*FPDF_RenderPage_t)(HDC dc, FPDF_PAGE page, int start_x, int start_y, int size_x, int size_y, int rotate, int flags);

// Struct to hold all our dynamically loaded PDFium function pointers.
static struct
{
    HMODULE module;
    FPDF_InitLibraryWithConfig_t FPDF_InitLibraryWithConfig;
    FPDF_LoadDocument_t FPDF_LoadDocument;
    FPDF_GetLastError_t FPDF_GetLastError;
    FPDF_CloseDocument_t FPDF_CloseDocument;
    FPDF_GetPageCount_t FPDF_GetPageCount;
    FPDF_LoadPage_t FPDF_LoadPage;
    FPDF_GetPageWidthF_t FPDF_GetPageWidthF;
    FPDF_GetPageHeightF_t FPDF_GetPageHeightF;
    FPDFPage_GetRotation_t FPDFPage_GetRotation;
    FPDF_ClosePage_t FPDF_ClosePage;
    FPDF_RenderPage_t FPDF_RenderPage;
    FPDF_DestroyLibrary_t FPDF_DestroyLibrary;
} g_pdfium = {0};

// Thread-safe initialization control for PDFium
static INIT_ONCE g_pdfium_init_once = INIT_ONCE_STATIC_INIT;
static bool g_pdfium_init_succeeded = false;
#endif

#ifndef LOG
#define LOG(...)
#endif

// --- Last Error Handling ---

// Use thread-local storage for the last error message to ensure thread safety.
#ifdef _WIN32
__declspec(thread) static char *g_last_error_message = NULL;
#else // macOS, Linux
static __thread char *g_last_error_message = NULL;
#endif

// Internal helper to set the last error message for the current thread.
static void set_last_error(const char *format, ...)
{
    // Free the previous error message if it exists
    if (g_last_error_message)
    {
        free(g_last_error_message);
        g_last_error_message = NULL;
    }

    va_list args;
    va_start(args, format);

    // Determine the required buffer size
    va_list args_copy;
    va_copy(args_copy, args);
    int size = vsnprintf(NULL, 0, format, args_copy);
    va_end(args_copy);

    if (size >= 0)
    {
        g_last_error_message = (char *)malloc(size + 1);
        if (g_last_error_message)
            vsnprintf(g_last_error_message, size + 1, format, args);
    }
    va_end(args);
}

#ifdef _WIN32
// This is the function that will be called only once to initialize PDFium.
static BOOL CALLBACK InitPdfiumCallback(PINIT_ONCE InitOnce, PVOID Parameter, PVOID *Context)
{
    // Attempt to load the isolated DLL first, then fall back to the standard name.
    const char *pdfium_names[] = {"printing_ffi_pdfium.dll", "pdfium.dll", NULL};
    for (int i = 0; pdfium_names[i] != NULL; ++i)
    {
        g_pdfium.module = LoadLibraryA(pdfium_names[i]);
        if (g_pdfium.module)
        {
            LOG("Successfully loaded PDFium library as '%s'", pdfium_names[i]);
            break;
        }
    }

    if (!g_pdfium.module)
    {
        set_last_error("Failed to load pdfium.dll. Make sure it is present alongside the application executable.");
        LOG("Failed to load any of the PDFium DLL candidates.");
        g_pdfium_init_succeeded = false;
        return TRUE; // The one-time initialization itself completed, even if the logic failed.
    }

#define LOAD_PDFIUM_FUNC(name)                                                \
    g_pdfium.name = (name##_t)GetProcAddress(g_pdfium.module, #name);         \
    if (!g_pdfium.name)                                                       \
    {                                                                         \
        set_last_error("Failed to find function '%s' in PDFium DLL.", #name); \
        LOG("Failed to find function '%s' in PDFium DLL.", #name);            \
        FreeLibrary(g_pdfium.module);                                         \
        g_pdfium.module = NULL;                                               \
        g_pdfium_init_succeeded = false;                                      \
        return TRUE;                                                          \
    }

    // Load all required functions.
    LOAD_PDFIUM_FUNC(FPDF_InitLibraryWithConfig);
    LOAD_PDFIUM_FUNC(FPDF_LoadDocument);
    LOAD_PDFIUM_FUNC(FPDF_GetLastError);
    LOAD_PDFIUM_FUNC(FPDF_CloseDocument);
    LOAD_PDFIUM_FUNC(FPDF_GetPageCount);
    LOAD_PDFIUM_FUNC(FPDF_LoadPage);
    LOAD_PDFIUM_FUNC(FPDF_GetPageWidthF);
    LOAD_PDFIUM_FUNC(FPDF_GetPageHeightF);
    LOAD_PDFIUM_FUNC(FPDFPage_GetRotation);
    LOAD_PDFIUM_FUNC(FPDF_ClosePage);
    LOAD_PDFIUM_FUNC(FPDF_RenderPage);
    LOAD_PDFIUM_FUNC(FPDF_DestroyLibrary);

#undef LOAD_PDFIUM_FUNC

    // Now initialize the library
    FPDF_LIBRARY_CONFIG config;
    memset(&config, 0, sizeof(config));
    config.version = 2;
    g_pdfium.FPDF_InitLibraryWithConfig(&config);
    LOG("PDFium library initialized successfully.");
    g_pdfium_init_succeeded = true;
    return TRUE;
}

// Loads and initializes the PDFium DLL. This function is thread-safe and idempotent.
// Returns true on success, false on failure.
static bool ensure_pdfium_initialized()
{
    if (!InitOnceExecuteOnce(&g_pdfium_init_once, InitPdfiumCallback, NULL, NULL))
    {
        // This means the InitOnceExecuteOnce call itself failed, which is a system-level error.
        set_last_error("Failed to execute one-time PDFium initialization (InitOnceExecuteOnce failed).");
        return false;
    }
    // g_pdfium_init_succeeded is set inside the callback.
    if (!g_pdfium_init_succeeded)
    {
        // If the error message is not already set by the callback, set a generic one.
        if (g_last_error_message == NULL || strlen(g_last_error_message) == 0)
        {
            set_last_error("PDFium initialization failed for an unknown reason.");
        }
    }
    return g_pdfium_init_succeeded;
}

#endif

#ifdef _WIN32
// Helper to convert UTF-8 char* to wchar_t*
// The caller is responsible for freeing the returned string.
static wchar_t *to_utf16(const char *utf8_str)
{
    if (!utf8_str)
        return NULL;
    int len = MultiByteToWideChar(CP_UTF8, 0, utf8_str, -1, NULL, 0);
    if (len == 0)
    {
        LOG("MultiByteToWideChar to get len failed with error %lu", GetLastError());
        return NULL;
    }
    wchar_t *utf16_str = (wchar_t *)malloc(len * sizeof(wchar_t));
    if (!utf16_str)
        return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8_str, -1, utf16_str, len) == 0)
    {
        LOG("MultiByteToWideChar to convert failed with error %lu", GetLastError());
        free(utf16_str);
        return NULL;
    }
    return utf16_str;
}

// Helper to convert wchar_t* to UTF-8 char*
// The caller is responsible for freeing the returned string.
static char *to_utf8(const wchar_t *utf16_str)
{
    if (!utf16_str)
        return strdup("");
    int len = WideCharToMultiByte(CP_UTF8, 0, utf16_str, -1, NULL, 0, NULL, NULL);
    if (len == 0)
        return strdup("");
    char *utf8_str = (char *)malloc(len);
    if (!utf8_str)
        return strdup(""); // Should not happen
    WideCharToMultiByte(CP_UTF8, 0, utf16_str, -1, utf8_str, len, NULL, NULL);
    return utf8_str;
}

// Helper function to parse page ranges.
// `range_str`: e.g., "1-3,5,8-10"
// `page_flags`: A pre-allocated array of bools of size `total_pages`.
// `total_pages`: Total number of pages in the document.
// Returns true on success, false on parsing error.
static bool parse_page_range(const char *range_str, bool *page_flags, int total_pages)
{
    // If range is empty or null, mark all pages for printing.
    if (!range_str || strlen(range_str) == 0)
    {
        for (int i = 0; i < total_pages; i++)
            page_flags[i] = true;
        return true;
    }

    // Otherwise, first mark all as false.
    for (int i = 0; i < total_pages; i++)
        page_flags[i] = false;

    char *str = strdup(range_str);
    if (!str)
        return false;
    char *to_free = str;

    // Use strtok for non-Windows, strtok_s for Windows
    char *token;
    char *context = NULL;

#ifdef _WIN32
    token = strtok_s(str, ",", &context);
#else
    token = strtok(str, ",");
#endif

    while (token)
    {
        // Trim whitespace
        while (isspace((unsigned char)*token))
            token++;
        char *end = token + strlen(token) - 1;
        while (end > token && isspace((unsigned char)*end))
            *end-- = '\0';

        if (strlen(token) == 0)
            goto next_token;

        // Make a copy of the token for parsing, so we can use the original for error messages.
        char *token_copy = strdup(token);
        if (!token_copy)
        {
            free(to_free);
            return false;
        }

        int start_page, end_page;
        char *dash = strchr(token_copy, '-');

        if (dash)
        { // It's a range like "3-5"
            *dash = '\0';
            start_page = atoi(token_copy);
            end_page = atoi(dash + 1);
        }
        else
        { // It's a single page like "7"
            start_page = end_page = atoi(token_copy);
        }

        free(token_copy); // Clean up the copy

        // Validate input
        // The page count must be positive.
        // The start page must be at least 1.
        // The end page must not be less than the start page.
        // The end page must not exceed the total number of pages in the document.
        if (total_pages <= 0 || start_page < 1 || end_page < start_page || end_page > total_pages)
        {
            // Use the original, unmodified token for the error message.
            set_last_error("Page range '%s' is invalid for a document with %d pages.", token, total_pages);
            LOG("Invalid page range value: '%s' for a document with %d pages.", token, total_pages);
            free(to_free);
            return false; // Invalid range
        }

        // Mark pages to be printed (adjusting for 0-based index)
        for (int i = start_page; i <= end_page; i++)
        {
            page_flags[i - 1] = true;
        }

    next_token:
#ifdef _WIN32
        token = strtok_s(NULL, ",", &context);
#else
        token = strtok(NULL, ",");
#endif
    }
    free(to_free);
    return true;
}

// Helper function to parse Windows-specific print options from the generic key-value array.
static void parse_windows_options(int num_options, const char **option_keys, const char **option_values,
                                  int *paper_size_id, int *paper_source_id, int *orientation,
                                  int *color_mode, int *print_quality, int *media_type_id,
                                  double *custom_scale, bool *collate, int *duplex_mode, int *pdf_rotation)
{
    // Set default values
    *paper_size_id = 0;
    *paper_source_id = 0;
    *orientation = 0;
    *pdf_rotation = -1; // Default to -1 (auto from PDF)
    *color_mode = 0;
    *print_quality = 0;
    *media_type_id = 0;
    *custom_scale = 1.0; // Default to 100%
    *collate = true;     // Default to collated (complete copies printed together)
    *duplex_mode = 0;    // Default to single-sided (DMDUP_SIMPLEX)

    for (int i = 0; i < num_options; i++)
    {
        if (strcmp(option_keys[i], "paper-size-id") == 0)
        {
            *paper_size_id = atoi(option_values[i]);
        }
        else if (strcmp(option_keys[i], "paper-source-id") == 0)
        {
            *paper_source_id = atoi(option_values[i]);
        }
        else if (strcmp(option_keys[i], "orientation") == 0)
        {
            if (strcmp(option_values[i], "landscape") == 0)
                *orientation = 2; // DMORIENT_LANDSCAPE
            else
                *orientation = 1; // DMORIENT_PORTRAIT
        }
        else if (strcmp(option_keys[i], "color-mode") == 0)
        {
            if (strcmp(option_values[i], "monochrome") == 0)
            {
                *color_mode = 1; // DMCOLOR_MONOCHROME
            }
            else
            {
                *color_mode = 2; // DMCOLOR_COLOR
            }
            // For color/monochrome, also ensure print quality is set to trigger driver update.
            // If it's not already being set, use a neutral value.
            if (*print_quality == 0)
            {
                *print_quality = -3; // DMRES_MEDIUM
            }
        }
        else if (strcmp(option_keys[i], "print-quality") == 0)
        {
            if (strcmp(option_values[i], "draft") == 0)
                *print_quality = -1; // DMRES_DRAFT
            else if (strcmp(option_values[i], "low") == 0)
                *print_quality = -2; // DMRES_LOW
            else if (strcmp(option_values[i], "high") == 0)
                *print_quality = -4; // DMRES_HIGH
            else
                *print_quality = -3; // DMRES_MEDIUM / normal
        }
        else if (strcmp(option_keys[i], "media-type-id") == 0)
        {
            *media_type_id = atoi(option_values[i]);
        }
        else if (strcmp(option_keys[i], "custom-scale-factor") == 0)
        {
            *custom_scale = atof(option_values[i]);
        }
        else if (strcmp(option_keys[i], "collate") == 0)
        {
            // Parse collate option: true = collated (complete copies together), false = non-collated (all copies of each page together)
            *collate = (strcmp(option_values[i], "true") == 0);
        }
        else if (strcmp(option_keys[i], "duplex") == 0)
        {
            // Parse duplex option: singleSided, duplexLongEdge, duplexShortEdge
            if (strcmp(option_values[i], "singleSided") == 0)
            {
                *duplex_mode = 1; // DMDUP_SIMPLEX
            }
            else if (strcmp(option_values[i], "duplexLongEdge") == 0)
            {
                *duplex_mode = 2; // DMDUP_VERTICAL (long edge)
            }
            else if (strcmp(option_values[i], "duplexShortEdge") == 0)
            {
                *duplex_mode = 3; // DMDUP_HORIZONTAL (short edge)
            }
        }
        else if (strcmp(option_keys[i], "pdf-rotation") == 0)
        {
            *pdf_rotation = atoi(option_values[i]);
        }
    }
}
#endif

#ifdef _WIN32
// Helper to get a modified DEVMODE struct for a printer.
// The caller is responsible for freeing the returned struct.
static DEVMODEW *get_modified_devmode(wchar_t *printer_name_w, int paper_size_id, int paper_source_id, int orientation, int color_mode, int print_quality, int media_type_id, int copies, bool collate, int duplex_mode)
{
    if (!printer_name_w)
        return NULL;
    LOG("get_modified_devmode: Creating DEVMODE for '%ls' with paper_id:%d, source_id:%d, orientation:%d, color:%d, quality:%d, media_id:%d, copies:%d, duplex:%d",
        printer_name_w, paper_size_id, paper_source_id, orientation, color_mode, print_quality, media_type_id, copies, duplex_mode);

    HANDLE hPrinter;
    if (!OpenPrinterW(printer_name_w, &hPrinter, NULL))
    {
        LOG("get_modified_devmode: OpenPrinterW failed with error %lu", GetLastError());
        return NULL;
    }

    DEVMODEW *pDevMode = NULL;
    LONG devModeSize = DocumentPropertiesW(NULL, hPrinter, printer_name_w, NULL, NULL, 0);
    if (devModeSize <= 0)
    {
        LOG("get_modified_devmode: DocumentPropertiesW (get size) failed with error %lu. Size was %ld.", GetLastError(), devModeSize);
        ClosePrinter(hPrinter);
        return NULL;
    }

    pDevMode = (DEVMODEW *)malloc(devModeSize);
    if (!pDevMode)
    {
        LOG("get_modified_devmode: Failed to allocate memory for DEVMODE.");
        ClosePrinter(hPrinter);
        return NULL;
    }

    // Get the default DEVMODE for the printer.
    if (DocumentPropertiesW(NULL, hPrinter, printer_name_w, pDevMode, NULL, DM_OUT_BUFFER) != IDOK)
    {
        LOG("get_modified_devmode: DocumentPropertiesW (get defaults) failed with error %lu", GetLastError());
        free(pDevMode);
        ClosePrinter(hPrinter);
        return NULL;
    }
    LOG("get_modified_devmode: Successfully retrieved default DEVMODE.");

    bool modified = false;
    // A value <= 0 for IDs/orientation means "use default".
    if (paper_size_id > 0)
    {
        LOG("get_modified_devmode: Setting dmPaperSize to %d.", paper_size_id);
        pDevMode->dmFields |= DM_PAPERSIZE;
        pDevMode->dmPaperSize = (short)paper_size_id;
        modified = true;
    }
    if (paper_source_id > 0)
    {
        LOG("get_modified_devmode: Setting dmDefaultSource to %d.", paper_source_id);
        pDevMode->dmFields |= DM_DEFAULTSOURCE;
        pDevMode->dmDefaultSource = (short)paper_source_id;
        modified = true;
    }
    if (orientation > 0)
    {
        LOG("get_modified_devmode: Setting dmOrientation to %d.", orientation);
        // If changing orientation, swap paper dimensions to give the driver a hint.
        // The driver should correct this if it's wrong, but some drivers need the help.
        if ((pDevMode->dmFields & DM_ORIENTATION) && pDevMode->dmOrientation != (short)orientation)
        {
            LOG("get_modified_devmode: Swapping paper width (%d) and length (%d) for orientation change.", pDevMode->dmPaperWidth, pDevMode->dmPaperLength);
            short temp = pDevMode->dmPaperWidth;
            pDevMode->dmPaperWidth = pDevMode->dmPaperLength;
            pDevMode->dmPaperLength = temp;
        }
        pDevMode->dmFields |= DM_ORIENTATION;
        pDevMode->dmOrientation = (short)orientation;
        pDevMode->dmFields |= DM_PAPERSIZE; // Ensure paper size is considered with orientation
        modified = true;
    }
    if (color_mode > 0)
    {
        LOG("get_modified_devmode: Setting dmColor to %d.", color_mode);
        pDevMode->dmFields |= DM_COLOR;
        pDevMode->dmColor = (short)color_mode;
        modified = true;
    }
    if (print_quality != 0)
    {
        LOG("get_modified_devmode: Setting dmPrintQuality to %d.", print_quality);
        pDevMode->dmFields |= DM_PRINTQUALITY;
        pDevMode->dmPrintQuality = (short)print_quality;
        modified = true;
    }
    if (media_type_id > 0)
    {
        LOG("get_modified_devmode: Setting dmMediaType to %d.", media_type_id);
        pDevMode->dmFields |= DM_MEDIATYPE;
        pDevMode->dmMediaType = (short)media_type_id;
        modified = true;
    }
    if (duplex_mode > 0)
    {
        LOG("get_modified_devmode: Setting dmDuplex to %d.", duplex_mode);
        pDevMode->dmFields |= DM_DUPLEX;
        pDevMode->dmDuplex = (short)duplex_mode;
        modified = true;
    }

    if (copies > 1)
    {
        LOG("get_modified_devmode: Setting dmCopies to %d.", copies);
        pDevMode->dmFields |= DM_COPIES;
        pDevMode->dmCopies = (short)copies;
        modified = true;
    }

    // Set collate mode
    LOG("get_modified_devmode: Setting dmCollate to %s.", collate ? "true" : "false");
    pDevMode->dmFields |= DM_COLLATE;
    pDevMode->dmCollate = collate ? DMCOLLATE_TRUE : DMCOLLATE_FALSE;
    modified = true;

    if (modified)
    {
        LOG("get_modified_devmode: DEVMODE was modified. Validating with driver...");
        // Validate and merge the changes. The driver may update the DEVMODE struct.
        LONG result = DocumentPropertiesW(NULL, hPrinter, printer_name_w, pDevMode, pDevMode, DM_IN_BUFFER | DM_OUT_BUFFER);
        if (result != IDOK)
        {
            LOG("get_modified_devmode: DocumentPropertiesW (merge) failed with result %ld and error %lu. The driver may have rejected the settings. Continuing anyway.", result, GetLastError());
        }
        else
        {
            LOG("get_modified_devmode: Driver accepted and merged DEVMODE changes.");
        }
    }
    else
    {
        LOG("get_modified_devmode: No modifications requested, using default DEVMODE.");
    }

    ClosePrinter(hPrinter);
    return pDevMode;
}
#endif

FFI_PLUGIN_EXPORT void shutdown_pdfium_library()
{
#ifdef _WIN32
    if (g_pdfium_init_succeeded && g_pdfium.module && g_pdfium.FPDF_DestroyLibrary)
    {
        g_pdfium.FPDF_DestroyLibrary();
        // We don't free the library handle, as the process is likely shutting down.
        // Re-initializing after shutdown is not a supported scenario.
        LOG("PDFium library shut down.");
    }
#endif
}

FFI_PLUGIN_EXPORT void init_pdfium_library()
{
#ifdef _WIN32
    // This function now just ensures initialization. It's safe to call multiple times
    // from any thread. The underlying implementation uses InitOnceExecuteOnce.
    if (ensure_pdfium_initialized())
    {
        LOG("PDFium library explicitly initialized or already initialized.");
    }

#endif
}

FFI_PLUGIN_EXPORT int sum(int a, int b)
{
    return a + b;
}

FFI_PLUGIN_EXPORT int sum_long_running(int a, int b)
{
#ifdef _WIN32
    Sleep(5000);
#else
    usleep(5000 * 1000);
#endif
    return a + b;
}

FFI_PLUGIN_EXPORT PrinterList *get_printers(void)
{
    PrinterList *list = (PrinterList *)malloc(sizeof(PrinterList));
    if (!list)
        return NULL;
    list->count = 0;
    list->printers = NULL;

#ifdef _WIN32
    DWORD needed, returned;
    EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, NULL, 2, NULL, 0, &needed, &returned);
    LOG("EnumPrintersW needed %lu bytes for printer list", needed);
    if (needed == 0)
    {
        return list; // Return empty list
    }
    BYTE *buffer = (BYTE *)malloc(needed);
    if (!buffer)
    {
        free(list);
        return NULL;
    }

    if (EnumPrintersW(PRINTER_ENUM_LOCAL | PRINTER_ENUM_CONNECTIONS, NULL, 2, buffer, needed, &needed, &returned))
    {
        LOG("Found %lu printers on Windows", returned);
        list->count = (int)returned; // Cast to int for consistency
        list->printers = (PrinterInfo *)malloc(returned * sizeof(PrinterInfo));
        if (!list->printers)
        {
            free(buffer);
            free(list);
            return NULL;
        }
        PRINTER_INFO_2W *printers = (PRINTER_INFO_2W *)buffer;
        for (DWORD i = 0; i < returned; i++)
        {
            list->printers[i].name = to_utf8(printers[i].pPrinterName);
            list->printers[i].state = (int)printers[i].Status;         // Cast to int
            list->printers[i].url = to_utf8(printers[i].pPrinterName); // Use printer name as URL for Windows
            list->printers[i].model = to_utf8(printers[i].pDriverName);
            list->printers[i].location = to_utf8(printers[i].pLocation);
            list->printers[i].comment = to_utf8(printers[i].pComment);
            list->printers[i].is_default = (printers[i].Attributes & PRINTER_ATTRIBUTE_DEFAULT) != 0;
            list->printers[i].is_available = (printers[i].Status & PRINTER_STATUS_OFFLINE) == 0;
        }
    }
    else
    {
        LOG("EnumPrintersW failed with error %lu", GetLastError());
    }
    free(buffer);
    return list;
#else // macOS / Linux
    cups_dest_t *dests = NULL;
    int num_dests = cupsGetDests(&dests);
    if (num_dests <= 0)
    {
        cupsFreeDests(num_dests, dests);
        return list; // Return empty list
    }

    list->count = num_dests;
    list->printers = (PrinterInfo *)malloc(num_dests * sizeof(PrinterInfo));
    if (!list->printers)
    {
        cupsFreeDests(num_dests, dests);
        free(list);
        return NULL;
    }

    for (int i = 0; i < num_dests; i++)
    {
        list->printers[i].name = strdup(dests[i].name ? dests[i].name : "");
        list->printers[i].is_default = dests[i].is_default;

        const char *state_str = cupsGetOption("printer-state", dests[i].num_options, dests[i].options);
        list->printers[i].state = state_str ? atoi(state_str) : 3;     // Default to IPP_PRINTER_IDLE (3)
        list->printers[i].is_available = list->printers[i].state != 5; // 5 is IPP_PRINTER_STOPPED

        const char *uri_str = cupsGetOption("device-uri", dests[i].num_options, dests[i].options);
        list->printers[i].url = strdup(uri_str ? uri_str : "");

        const char *model_str = cupsGetOption("printer-make-and-model", dests[i].num_options, dests[i].options);
        list->printers[i].model = strdup(model_str ? model_str : "");

        const char *location_str = cupsGetOption("printer-location", dests[i].num_options, dests[i].options);
        list->printers[i].location = strdup(location_str ? location_str : "");

        const char *comment_str = cupsGetOption("printer-info", dests[i].num_options, dests[i].options);
        list->printers[i].comment = strdup(comment_str ? comment_str : "");
    }
    cupsFreeDests(num_dests, dests);
    return list;
#endif
}

FFI_PLUGIN_EXPORT void free_printer_list(PrinterList *printer_list)
{
    if (!printer_list)
        return;
    if (printer_list->printers)
    {
        for (int i = 0; i < printer_list->count; i++)
        {
            free(printer_list->printers[i].name);
            free(printer_list->printers[i].url);
            free(printer_list->printers[i].model);
            free(printer_list->printers[i].location);
            free(printer_list->printers[i].comment);
        }
        free(printer_list->printers);
    }
    free(printer_list);
}

FFI_PLUGIN_EXPORT PrinterInfo *get_default_printer(void)
{
#ifdef _WIN32
    DWORD len = 0;
    GetDefaultPrinterW(NULL, &len);
    if (len == 0)
    {
        return NULL; // No default printer or an error occurred
    }

    wchar_t *default_printer_name_w = (wchar_t *)malloc(len * sizeof(wchar_t));
    if (!default_printer_name_w)
        return NULL;

    if (!GetDefaultPrinterW(default_printer_name_w, &len))
    {
        LOG("GetDefaultPrinterW failed with error %lu", GetLastError());
        free(default_printer_name_w);
        return NULL;
    }

    HANDLE hPrinter;
    if (!OpenPrinterW(default_printer_name_w, &hPrinter, NULL))
    {
        LOG("OpenPrinterW for default printer failed with error %lu", GetLastError());
        free(default_printer_name_w);
        return NULL;
    }

    DWORD needed = 0;
    GetPrinterW(hPrinter, 2, NULL, 0, &needed);
    if (needed == 0)
    {
        LOG("GetPrinterW (to get size) failed with error %lu", GetLastError());
        ClosePrinter(hPrinter);
        free(default_printer_name_w);
        return NULL;
    }

    PRINTER_INFO_2W *pinfo2 = (PRINTER_INFO_2W *)malloc(needed);
    if (!pinfo2)
    {
        ClosePrinter(hPrinter);
        free(default_printer_name_w);
        return NULL;
    }

    if (!GetPrinterW(hPrinter, 2, (LPBYTE)pinfo2, needed, &needed))
    {
        LOG("GetPrinterW (to get data) failed with error %lu", GetLastError());
        free(pinfo2);
        ClosePrinter(hPrinter);
        free(default_printer_name_w);
        return NULL;
    }
    ClosePrinter(hPrinter);
    free(default_printer_name_w); // We have the info in pinfo2 now

    PrinterInfo *printer_info = (PrinterInfo *)malloc(sizeof(PrinterInfo));
    if (!printer_info)
    {
        free(pinfo2);
        return NULL;
    }
    printer_info->name = to_utf8(pinfo2->pPrinterName);
    printer_info->state = (int)pinfo2->Status; // Cast to int
    printer_info->url = to_utf8(pinfo2->pPrinterName);
    printer_info->model = to_utf8(pinfo2->pDriverName);
    printer_info->location = to_utf8(pinfo2->pLocation);
    printer_info->comment = to_utf8(pinfo2->pComment);
    printer_info->is_default = (pinfo2->Attributes & PRINTER_ATTRIBUTE_DEFAULT) != 0;
    printer_info->is_available = (pinfo2->Status & PRINTER_STATUS_OFFLINE) == 0;

    free(pinfo2);
    return printer_info;
#else // macOS / Linux
    const char *default_printer_name = cupsGetDefault();
    if (!default_printer_name)
    {
        return NULL;
    }

    cups_dest_t *dests = NULL;
    int num_dests = cupsGetDests(&dests);
    cups_dest_t *default_dest = cupsGetDest(default_printer_name, NULL, num_dests, dests);

    if (!default_dest)
    {
        cupsFreeDests(num_dests, dests);
        return NULL;
    }

    PrinterInfo *printer_info = (PrinterInfo *)malloc(sizeof(PrinterInfo));
    if (!printer_info)
    {
        cupsFreeDests(num_dests, dests);
        return NULL;
    }

    printer_info->name = strdup(default_dest->name ? default_dest->name : "");
    printer_info->is_default = default_dest->is_default;
    const char *state_str = cupsGetOption("printer-state", default_dest->num_options, default_dest->options);
    printer_info->state = state_str ? atoi(state_str) : 3;
    printer_info->is_available = printer_info->state != 5;
    const char *uri_str = cupsGetOption("device-uri", default_dest->num_options, default_dest->options);
    printer_info->url = strdup(uri_str ? uri_str : "");
    const char *model_str = cupsGetOption("printer-make-and-model", default_dest->num_options, default_dest->options);
    printer_info->model = strdup(model_str ? model_str : "");
    const char *location_str = cupsGetOption("printer-location", default_dest->num_options, default_dest->options);
    printer_info->location = strdup(location_str ? location_str : "");
    const char *comment_str = cupsGetOption("printer-info", default_dest->num_options, default_dest->options);
    printer_info->comment = strdup(comment_str ? comment_str : "");

    cupsFreeDests(num_dests, dests);
    return printer_info;
#endif
}

FFI_PLUGIN_EXPORT void free_printer_info(PrinterInfo *printer_info)
{
    if (!printer_info)
        return;
    free(printer_info->name);
    free(printer_info->url);
    free(printer_info->model);
    free(printer_info->location);
    free(printer_info->comment);
    free(printer_info);
}

FFI_PLUGIN_EXPORT bool raw_data_to_printer(const char *printer_name, const uint8_t *data, int length, const char *doc_name, int num_options, const char **option_keys, const char **option_values)
{

    // Validate input parameters
    if (!printer_name || !data || length <= 0 || !doc_name)
    {
        LOG("Invalid input parameters");
        return false;
    }

#ifdef _WIN32
    int paper_size_id, paper_source_id, orientation, color_mode, print_quality, media_type_id, duplex_mode, pdf_rotation;
    double custom_scale; // Dummy for raw printing
    bool collate = true; // Default to collated (complete copies printed together)
    parse_windows_options(num_options, option_keys, option_values, &paper_size_id, &paper_source_id, &orientation, &color_mode, &print_quality, &media_type_id, &custom_scale, &collate, &duplex_mode, &pdf_rotation);

    wchar_t *printer_name_w = to_utf16(printer_name);
    if (!printer_name_w)
        return false;

    HANDLE hPrinter;
    DOC_INFO_1W docInfo;
    DEVMODEW *pDevMode = get_modified_devmode(printer_name_w, paper_size_id, paper_source_id, orientation, color_mode, print_quality, media_type_id, 1, collate, duplex_mode);

    PRINTER_DEFAULTSW printerDefaults = {NULL, pDevMode, PRINTER_ACCESS_USE};
    printerDefaults.pDatatype = L"RAW";

    if (!OpenPrinterW(printer_name_w, &hPrinter, &printerDefaults))
    {
        LOG("OpenPrinterW failed with error %lu", GetLastError());
        free(printer_name_w);
        if (pDevMode)
            free(pDevMode);
        return false;
    }

    wchar_t *doc_name_w = to_utf16(doc_name);
    docInfo.pDocName = doc_name_w;
    docInfo.pOutputFile = NULL;
    docInfo.pDatatype = L"RAW";

    if (StartDocPrinterW(hPrinter, 1, (LPBYTE)&docInfo) == 0)
    {
        ClosePrinter(hPrinter);
        LOG("StartDocPrinterW failed with error %lu", GetLastError());
        if (doc_name_w)
            free(doc_name_w);
        free(printer_name_w);
        if (pDevMode)
            free(pDevMode);
        return false;
    }
    if (doc_name_w)
        free(doc_name_w);

    if (!StartPagePrinter(hPrinter))
    {
        EndDocPrinter(hPrinter);
        ClosePrinter(hPrinter);
        LOG("StartPagePrinter failed with error %lu", GetLastError());
        free(printer_name_w);
        if (pDevMode)
            free(pDevMode);
        return false;
    }

    // --- Chunked Write with Message Pump ---
    // This prevents the STA thread from blocking if a very large raw data file is sent.
    const DWORD CHUNK_SIZE = 65536; // 64 KB
    DWORD total_written = 0;
    DWORD bytes_to_write = (DWORD)length;
    bool write_success = true;

    while (total_written < bytes_to_write)
    {
        DWORD chunk_to_write = (bytes_to_write - total_written > CHUNK_SIZE) ? CHUNK_SIZE : (bytes_to_write - total_written);
        DWORD written_this_chunk = 0;

        if (!WritePrinter(hPrinter, (LPVOID)(data + total_written), chunk_to_write, &written_this_chunk))
        {
            LOG("WritePrinter failed during chunked write with error %lu", GetLastError());
            write_success = false;
            break;
        }

        total_written += written_this_chunk;

        // Pump messages to keep the STA thread responsive.
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    EndPagePrinter(hPrinter);
    EndDocPrinter(hPrinter);
    ClosePrinter(hPrinter);
    free(printer_name_w);
    if (pDevMode)
        free(pDevMode);

    bool success = write_success && (total_written == (DWORD)length);
    if (!success)
    {
        LOG("WritePrinter failed. Success: %d, Bytes written: %lu, Expected: %d", write_success, total_written, length);
    }
    return success;
#else // macOS / Linux
    // Use getenv("TMPDIR") to get the correct temporary directory,
    // especially important for sandboxed macOS apps where /tmp is not writable.
    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir)
    {
        tmpdir = "/tmp"; // Fallback for Linux or non-sandboxed environments
    }

    char temp_file[PATH_MAX];
    snprintf(temp_file, sizeof(temp_file), "%s/printing_ffi_XXXXXX", tmpdir);
    LOG("Creating temporary file at: %s", temp_file);

    int fd = mkstemp(temp_file);
    if (fd == -1)
    {
        LOG("mkstemp failed to create temporary file");
        return false;
    }

    FILE *fp = fdopen(fd, "wb");
    if (!fp)
    {
        close(fd);
        unlink(temp_file);
        return false;
    }

    size_t written = fwrite(data, 1, (size_t)length, fp);
    fclose(fp);

    if (written != (size_t)length)
    {
        unlink(temp_file);
        return false;
    }

    // Add the "raw" option to tell CUPS not to filter the data.
    cups_option_t *options = NULL;
    int num_cups_options = 0;
    num_cups_options = cupsAddOption("raw", "true", num_cups_options, &options);

    for (int i = 0; i < num_options; i++)
    {
        if (option_keys && option_keys[i] && option_values && option_values[i])
        {
            num_cups_options = cupsAddOption(option_keys[i], option_values[i], num_cups_options, &options);
        }
    }

    int job_id = cupsPrintFile(printer_name, temp_file, doc_name, num_cups_options, options);
    if (job_id <= 0)
    {
        LOG("cupsPrintFile failed, error: %s", cupsLastErrorString());
    }
    cupsFreeOptions(num_cups_options, options);
    unlink(temp_file);
    return job_id > 0;
#endif
}

// Internal helper to calculate the destination rectangle for scaling content to fit a target area.
static void _scale_to_fit(int src_width, int src_height, int target_width, int target_height, int *dest_width, int *dest_height)
{
    float page_aspect = 1.0f;
    if (src_height > 0)
    {
        page_aspect = (float)src_width / (float)src_height;
    }

    float target_aspect = 1.0f;
    if (target_height != 0)
    {
        target_aspect = (float)target_width / (float)target_height;
    }

    if (page_aspect > target_aspect)
    {
        *dest_width = target_width;
        *dest_height = (int)(target_width / page_aspect);
    }
    else
    {
        *dest_height = target_height;
        *dest_width = (int)(target_height * page_aspect);
    }
}

#ifdef _WIN32

// Common internal function for PDF printing on Windows.
// Returns a job ID if `submit_job` is true, otherwise returns 1 for success or 0 for failure.
static int32_t _print_pdf_job_win(const char *printer_name, const char *pdf_file_path, const char *doc_name, int scaling_mode, int copies, const char *page_range, const char *alignment, int num_options, const char **option_keys, const char **option_values, bool submit_job)
{
    // Ensure the PDFium library is loaded and initialized. This is thread-safe and idempotent.
    if (!ensure_pdfium_initialized())
    {
        // Error is already set by ensure_pdfium_initialized or its callback.
        return 0;
    }

    // Clear any previous errors at the start of an operation.
    set_last_error("");
    double custom_scale;
    int paper_size_id, paper_source_id, orientation, color_mode, print_quality, media_type_id, duplex_mode, pdf_rotation;
    bool collate = true; // Default to collated (complete copies printed together)
    parse_windows_options(num_options, option_keys, option_values, &paper_size_id, &paper_source_id, &orientation, &color_mode, &print_quality, &media_type_id, &custom_scale, &collate, &duplex_mode, &pdf_rotation);

    wchar_t *printer_name_w = to_utf16(printer_name);
    if (!printer_name_w)
    {
        set_last_error("Failed to convert printer name to UTF-16.");
        LOG("print_pdf_job_win: Failed to convert printer name to UTF-16");
        return 0;
    }

    FPDF_DOCUMENT doc = g_pdfium.FPDF_LoadDocument((FPDF_STRING)pdf_file_path, NULL);
    if (!doc)
    {
        set_last_error("Failed to load PDF document at path '%s'. Error code: %ld. The file may be missing, corrupt, or password-protected.", pdf_file_path, g_pdfium.FPDF_GetLastError());
        LOG("print_pdf_job_win: FPDF_LoadDocument failed for path: %s. Error: %ld", pdf_file_path, g_pdfium.FPDF_GetLastError());
        free(printer_name_w);
        return 0;
    }
    LOG("print_pdf_job_win: PDF document loaded successfully.");

    DEVMODEW *pDevMode = get_modified_devmode(printer_name_w, paper_size_id, paper_source_id, orientation, color_mode, print_quality, media_type_id, copies, collate, duplex_mode);

    HDC hdc = CreateDCW(L"WINSPOOL", printer_name_w, NULL, pDevMode);
    if (pDevMode)
        free(pDevMode); // DEVMODE is copied by CreateDC, so we can free it now.

    if (!hdc)
    {
        set_last_error("Failed to create device context (CreateDCW) for printer '%s'. Error: %lu. This often indicates an invalid printer name or driver issue.", printer_name, GetLastError());
        LOG("print_pdf_job_win: CreateDCW failed for printer '%s' with error %lu. This often indicates an invalid DEVMODE.", printer_name, GetLastError());
        g_pdfium.FPDF_CloseDocument(doc);
        free(printer_name_w);
        return 0;
    }

    wchar_t *doc_name_w = to_utf16(doc_name);
    DOCINFOW di;
    memset(&di, 0, sizeof(DOCINFOW));
    di.cbSize = sizeof(DOCINFOW);
    di.lpszDocName = doc_name_w;
    int job_id = StartDocW(hdc, &di);

    if (job_id <= 0)
    {
        set_last_error("Failed to start print document (StartDocW). Error: %lu.", GetLastError());
        LOG("print_pdf_job_win: StartDocW failed with error %lu", GetLastError());
        if (doc_name_w)
            free(doc_name_w);
        DeleteDC(hdc);
        g_pdfium.FPDF_CloseDocument(doc);
        free(printer_name_w);
        return 0;
    }
    // doc_name_w is used by the system, don't free it until EndDoc.
    LOG("print_pdf_job_win: StartDocW succeeded with Job ID: %d", job_id);

    int page_count = g_pdfium.FPDF_GetPageCount(doc);
    if (page_count <= 0)
    {
        set_last_error("Could not get page count from the PDF document. The file may be empty, corrupt, or in an unsupported format. (Page count: %d)", page_count);
        LOG("print_pdf_job_win: FPDF_GetPageCount returned %d. Aborting.", page_count);
        if (doc_name_w)
            free(doc_name_w);
        AbortDoc(hdc);
        DeleteDC(hdc);
        g_pdfium.FPDF_CloseDocument(doc);
        free(printer_name_w);
        // We don't need to free pages_to_print as it's not allocated yet.
        return 0;
    }

    LOG("print_pdf_job_win: PDF has %d pages.", page_count);
    bool *pages_to_print = (bool *)malloc(page_count * sizeof(bool));
    if (!pages_to_print)
    {
        set_last_error("Failed to allocate memory for page range flags.");
        LOG("print_pdf_job_win: Failed to allocate memory for page range flags.");
        if (doc_name_w)
            free(doc_name_w);
        AbortDoc(hdc);
        DeleteDC(hdc);
        g_pdfium.FPDF_CloseDocument(doc);
        free(printer_name_w);
        return 0;
    }

    if (!parse_page_range(page_range, pages_to_print, page_count))
    {
        // If parse_page_range fails, it now sets a specific error. If it's still empty, provide a generic one.
        if (g_last_error_message == NULL || strlen(g_last_error_message) == 0)
            set_last_error("Invalid page range format: '%s'. Use a format like '1-3,5,7-9'.", page_range ? page_range : "");
        LOG("print_pdf_job_win: Invalid page range string provided: %s", page_range ? page_range : "(null)");
        free(pages_to_print);
        if (doc_name_w)
            free(doc_name_w);
        AbortDoc(hdc);
        DeleteDC(hdc);
        g_pdfium.FPDF_CloseDocument(doc);
        free(printer_name_w);
        return 0;
    }
    LOG("print_pdf_job_win: Page range parsed successfully. Copies: %d.", copies);

    // --- Alignment ---
    double align_x_factor = 0.5; // Default to center
    double align_y_factor = 0.5; // Default to center

    if (alignment)
    {
        char *alignment_lower = strdup(alignment);
        if (alignment_lower)
        {
            for (int i = 0; alignment_lower[i]; i++)
            {
                alignment_lower[i] = tolower(alignment_lower[i]);
            }

            if (strstr(alignment_lower, "left"))
            {
                align_x_factor = 0.0;
            }
            else if (strstr(alignment_lower, "right"))
            {
                align_x_factor = 1.0;
            }

            if (strstr(alignment_lower, "top"))
            {
                align_y_factor = 0.0;
            }
            else if (strstr(alignment_lower, "bottom"))
            {
                align_y_factor = 1.0;
            }

            free(alignment_lower);
        }
    }

    bool success = true;
    // The outer loop for copies is removed. The driver will handle it via DEVMODE.
    // for (int c = 0; c < copies && success; c++)
    // {
    // LOG("print_pdf_job_win: Starting copy %d of %d.", c + 1, copies);
    for (int i = 0; i < page_count && success; ++i)
    {
        if (!pages_to_print[i])
        {
            continue;
        }
        LOG("print_pdf_job_win: Printing page %d (0-indexed).", i);

        // Manually pump the Windows message queue. This is CRITICAL for STA threads
        // that perform long-running operations. It prevents the thread from becoming
        // unresponsive and causing deadlocks or other COM errors with the printer driver.
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }

        // Declare destination rectangle variables for the current page.
        int dest_x = 0, dest_y = 0, dest_width = 0, dest_height = 0;

        FPDF_PAGE page = g_pdfium.FPDF_LoadPage(doc, i);
        if (!page)
        {
            set_last_error("Failed to load PDF page %d.", i + 1);
            LOG("print_pdf_job_win: FPDF_LoadPage failed for page %d", i);
            success = false;
            break;
        }

        if (StartPage(hdc) <= 0)
        {
            set_last_error("Failed to start page %d. Error: %lu.", i + 1, GetLastError());
            LOG("print_pdf_job_win: StartPage failed for page %d with error %lu", i, GetLastError());
            // Clean up the page resource before breaking from the loop.
            g_pdfium.FPDF_ClosePage(page);
            success = false;
            break;
        }

        // --- Get PDF page dimensions and rotation ---
        float pdf_width_pt = g_pdfium.FPDF_GetPageWidthF(page);
        float pdf_height_pt = g_pdfium.FPDF_GetPageHeightF(page);

        int rotation = g_pdfium.FPDFPage_GetRotation(page);
        if (pdf_rotation != -1)
        {
            rotation = pdf_rotation;
        }
        if (rotation == 1 || rotation == 3)
        { // 90 or 270 degrees, swap dimensions
            float temp = pdf_width_pt;
            pdf_width_pt = pdf_height_pt;
            pdf_height_pt = temp;
        }

        int dpi_x = GetDeviceCaps(hdc, LOGPIXELSX);
        int dpi_y = GetDeviceCaps(hdc, LOGPIXELSY);
        int printable_width_pixels = GetDeviceCaps(hdc, HORZRES);
        int printable_height_pixels = GetDeviceCaps(hdc, VERTRES);

        LOG("print_pdf_job_win: Page %d: PDF Dimensions (pt): %.2f x %.2f", i, pdf_width_pt, pdf_height_pt);
        LOG("print_pdf_job_win: Page %d: Device DPI: %d x %d", i, dpi_x, dpi_y);
        LOG("print_pdf_job_win: Page %d: Printable Area (pixels): %d x %d", i, printable_width_pixels, printable_height_pixels);

        // Calculate the PDF page size in device pixels.
        int pdf_pixel_width = (int)(pdf_width_pt / 72.0f * dpi_x);
        int pdf_pixel_height = (int)(pdf_height_pt / 72.0f * dpi_y);

        if (scaling_mode == 0)
        { // Fit to Printable Area (formerly Fit Page)
            _scale_to_fit(pdf_pixel_width, pdf_pixel_height, printable_width_pixels, printable_height_pixels, &dest_width, &dest_height);
            LOG("print_pdf_job_win: Page %d: ScalingMode=FitToPrintableArea, Dest=(%d,%d)", i, dest_width, dest_height);
        }
        else if (scaling_mode == 1)
        { // Actual Size
            // Calculate actual size in device pixels
            dest_width = pdf_pixel_width;
            dest_height = pdf_pixel_height;
            LOG("print_pdf_job_win: Page %d: ScalingMode=ActualSize, Dest=(%d,%d)", i, dest_width, dest_height);
        }
        else if (scaling_mode == 2)
        { // Shrink to Fit
            // If the PDF page is larger than the printable area, scale down to fit.
            // Otherwise, print at actual size.
            if (pdf_pixel_width > printable_width_pixels || pdf_pixel_height > printable_height_pixels)
            {
                _scale_to_fit(pdf_pixel_width, pdf_pixel_height, printable_width_pixels, printable_height_pixels, &dest_width, &dest_height);
                LOG("print_pdf_job_win: Page %d: ScalingMode=ShrinkToFit (scaled), Dest=(%d,%d)", i, dest_width, dest_height);
            }
            else
            {
                dest_width = pdf_pixel_width;
                dest_height = pdf_pixel_height;
                LOG("print_pdf_job_win: Page %d: ScalingMode=ShrinkToFit (actual size), Dest=(%d,%d)", i, dest_width, dest_height);
            }
        }
        else if (scaling_mode == 3)
        { // Fit to Paper
            int paper_width = GetDeviceCaps(hdc, PHYSICALWIDTH);
            int paper_height = GetDeviceCaps(hdc, PHYSICALHEIGHT);
            _scale_to_fit(pdf_pixel_width, pdf_pixel_height, paper_width, paper_height, &dest_width, &dest_height);
            LOG("print_pdf_job_win: Page %d: ScalingMode=FitToPaper, Dest=(%d,%d)", i, dest_width, dest_height);
        }
        else if (scaling_mode == 4)
        { // Custom Scale
            // Apply custom scale factor
            dest_width = (int)(pdf_pixel_width * custom_scale);
            dest_height = (int)(pdf_pixel_height * custom_scale);
            LOG("print_pdf_job_win: Page %d: ScalingMode=CustomScale (%.2f), Dest=(%d,%d)", i, custom_scale, dest_width, dest_height);
        }
        else
        { // Default to Fit to Printable Area
            _scale_to_fit(pdf_pixel_width, pdf_pixel_height, printable_width_pixels, printable_height_pixels, &dest_width, &dest_height);
            LOG("print_pdf_job_win: Page %d: ScalingMode=Default (FitToPrintableArea), Dest=(%d,%d)", i, dest_width, dest_height);
        }

        if (scaling_mode == 3)
        { // Fit to Paper alignment is relative to physical paper
            int paper_width = GetDeviceCaps(hdc, PHYSICALWIDTH);
            int paper_height = GetDeviceCaps(hdc, PHYSICALHEIGHT);
            int offset_x = GetDeviceCaps(hdc, PHYSICALOFFSETX);
            int offset_y = GetDeviceCaps(hdc, PHYSICALOFFSETY);
            dest_x = (int)((paper_width - dest_width) * align_x_factor) - offset_x;
            dest_y = (int)((paper_height - dest_height) * align_y_factor) - offset_y;
        }
        else
        { // All other modes are relative to the printable area
            dest_x = (int)((printable_width_pixels - dest_width) * align_x_factor);
            dest_y = (int)((printable_height_pixels - dest_height) * align_y_factor);
        }

        LOG("print_pdf_job_win: Page %d: Final DestRect=(%d,%d, %dx%d)", i, dest_x, dest_y, dest_width, dest_height);

        // --- Direct Rendering to Printer DC ---
        // Render the page directly to the printer's device context. This simplifies
        // the code by avoiding an intermediate bitmap.
        // NOTE: This is a synchronous, blocking call. While simpler, it prevents
        // the message pump from running during rendering, which could cause
        // issues on very complex pages. The previous progressive rendering
        // implementation was more complex but kept the thread responsive.
        g_pdfium.FPDF_RenderPage(hdc, page, dest_x, dest_y, dest_width, dest_height, rotation, FPDF_ANNOT | FPDF_PRINTING | FPDF_NO_NATIVETEXT);

        if (EndPage(hdc) <= 0)
        {
            set_last_error("Failed to end page %d. Error: %lu.", i + 1, GetLastError());
            LOG("print_pdf_job_win: EndPage failed for page %d with error %lu", i, GetLastError());
            success = false;
        }

        // Now, close the page object itself to prevent memory leaks.
        g_pdfium.FPDF_ClosePage(page);

        if (!success)
        {
            break; // Exit the loop on failure
        }
    }
    // }

    free(pages_to_print);
    if (doc_name_w)
        free(doc_name_w);

    if (success)
    {
        LOG("print_pdf_job_win: All pages processed successfully. Calling EndDoc.");
        EndDoc(hdc);
    }
    else
    {
        LOG("print_pdf_job_win: A failure occurred. Calling AbortDoc.");
        AbortDoc(hdc);
    }

    DeleteDC(hdc);
    g_pdfium.FPDF_CloseDocument(doc);
    free(printer_name_w);

    if (submit_job)
    {
        return success ? job_id : 0;
    }
    else
    {
        return success ? 1 : 0;
    }
}
#endif

FFI_PLUGIN_EXPORT const char *get_last_error()
{
    return g_last_error_message ? g_last_error_message : "";
}

// ============================================================================
// Android: bundled cupsd scheduler (runs inside the app sandbox at the app uid)
// ============================================================================
#ifdef __ANDROID__

#include <sys/un.h>

// PID of the cupsd child we forked. 0 = not running.
static pid_t g_cupsd_pid = 0;
// The localhost port cupsd is listening on (chosen at start time).
static int g_cupsd_port = 0;
// The canonical USB-fd AF_UNIX socket path (<server_root>/usbfd.sock), filled by
// start_cups_server. Empty until then. Both start_usb_fd_server (via the caller)
// and the backend's PRINTING_FFI_USB_FD_SOCK env line derive from this.
static char g_usb_fd_sock_path[PATH_MAX] = {0};

// PPD-generation context, captured by start_cups_server so generate_cups_dnp_ppd()
// can (re)generate a Gutenprint PPD for ANY detected DNP model at runtime (not just
// the representative DS620 emitted at boot). Empty until start_cups_server succeeds.
static char g_native_lib_dir[PATH_MAX] = {0}; // nativeLibraryDir (holds genppd)
static char g_ppddir[PATH_MAX] = {0};         // <serverroot>/ppd (PPD output dir)
static char g_stp_data_path[PATH_MAX] = {0};  // gutenprint xml dir (STP_DATA_PATH)
// Static return buffer for generate_cups_dnp_ppd()'s absolute path.
static char g_dnp_ppd_path[PATH_MAX] = {0};

// mkdir -p equivalent. Returns 0 on success.
static int mkdirs(const char *path, mode_t mode)
{
    char tmp[PATH_MAX];
    size_t len = strlen(path);
    if (len == 0 || len >= sizeof(tmp))
        return -1;
    strcpy(tmp, path);
    if (tmp[len - 1] == '/')
        tmp[len - 1] = '\0';
    for (char *p = tmp + 1; *p; p++)
    {
        if (*p == '/')
        {
            *p = '\0';
            if (mkdir(tmp, mode) != 0 && errno != EEXIST)
                return -1;
            *p = '/';
        }
    }
    if (mkdir(tmp, mode) != 0 && errno != EEXIST)
        return -1;
    return 0;
}

// Write a whole string to a file (truncating). Returns 0 on success.
static int write_file(const char *path, const char *content)
{
    FILE *f = fopen(path, "w");
    if (!f)
        return -1;
    size_t n = strlen(content);
    size_t w = fwrite(content, 1, n, f);
    fclose(f);
    return (w == n) ? 0 : -1;
}

// Create one symlink target<-linkpath, replacing any existing entry. Logs but
// does not fail the whole farm on a single error (best-effort).
static void make_symlink(const char *target, const char *linkpath)
{
    unlink(linkpath); // ignore errors (may not exist)
    if (symlink(target, linkpath) != 0)
        LOG("symlink %s -> %s failed: %s", linkpath, target, strerror(errno));
}

// Try to bind a localhost TCP port to find a free one. Returns the port, or -1.
static int find_free_port(void)
{
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0)
        return -1;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = 0; // ask the kernel for an ephemeral port
    if (bind(s, (struct sockaddr *)&addr, sizeof(addr)) != 0)
    {
        close(s);
        return -1;
    }
    socklen_t alen = sizeof(addr);
    if (getsockname(s, (struct sockaddr *)&addr, &alen) != 0)
    {
        close(s);
        return -1;
    }
    int port = ntohs(addr.sin_port);
    close(s);
    return port;
}

// Poll a localhost TCP port until something accepts a connection (cupsd is up),
// or we time out. Returns true if connectable.
static bool wait_for_port(int port, int timeout_ms)
{
    int waited = 0;
    const int step = 100; // ms
    while (waited < timeout_ms)
    {
        int s = socket(AF_INET, SOCK_STREAM, 0);
        if (s >= 0)
        {
            struct sockaddr_in addr;
            memset(&addr, 0, sizeof(addr));
            addr.sin_family = AF_INET;
            addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            addr.sin_port = htons((uint16_t)port);
            int rc = connect(s, (struct sockaddr *)&addr, sizeof(addr));
            close(s);
            if (rc == 0)
                return true;
        }
        // Also bail early if the child died.
        if (g_cupsd_pid > 0)
        {
            int status = 0;
            pid_t r = waitpid(g_cupsd_pid, &status, WNOHANG);
            if (r == g_cupsd_pid)
            {
                LOG("cupsd child %d exited early (status=%d) while waiting for port", (int)g_cupsd_pid, status);
                g_cupsd_pid = 0;
                return false;
            }
        }
        usleep(step * 1000);
        waited += step;
    }
    return false;
}

// Build the ServerBin symlink farm: serverbin/{backend,filter,daemon}/<name>
// -> native_lib_dir/lib*.so (per tool/android/jnilibs-map.md).
static void build_symlink_farm(const char *serverbin, const char *native_lib_dir)
{
    char dir[PATH_MAX], link[PATH_MAX], target[PATH_MAX];

    // backends
    snprintf(dir, sizeof(dir), "%s/backend", serverbin);
    mkdirs(dir, 0755);
    static const char *backends[][2] = {
        {"socket", "libcupsbe_socket.so"},
        {"ipp", "libcupsbe_ipp.so"},
        {"lpd", "libcupsbe_lpd.so"},
        {"snmp", "libcupsbe_snmp.so"},
        {"usb", "libcupsbe_usb.so"},
        {"http", "libcupsbe_http.so"},
        // Gutenprint dye-sub USB backend (DNP etc.). Canonical name has a '+',
        // which is illegal in a lib*.so name, so the .so drops it. See
        // tool/android/jnilibs-map.md. The device-uri scheme is gutenprint53+usb:.
        {"gutenprint53+usb", "libcupsbe_gutenprint53usb.so"},
        {NULL, NULL}};
    for (int i = 0; backends[i][0]; i++)
    {
        snprintf(link, sizeof(link), "%s/backend/%s", serverbin, backends[i][0]);
        snprintf(target, sizeof(target), "%s/%s", native_lib_dir, backends[i][1]);
        make_symlink(target, link);
    }

    // daemons
    snprintf(dir, sizeof(dir), "%s/daemon", serverbin);
    mkdirs(dir, 0755);
    static const char *daemons[][2] = {
        {"cups-deviced", "libcupsd_deviced.so"},
        {"cups-driverd", "libcupsd_driverd.so"},
        {"cups-exec", "libcupsd_exec.so"},
        {"cups-lpd", "libcupsd_lpd.so"},
        {"cupsfilter", "libcupsd_cupsfilter.so"},
        {NULL, NULL}};
    for (int i = 0; daemons[i][0]; i++)
    {
        snprintf(link, sizeof(link), "%s/daemon/%s", serverbin, daemons[i][0]);
        snprintf(target, sizeof(target), "%s/%s", native_lib_dir, daemons[i][1]);
        make_symlink(target, link);
    }

    // filters
    snprintf(dir, sizeof(dir), "%s/filter", serverbin);
    mkdirs(dir, 0755);
    static const char *filters[][2] = {
        {"gziptoany", "libcupsf_gziptoany.so"},
        {"pstops", "libcupsf_pstops.so"},
        {"commandtops", "libcupsf_commandtops.so"},
        {"rastertopwg", "libcupsf_rastertopwg.so"},
        {"rastertoepson", "libcupsf_rastertoepson.so"},
        {"rastertohp", "libcupsf_rastertohp.so"},
        {"rastertolabel", "libcupsf_rastertolabel.so"},
        // Image -> CUPS-raster input filter (from cups-filters 1.28.17). CUPS 2.x
        // moved the input filters out of core into cups-filters, so without this
        // cupsd rejects "unsupported document format image/jpeg". The mime CONV
        // rules (share/cups/mime/imagetoraster.convs) route image/jpeg|png|gif|bmp
        // -> application/vnd.cups-raster via this filter, which then feeds the
        // Gutenprint DNP chain (rastertogutenprint.5.3 -> gutenprint53+usb).
        // Permissive image libs (libjpeg-turbo/libpng) are STATICALLY embedded;
        // the filter is exec'd as a separate process (license firewall).
        {"imagetoraster", "libcupsf_imagetoraster.so"},
        // Gutenprint dye-sub (DNP) raster filter + command filter. The generated
        // DNP PPD references these EXACT names in its *cupsFilter lines:
        //   "application/vnd.cups-raster 100 rastertogutenprint.5.3"  (version suffix!)
        //   "application/vnd.cups-command 33 commandtodyesub"
        // (see src/cups/genppd.c). cupsd resolves them under ServerBin/filter/.
        {"rastertogutenprint.5.3", "libcupsf_rastertogutenprint.so"},
        {"commandtodyesub", "libcupsf_commandtodyesub.so"},
        {NULL, NULL}};
    for (int i = 0; filters[i][0]; i++)
    {
        snprintf(link, sizeof(link), "%s/filter/%s", serverbin, filters[i][0]);
        snprintf(target, sizeof(target), "%s/%s", native_lib_dir, filters[i][1]);
        make_symlink(target, link);
    }

    // cgi-bin (web interface). cupsd exec's these as ServerBin/cgi-bin/<name>.cgi
    // (scheduler/client.c). Each maps to nativeLibraryDir/libcupscgi_<name>.so.
    snprintf(dir, sizeof(dir), "%s/cgi-bin", serverbin);
    mkdirs(dir, 0755);
    static const char *cgis[][2] = {
        {"admin.cgi", "libcupscgi_admin.so"},
        {"printers.cgi", "libcupscgi_printers.so"},
        {"jobs.cgi", "libcupscgi_jobs.so"},
        {"classes.cgi", "libcupscgi_classes.so"},
        {"help.cgi", "libcupscgi_help.so"},
        {NULL, NULL}};
    for (int i = 0; cgis[i][0]; i++)
    {
        snprintf(link, sizeof(link), "%s/cgi-bin/%s", serverbin, cgis[i][0]);
        snprintf(target, sizeof(target), "%s/%s", native_lib_dir, cgis[i][1]);
        make_symlink(target, link);
    }
}

// Generate a Gutenprint PPD for a single dye-sub driver by exec'ing the bundled
// cups-genppd (staged as libcupstool_gutenprint_genppd.so). genppd is arm64-only
// (can't run on the host at build time), so DNP PPDs are generated at runtime,
// on first boot, into ppddir. Writes <ppddir>/stp-<driver>.5.3.ppd (uncompressed,
// -Z). STP_DATA_PATH must point at the gutenprint xml dir so genppd finds the
// driver data. Best-effort: logs + returns non-zero on failure, never aborts boot.
// Returns 0 on success (or if the PPD already exists), -1 otherwise.
static int generate_dnp_ppd(const char *native_lib_dir, const char *ppddir,
                            const char *stp_data_path, const char *driver)
{
    char ppdfile[PATH_MAX];
    snprintf(ppdfile, sizeof(ppdfile), "%s/stp-%s.5.3.ppd", ppddir, driver);
    struct stat st;
    if (stat(ppdfile, &st) == 0 && st.st_size > 0)
    {
        LOG("generate_dnp_ppd: %s already present (%lld bytes), skipping", ppdfile, (long long)st.st_size);
        return 0;
    }

    char genppd_bin[PATH_MAX];
    snprintf(genppd_bin, sizeof(genppd_bin), "%s/libcupstool_gutenprint_genppd.so", native_lib_dir);
    if (stat(genppd_bin, &st) != 0)
    {
        LOG("generate_dnp_ppd: genppd binary not found at %s (DNP PPD unavailable)", genppd_bin);
        return -1;
    }
    if (stat(stp_data_path, &st) != 0)
    {
        LOG("generate_dnp_ppd: gutenprint data not found at %s", stp_data_path);
        return -1;
    }

    pid_t pid = fork();
    if (pid < 0)
    {
        LOG("generate_dnp_ppd: fork failed: %s", strerror(errno));
        return -1;
    }
    if (pid == 0)
    {
        // Child: genppd reads STP_DATA_PATH to find the driver XML data.
        setenv("STP_DATA_PATH", stp_data_path, 1);
        // -p <ppddir>: output dir; -Z: no gzip; <driver>: single model to emit.
        char *const argv[] = {
            genppd_bin,
            (char *)"-p", (char *)ppddir,
            (char *)"-Z",
            (char *)driver,
            NULL};
        execv(genppd_bin, argv);
        _exit(127);
    }

    int status = 0;
    if (waitpid(pid, &status, 0) != pid)
    {
        LOG("generate_dnp_ppd: waitpid failed: %s", strerror(errno));
        return -1;
    }
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
    {
        LOG("generate_dnp_ppd: cups-genppd exited abnormally (status=%d) for driver %s", status, driver);
        return -1;
    }
    if (stat(ppdfile, &st) != 0 || st.st_size == 0)
    {
        LOG("generate_dnp_ppd: cups-genppd reported success but %s missing/empty", ppdfile);
        return -1;
    }
    LOG("generate_dnp_ppd: generated %s (%lld bytes)", ppdfile, (long long)st.st_size);
    return 0;
}

FFI_PLUGIN_EXPORT int32_t start_cups_server(const char *server_root, const char *native_lib_dir, const char *data_dir, const char *doc_root)
{
    set_last_error("");

    if (!server_root || !native_lib_dir || !data_dir)
    {
        set_last_error("start_cups_server: server_root/native_lib_dir/data_dir required");
        return -1;
    }

    if (g_cupsd_pid > 0)
    {
        // Already running: verify it's still alive; if so, just re-point the client.
        int status = 0;
        if (waitpid(g_cupsd_pid, &status, WNOHANG) == 0)
        {
            LOG("cupsd already running (pid %d, port %d)", (int)g_cupsd_pid, g_cupsd_port);
            cupsSetServer("127.0.0.1");
            return g_cupsd_port;
        }
        g_cupsd_pid = 0;
    }

    uid_t uid = getuid();
    gid_t gid = getgid();
    LOG("start_cups_server: uid=%d gid=%d server_root=%s native_lib_dir=%s data_dir=%s doc_root=%s",
        (int)uid, (int)gid, server_root, native_lib_dir, data_dir, doc_root ? doc_root : "(null)");

    // --- Directory layout under server_root ---
    char serverroot[PATH_MAX];   // ServerRoot (config: cupsd.conf, cups-files.conf, ppd)
    char serverbin[PATH_MAX];    // ServerBin  (symlink farm)
    char requestroot[PATH_MAX];  // RequestRoot (spool)
    char statedir[PATH_MAX];     // StateDir
    char cachedir[PATH_MAX];     // CacheDir
    char tempdir[PATH_MAX];      // TempDir
    char logdir[PATH_MAX];       // logs
    char ppddir[PATH_MAX];

    snprintf(serverroot, sizeof(serverroot), "%s/etc/cups", server_root);
    snprintf(serverbin, sizeof(serverbin), "%s/sbin", server_root);
    snprintf(requestroot, sizeof(requestroot), "%s/var/spool", server_root);
    snprintf(statedir, sizeof(statedir), "%s/var/run", server_root);
    snprintf(cachedir, sizeof(cachedir), "%s/var/cache", server_root);
    snprintf(tempdir, sizeof(tempdir), "%s/var/spool/tmp", server_root);
    snprintf(logdir, sizeof(logdir), "%s/var/log", server_root);
    snprintf(ppddir, sizeof(ppddir), "%s/ppd", serverroot);

    if (mkdirs(serverroot, 0755) != 0 || mkdirs(serverbin, 0755) != 0 ||
        mkdirs(requestroot, 0710) != 0 || mkdirs(statedir, 0755) != 0 ||
        mkdirs(cachedir, 0755) != 0 || mkdirs(tempdir, 01770) != 0 ||
        mkdirs(logdir, 0755) != 0 || mkdirs(ppddir, 0755) != 0)
    {
        set_last_error("start_cups_server: failed to create runtime dirs under %s: %s", server_root, strerror(errno));
        return -2;
    }

    // --- ServerBin symlink farm -> nativeLibraryDir/lib*.so ---
    build_symlink_farm(serverbin, native_lib_dir);

    // --- Pick a free localhost port ---
    int port = find_free_port();
    if (port <= 0)
    {
        set_last_error("start_cups_server: could not find a free localhost port");
        return -3;
    }

    // --- DataDir: cupsd wants <DataDir>/mime + <DataDir>/data; we extracted
    //     share/cups under data_dir. ---
    char datadir[PATH_MAX];
    snprintf(datadir, sizeof(datadir), "%s/share/cups", data_dir);
    // Fallback: if the caller already pointed data_dir at share/cups itself.
    {
        struct stat st;
        char mimecheck[PATH_MAX];
        snprintf(mimecheck, sizeof(mimecheck), "%s/mime", datadir);
        if (stat(mimecheck, &st) != 0)
        {
            snprintf(datadir, sizeof(datadir), "%s", data_dir);
        }
    }

    // --- Gutenprint driver data path (STP_DATA_PATH) ---
    // The DNP dye-sub filter (rastertogutenprint), backend (gutenprint53+usb) and
    // the PPD generator (cups-genppd) all read the gutenprint XML driver data via
    // the STP_DATA_PATH env var (libgutenprint stp_data_path(), path.c). It must
    // point at the dir that DIRECTLY contains xml-stamp + printers/dyesub.xml etc.
    // The Kotlin layer extracts it as a sibling of share/cups under the same
    // data_dir root, so it lives at <data_dir>/share/gutenprint/5.3/xml.
    //
    // cupsd does NOT inherit its own process env for filters/backends — it builds
    // a fixed common_env (scheduler/env.c). To propagate STP_DATA_PATH to the
    // forked filter/backend/genppd we must emit a `SetEnv` directive in
    // cups-files.conf (SetEnv/PassEnv live in cups-files.conf as of CUPS 2.x;
    // see scheduler/conf.c read_cups_files_conf).
    char stp_data_path[PATH_MAX];
    char setenv_line[PATH_MAX + 32];
    setenv_line[0] = '\0';
    snprintf(stp_data_path, sizeof(stp_data_path), "%s/share/gutenprint/5.3/xml", data_dir);
    {
        struct stat st;
        char stampcheck[PATH_MAX];
        snprintf(stampcheck, sizeof(stampcheck), "%s/xml-stamp", stp_data_path);
        if (stat(stampcheck, &st) == 0)
        {
            snprintf(setenv_line, sizeof(setenv_line), "SetEnv STP_DATA_PATH %s\n", stp_data_path);
            // Capture the PPD-generation context so generate_cups_dnp_ppd() can
            // (re)generate a PPD for ANY detected DNP model at runtime (per-model
            // PPDs), not only the representative DS620 emitted here at boot.
            snprintf(g_native_lib_dir, sizeof(g_native_lib_dir), "%s", native_lib_dir);
            snprintf(g_ppddir, sizeof(g_ppddir), "%s", ppddir);
            snprintf(g_stp_data_path, sizeof(g_stp_data_path), "%s", stp_data_path);
            // Best-effort: generate the representative DNP DS620 PPD on first
            // boot (genppd is arm64-only, so we can't pre-generate on the host).
            // The PPD lands at <ppddir>/stp-dnp-ds620.5.3.ppd; a queue is created
            // against it with device-uri gutenprint53+usb:... Non-fatal on failure.
            generate_dnp_ppd(native_lib_dir, ppddir, stp_data_path, "dnp-ds620");
        }
        else
            LOG("start_cups_server: gutenprint data not found at %s (DNP printing unavailable)", stp_data_path);
    }

    // --- USB fd delivery socket (PRINTING_FFI_USB_FD_SOCK) ---
    // The patched DNP backend connects to this AF_UNIX (filesystem) socket at job
    // dispatch to receive the app's USB fd via SCM_RIGHTS. We publish the canonical
    // path <server_root>/usbfd.sock so C (start_usb_fd_server / cups_usb_fd_sock_path),
    // the backend env, and the Kotlin caller all agree, and — like STP_DATA_PATH —
    // propagate it to the forked backend via a SetEnv line in cups-files.conf
    // (cupsd builds a fixed common_env; process env isn't inherited). We always emit
    // the env line (the app decides at runtime whether to actually serve an fd; if it
    // doesn't, the backend's connect() fails and it falls back to enumeration).
    snprintf(g_usb_fd_sock_path, sizeof(g_usb_fd_sock_path), "%s/usbfd.sock", server_root);
    char usbfd_setenv_line[PATH_MAX + 40];
    snprintf(usbfd_setenv_line, sizeof(usbfd_setenv_line), "SetEnv PRINTING_FFI_USB_FD_SOCK %s\n", g_usb_fd_sock_path);

    // --- cups-files.conf ---
    // KNOWN HARD PART: at app uid there is usually no passwd name, so use numeric
    // "User #<uid>" / "Group #<gid>". cupsd is non-root so it never setuids; the
    // directive is only used for the (skipped) privilege drop + ownership checks.
    // --- DocumentRoot for the web interface (only if the extracted docroot exists) ---
    // cupsd serves static files (index.html, css, images) from DocumentRoot; the
    // CGIs reference /cups.css, /images/... relative to it. Empty = web UI static
    // assets unavailable (CGIs still run, just unstyled).
    char docroot_line[PATH_MAX + 32];
    docroot_line[0] = '\0';
    if (doc_root && doc_root[0])
    {
        struct stat st;
        if (stat(doc_root, &st) == 0 && S_ISDIR(st.st_mode))
            snprintf(docroot_line, sizeof(docroot_line), "DocumentRoot %s\n", doc_root);
        else
            LOG("start_cups_server: doc_root '%s' not a dir; web UI will be unstyled", doc_root);
    }

    char files_conf_path[PATH_MAX];
    snprintf(files_conf_path, sizeof(files_conf_path), "%s/cups-files.conf", serverroot);
    {
        char buf[4096];
        snprintf(buf, sizeof(buf),
                 "User #%d\n"
                 "Group #%d\n"
                 "SystemGroup #%d\n"
                 "ServerRoot   %s\n"
                 "ServerBin    %s\n"
                 "DataDir      %s\n"
                 "%s"
                 "%s"
                 "%s"
                 "RequestRoot  %s\n"
                 "StateDir     %s\n"
                 "CacheDir     %s\n"
                 "TempDir      %s\n"
                 "AccessLog    %s/access_log\n"
                 "ErrorLog     %s/error_log\n"
                 "PageLog      %s/page_log\n"
                 "FileDevice Yes\n",
                 (int)uid, (int)gid, (int)gid,
                 serverroot, serverbin, datadir, docroot_line, setenv_line, usbfd_setenv_line, requestroot, statedir, cachedir, tempdir,
                 logdir, logdir, logdir);
        if (write_file(files_conf_path, buf) != 0)
        {
            set_last_error("start_cups_server: failed to write %s: %s", files_conf_path, strerror(errno));
            return -4;
        }
    }

    // --- cupsd.conf ---
    char cupsd_conf_path[PATH_MAX];
    snprintf(cupsd_conf_path, sizeof(cupsd_conf_path), "%s/cupsd.conf", serverroot);
    {
        char buf[4096];
        snprintf(buf, sizeof(buf),
                 "LogLevel debug\n"
                 "MaxLogSize 10m\n"
                 "Listen 127.0.0.1:%d\n"
                 "Browsing Off\n"
                 "DefaultAuthType None\n"
                 "WebInterface Yes\n"
                 "ErrorPolicy retry-job\n"
                 "<Location />\n"
                 "  Order allow,deny\n"
                 "  Allow from all\n"
                 "</Location>\n"
                 "<Location /admin>\n"
                 "  Order allow,deny\n"
                 "  Allow from all\n"
                 "</Location>\n"
                 "<Location /admin/conf>\n"
                 "  Order allow,deny\n"
                 "  Allow from all\n"
                 "</Location>\n"
                 "<Policy default>\n"
                 "  JobPrivateAccess all\n"
                 "  JobPrivateValues none\n"
                 "  SubscriptionPrivateAccess all\n"
                 "  SubscriptionPrivateValues none\n"
                 "  <Limit All>\n"
                 "    Order allow,deny\n"
                 "    Allow from all\n"
                 "  </Limit>\n"
                 "</Policy>\n",
                 port);
        if (write_file(cupsd_conf_path, buf) != 0)
        {
            set_last_error("start_cups_server: failed to write %s: %s", cupsd_conf_path, strerror(errno));
            return -5;
        }
    }

    // --- cupsd executable (extracted lib in nativeLibraryDir) ---
    char cupsd_bin[PATH_MAX];
    snprintf(cupsd_bin, sizeof(cupsd_bin), "%s/libcupsd.so", native_lib_dir);
    {
        struct stat st;
        if (stat(cupsd_bin, &st) != 0)
        {
            set_last_error("start_cups_server: cupsd binary not found at %s: %s", cupsd_bin, strerror(errno));
            return -6;
        }
    }

    // --- fork + execv cupsd in the foreground (-f) ---
    pid_t pid = fork();
    if (pid < 0)
    {
        set_last_error("start_cups_server: fork failed: %s", strerror(errno));
        return -7;
    }
    if (pid == 0)
    {
        // Child: exec cupsd. -f = foreground (don't daemonize), -c/-s = configs.
        char *const argv[] = {
            cupsd_bin,
            (char *)"-f",
            (char *)"-c", cupsd_conf_path,
            (char *)"-s", files_conf_path,
            NULL};
        execv(cupsd_bin, argv);
        // If execv returns it failed.
        _exit(127);
    }

    // Parent.
    g_cupsd_pid = pid;
    g_cupsd_port = port;
    LOG("start_cups_server: forked cupsd pid=%d on 127.0.0.1:%d", (int)pid, port);

    // Wait for cupsd to answer on the port.
    if (!wait_for_port(port, 8000))
    {
        set_last_error("start_cups_server: cupsd did not answer on 127.0.0.1:%d within timeout (check error_log under %s)", port, logdir);
        // Try to clean up if it's still around.
        if (g_cupsd_pid > 0)
        {
            kill(g_cupsd_pid, SIGTERM);
        }
        return -8;
    }

    // Point the libcups client at our in-app cupsd.
    cupsSetServer("127.0.0.1"); // sets server; port is taken from CUPS_SERVER/ippPort below
    // cupsSetServer parses host[:port] — pass host:port so ippPort() resolves too.
    {
        char hostport[64];
        snprintf(hostport, sizeof(hostport), "127.0.0.1:%d", port);
        cupsSetServer(hostport);
        // Belt-and-suspenders: also set CUPS_SERVER for any code path reading env.
        setenv("CUPS_SERVER", hostport, 1);
    }

    LOG("start_cups_server: SUCCESS, cupsd up on 127.0.0.1:%d (client targeted)", port);
    return port;
}

FFI_PLUGIN_EXPORT void stop_cups_server(void)
{
    if (g_cupsd_pid > 0)
    {
        LOG("stop_cups_server: terminating cupsd pid=%d", (int)g_cupsd_pid);
        kill(g_cupsd_pid, SIGTERM);
        int status = 0;
        // Give it a moment to exit cleanly, then reap.
        for (int i = 0; i < 20; i++)
        {
            if (waitpid(g_cupsd_pid, &status, WNOHANG) == g_cupsd_pid)
            {
                g_cupsd_pid = 0;
                g_cupsd_port = 0;
                return;
            }
            usleep(100 * 1000);
        }
        // Force kill if still alive.
        kill(g_cupsd_pid, SIGKILL);
        waitpid(g_cupsd_pid, &status, 0);
        g_cupsd_pid = 0;
        g_cupsd_port = 0;
    }
}

// --- USB fd delivery server -------------------------------------------------
//
// Hands the app's live USB fd to the forked DNP backend over an AF_UNIX socket
// via SCM_RIGHTS. See the header for the full contract.

// Server state (single active server at a time — one printer).
// NOTE: Android's bionic has NO pthread cancellation (pthread_cancel etc. are
// absent), so clean shutdown is done by g_usbfd_stop + closing the listen fd,
// which makes the blocked accept() return; the thread then observes the flag/EBADF
// and exits, and stop_usb_fd_server joins it.
static int g_usbfd_listen_fd = -1;    // listening AF_UNIX socket, -1 = none
static int g_usbfd_source_fd = -1;    // long-lived USB fd owned by caller (NOT ours to close)
static pthread_t g_usbfd_thread;      // accept loop thread
static volatile bool g_usbfd_thread_running = false;
static volatile bool g_usbfd_stop = false;      // set by stop to unwind the loop
static char g_usbfd_bound_path[PATH_MAX] = {0}; // path we bound (for unlink on stop)

// Send exactly one payload byte + a SCM_RIGHTS control message carrying a single
// int fd over `conn_fd`. This is the exact cmsg layout the patched backend's
// printing_ffi_recv_fd() expects (1 data byte + CMSG_LEN(sizeof(int))). Returns 0
// on success, -1 on failure. SIGPIPE is suppressed per-call via MSG_NOSIGNAL.
static int usbfd_send_one(int conn_fd, int fd_to_send)
{
    char dummy = 'F'; // >= 1 data byte; the backend reads (and ignores) it
    struct iovec iov;
    iov.iov_base = &dummy;
    iov.iov_len = 1;

    union
    {
        char buf[CMSG_SPACE(sizeof(int))];
        struct cmsghdr align;
    } cmsgu;
    memset(&cmsgu, 0, sizeof(cmsgu));

    struct msghdr msg;
    memset(&msg, 0, sizeof(msg));
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    msg.msg_control = cmsgu.buf;
    msg.msg_controllen = sizeof(cmsgu.buf);

    struct cmsghdr *cmsg = CMSG_FIRSTHDR(&msg);
    cmsg->cmsg_level = SOL_SOCKET;
    cmsg->cmsg_type = SCM_RIGHTS;
    cmsg->cmsg_len = CMSG_LEN(sizeof(int));
    memcpy(CMSG_DATA(cmsg), &fd_to_send, sizeof(int));
    // Match msg_controllen to the actual cmsg length we filled.
    msg.msg_controllen = cmsg->cmsg_len;

    ssize_t n;
    do
    {
        n = sendmsg(conn_fd, &msg, MSG_NOSIGNAL);
    } while (n < 0 && errno == EINTR);

    return (n >= 1) ? 0 : -1;
}

// Accept loop: for each backend connection, dup the live USB fd and send it via
// SCM_RIGHTS, then close the accepted conn. dup() because libusb (in the backend)
// closes the wrapped fd at job end — our source fd must survive across jobs.
static void *usbfd_accept_thread(void *arg)
{
    // The listen fd is captured by value at start: stop_usb_fd_server closes it to
    // unblock accept(), which then returns EBADF/EINVAL and we exit the loop.
    int listen_fd = (int)(intptr_t)arg;

    for (;;)
    {
        int conn = accept(listen_fd, NULL, NULL);
        if (conn < 0)
        {
            if (errno == EINTR && !g_usbfd_stop)
                continue;
            // Listen fd closed by stop (EBADF/EINVAL) or fatal error -> exit.
            break;
        }
        if (g_usbfd_stop)
        {
            close(conn);
            break;
        }

        int dup_fd = dup(g_usbfd_source_fd);
        if (dup_fd < 0)
        {
            LOG("usbfd: dup(usb_fd=%d) failed: %s", g_usbfd_source_fd, strerror(errno));
            close(conn);
            continue;
        }

        if (usbfd_send_one(conn, dup_fd) != 0)
            LOG("usbfd: sendmsg(SCM_RIGHTS) failed: %s", strerror(errno));
        else
            LOG("usbfd: delivered dup(fd=%d) to backend", g_usbfd_source_fd);

        // We own the dup; libusb in the backend owns its received copy. Close ours.
        close(dup_fd);
        close(conn);
    }
    return NULL;
}

FFI_PLUGIN_EXPORT int start_usb_fd_server(const char *sock_path, int usb_fd)
{
    set_last_error("");

    if (!sock_path || !sock_path[0])
    {
        set_last_error("start_usb_fd_server: sock_path required");
        return -1;
    }
    if (usb_fd < 0)
    {
        set_last_error("start_usb_fd_server: usb_fd (%d) invalid", usb_fd);
        return -1;
    }
    if (strlen(sock_path) >= sizeof(((struct sockaddr_un *)0)->sun_path))
    {
        set_last_error("start_usb_fd_server: sock_path too long (%zu >= %zu)",
                       strlen(sock_path), sizeof(((struct sockaddr_un *)0)->sun_path));
        return -1;
    }

    // One active server at a time: replace any existing one.
    if (g_usbfd_thread_running || g_usbfd_listen_fd >= 0)
        stop_usb_fd_server();

    // Process-wide: never die from a write to a peer that closed early.
    signal(SIGPIPE, SIG_IGN);

    int lfd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (lfd < 0)
    {
        set_last_error("start_usb_fd_server: socket() failed: %s", strerror(errno));
        return -1;
    }

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);

    unlink(sock_path); // stale socket from a prior run; ignore errors

    if (bind(lfd, (struct sockaddr *)&addr, sizeof(addr)) != 0)
    {
        set_last_error("start_usb_fd_server: bind(%s) failed: %s", sock_path, strerror(errno));
        close(lfd);
        return -1;
    }
    if (listen(lfd, 4) != 0)
    {
        set_last_error("start_usb_fd_server: listen(%s) failed: %s", sock_path, strerror(errno));
        close(lfd);
        unlink(sock_path);
        return -1;
    }

    g_usbfd_listen_fd = lfd;
    g_usbfd_source_fd = usb_fd; // caller owns it; we only dup() from it
    g_usbfd_stop = false;
    snprintf(g_usbfd_bound_path, sizeof(g_usbfd_bound_path), "%s", sock_path);

    int rc = pthread_create(&g_usbfd_thread, NULL, usbfd_accept_thread, (void *)(intptr_t)lfd);
    if (rc != 0)
    {
        set_last_error("start_usb_fd_server: pthread_create failed: %s", strerror(rc));
        close(lfd);
        unlink(sock_path);
        g_usbfd_listen_fd = -1;
        g_usbfd_source_fd = -1;
        g_usbfd_bound_path[0] = '\0';
        return -1;
    }
    g_usbfd_thread_running = true;

    LOG("start_usb_fd_server: serving usb_fd=%d on %s", usb_fd, sock_path);
    return 0;
}

FFI_PLUGIN_EXPORT void stop_usb_fd_server(void)
{
    // Signal stop, then close the listen fd so the blocked accept() returns; the
    // thread observes the flag / the closed fd and exits its loop, and we join it.
    // (bionic has no pthread_cancel, so this is the only clean way to unwind.)
    g_usbfd_stop = true;
    int lfd = g_usbfd_listen_fd;
    g_usbfd_listen_fd = -1;
    if (lfd >= 0)
        close(lfd);

    if (g_usbfd_thread_running)
    {
        pthread_join(g_usbfd_thread, NULL);
        g_usbfd_thread_running = false;
    }
    g_usbfd_stop = false;

    if (g_usbfd_bound_path[0])
    {
        unlink(g_usbfd_bound_path);
        g_usbfd_bound_path[0] = '\0';
    }

    // Do NOT close g_usbfd_source_fd — it is owned by the Kotlin/UsbDeviceConnection
    // layer. We only ever closed the dups we created.
    g_usbfd_source_fd = -1;
}

FFI_PLUGIN_EXPORT const char *cups_usb_fd_sock_path(void)
{
    return g_usb_fd_sock_path[0] ? g_usb_fd_sock_path : NULL;
}

// generate_cups_dnp_ppd: generate (if not already present) a Gutenprint PPD for a
// specific DNP/Citizen dye-sub driver and return its ABSOLUTE on-device path, so the
// caller can hand that path straight to add_cups_printer (which uploads the PPD file
// directly, avoiding cups-driverd). `driver` is the Gutenprint driver id — which is
// exactly the DnpUsbManager "make" string, e.g. "dnp-dsrx1", "dnp-ds620", "dnp-ds820"
// (see src/xml/printers/dyesub.xml <printer driver="..."/>). Returns a pointer to a
// static buffer with the PPD path on success, or NULL on failure (get_last_error).
// Requires start_cups_server to have run (needs the captured PPD context).
FFI_PLUGIN_EXPORT const char *generate_cups_dnp_ppd(const char *driver)
{
    set_last_error("");
    if (!driver || !*driver)
    {
        set_last_error("generate_cups_dnp_ppd: driver id is required");
        return NULL;
    }
    if (!g_ppddir[0] || !g_native_lib_dir[0] || !g_stp_data_path[0])
    {
        set_last_error("generate_cups_dnp_ppd: PPD context not ready (start_cups_server not run / gutenprint data missing)");
        return NULL;
    }
    // Reject anything that isn't a plain driver token (no path separators / traversal)
    // — genppd takes it as a model id, and it becomes part of the output filename.
    if (strchr(driver, '/') != NULL || strstr(driver, "..") != NULL)
    {
        set_last_error("generate_cups_dnp_ppd: invalid driver id '%s'", driver);
        return NULL;
    }

    if (generate_dnp_ppd(g_native_lib_dir, g_ppddir, g_stp_data_path, driver) != 0)
    {
        set_last_error("generate_cups_dnp_ppd: could not generate PPD for driver '%s' (see log)", driver);
        return NULL;
    }
    snprintf(g_dnp_ppd_path, sizeof(g_dnp_ppd_path), "%s/stp-%s.5.3.ppd", g_ppddir, driver);
    LOG("generate_cups_dnp_ppd: driver=%s -> %s", driver, g_dnp_ppd_path);
    return g_dnp_ppd_path;
}

#else // not Android

FFI_PLUGIN_EXPORT int32_t start_cups_server(const char *server_root, const char *native_lib_dir, const char *data_dir, const char *doc_root)
{
    (void)server_root;
    (void)native_lib_dir;
    (void)data_dir;
    (void)doc_root;
    set_last_error("start_cups_server is only supported on Android");
    return -1;
}

FFI_PLUGIN_EXPORT void stop_cups_server(void)
{
    // no-op off Android
}

FFI_PLUGIN_EXPORT int start_usb_fd_server(const char *sock_path, int usb_fd)
{
    (void)sock_path;
    (void)usb_fd;
    set_last_error("start_usb_fd_server is only supported on Android");
    return -1;
}

FFI_PLUGIN_EXPORT void stop_usb_fd_server(void)
{
    // no-op off Android
}

FFI_PLUGIN_EXPORT const char *cups_usb_fd_sock_path(void)
{
    return NULL;
}

FFI_PLUGIN_EXPORT const char *generate_cups_dnp_ppd(const char *driver)
{
    (void)driver;
    set_last_error("generate_cups_dnp_ppd is only supported on Android");
    return NULL;
}

#endif // __ANDROID__

// add_cups_printer: CUPS-Add-Modify-Printer over IPP against the current server
// (which on Android is the in-app cupsd targeted by start_cups_server). Available
// on all CUPS platforms (macOS/Linux/Android). On Windows it is unsupported.
FFI_PLUGIN_EXPORT bool add_cups_printer(const char *name, const char *device_uri, const char *ppd_or_model)
{
#ifdef _WIN32
    (void)name;
    (void)device_uri;
    (void)ppd_or_model;
    set_last_error("add_cups_printer is not supported on Windows");
    return false;
#else
    set_last_error("");
    if (!name || !device_uri)
    {
        set_last_error("add_cups_printer: name and device_uri are required");
        return false;
    }

    LOG("add_cups_printer: name=%s device_uri=%s model=%s", name, device_uri,
        ppd_or_model ? ppd_or_model : "(null)");

    // Build the printer-uri for the admin op: ipp://<server>:<port>/printers/<name>
    char printer_uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, printer_uri, sizeof(printer_uri), "ipp", NULL,
                     cupsServer(), ippPort(), "/printers/%s", name);

    http_t *http = httpConnectEncrypt(cupsServer(), ippPort(), HTTP_ENCRYPT_IF_REQUESTED);
    if (!http)
    {
        set_last_error("add_cups_printer: failed to connect to CUPS server %s:%d", cupsServer(), ippPort());
        return false;
    }

    ipp_t *request = ippNewRequest(IPP_OP_CUPS_ADD_MODIFY_PRINTER);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, printer_uri);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, cupsUser());
    // Printer state: idle + accepting jobs + enabled.
    ippAddInteger(request, IPP_TAG_PRINTER, IPP_TAG_ENUM, "printer-state", IPP_PSTATE_IDLE);
    ippAddBoolean(request, IPP_TAG_PRINTER, "printer-is-accepting-jobs", 1);
    ippAddString(request, IPP_TAG_PRINTER, IPP_TAG_URI, "device-uri", NULL, device_uri);

    // Model / interface. Three cases:
    //  (1) ppd_or_model is an ABSOLUTE path to a readable .ppd file -> upload the PPD
    //      FILE directly via cupsDoFileRequest (the `lpadmin -P file.ppd` mechanism).
    //      This installs the queue from the exact PPD and does NOT invoke cups-driverd
    //      to resolve a ppd-name — critical on Android, where cups-driverd resolution
    //      is slow/fragile. We set NO ppd-name in this branch.
    //  (2) NULL/empty/"raw" -> a raw queue (ppd-name=raw).
    //  (3) otherwise -> a ppd-name string, resolved server-side by cups-driverd.
    const char *model = (ppd_or_model && *ppd_or_model) ? ppd_or_model : "raw";
    const char *ppd_file = NULL;
    {
        // Treat as a PPD file only if it's an absolute path ending in .ppd that we
        // can actually read. Guarded so bare model strings / "raw" fall through.
        size_t mlen = strlen(model);
        if (model[0] == '/' && mlen > 4 &&
            strcmp(model + mlen - 4, ".ppd") == 0 &&
            access(model, R_OK) == 0)
        {
            ppd_file = model;
        }
    }

    if (ppd_file == NULL)
    {
        if (strcmp(model, "raw") == 0)
        {
            ippAddString(request, IPP_TAG_PRINTER, IPP_TAG_NAME, "ppd-name", NULL, "raw");
        }
        else
        {
            ippAddString(request, IPP_TAG_PRINTER, IPP_TAG_NAME, "ppd-name", NULL, model);
        }
    }
    // else: no ppd-name; the PPD file is sent as the request body below.

    ipp_t *response = ppd_file
                          ? cupsDoFileRequest(http, request, "/admin/", ppd_file)
                          : cupsDoRequest(http, request, "/admin/");
    if (!response)
    {
        set_last_error("add_cups_printer: CUPS-Add-Modify-Printer failed: %s", cupsLastErrorString());
        httpClose(http);
        return false;
    }

    ipp_status_t status = ippGetStatusCode(response);
    bool ok = (status <= IPP_OK_CONFLICT);
    if (!ok)
    {
        set_last_error("add_cups_printer: CUPS-Add-Modify-Printer status %s: %s",
                       ippErrorString(status), cupsLastErrorString());
    }
    ippDelete(response);
    httpClose(http);

    if (ok)
        LOG("add_cups_printer: SUCCESS for '%s'%s", name,
            ppd_file ? " (uploaded PPD file, no cups-driverd)" : "");
    return ok;
#endif
}

// remove_cups_printer: CUPS-Delete-Printer over IPP against the current server
// (which on Android is the in-app cupsd targeted by start_cups_server). Mirrors
// add_cups_printer's style. Available on all CUPS platforms; unsupported on Windows.
FFI_PLUGIN_EXPORT bool remove_cups_printer(const char *name)
{
#ifdef _WIN32
    (void)name;
    set_last_error("remove_cups_printer is not supported on Windows");
    return false;
#else
    set_last_error("");
    if (!name || !*name)
    {
        set_last_error("remove_cups_printer: name is required");
        return false;
    }

    LOG("remove_cups_printer: name=%s", name);

    // Build the printer-uri for the admin op: ipp://<server>:<port>/printers/<name>
    char printer_uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, printer_uri, sizeof(printer_uri), "ipp", NULL,
                     cupsServer(), ippPort(), "/printers/%s", name);

    http_t *http = httpConnectEncrypt(cupsServer(), ippPort(), HTTP_ENCRYPT_IF_REQUESTED);
    if (!http)
    {
        set_last_error("remove_cups_printer: failed to connect to CUPS server %s:%d", cupsServer(), ippPort());
        return false;
    }

    ipp_t *request = ippNewRequest(IPP_OP_CUPS_DELETE_PRINTER);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, printer_uri);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, cupsUser());

    ipp_t *response = cupsDoRequest(http, request, "/admin/");
    if (!response)
    {
        set_last_error("remove_cups_printer: CUPS-Delete-Printer failed: %s", cupsLastErrorString());
        httpClose(http);
        return false;
    }

    ipp_status_t status = ippGetStatusCode(response);
    // Treat "not found" as success (idempotent removal on detach).
    bool ok = (status <= IPP_OK_CONFLICT) || (status == IPP_STATUS_ERROR_NOT_FOUND);
    if (!ok)
    {
        set_last_error("remove_cups_printer: CUPS-Delete-Printer status %s: %s",
                       ippErrorString(status), cupsLastErrorString());
    }
    ippDelete(response);
    httpClose(http);

    if (ok)
        LOG("remove_cups_printer: SUCCESS for '%s'", name);
    return ok;
#endif
}

FFI_PLUGIN_EXPORT bool print_pdf(const char *printer_name, const char *pdf_file_path, const char *doc_name, int scaling_mode, int copies, const char *page_range, int num_options, const char **option_keys, const char **option_values, const char *alignment)
{

    // Validate input parameters
    if (!printer_name || !pdf_file_path || !doc_name || copies <= 0)
    {
        LOG("Invalid input parameters");
        return false;
    }

#ifdef _WIN32
    return _print_pdf_job_win(printer_name, pdf_file_path, doc_name, scaling_mode, copies, page_range, alignment, num_options, option_keys, option_values, false) == 1;
#else // macOS / Linux (CUPS)
    cups_option_t *options = NULL;
    int num_cups_options = 0;

    for (int i = 0; i < num_options; i++)
    {
        if (option_keys && option_keys[i] && option_values && option_values[i])
        {
            num_cups_options = cupsAddOption(option_keys[i], option_values[i], num_cups_options, &options);
        }
    }

    int job_id = cupsPrintFile(printer_name, pdf_file_path, doc_name, num_cups_options, options);
    if (job_id <= 0)
    {
        LOG("cupsPrintFile failed, error: %s", cupsLastErrorString());
    }
    cupsFreeOptions(num_cups_options, options);
    return job_id > 0;
#endif
}

FFI_PLUGIN_EXPORT JobList *get_print_jobs(const char *printer_name)
{
    JobList *list = (JobList *)malloc(sizeof(JobList));
    if (!list)
        return NULL;
    list->count = 0;
    list->jobs = NULL;

    if (!printer_name)
    {
        return list; // Return empty list
    }

#ifdef _WIN32
    HANDLE hPrinter;
    DWORD needed, returned;

    wchar_t *printer_name_w = to_utf16(printer_name);
    if (!printer_name_w)
    {
        free(list);
        return NULL;
    }
    if (!OpenPrinterW(printer_name_w, &hPrinter, NULL))
    {
        free(list);
        LOG("OpenPrinterW failed with error %lu", GetLastError());
        free(printer_name_w);
        return NULL;
    }

    EnumJobsW(hPrinter, 0, 0xFFFFFFFF, 2, NULL, 0, &needed, &returned);
    if (needed == 0)
    {
        ClosePrinter(hPrinter);
        free(printer_name_w);
        return list;
    }
    BYTE *buffer = (BYTE *)malloc(needed);
    if (!buffer)
    {
        ClosePrinter(hPrinter);
        free(printer_name_w);
        free(list);
        return NULL;
    }

    if (EnumJobsW(hPrinter, 0, 0xFFFFFFFF, 2, buffer, needed, &needed, &returned))
    {
        LOG("Found %lu jobs on Windows", returned);
        list->count = (int)returned;
        list->jobs = (JobInfo *)malloc(returned * sizeof(JobInfo));
        if (!list->jobs)
        {
            free(buffer);
            ClosePrinter(hPrinter);
            free(printer_name_w);
            free(list);
            return NULL;
        }
        JOB_INFO_2W *jobs = (JOB_INFO_2W *)buffer;
        for (DWORD i = 0; i < returned; i++)
        {
            list->jobs[i].id = jobs[i].JobId;
            list->jobs[i].title = to_utf8(jobs[i].pDocument);
            list->jobs[i].status = (int)jobs[i].Status;
        }
    }
    else
    {
        LOG("EnumJobsW failed with error %lu", GetLastError());
    }
    free(buffer);
    free(printer_name_w);
    ClosePrinter(hPrinter);
    return list;
#else // macOS / Linux
    cups_job_t *jobs;
    // Query ALL users' jobs (my_jobs = 0), not only the querying CUPS user's.
    // The host app may run as a root daemon whose CUPS user does not match the
    // job's recorded owner; with my_jobs = 1 those jobs are invisible, so a
    // caller correlating jobs (e.g. by title/token) never sees them advance and
    // the queue appears frozen. CUPS_WHICHJOBS_ALL (vs ACTIVE) additionally
    // returns COMPLETED jobs so the caller can observe a job reach the
    // `completed` state instead of having it silently vanish from the list.
    // Safe: callers already filter the returned list by their own job title.
    int num_jobs = cupsGetJobs(&jobs, printer_name, 0, CUPS_WHICHJOBS_ALL);
    if (num_jobs <= 0)
    {
        cupsFreeJobs(num_jobs, jobs);
        return list;
    }

    list->count = num_jobs;
    list->jobs = (JobInfo *)malloc(num_jobs * sizeof(JobInfo));
    if (!list->jobs)
    {
        cupsFreeJobs(num_jobs, jobs);
        free(list);
        return NULL;
    }

    for (int i = 0; i < num_jobs; i++)
    {
        list->jobs[i].id = (uint32_t)jobs[i].id;
        list->jobs[i].title = strdup(jobs[i].title ? jobs[i].title : "Unknown");
        list->jobs[i].status = jobs[i].state;
    }
    cupsFreeJobs(num_jobs, jobs);
    return list;
#endif
}

FFI_PLUGIN_EXPORT void free_job_list(JobList *job_list)
{
    if (!job_list)
        return;
    if (job_list->jobs)
    {
        for (int i = 0; i < job_list->count; i++)
        {
            free(job_list->jobs[i].title);
        }
        free(job_list->jobs);
    }
    free(job_list);
}

FFI_PLUGIN_EXPORT int open_printer_properties(const char *printer_name, intptr_t hwnd)
{
#ifdef _WIN32
    if (!printer_name)
    {
        LOG("Printer name is null");
        return 0; // Error
    }

    wchar_t *printer_name_w = to_utf16(printer_name);
    if (!printer_name_w)
    {
        LOG("Failed to convert printer name to UTF-16");
        return 0; // Error
    }

    HANDLE hPrinter;
    PRINTER_DEFAULTSW printerDefaults = {NULL, NULL, PRINTER_ALL_ACCESS};
    if (!OpenPrinterW(printer_name_w, &hPrinter, &printerDefaults))
    {
        LOG("OpenPrinterW failed with error %lu", GetLastError());
        free(printer_name_w);
        return 0; // Error
    }

    // The modern and recommended way to show the printer properties dialog is
    // by using DocumentProperties with the DM_PROMPT flag.

    // First, get the size of the DEVMODE structure for the printer.
    LONG devModeSize = DocumentPropertiesW(NULL, hPrinter, printer_name_w, NULL, NULL, 0);
    if (devModeSize <= 0)
    {
        LOG("DocumentProperties (get size) failed with error %lu", GetLastError());
        ClosePrinter(hPrinter);
        free(printer_name_w);
        return 0; // Error
    }

    DEVMODEW *pDevMode = (DEVMODEW *)malloc(devModeSize);
    if (!pDevMode)
    {
        LOG("Failed to allocate memory for DEVMODE structure.");
        ClosePrinter(hPrinter);
        free(printer_name_w);
        return 0; // Error
    }

    // Get the current printer settings to populate the dialog.
    if (DocumentPropertiesW(NULL, hPrinter, printer_name_w, pDevMode, NULL, DM_OUT_BUFFER) != IDOK)
    {
        LOG("DocumentProperties (get defaults) failed with error %lu", GetLastError());
        free(pDevMode);
        ClosePrinter(hPrinter);
        free(printer_name_w);
        return 0; // Error
    }

    // Display the properties dialog. The user's changes will be written back to pDevMode.
    LONG result = DocumentPropertiesW((HWND)hwnd, hPrinter, printer_name_w, pDevMode, pDevMode, DM_IN_BUFFER | DM_OUT_BUFFER | DM_PROMPT);

    int return_status = 0; // Default to error

    if (result == IDOK)
    {
        LOG("Printer properties dialog closed with OK. Applying changes to printer defaults.");

        // To apply the changes, we need to use SetPrinter with PRINTER_INFO_2.
        DWORD needed = 0;
        // Get the size needed for PRINTER_INFO_2
        GetPrinterW(hPrinter, 2, NULL, 0, &needed);
        if (needed > 0)
        {
            PRINTER_INFO_2W *pinfo2 = (PRINTER_INFO_2W *)malloc(needed);
            if (pinfo2)
            {
                // Get the current printer info
                if (GetPrinterW(hPrinter, 2, (LPBYTE)pinfo2, needed, &needed))
                {
                    // Update the DEVMODE pointer in the PRINTER_INFO_2 struct with the user's changes.
                    pinfo2->pDevMode = pDevMode;
                    // Security descriptor must be NULL for SetPrinter.
                    pinfo2->pSecurityDescriptor = NULL;

                    // Apply the changes to the printer's defaults.
                    if (!SetPrinterW(hPrinter, 2, (LPBYTE)pinfo2, 0))
                    {
                        LOG("SetPrinterW failed with error %lu", GetLastError());
                    }
                    else
                    {
                        LOG("SetPrinterW succeeded. Broadcasting change.");
                        SendMessageTimeout(HWND_BROADCAST, WM_WININICHANGE, 0, (LPARAM)L"windows", SMTO_NORMAL, 1000, NULL);
                    }
                }
                free(pinfo2);
            }
        }
        return_status = 1; // OK
    }
    else if (result == IDCANCEL)
    {
        LOG("Printer properties dialog was cancelled.");
        return_status = 2; // Cancel
    }
    else
    {
        LOG("DocumentProperties (prompt) failed with result: %ld, error: %lu", result, GetLastError());
        return_status = 0; // Error
    }

    free(pDevMode);
    ClosePrinter(hPrinter);
    free(printer_name_w);
    return return_status;
#elif defined(__ANDROID__)
    // No xdg-open / desktop browser on Android. The CUPS web interface is also
    // disabled in the bundled cupsd config. Not supported here.
    (void)hwnd;
    (void)printer_name;
    LOG("open_printer_properties is not supported on Android");
    return 0; // Error / unsupported
#else
    (void)hwnd; // hwnd is Windows-specific
    if (!printer_name)
    {
        LOG("Printer name is null");
        return 0; // Error
    }
    char command[PATH_MAX];
    snprintf(command, sizeof(command),
#ifdef __APPLE__
             "open http://localhost:631/printers/\"%s\"",
#else // Linux
             "xdg-open http://localhost:631/printers/\"%s\"",
#endif
             printer_name);
    LOG("Executing command: %s", command);
    int cmd_result = system(command);
    if (cmd_result != 0)
    {
        LOG("Command '%s' failed with exit code %d", command, cmd_result);
        return 0; // Error
    }
    return 1; // Dispatched
#endif
}

FFI_PLUGIN_EXPORT bool pause_print_job(const char *printer_name, uint32_t job_id)
{
    if (!printer_name)
    {
        return false;
    }

#ifdef _WIN32
    HANDLE hPrinter;
    wchar_t *printer_name_w = to_utf16(printer_name);
    if (!printer_name_w)
        return false;
    if (!OpenPrinterW(printer_name_w, &hPrinter, NULL))
    {
        free(printer_name_w);
        return false;
    }
    free(printer_name_w);

    bool result = SetJobW(hPrinter, job_id, 0, NULL, JOB_CONTROL_PAUSE);
    if (!result)
        LOG("SetJobW(PAUSE) failed with error %lu", GetLastError());
    ClosePrinter(hPrinter);
    return result;
#else
    bool result = cupsCancelJob2(CUPS_HTTP_DEFAULT, printer_name, (int)job_id, IPP_HOLD_JOB) == 1;
    if (!result)
        LOG("cupsCancelJob2(IPP_HOLD_JOB) failed, error: %s", cupsLastErrorString());
    return result;
#endif
}

FFI_PLUGIN_EXPORT bool resume_print_job(const char *printer_name, uint32_t job_id)
{
    if (!printer_name)
    {
        return false;
    }

#ifdef _WIN32
    HANDLE hPrinter;
    wchar_t *printer_name_w = to_utf16(printer_name);
    if (!printer_name_w)
        return false;
    if (!OpenPrinterW(printer_name_w, &hPrinter, NULL))
    {
        free(printer_name_w);
        return false;
    }
    free(printer_name_w);

    bool result = SetJobW(hPrinter, job_id, 0, NULL, JOB_CONTROL_RESUME);
    if (!result)
        LOG("SetJobW(RESUME) failed with error %lu", GetLastError());
    ClosePrinter(hPrinter);
    return result;
#else
    bool result = cupsCancelJob2(CUPS_HTTP_DEFAULT, printer_name, (int)job_id, IPP_RELEASE_JOB) == 1;
    if (!result)
        LOG("cupsCancelJob2(IPP_RELEASE_JOB) failed, error: %s", cupsLastErrorString());
    return result;
#endif
}

FFI_PLUGIN_EXPORT bool cancel_print_job(const char *printer_name, uint32_t job_id)
{
    if (!printer_name)
    {
        return false;
    }

#ifdef _WIN32
    HANDLE hPrinter;
    wchar_t *printer_name_w = to_utf16(printer_name);
    if (!printer_name_w)
        return false;
    if (!OpenPrinterW(printer_name_w, &hPrinter, NULL))
    {
        free(printer_name_w);
        return false;
    }
    free(printer_name_w);

    bool result = SetJobW(hPrinter, job_id, 0, NULL, JOB_CONTROL_CANCEL);
    if (!result)
        LOG("SetJobW(CANCEL) failed with error %lu", GetLastError());
    ClosePrinter(hPrinter);
    return result;
#else
    bool result = cupsCancelJob(printer_name, (int)job_id) == 1;
    if (!result)
        LOG("cupsCancelJob failed, error: %s", cupsLastErrorString());
    return result;
#endif
}

FFI_PLUGIN_EXPORT CupsOptionList *get_supported_cups_options(const char *printer_name)
{
    if (!printer_name)
    {
        CupsOptionList *list = (CupsOptionList *)malloc(sizeof(CupsOptionList));
        if (list)
        {
            list->count = 0;
            list->options = NULL;
        }
        return list;
    }

    CupsOptionList *list = (CupsOptionList *)malloc(sizeof(CupsOptionList));
    if (!list)
        return NULL;
    list->count = 0;
    list->options = NULL;

#ifdef _WIN32
    // Not supported on Windows
    return list;
#else // macOS / Linux (CUPS)
    const char *ppd_filename = cupsGetPPD(printer_name);
    if (!ppd_filename)
    {
        LOG("cupsGetPPD failed for '%s', error: %s", printer_name, cupsLastErrorString());
        return list;
    }

    ppd_file_t *ppd = ppdOpenFile(ppd_filename);
    if (!ppd)
    {
        LOG("ppdOpenFile failed for '%s'", ppd_filename);
        unlink(ppd_filename); // Clean up temporary PPD file
        return list;
    }

    ppdMarkDefaults(ppd);

    int num_ui_options = 0;
    for (int i = 0; i < ppd->num_groups; i++)
    {
        num_ui_options += ppd->groups[i].num_options;
    }

    if (num_ui_options == 0)
    {
        ppdClose(ppd);
        unlink(ppd_filename);
        return list;
    }

    list->count = num_ui_options;
    list->options = (CupsOption *)malloc(num_ui_options * sizeof(CupsOption));
    if (!list->options)
    {
        ppdClose(ppd);
        unlink(ppd_filename);
        free(list);
        return NULL;
    }

    int current_option_index = 0;
    ppd_option_t *option;
    for (int i = 0; i < ppd->num_groups; i++)
    {
        ppd_group_t *group = ppd->groups + i;
        for (int j = 0; j < group->num_options; j++)
        {
            option = group->options + j;

            list->options[current_option_index].name = strdup(option->keyword ? option->keyword : "");
            list->options[current_option_index].default_value = strdup(option->defchoice ? option->defchoice : "");

            list->options[current_option_index].supported_values.count = option->num_choices;
            if (option->num_choices > 0)
            {
                list->options[current_option_index].supported_values.choices = (CupsOptionChoice *)malloc(option->num_choices * sizeof(CupsOptionChoice));
                if (list->options[current_option_index].supported_values.choices)
                {
                    for (int k = 0; k < option->num_choices; k++)
                    {
                        list->options[current_option_index].supported_values.choices[k].choice = strdup(option->choices[k].choice ? option->choices[k].choice : "");
                        list->options[current_option_index].supported_values.choices[k].text = strdup(option->choices[k].text ? option->choices[k].text : "");
                    }
                }
                else
                {
                    list->options[current_option_index].supported_values.count = 0;
                }
            }
            else
            {
                list->options[current_option_index].supported_values.choices = NULL;
            }
            current_option_index++;
        }
    }

    ppdClose(ppd);
    unlink(ppd_filename); // Clean up temporary PPD file
    return list;
#endif
}

FFI_PLUGIN_EXPORT void free_cups_option_list(CupsOptionList *option_list)
{
    if (!option_list)
        return;
    if (option_list->options)
    {
        for (int i = 0; i < option_list->count; i++)
        {
            free(option_list->options[i].name);
            free(option_list->options[i].default_value);
            if (option_list->options[i].supported_values.choices)
            {
                for (int j = 0; j < option_list->options[i].supported_values.count; j++)
                {
                    free(option_list->options[i].supported_values.choices[j].choice);
                    free(option_list->options[i].supported_values.choices[j].text);
                }
                free(option_list->options[i].supported_values.choices);
            }
        }
        free(option_list->options);
    }
    free(option_list);
}

FFI_PLUGIN_EXPORT WindowsPrinterCapabilities *get_windows_printer_capabilities(const char *printer_name)
{
    if (!printer_name)
    {
        return (WindowsPrinterCapabilities *)calloc(1, sizeof(WindowsPrinterCapabilities));
    }

#ifndef _WIN32
    return (WindowsPrinterCapabilities *)calloc(1, sizeof(WindowsPrinterCapabilities));
#else
    wchar_t *printer_name_w = to_utf16(printer_name);
    if (!printer_name_w)
    {
        LOG("Failed to convert printer name to UTF-16");
        return (WindowsPrinterCapabilities *)calloc(1, sizeof(WindowsPrinterCapabilities));
    }

    HANDLE hPrinter;
    if (!OpenPrinterW(printer_name_w, &hPrinter, NULL))
    {
        LOG("OpenPrinterW failed with error %lu", GetLastError());
        free(printer_name_w);
        return (WindowsPrinterCapabilities *)calloc(1, sizeof(WindowsPrinterCapabilities));
    }

    // First, get the size of the DEVMODE structure.
    LONG devModeSize = DocumentPropertiesW(NULL, hPrinter, printer_name_w, NULL, NULL, 0);
    if (devModeSize <= 0)
    {
        LOG("DocumentProperties (get size) failed with error %lu", GetLastError());
        ClosePrinter(hPrinter);
        free(printer_name_w);
        return (WindowsPrinterCapabilities *)calloc(1, sizeof(WindowsPrinterCapabilities));
    }

    DEVMODEW *pDevMode = (DEVMODEW *)malloc(devModeSize);
    if (!pDevMode)
    {
        LOG("Failed to allocate memory for DEVMODE structure.");
        ClosePrinter(hPrinter);
        free(printer_name_w);
        return (WindowsPrinterCapabilities *)calloc(1, sizeof(WindowsPrinterCapabilities));
    }

    // Get the default DEVMODE for the printer.
    if (DocumentPropertiesW(NULL, hPrinter, printer_name_w, pDevMode, NULL, DM_OUT_BUFFER) != IDOK)
    {
        LOG("DocumentProperties (get defaults) failed with error %lu", GetLastError());
        free(pDevMode);
        ClosePrinter(hPrinter);
        free(printer_name_w);
        return (WindowsPrinterCapabilities *)calloc(1, sizeof(WindowsPrinterCapabilities));
    }

    WindowsPrinterCapabilities *caps = (WindowsPrinterCapabilities *)calloc(1, sizeof(WindowsPrinterCapabilities));
    if (!caps)
    {
        free(pDevMode);
        ClosePrinter(hPrinter);
        free(printer_name_w);
        return NULL;
    }

    // --- Check DEVMODE fields for supported features ---
    caps->supports_landscape = (pDevMode->dmFields & DM_ORIENTATION) != 0;
    if (pDevMode->dmFields & DM_COLOR)
    {
        if (pDevMode->dmColor == DMCOLOR_COLOR)
        {
            caps->is_color_supported = true;
            caps->is_monochrome_supported = true; // Color printers can always print monochrome
        }
        else
        {
            caps->is_color_supported = false;
            caps->is_monochrome_supported = true;
        }
    }
    else
    {
        // If the DM_COLOR field is not supported, we can assume monochrome.
        caps->is_color_supported = false;
        caps->is_monochrome_supported = true;
    }

    // Get PRINTER_INFO_2 to find the port name required by DeviceCapabilities
    DWORD needed = 0;
    GetPrinterW(hPrinter, 2, NULL, 0, &needed);
    if (needed == 0)
    {
        LOG("GetPrinterW (to get size) failed with error %lu", GetLastError());
        // We can still return the basic caps from DEVMODE
        free(pDevMode);
        ClosePrinter(hPrinter);
        free(printer_name_w);
        return caps;
    }
    PRINTER_INFO_2W *pinfo2 = (PRINTER_INFO_2W *)malloc(needed);
    if (!pinfo2)
    {
        LOG("Failed to allocate memory for PRINTER_INFO_2W");
        free(pDevMode);
        ClosePrinter(hPrinter);
        free(printer_name_w);
        return caps; // Return what we have
    }
    if (!GetPrinterW(hPrinter, 2, (LPBYTE)pinfo2, needed, &needed))
    {
        LOG("GetPrinterW failed with error %lu", GetLastError());
        // Fallback to DEVMODE if GetPrinterW fails
        caps->supports_landscape = (pDevMode->dmFields & DM_ORIENTATION) != 0;
        caps->is_color_supported = (pDevMode->dmFields & DM_COLOR) && (pDevMode->dmColor == DMCOLOR_COLOR);
        caps->is_monochrome_supported = true;
        free(pinfo2);
        free(pDevMode);
        ClosePrinter(hPrinter);
        free(printer_name_w);
        return caps; // Return what we have
    }

    const wchar_t *port_w = pinfo2->pPortName;
    if (!port_w)
    {
        LOG("pPortName is NULL for printer '%s'. Cannot get extended capabilities.", printer_name);
        // Fallback to DEVMODE if port name is not available
        caps->supports_landscape = (pDevMode->dmFields & DM_ORIENTATION) != 0;
        caps->is_color_supported = (pDevMode->dmFields & DM_COLOR) && (pDevMode->dmColor == DMCOLOR_COLOR);
        caps->is_monochrome_supported = true;
    }
    else
    {
        // Use DeviceCapabilities for more reliable capability detection.
        caps->supports_landscape = (DeviceCapabilitiesW(printer_name_w, port_w, DC_ORIENTATION, NULL, pDevMode) > 0);
        caps->is_color_supported = (DeviceCapabilitiesW(printer_name_w, port_w, DC_COLORDEVICE, NULL, NULL) == 1);
        caps->is_monochrome_supported = true; // All printers should support monochrome.
        // --- Get Paper Sizes ---
        long num_papers = DeviceCapabilitiesW(printer_name_w, port_w, DC_PAPERS, NULL, NULL);
        if (num_papers > 0)
        {
            WORD *papers = (WORD *)malloc(num_papers * sizeof(WORD));
            wchar_t(*paper_names_w)[64] = (wchar_t(*)[64])malloc(num_papers * 64 * sizeof(wchar_t));
            POINT *paper_sizes_points = (POINT *)malloc(num_papers * sizeof(POINT));

            if (papers && paper_names_w && paper_sizes_points)
            {
                DeviceCapabilitiesW(printer_name_w, port_w, DC_PAPERS, (LPWSTR)papers, NULL);
                DeviceCapabilitiesW(printer_name_w, port_w, DC_PAPERNAMES, (LPWSTR)paper_names_w, NULL);
                DeviceCapabilitiesW(printer_name_w, port_w, DC_PAPERSIZE, (LPWSTR)paper_sizes_points, NULL);

                caps->paper_sizes.count = (int)num_papers;
                caps->paper_sizes.papers = (PaperSize *)malloc(num_papers * sizeof(PaperSize));
                if (caps->paper_sizes.papers)
                {
                    for (long i = 0; i < num_papers; i++)
                    {
                        caps->paper_sizes.papers[i].id = papers[i];
                        caps->paper_sizes.papers[i].name = to_utf8(paper_names_w[i]);
                        caps->paper_sizes.papers[i].width_mm = (float)paper_sizes_points[i].x / 10.0f;
                        caps->paper_sizes.papers[i].height_mm = (float)paper_sizes_points[i].y / 10.0f;
                    }
                }
            }
            if (papers)
                free(papers);
            if (paper_names_w)
                free(paper_names_w);
            if (paper_sizes_points)
                free(paper_sizes_points);
        }

        // --- Get Paper Bins (Sources) ---
        long num_bins = DeviceCapabilitiesW(printer_name_w, port_w, DC_BINS, NULL, NULL);
        if (num_bins > 0)
        {
            WORD *bins = (WORD *)malloc(num_bins * sizeof(WORD));
            wchar_t(*bin_names_w)[24] = (wchar_t(*)[24])malloc(num_bins * 24 * sizeof(wchar_t));

            if (bins && bin_names_w)
            {
                DeviceCapabilitiesW(printer_name_w, port_w, DC_BINS, (LPWSTR)bins, NULL);
                DeviceCapabilitiesW(printer_name_w, port_w, DC_BINNAMES, (LPWSTR)bin_names_w, NULL);

                caps->paper_sources.count = (int)num_bins;
                caps->paper_sources.sources = (PaperSource *)malloc(num_bins * sizeof(PaperSource));
                if (caps->paper_sources.sources)
                {
                    for (long i = 0; i < num_bins; i++)
                    {
                        caps->paper_sources.sources[i].id = bins[i];
                        caps->paper_sources.sources[i].name = to_utf8(bin_names_w[i]);
                    }
                }
            }
            if (bins)
                free(bins);
            if (bin_names_w)
                free(bin_names_w);
        }
    }

    free(pinfo2);
    free(pDevMode);
    ClosePrinter(hPrinter);
    free(printer_name_w);
    return caps;
#endif
}

FFI_PLUGIN_EXPORT void free_windows_printer_capabilities(WindowsPrinterCapabilities *capabilities)
{
    if (!capabilities)
        return;
    if (capabilities->paper_sizes.papers)
    {
        for (int i = 0; i < capabilities->paper_sizes.count; i++)
        {
            free(capabilities->paper_sizes.papers[i].name);
        }
        free(capabilities->paper_sizes.papers);
    }
    if (capabilities->paper_sources.sources)
    {
        for (int i = 0; i < capabilities->paper_sources.count; i++)
        {
            free(capabilities->paper_sources.sources[i].name);
        }
        free(capabilities->paper_sources.sources);
    }
    if (capabilities->media_types.types)
    {
        for (int i = 0; i < capabilities->media_types.count; i++)
        {
            free(capabilities->media_types.types[i].name);
        }
        free(capabilities->media_types.types);
    }
    if (capabilities->resolutions.resolutions)
    {
        free(capabilities->resolutions.resolutions);
    }
    free(capabilities);
}

FFI_PLUGIN_EXPORT int32_t submit_raw_data_job(const char *printer_name, const uint8_t *data, int length, const char *doc_name, int num_options, const char **option_keys, const char **option_values)
{

    // Validate input parameters
    if (!printer_name || !data || length <= 0 || !doc_name)
    {
        LOG("Invalid input parameters");
        return 0;
    }

#ifdef _WIN32
    int paper_size_id, paper_source_id, orientation, color_mode, print_quality, media_type_id, duplex_mode, pdf_rotation;
    double custom_scale; // Dummy
    bool collate = true; // Default to collated (complete copies printed together)
    parse_windows_options(num_options, option_keys, option_values, &paper_size_id, &paper_source_id, &orientation, &color_mode, &print_quality, &media_type_id, &custom_scale, &collate, &duplex_mode, &pdf_rotation);

    DWORD job_id = 0;
    wchar_t *printer_name_w = to_utf16(printer_name);
    if (!printer_name_w)
        return 0;

    HANDLE hPrinter;
    DOC_INFO_1W docInfo;
    DEVMODEW *pDevMode = get_modified_devmode(printer_name_w, paper_size_id, paper_source_id, orientation, color_mode, print_quality, media_type_id, 1, collate, duplex_mode);

    PRINTER_DEFAULTSW printerDefaults = {NULL, pDevMode, PRINTER_ACCESS_USE};
    printerDefaults.pDatatype = L"RAW";

    if (!OpenPrinterW(printer_name_w, &hPrinter, &printerDefaults))
    {
        LOG("OpenPrinterW failed with error %lu", GetLastError());
        free(printer_name_w);
        if (pDevMode)
            free(pDevMode);
        return 0;
    }

    wchar_t *doc_name_w = to_utf16(doc_name);
    docInfo.pDocName = doc_name_w;
    docInfo.pOutputFile = NULL;
    docInfo.pDatatype = L"RAW";

    job_id = StartDocPrinterW(hPrinter, 1, (LPBYTE)&docInfo);
    if (job_id == 0)
    {
        ClosePrinter(hPrinter);
        LOG("StartDocPrinterW failed with error %lu", GetLastError());
        if (doc_name_w)
            free(doc_name_w);
        free(printer_name_w);
        if (pDevMode)
            free(pDevMode);
        return 0;
    }
    if (doc_name_w)
        free(doc_name_w);

    if (!StartPagePrinter(hPrinter))
    {
        EndDocPrinter(hPrinter);
        LOG("StartPagePrinter failed with error %lu", GetLastError());
        ClosePrinter(hPrinter);
        free(printer_name_w);
        if (pDevMode)
            free(pDevMode);
        return 0;
    }

    // --- Chunked Write with Message Pump ---
    // This prevents the STA thread from blocking if a very large raw data file is sent.
    const DWORD CHUNK_SIZE = 65536; // 64 KB
    DWORD total_written = 0;
    DWORD bytes_to_write = (DWORD)length;
    bool write_success = true;

    while (total_written < bytes_to_write)
    {
        DWORD chunk_to_write = (bytes_to_write - total_written > CHUNK_SIZE) ? CHUNK_SIZE : (bytes_to_write - total_written);
        DWORD written_this_chunk = 0;

        if (!WritePrinter(hPrinter, (LPVOID)(data + total_written), chunk_to_write, &written_this_chunk))
        {
            LOG("WritePrinter failed during chunked write with error %lu", GetLastError());
            write_success = false;
            break;
        }

        total_written += written_this_chunk;

        // Pump messages to keep the STA thread responsive.
        MSG msg;
        while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE))
        {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }

    EndPagePrinter(hPrinter);
    EndDocPrinter(hPrinter);
    ClosePrinter(hPrinter);
    free(printer_name_w);
    if (pDevMode)
        free(pDevMode);

    if (!write_success || total_written != (DWORD)length)
    {
        LOG("WritePrinter failed. Success: %d, Bytes written: %lu, Expected: %d", write_success, total_written, length);
        // The job might have been created but failed to write. The caller can still track this job ID to see its error state.
    }
    return (int32_t)job_id;
#else // macOS / Linux
    const char *tmpdir = getenv("TMPDIR");
    if (!tmpdir)
    {
        tmpdir = "/tmp";
    }

    char temp_file[PATH_MAX];
    snprintf(temp_file, sizeof(temp_file), "%s/printing_ffi_XXXXXX", tmpdir);
    LOG("Creating temporary file at: %s", temp_file);

    int fd = mkstemp(temp_file);
    if (fd == -1)
    {
        LOG("mkstemp failed to create temporary file");
        return 0;
    }

    FILE *fp = fdopen(fd, "wb");
    if (!fp)
    {
        close(fd);
        unlink(temp_file);
        return 0;
    }

    size_t written = fwrite(data, 1, (size_t)length, fp);
    fclose(fp);

    if (written != (size_t)length)
    {
        unlink(temp_file);
        return 0;
    }

    cups_option_t *options = NULL;
    int num_cups_options = 0;
    num_cups_options = cupsAddOption("raw", "true", num_cups_options, &options);

    for (int i = 0; i < num_options; i++)
    {
        if (option_keys && option_keys[i] && option_values && option_values[i])
        {
            num_cups_options = cupsAddOption(option_keys[i], option_values[i], num_cups_options, &options);
        }
    }

    int job_id = cupsPrintFile(printer_name, temp_file, doc_name, num_cups_options, options);
    if (job_id <= 0)
    {
        LOG("cupsPrintFile failed, error: %s", cupsLastErrorString());
    }
    cupsFreeOptions(num_cups_options, options);
    unlink(temp_file);
    return job_id > 0 ? job_id : 0;
#endif
}

FFI_PLUGIN_EXPORT int32_t submit_pdf_job(const char *printer_name, const char *pdf_file_path, const char *doc_name, int scaling_mode, int copies, const char *page_range, int num_options, const char **option_keys, const char **option_values, const char *alignment)
{

    // Validate input parameters
    if (!printer_name || !pdf_file_path || !doc_name || copies <= 0)
    {
        LOG("Invalid input parameters");
        return 0;
    }

#ifdef _WIN32
    return _print_pdf_job_win(printer_name, pdf_file_path, doc_name, scaling_mode, copies, page_range, alignment, num_options, option_keys, option_values, true);
#else // macOS / Linux (CUPS)
    cups_option_t *options = NULL;
    int num_cups_options = 0;
    for (int i = 0; i < num_options; i++)
    {
        if (option_keys && option_keys[i] && option_values && option_values[i])
        {
            num_cups_options = cupsAddOption(option_keys[i], option_values[i], num_cups_options, &options);
        }
    }

    int job_id = cupsPrintFile(printer_name, pdf_file_path, doc_name, num_cups_options, options);
    if (job_id <= 0)
    {
        LOG("cupsPrintFile failed, error: %s", cupsLastErrorString());
    }
    cupsFreeOptions(num_cups_options, options);
    return job_id > 0 ? job_id : 0;
#endif
}

// Submit an arbitrary file to CUPS and let it auto-detect the MIME/document
// format from the file contents (e.g. image/jpeg, image/png, application/pdf).
// This intentionally does NOT force a document-format option, so it works for
// images and any other type CUPS can sniff. Returns the job id on success, 0 on
// failure (get_last_error has details). Not supported on Windows (returns 0).
FFI_PLUGIN_EXPORT int32_t submit_file_job(const char *printer_name, const char *file_path, const char *doc_name, int num_options, const char **option_keys, const char **option_values)
{

    if (!printer_name || !file_path || !doc_name)
    {
        set_last_error("Printer name, file path, and document name cannot be null.");
        return 0;
    }

#ifdef _WIN32
    set_last_error("submit_file_job is not supported on Windows.");
    return 0;
#else // macOS / Linux / Android (CUPS)
    cups_option_t *options = NULL;
    int num_cups_options = 0;
    for (int i = 0; i < num_options; i++)
    {
        if (option_keys && option_keys[i] && option_values && option_values[i])
        {
            num_cups_options = cupsAddOption(option_keys[i], option_values[i], num_cups_options, &options);
        }
    }

    // Let CUPS auto-detect the document format from the file contents. We do not
    // add a "document-format" option so image/jpeg, image/png, application/pdf,
    // etc. are all handled by the server's MIME rules.
    int job_id = cupsPrintFile(printer_name, file_path, doc_name, num_cups_options, options);
    if (job_id <= 0)
    {
        set_last_error("cupsPrintFile failed for '%s': %s", file_path, cupsLastErrorString());
        LOG("cupsPrintFile failed, error: %s", cupsLastErrorString());
    }
    cupsFreeOptions(num_cups_options, options);
    return job_id > 0 ? job_id : 0;
#endif
}

FFI_PLUGIN_EXPORT bool print_file_with_dialog(const char *file_path, const char *doc_name)
{
    if (!file_path || !doc_name)
    {
        set_last_error("File path and document name cannot be null.");
        return false;
    }


#ifdef _WIN32
    wchar_t *file_path_w = to_utf16(file_path);
    if (!file_path_w)
    {
        set_last_error("Failed to convert file path to UTF-16.");
        return false;
    }

    // Use ShellExecuteW to open the print dialog for the given file.
    // This relies on the file type's registered 'print' verb.
    HINSTANCE result = ShellExecuteW(NULL, L"print", file_path_w, NULL, NULL, SW_SHOWNORMAL);
    free(file_path_w);

    // ShellExecuteW returns a value > 32 on success.
    if ((intptr_t)result > 32)
    {
        return true;
    }
    else
    {
        set_last_error("ShellExecuteW failed to print file. Error code: %d. Ensure a default application is set for this file type.", (int)(intptr_t)result);
        return false;
    }
#else // macOS / Linux
#ifdef __APPLE__
    // On macOS, use lpr to print the file.
    char command[PATH_MAX * 4];
    snprintf(command, sizeof(command), "lpr -T \"%s\" \"%s\" 2>&1", doc_name, file_path);
    LOG("Executing macOS command: %s", command);
#else
    // On Linux, use lpr with -p (prettyprint) which may show a dialog depending on the setup.
    char command[PATH_MAX * 4];
    snprintf(command, sizeof(command), "lpr -p -J \"%s\" \"%s\" 2>&1", doc_name, file_path);
    LOG("Executing Linux command: %s", command);
#endif

    FILE *pipe = popen(command, "r");
    if (!pipe)
    {
        set_last_error("popen() failed to execute print command.");
        return false;
    }

    char buffer[256];
    char *output = NULL;
    size_t output_size = 0;

    // Read the entire output of the command.
    while (fgets(buffer, sizeof(buffer), pipe) != NULL)
    {
        size_t len = strlen(buffer);
        char *new_output = (char *)realloc(output, output_size + len + 1);
        if (!new_output)
        {
            set_last_error("Failed to allocate memory for command output.");
            if (output)
                free(output);
            pclose(pipe);
            return false;
        }
        output = new_output;
        strcpy(output + output_size, buffer);
        output_size += len;
    }

    int cmd_result = pclose(pipe);
    if (cmd_result != 0)
    {
        if (output && output_size > 0)
        {
            // Trim trailing newline if present.
            if (output[output_size - 1] == '\n')
            {
                output[output_size - 1] = '\0';
            }
            set_last_error("Print command failed: %s", output);
        }
        else
        {
            set_last_error("Print command failed with exit code %d.", cmd_result);
        }
    }

    if (output)
    {
        free(output);
    }

    return cmd_result == 0;
#endif
}

// ============================================================================
// CUPS Printer Control Functions (macOS/Linux only)
// ============================================================================

#ifndef _WIN32
// Helper function to create an IPP request with authentication if provided
static ipp_t *create_ipp_request(ipp_op_t op, const char *printer_name, const char *username, const char *password, http_t **http_out)
{
    char uri[HTTP_MAX_URI];
    
    // Get printer URI
    cups_dest_t *dests = NULL;
    int num_dests = cupsGetDests(&dests);
    cups_dest_t *dest = NULL;
    
    for (int i = 0; i < num_dests; i++)
    {
        if (strcmp(dests[i].name, printer_name) == 0)
        {
            dest = &dests[i];
            break;
        }
    }
    
    if (!dest)
    {
        cupsFreeDests(num_dests, dests);
        set_last_error("Printer '%s' not found", printer_name);
        return NULL;
    }
    
    // Build a CUPS queue URI for IPP operations (device-uri is not valid here).
    httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL,
                     cupsServer(), ippPort(), "/printers/%s", dest->name);

    cupsFreeDests(num_dests, dests);
    
    // Set authentication if provided
    if (username && password)
    {
        cupsSetUser(username);
        cupsSetPasswordCB2(NULL, NULL);
        // Note: CUPS will use the password via callback or environment
        // For programmatic usage, we'd need a custom password callback
    }
    
    // Create HTTP connection
    http_t *http = httpConnectEncrypt(cupsServer(), ippPort(), HTTP_ENCRYPT_IF_REQUESTED);
    if (!http)
    {
        set_last_error("Failed to connect to CUPS server");
        return NULL;
    }
    
    // Create IPP request
    ipp_t *request = ippNewRequest(op);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
    
    if (username)
    {
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, username);
    }
    else
    {
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, cupsUser());
    }
    
    *http_out = http;
    return request;
}

// Helper to execute IPP request and check response
static bool execute_ipp_request(http_t *http, ipp_t *request, const char *operation_name, const char *resource_path)
{
    ipp_t *response = cupsDoRequest(http, request, resource_path);

    if (!response)
    {
        set_last_error("%s failed: %s", operation_name, cupsLastErrorString());
        httpClose(http);
        return false;
    }
    
    ipp_status_t status = ippGetStatusCode(response);
    bool success = (status <= IPP_OK_CONFLICT);
    
    if (!success)
    {
        set_last_error("%s failed with status: %s", operation_name, ippErrorString(status));
    }
    
    ippDelete(response);
    httpClose(http);
    return success;
}
#endif

FFI_PLUGIN_EXPORT bool cups_pause_printer(const char *printer_name, const char *username, const char *password)
{
#ifdef _WIN32
    set_last_error("cups_pause_printer is not supported on Windows");
    return false;
#else
    if (!printer_name)
    {
        set_last_error("Printer name is required");
        return false;
    }
    
    
    http_t *http = NULL;
    ipp_t *request = create_ipp_request(IPP_OP_PAUSE_PRINTER, printer_name, username, password, &http);
    if (!request)
        return false;
    
    return execute_ipp_request(http, request, "Pause printer", "/admin/");
#endif
}

FFI_PLUGIN_EXPORT bool cups_resume_printer(const char *printer_name, const char *username, const char *password)
{
#ifdef _WIN32
    set_last_error("cups_resume_printer is not supported on Windows");
    return false;
#else
    if (!printer_name)
    {
        set_last_error("Printer name is required");
        return false;
    }
    
    
    http_t *http = NULL;
    ipp_t *request = create_ipp_request(IPP_OP_RESUME_PRINTER, printer_name, username, password, &http);
    if (!request)
        return false;
    
    return execute_ipp_request(http, request, "Resume printer", "/admin/");
#endif
}

FFI_PLUGIN_EXPORT bool cups_enable_printer(const char *printer_name, const char *username, const char *password)
{
#ifdef _WIN32
    set_last_error("cups_enable_printer is not supported on Windows");
    return false;
#else
    if (!printer_name)
    {
        set_last_error("Printer name is required");
        return false;
    }
    

    if (username)
        cupsSetUser(username);

    http_t *http = NULL;
    ipp_t *request = create_ipp_request(IPP_OP_ENABLE_PRINTER, printer_name, username, password, &http);
    if (!request)
        return false;

    return execute_ipp_request(http, request, "Enable printer", "/admin/");
#endif
}

FFI_PLUGIN_EXPORT bool cups_disable_printer(const char *printer_name, const char *reason, const char *username, const char *password)
{
#ifdef _WIN32
    set_last_error("cups_disable_printer is not supported on Windows");
    return false;
#else
    if (!printer_name)
    {
        set_last_error("Printer name is required");
        return false;
    }
    
    
    cups_dest_t *dests = NULL;
    int num_dests = cupsGetDests(&dests);
    cups_dest_t *dest = cupsGetDest(printer_name, NULL, num_dests, dests);
    
    if (!dest)
    {
        cupsFreeDests(num_dests, dests);
        set_last_error("Printer '%s' not found", printer_name);
        return false;
    }
    
    if (username)
        cupsSetUser(username);
    
    // For disable, we need to send the reason if provided
    http_t *http = httpConnectEncrypt(cupsServer(), ippPort(), HTTP_ENCRYPT_IF_REQUESTED);
    if (!http)
    {
        cupsFreeDests(num_dests, dests);
        set_last_error("Failed to connect to CUPS server");
        return false;
    }
    
    char uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL, 
                     cupsServer(), ippPort(), "/printers/%s", printer_name);
    
    ipp_t *request = ippNewRequest(IPP_OP_DISABLE_PRINTER);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, username ? username : cupsUser());
    
    if (reason && strlen(reason) > 0)
    {
        ippAddString(request, IPP_TAG_PRINTER, IPP_TAG_TEXT, "printer-state-message", NULL, reason);
    }
    
    ipp_t *response = cupsDoRequest(http, request, "/admin/");
    cupsFreeDests(num_dests, dests);
    
    if (!response)
    {
        set_last_error("Disable printer failed: %s", cupsLastErrorString());
        httpClose(http);
        return false;
    }
    
    ipp_status_t status = ippGetStatusCode(response);
    bool success = (status <= IPP_OK_CONFLICT);
    
    if (!success)
    {
        set_last_error("Disable printer failed with status: %s", ippErrorString(status));
    }
    
    ippDelete(response);
    httpClose(http);
    return success;
#endif
}

FFI_PLUGIN_EXPORT bool cups_accept_jobs(const char *printer_name, const char *username, const char *password)
{
#ifdef _WIN32
    set_last_error("cups_accept_jobs is not supported on Windows");
    return false;
#else
    if (!printer_name)
    {
        set_last_error("Printer name is required");
        return false;
    }
    
    
    if (username)
        cupsSetUser(username);
    
    http_t *http = NULL;
    ipp_t *request = create_ipp_request(IPP_OP_CUPS_ACCEPT_JOBS, printer_name, username, password, &http);
    if (!request)
        return false;
    
    return execute_ipp_request(http, request, "Accept jobs", "/admin/");
#endif
}

FFI_PLUGIN_EXPORT bool cups_reject_jobs(const char *printer_name, const char *reason, const char *username, const char *password)
{
#ifdef _WIN32
    set_last_error("cups_reject_jobs is not supported on Windows");
    return false;
#else
    if (!printer_name)
    {
        set_last_error("Printer name is required");
        return false;
    }
    
    
    if (username)
        cupsSetUser(username);
    
    http_t *http = httpConnectEncrypt(cupsServer(), ippPort(), HTTP_ENCRYPT_IF_REQUESTED);
    if (!http)
    {
        set_last_error("Failed to connect to CUPS server");
        return false;
    }
    
    char uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL, 
                     cupsServer(), ippPort(), "/printers/%s", printer_name);
    
    ipp_t *request = ippNewRequest(IPP_OP_CUPS_REJECT_JOBS);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, username ? username : cupsUser());
    
    if (reason && strlen(reason) > 0)
    {
        ippAddString(request, IPP_TAG_PRINTER, IPP_TAG_TEXT, "printer-state-message", NULL, reason);
    }
    
    ipp_t *response = cupsDoRequest(http, request, "/admin/");
    
    if (!response)
    {
        set_last_error("Reject jobs failed: %s", cupsLastErrorString());
        httpClose(http);
        return false;
    }
    
    ipp_status_t status = ippGetStatusCode(response);
    bool success = (status <= IPP_OK_CONFLICT);
    
    if (!success)
    {
        set_last_error("Reject jobs failed with status: %s", ippErrorString(status));
    }
    
    ippDelete(response);
    httpClose(http);
    return success;
#endif
}

// ============================================================================
// CUPS Job Control Functions (macOS/Linux only)
// ============================================================================

FFI_PLUGIN_EXPORT bool cups_hold_job(const char *printer_name, uint32_t job_id, const char *username, const char *password)
{
#ifdef _WIN32
    set_last_error("cups_hold_job is not supported on Windows");
    return false;
#else
    if (!printer_name)
    {
        set_last_error("Printer name is required");
        return false;
    }
    
    
    if (username)
        cupsSetUser(username);
    
    http_t *http = httpConnectEncrypt(cupsServer(), ippPort(), HTTP_ENCRYPT_IF_REQUESTED);
    if (!http)
    {
        set_last_error("Failed to connect to CUPS server");
        return false;
    }
    
    char uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL, 
                     cupsServer(), ippPort(), "/printers/%s", printer_name);
    
    char job_uri[HTTP_MAX_URI];
    snprintf(job_uri, sizeof(job_uri), "ipp://localhost/jobs/%u", job_id);
    
    ipp_t *request = ippNewRequest(IPP_OP_HOLD_JOB);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
    ippAddInteger(request, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "job-id", job_id);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, username ? username : cupsUser());
    
    ipp_t *response = cupsDoRequest(http, request, "/jobs/");
    
    if (!response)
    {
        set_last_error("Hold job failed: %s", cupsLastErrorString());
        httpClose(http);
        return false;
    }
    
    ipp_status_t status = ippGetStatusCode(response);
    bool success = (status <= IPP_OK_CONFLICT);
    
    if (!success)
    {
        set_last_error("Hold job failed with status: %s", ippErrorString(status));
    }
    
    ippDelete(response);
    httpClose(http);
    return success;
#endif
}

FFI_PLUGIN_EXPORT bool cups_release_job(const char *printer_name, uint32_t job_id, const char *username, const char *password)
{
#ifdef _WIN32
    set_last_error("cups_release_job is not supported on Windows");
    return false;
#else
    if (!printer_name)
    {
        set_last_error("Printer name is required");
        return false;
    }
    
    
    if (username)
        cupsSetUser(username);
    
    http_t *http = httpConnectEncrypt(cupsServer(), ippPort(), HTTP_ENCRYPT_IF_REQUESTED);
    if (!http)
    {
        set_last_error("Failed to connect to CUPS server");
        return false;
    }
    
    char uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL, 
                     cupsServer(), ippPort(), "/printers/%s", printer_name);
    
    ipp_t *request = ippNewRequest(IPP_OP_RELEASE_JOB);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
    ippAddInteger(request, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "job-id", job_id);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, username ? username : cupsUser());
    
    ipp_t *response = cupsDoRequest(http, request, "/jobs/");
    
    if (!response)
    {
        set_last_error("Release job failed: %s", cupsLastErrorString());
        httpClose(http);
        return false;
    }
    
    ipp_status_t status = ippGetStatusCode(response);
    bool success = (status <= IPP_OK_CONFLICT);
    
    if (!success)
    {
        set_last_error("Release job failed with status: %s", ippErrorString(status));
    }
    
    ippDelete(response);
    httpClose(http);
    return success;
#endif
}

FFI_PLUGIN_EXPORT bool cups_move_job(const char *source_printer, uint32_t job_id, const char *dest_printer, const char *username, const char *password)
{
#ifdef _WIN32
    set_last_error("cups_move_job is not supported on Windows");
    return false;
#else
    if (!source_printer || !dest_printer)
    {
        set_last_error("Source and destination printer names are required");
        return false;
    }
    
    
    if (username)
        cupsSetUser(username);
    
    http_t *http = httpConnectEncrypt(cupsServer(), ippPort(), HTTP_ENCRYPT_IF_REQUESTED);
    if (!http)
    {
        set_last_error("Failed to connect to CUPS server");
        return false;
    }
    
    char job_uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, job_uri, sizeof(job_uri), "ipp", NULL, 
                     cupsServer(), ippPort(), "/jobs/%u", job_id);
    
    char dest_uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, dest_uri, sizeof(dest_uri), "ipp", NULL, 
                     cupsServer(), ippPort(), "/printers/%s", dest_printer);
    
    ipp_t *request = ippNewRequest(IPP_OP_CUPS_MOVE_JOB);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "job-uri", NULL, job_uri);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, username ? username : cupsUser());
    ippAddString(request, IPP_TAG_JOB, IPP_TAG_URI, "job-printer-uri", NULL, dest_uri);
    
    ipp_t *response = cupsDoRequest(http, request, "/jobs/");
    
    if (!response)
    {
        set_last_error("Move job failed: %s", cupsLastErrorString());
        httpClose(http);
        return false;
    }
    
    ipp_status_t status = ippGetStatusCode(response);
    bool success = (status <= IPP_OK_CONFLICT);
    
    if (!success)
    {
        set_last_error("Move job failed with status: %s", ippErrorString(status));
    }
    
    ippDelete(response);
    httpClose(http);
    return success;
#endif
}

FFI_PLUGIN_EXPORT bool cups_set_job_priority(const char *printer_name, uint32_t job_id, int priority, const char *username, const char *password)
{
#ifdef _WIN32
    set_last_error("cups_set_job_priority is not supported on Windows");
    return false;
#else
    if (!printer_name)
    {
        set_last_error("Printer name is required");
        return false;
    }
    
    // CUPS priority ranges from 1 (lowest) to 100 (highest)
    if (priority < 1 || priority > 100)
    {
        set_last_error("Priority must be between 1 and 100");
        return false;
    }
    
    
    if (username)
        cupsSetUser(username);
    
    http_t *http = httpConnectEncrypt(cupsServer(), ippPort(), HTTP_ENCRYPT_IF_REQUESTED);
    if (!http)
    {
        set_last_error("Failed to connect to CUPS server");
        return false;
    }
    
    char printer_uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, printer_uri, sizeof(printer_uri), "ipp", NULL,
                     cupsServer(), ippPort(), "/printers/%s", printer_name);

    char job_uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, job_uri, sizeof(job_uri), "ipp", NULL,
                     cupsServer(), ippPort(), "/jobs/%u", job_id);

    const char *request_user = username ? username : cupsUser();
    ipp_status_t primary_status = IPP_STATUS_OK;

    // Primary request form: printer-uri + job-id. This is broadly accepted by CUPS.
    ipp_t *request = ippNewRequest(IPP_OP_SET_JOB_ATTRIBUTES);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, printer_uri);
    ippAddInteger(request, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "job-id", job_id);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, request_user);
    ippAddInteger(request, IPP_TAG_JOB, IPP_TAG_INTEGER, "job-priority", priority);

    ipp_t *response = cupsDoRequest(http, request, "/");

    if (!response)
    {
        set_last_error("Set job priority failed: %s", cupsLastErrorString());
        httpClose(http);
        return false;
    }

    primary_status = ippGetStatusCode(response);
    bool success = (primary_status <= IPP_OK_CONFLICT);
    ippDelete(response);

    if (success)
    {
        httpClose(http);
        return true;
    }

    // Some servers reject the first form but accept job-uri addressing.
    request = ippNewRequest(IPP_OP_SET_JOB_ATTRIBUTES);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "job-uri", NULL, job_uri);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, request_user);
    ippAddInteger(request, IPP_TAG_JOB, IPP_TAG_INTEGER, "job-priority", priority);

    response = cupsDoRequest(http, request, "/jobs/");

    if (!response)
    {
        set_last_error("Set job priority failed: %s", cupsLastErrorString());
        httpClose(http);
        return false;
    }

    ipp_status_t fallback_status = ippGetStatusCode(response);
    success = (fallback_status <= IPP_OK_CONFLICT);

    if (!success)
    {
        set_last_error("Set job priority failed with status: %s (fallback status: %s)", ippErrorString(primary_status), ippErrorString(fallback_status));
    }

    ippDelete(response);
    httpClose(http);
    return success;
#endif
}

// ============================================================================
// CUPS Printer Attribute Query Functions (macOS/Linux only)
// ============================================================================

#ifndef _WIN32
// Convert a single value (at `index`) of an IPP attribute to a freshly malloc'd
// C string. Handles the common CUPS value tags — including range, resolution and
// the out-of-band tags surfaced by a full "all" attribute dump — and falls back
// to the tag's human name (e.g. "no-value", "collection") for anything else.
// Never returns NULL except on strdup OOM.
static char *ipp_attr_value_to_string(ipp_attribute_t *attr, int index)
{
    ipp_tag_t value_tag = ippGetValueTag(attr);
    char buffer[256];

    switch (value_tag)
    {
        case IPP_TAG_INTEGER:
        case IPP_TAG_ENUM:
            snprintf(buffer, sizeof(buffer), "%d", ippGetInteger(attr, index));
            return strdup(buffer);
        case IPP_TAG_BOOLEAN:
            return strdup(ippGetBoolean(attr, index) ? "true" : "false");
        case IPP_TAG_RANGE:
        {
            int upper = 0;
            int lower = ippGetRange(attr, index, &upper);
            snprintf(buffer, sizeof(buffer), "%d-%d", lower, upper);
            return strdup(buffer);
        }
        case IPP_TAG_RESOLUTION:
        {
            ipp_res_t units = IPP_RES_PER_INCH;
            int yres = 0;
            int xres = ippGetResolution(attr, index, &yres, &units);
            snprintf(buffer, sizeof(buffer), "%dx%d%s", xres, yres, units == IPP_RES_PER_CM ? "dpcm" : "dpi");
            return strdup(buffer);
        }
        case IPP_TAG_STRING:
        case IPP_TAG_TEXT:
        case IPP_TAG_TEXTLANG:
        case IPP_TAG_NAME:
        case IPP_TAG_NAMELANG:
        case IPP_TAG_KEYWORD:
        case IPP_TAG_URI:
        case IPP_TAG_URISCHEME:
        case IPP_TAG_CHARSET:
        case IPP_TAG_LANGUAGE:
        case IPP_TAG_MIMETYPE:
        {
            const char *value = ippGetString(attr, index, NULL);
            return strdup(value ? value : "");
        }
        default:
            // Out-of-band (no-value/unknown/unsupported) and structured tags
            // (collection): report the tag name so callers still see the attribute.
            return strdup(ippTagString(value_tag));
    }
}
#endif

FFI_PLUGIN_EXPORT PrinterAttribute *cups_get_printer_attribute(const char *printer_name, const char *attribute_name, const char *username, const char *password)
{
#ifdef _WIN32
    set_last_error("cups_get_printer_attribute is not supported on Windows");
    return NULL;
#else
    if (!printer_name || !attribute_name)
    {
        set_last_error("Printer name and attribute name are required");
        return NULL;
    }
    
    
    if (username)
        cupsSetUser(username);
    
    http_t *http = httpConnectEncrypt(cupsServer(), ippPort(), HTTP_ENCRYPT_IF_REQUESTED);
    if (!http)
    {
        set_last_error("Failed to connect to CUPS server");
        return NULL;
    }
    
    char uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL, 
                     cupsServer(), ippPort(), "/printers/%s", printer_name);
    
    ipp_t *request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, username ? username : cupsUser());
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", NULL, attribute_name);
    
    ipp_t *response = cupsDoRequest(http, request, "/");
    
    if (!response)
    {
        set_last_error("Get printer attribute failed: %s", cupsLastErrorString());
        httpClose(http);
        return NULL;
    }
    
    ipp_status_t status = ippGetStatusCode(response);
    if (status > IPP_OK_CONFLICT)
    {
        set_last_error("Get printer attribute failed with status: %s", ippErrorString(status));
        ippDelete(response);
        httpClose(http);
        return NULL;
    }
    
    // Find the requested attribute
    ipp_attribute_t *attr = ippFindAttribute(response, attribute_name, IPP_TAG_ZERO);
    if (!attr)
    {
        set_last_error("Attribute '%s' not found", attribute_name);
        ippDelete(response);
        httpClose(http);
        return NULL;
    }
    
    // Allocate result structure
    PrinterAttribute *result = (PrinterAttribute *)calloc(1, sizeof(PrinterAttribute));
    if (!result)
    {
        ippDelete(response);
        httpClose(http);
        return NULL;
    }
    
    result->attribute_name = strdup(attribute_name);
    
    // Get the attribute value(s)
    int value_count = ippGetCount(attr);
    result->value_count = value_count;
    
    if (value_count == 1)
    {
        // Single value - store in attribute_value
        const char *value = NULL;
        ipp_tag_t value_tag = ippGetValueTag(attr);
        
        switch (value_tag)
        {
            case IPP_TAG_INTEGER:
            case IPP_TAG_ENUM:
            {
                int int_val = ippGetInteger(attr, 0);
                char buffer[32];
                snprintf(buffer, sizeof(buffer), "%d", int_val);
                value = buffer;
                break;
            }
            case IPP_TAG_BOOLEAN:
            {
                int bool_val = ippGetBoolean(attr, 0);
                value = bool_val ? "true" : "false";
                break;
            }
            case IPP_TAG_STRING:
            case IPP_TAG_TEXT:
            case IPP_TAG_NAME:
            case IPP_TAG_KEYWORD:
            case IPP_TAG_URI:
            case IPP_TAG_URISCHEME:
            case IPP_TAG_CHARSET:
            case IPP_TAG_LANGUAGE:
            case IPP_TAG_MIMETYPE:
                value = ippGetString(attr, 0, NULL);
                break;
            default:
                value = "unsupported-type";
                break;
        }
        
        result->attribute_value = value ? strdup(value) : strdup("");
        result->array_values = NULL;
    }
    else if (value_count > 1)
    {
        // Multiple values - store in array_values
        result->attribute_value = NULL;
        result->array_values = (char **)calloc(value_count, sizeof(char *));
        
        if (result->array_values)
        {
            ipp_tag_t value_tag = ippGetValueTag(attr);
            
            for (int i = 0; i < value_count; i++)
            {
                const char *value = NULL;
                char buffer[32];
                
                switch (value_tag)
                {
                    case IPP_TAG_INTEGER:
                    case IPP_TAG_ENUM:
                    {
                        int int_val = ippGetInteger(attr, i);
                        snprintf(buffer, sizeof(buffer), "%d", int_val);
                        value = buffer;
                        break;
                    }
                    case IPP_TAG_BOOLEAN:
                    {
                        int bool_val = ippGetBoolean(attr, i);
                        value = bool_val ? "true" : "false";
                        break;
                    }
                    case IPP_TAG_STRING:
                    case IPP_TAG_TEXT:
                    case IPP_TAG_NAME:
                    case IPP_TAG_KEYWORD:
                    case IPP_TAG_URI:
                    case IPP_TAG_URISCHEME:
                    case IPP_TAG_CHARSET:
                    case IPP_TAG_LANGUAGE:
                    case IPP_TAG_MIMETYPE:
                        value = ippGetString(attr, i, NULL);
                        break;
                    default:
                        value = "unsupported-type";
                        break;
                }
                
                result->array_values[i] = value ? strdup(value) : strdup("");
            }
        }
    }
    else
    {
        // No values
        result->attribute_value = strdup("");
        result->array_values = NULL;
    }
    
    ippDelete(response);
    httpClose(http);
    return result;
#endif
}

FFI_PLUGIN_EXPORT PrinterAttributeList *cups_get_printer_attributes(const char *printer_name, const char **attribute_names, int num_attributes, const char *username, const char *password)
{
#ifdef _WIN32
    set_last_error("cups_get_printer_attributes is not supported on Windows");
    return NULL;
#else
    if (!printer_name || !attribute_names || num_attributes <= 0)
    {
        set_last_error("Printer name and attribute names are required");
        return NULL;
    }
    
    
    if (username)
        cupsSetUser(username);
    
    http_t *http = httpConnectEncrypt(cupsServer(), ippPort(), HTTP_ENCRYPT_IF_REQUESTED);
    if (!http)
    {
        set_last_error("Failed to connect to CUPS server");
        return NULL;
    }
    
    char uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL, 
                     cupsServer(), ippPort(), "/printers/%s", printer_name);
    
    ipp_t *request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, username ? username : cupsUser());
    
    // requested-attributes is a 1setOf keyword; send all names in one attribute.
    ippAddStrings(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", num_attributes, NULL, attribute_names);

    ipp_t *response = cupsDoRequest(http, request, "/");
    
    if (!response)
    {
        set_last_error("Get printer attributes failed: %s", cupsLastErrorString());
        httpClose(http);
        return NULL;
    }
    
    ipp_status_t status = ippGetStatusCode(response);
    if (status > IPP_OK_CONFLICT)
    {
        set_last_error("Get printer attributes failed with status: %s", ippErrorString(status));
        ippDelete(response);
        httpClose(http);
        return NULL;
    }
    
    // Allocate result list
    PrinterAttributeList *result = (PrinterAttributeList *)calloc(1, sizeof(PrinterAttributeList));
    if (!result)
    {
        ippDelete(response);
        httpClose(http);
        return NULL;
    }
    
    result->count = num_attributes;
    result->attributes = (PrinterAttribute *)calloc(num_attributes, sizeof(PrinterAttribute));
    
    if (!result->attributes)
    {
        free(result);
        ippDelete(response);
        httpClose(http);
        return NULL;
    }
    
    // Extract each requested attribute
    for (int i = 0; i < num_attributes; i++)
    {
        const char *attr_name = attribute_names[i];
        result->attributes[i].attribute_name = strdup(attr_name);
        
        ipp_attribute_t *attr = ippFindAttribute(response, attr_name, IPP_TAG_ZERO);
        if (!attr)
        {
            // Attribute not found
            result->attributes[i].attribute_value = strdup("not-found");
            result->attributes[i].value_count = 0;
            result->attributes[i].array_values = NULL;
            continue;
        }
        
        int value_count = ippGetCount(attr);
        result->attributes[i].value_count = value_count;
        
        if (value_count == 1)
        {
            // Single value
            const char *value = NULL;
            ipp_tag_t value_tag = ippGetValueTag(attr);
            char buffer[256];
            
            switch (value_tag)
            {
                case IPP_TAG_INTEGER:
                case IPP_TAG_ENUM:
                {
                    int int_val = ippGetInteger(attr, 0);
                    snprintf(buffer, sizeof(buffer), "%d", int_val);
                    value = buffer;
                    break;
                }
                case IPP_TAG_BOOLEAN:
                {
                    int bool_val = ippGetBoolean(attr, 0);
                    value = bool_val ? "true" : "false";
                    break;
                }
                case IPP_TAG_STRING:
                case IPP_TAG_TEXT:
                case IPP_TAG_NAME:
                case IPP_TAG_KEYWORD:
                case IPP_TAG_URI:
                case IPP_TAG_URISCHEME:
                case IPP_TAG_CHARSET:
                case IPP_TAG_LANGUAGE:
                case IPP_TAG_MIMETYPE:
                    value = ippGetString(attr, 0, NULL);
                    break;
                default:
                    snprintf(buffer, sizeof(buffer), "unsupported-type-%d", value_tag);
                    value = buffer;
                    break;
            }
            
            result->attributes[i].attribute_value = value ? strdup(value) : strdup("");
            result->attributes[i].array_values = NULL;
        }
        else if (value_count > 1)
        {
            // Multiple values
            result->attributes[i].attribute_value = NULL;
            result->attributes[i].array_values = (char **)calloc(value_count, sizeof(char *));
            
            if (result->attributes[i].array_values)
            {
                ipp_tag_t value_tag = ippGetValueTag(attr);
                
                for (int j = 0; j < value_count; j++)
                {
                    const char *value = NULL;
                    char buffer[256];
                    
                    switch (value_tag)
                    {
                        case IPP_TAG_INTEGER:
                        case IPP_TAG_ENUM:
                        {
                            int int_val = ippGetInteger(attr, j);
                            snprintf(buffer, sizeof(buffer), "%d", int_val);
                            value = buffer;
                            break;
                        }
                        case IPP_TAG_BOOLEAN:
                        {
                            int bool_val = ippGetBoolean(attr, j);
                            value = bool_val ? "true" : "false";
                            break;
                        }
                        case IPP_TAG_STRING:
                        case IPP_TAG_TEXT:
                        case IPP_TAG_NAME:
                        case IPP_TAG_KEYWORD:
                        case IPP_TAG_URI:
                        case IPP_TAG_URISCHEME:
                        case IPP_TAG_CHARSET:
                        case IPP_TAG_LANGUAGE:
                        case IPP_TAG_MIMETYPE:
                            value = ippGetString(attr, j, NULL);
                            break;
                        default:
                            snprintf(buffer, sizeof(buffer), "unsupported-type-%d", value_tag);
                            value = buffer;
                            break;
                    }
                    
                    result->attributes[i].array_values[j] = value ? strdup(value) : strdup("");
                }
            }
        }
        else
        {
            // No values
            result->attributes[i].attribute_value = strdup("");
            result->attributes[i].array_values = NULL;
        }
    }
    
    ippDelete(response);
    httpClose(http);
    return result;
#endif
}

FFI_PLUGIN_EXPORT PrinterAttributeList *cups_get_all_printer_attributes(const char *printer_name, const char *username, const char *password)
{
#ifdef _WIN32
    set_last_error("cups_get_all_printer_attributes is not supported on Windows");
    return NULL;
#else
    (void)password;
    if (!printer_name)
    {
        set_last_error("Printer name is required");
        return NULL;
    }


    if (username)
        cupsSetUser(username);

    http_t *http = httpConnectEncrypt(cupsServer(), ippPort(), HTTP_ENCRYPT_IF_REQUESTED);
    if (!http)
    {
        set_last_error("Failed to connect to CUPS server");
        return NULL;
    }

    char uri[HTTP_MAX_URI];
    httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof(uri), "ipp", NULL,
                     cupsServer(), ippPort(), "/printers/%s", printer_name);

    ipp_t *request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", NULL, uri);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", NULL, username ? username : cupsUser());
    // "all" asks the printer to return every attribute it exposes.
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", NULL, "all");

    ipp_t *response = cupsDoRequest(http, request, "/");

    if (!response)
    {
        set_last_error("Get all printer attributes failed: %s", cupsLastErrorString());
        httpClose(http);
        return NULL;
    }

    ipp_status_t status = ippGetStatusCode(response);
    if (status > IPP_OK_CONFLICT)
    {
        set_last_error("Get all printer attributes failed with status: %s", ippErrorString(status));
        ippDelete(response);
        httpClose(http);
        return NULL;
    }

    // First pass: count the named attributes in the printer group (skip the
    // operation group and unnamed group separators).
    int count = 0;
    for (ipp_attribute_t *attr = ippFirstAttribute(response); attr != NULL; attr = ippNextAttribute(response))
    {
        if (ippGetGroupTag(attr) != IPP_TAG_PRINTER || ippGetName(attr) == NULL)
            continue;
        count++;
    }

    PrinterAttributeList *result = (PrinterAttributeList *)calloc(1, sizeof(PrinterAttributeList));
    if (!result)
    {
        set_last_error("Out of memory allocating attribute list");
        ippDelete(response);
        httpClose(http);
        return NULL;
    }

    result->count = count;
    result->attributes = count > 0 ? (PrinterAttribute *)calloc(count, sizeof(PrinterAttribute)) : NULL;
    if (count > 0 && !result->attributes)
    {
        set_last_error("Out of memory allocating attributes");
        free(result);
        ippDelete(response);
        httpClose(http);
        return NULL;
    }

    // Second pass: copy each attribute's name and value(s).
    int i = 0;
    for (ipp_attribute_t *attr = ippFirstAttribute(response); attr != NULL && i < count; attr = ippNextAttribute(response))
    {
        if (ippGetGroupTag(attr) != IPP_TAG_PRINTER)
            continue;
        const char *name = ippGetName(attr);
        if (name == NULL)
            continue;

        result->attributes[i].attribute_name = strdup(name);

        int value_count = ippGetCount(attr);
        result->attributes[i].value_count = value_count;

        if (value_count == 1)
        {
            result->attributes[i].attribute_value = ipp_attr_value_to_string(attr, 0);
            result->attributes[i].array_values = NULL;
        }
        else if (value_count > 1)
        {
            result->attributes[i].attribute_value = NULL;
            result->attributes[i].array_values = (char **)calloc(value_count, sizeof(char *));

            if (result->attributes[i].array_values)
            {
                for (int j = 0; j < value_count; j++)
                    result->attributes[i].array_values[j] = ipp_attr_value_to_string(attr, j);
            }
            else
            {
                // Allocation failed; degrade to an empty attribute rather than crash.
                result->attributes[i].value_count = 0;
            }
        }
        else
        {
            result->attributes[i].attribute_value = strdup("");
            result->attributes[i].array_values = NULL;
        }

        i++;
    }

    ippDelete(response);
    httpClose(http);
    return result;
#endif
}

FFI_PLUGIN_EXPORT void free_printer_attribute(PrinterAttribute *attribute)
{
    if (!attribute)
        return;
    
    if (attribute->attribute_name)
        free(attribute->attribute_name);
    
    if (attribute->attribute_value)
        free(attribute->attribute_value);
    
    if (attribute->array_values)
    {
        for (int i = 0; i < attribute->value_count; i++)
        {
            if (attribute->array_values[i])
                free(attribute->array_values[i]);
        }
        free(attribute->array_values);
    }
    
    free(attribute);
}

FFI_PLUGIN_EXPORT void free_printer_attribute_list(PrinterAttributeList *attribute_list)
{
    if (!attribute_list)
        return;
    
    if (attribute_list->attributes)
    {
        for (int i = 0; i < attribute_list->count; i++)
        {
            if (attribute_list->attributes[i].attribute_name)
                free(attribute_list->attributes[i].attribute_name);
            
            if (attribute_list->attributes[i].attribute_value)
                free(attribute_list->attributes[i].attribute_value);
            
            if (attribute_list->attributes[i].array_values)
            {
                for (int j = 0; j < attribute_list->attributes[i].value_count; j++)
                {
                    if (attribute_list->attributes[i].array_values[j])
                        free(attribute_list->attributes[i].array_values[j]);
                }
                free(attribute_list->attributes[i].array_values);
            }
        }
        free(attribute_list->attributes);
    }
    
    free(attribute_list);
}
