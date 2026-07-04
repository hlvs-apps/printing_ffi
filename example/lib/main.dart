import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'package:printing_ffi/printing_ffi.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'cups_android_boot.dart';
import 'dnp_usb.dart';
import 'widgets.dart';

/// A local helper class to represent the custom scaling option in the UI.
/// This is a marker class for the SegmentedButton.
class CustomScaling {
  const CustomScaling();
}

/// A helper class to hold color scheme information.
class AppColorScheme {
  const AppColorScheme(this.name, this.lightScheme, this.darkScheme);
  final String name;
  final ShadColorScheme lightScheme;
  final ShadColorScheme darkScheme;
}

/// A list of available color schemes for the theme switcher.
const List<AppColorScheme> availableColorSchemes = [
  AppColorScheme(
    'Zinc',
    ShadZincColorScheme.light(),
    ShadZincColorScheme.dark(),
  ),
  AppColorScheme(
    'Slate',
    ShadSlateColorScheme.light(),
    ShadSlateColorScheme.dark(),
  ),
  AppColorScheme(
    'Stone',
    ShadStoneColorScheme.light(),
    ShadStoneColorScheme.dark(),
  ),
  AppColorScheme(
    'Gray',
    ShadGrayColorScheme.light(),
    ShadGrayColorScheme.dark(),
  ),
  AppColorScheme(
    'Neutral',
    ShadNeutralColorScheme.light(),
    ShadNeutralColorScheme.dark(),
  ),
  AppColorScheme('Red', ShadRedColorScheme.light(), ShadRedColorScheme.dark()),
  AppColorScheme(
    'Rose',
    ShadRoseColorScheme.light(),
    ShadRoseColorScheme.dark(),
  ),
  AppColorScheme(
    'Orange',
    ShadOrangeColorScheme.light(),
    ShadOrangeColorScheme.dark(),
  ),
  AppColorScheme(
    'Green',
    ShadGreenColorScheme.light(),
    ShadGreenColorScheme.dark(),
  ),
  AppColorScheme(
    'Blue',
    ShadBlueColorScheme.light(),
    ShadBlueColorScheme.dark(),
  ),
  AppColorScheme(
    'Violet',
    ShadVioletColorScheme.light(),
    ShadVioletColorScheme.dark(),
  ),
];

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // On Windows, it's crucial to initialize the PDFium library.
  // This should be done once when the app starts.
  // If you use another PDF plugin (like pdfrx) that also initializes PDFium,
  // you might not need this call, but it's safe to leave it in as this plugin's
  // initialization is guarded against being run more than once.
  PrintingFfi.instance.initPdfium();
  // Phase 1: on Android, boot the bundled cupsd inside the app sandbox and probe
  // get_printers against it. Fire-and-forget; updates CupsAndroidBoot.status.
  if (Platform.isAndroid) {
    // Run after the first frame so the MethodChannel is ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      CupsAndroidBoot.bootAndProbe();
    });
  }
  runApp(const PrintingFfiExampleApp());
}

class PrintingFfiExampleApp extends StatefulWidget {
  const PrintingFfiExampleApp({super.key});

  @override
  State<PrintingFfiExampleApp> createState() => _PrintingFfiExampleAppState();
}

class _PrintingFfiExampleAppState extends State<PrintingFfiExampleApp> {
  ThemeMode _themeMode = ThemeMode.light;
  AppColorScheme _selectedColorScheme = availableColorSchemes.first;

  void _toggleTheme() {
    setState(() {
      _themeMode = _themeMode == ThemeMode.light
          ? ThemeMode.dark
          : ThemeMode.light;
    });
  }

  void _changeColorScheme(AppColorScheme? newScheme) {
    if (newScheme == null) return;
    setState(() {
      _selectedColorScheme = newScheme;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ShadApp(
      theme: ShadThemeData(
        brightness: Brightness.light,
        colorScheme: _selectedColorScheme.lightScheme,
      ),
      darkTheme: ShadThemeData(
        brightness: Brightness.dark,
        colorScheme: _selectedColorScheme.darkScheme,
      ),
      themeMode: _themeMode,
      title: 'Printing FFI Example',
      home: PrintingScreen(
        onThemeToggle: _toggleTheme,
        selectedScheme: _selectedColorScheme,
        onSchemeChange: _changeColorScheme,
      ),
    );
  }
}

class PrintingScreen extends StatefulWidget {
  const PrintingScreen({
    super.key,
    required this.onThemeToggle,
    required this.selectedScheme,
    required this.onSchemeChange,
  });

  final VoidCallback onThemeToggle;
  final AppColorScheme selectedScheme;
  final ValueChanged<AppColorScheme?> onSchemeChange;

  @override
  State<PrintingScreen> createState() => _PrintingScreenState();
}

class _PrintingScreenState extends State<PrintingScreen> {
  List<Printer> _printers = [];
  Printer? _selectedPrinter;
  List<PrintJob> _jobs = [];
  StreamSubscription<List<PrintJob>>? _jobsSubscription;
  List<CupsOptionModel>? _cupsOptions;
  Map<String, String> _selectedCupsOptions = {};
  WindowsPrinterCapabilitiesModel? _windowsCapabilities;
  WindowsPaperSize? _selectedPaperSize;
  WindowsPaperSource? _selectedPaperSource;
  WindowsOrientation _selectedOrientation = WindowsOrientation.portrait;
  ColorMode _selectedColorMode = ColorMode.color;
  PrintQuality _selectedPrintQuality = PrintQuality.normal;
  PdfPrintAlignment _selectedAlignment = PdfPrintAlignment.center;
  DuplexMode _selectedDuplexMode = DuplexMode.singleSided;
  PdfRotation _selectedPdfRotation = PdfRotation.auto;

  // Collate option for multiple copies
  // When true: Complete copies are printed together (1,2,3,4,5,6 - 1,2,3,4,5,6)
  // When false: All copies of each page are printed together (1,1 - 2,2 - 3,3 - 4,4 - 5,5 - 6,6)
  bool _collate = true;

  bool _isLoadingPrinters = false;
  bool _isLoadingJobs = false;
  bool _isLoadingCupsOptions = false;
  bool _isLoadingWindowsCaps = false;
  RawDataType _selectedRawDataType = RawDataType.zpl;

  // Android CUPS/DNP banners are collapsed by default so they don't dominate the
  // top of the screen. Tap a header to expand.
  bool _cupsBannerExpanded = false;
  bool _dnpBannerExpanded = false;

  late final TextEditingController _rawDataController;
  Object _selectedScaling = PdfPrintScaling.fitToPrintableArea;
  final TextEditingController _customScaleController = TextEditingController(
    text: '1.0',
  );
  final TextEditingController _copiesController = TextEditingController(
    text: '1',
  );
  final TextEditingController _pageRangeController = TextEditingController();
  // Android bundled-cupsd test: the device URI to add as a raw queue. Defaults to
  // a dev-Mac fake printer (tool/android/fake-printer.sh). Edit to your host:9100.
  final TextEditingController _cupsUriController = TextEditingController(
    text: 'socket://192.168.2.165:9100',
  );
  String? _selectedPdfPath;

  ///int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    _rawDataController = TextEditingController(
      text: _getExampleRawData(_selectedRawDataType),
    );
    _refreshPrinters();
  }

  @override
  void dispose() {
    _rawDataController.dispose();
    _jobsSubscription?.cancel();
    _copiesController.dispose();
    _pageRangeController.dispose();
    _customScaleController.dispose();
    _cupsUriController.dispose();
    super.dispose();
  }

  void _showToast(String message, {bool isError = false}) {
    if (!mounted) return;
    ShadToaster.of(
      context,
    ).show(ShadToast(description: SelectableText(message)));
  }

  String _getExampleRawData(RawDataType type) {
    switch (type) {
      case RawDataType.zpl:
        return '^XA^FO50,50^A0N,50,50^FDHello, ZPL!^FS^XZ';
      case RawDataType.escPos:
        // ESC @ (initialize) -> ESC a 1 (center) -> Text -> LF*3 -> GS V 1 (cut)
        const esc = '\x1B';
        const gs = '\x1D';
        return '$esc@${esc}a\x01Hello, ESC/POS!\n\n\n${gs}V\x01';
      case RawDataType.custom:
        return '';
    }
  }

  void _onRawDataTypeChanged(RawDataType? newType) {
    if (newType == null) return;
    setState(() {
      _selectedRawDataType = newType;
      _rawDataController.text = _getExampleRawData(newType);
    });
  }

  Future<void> _refreshPrinters() async {
    setState(() {
      _isLoadingPrinters = true;
      _printers = [];
      _selectedPrinter = null;
      _jobs = [];
      _cupsOptions = null;
      _selectedCupsOptions = {};
      _windowsCapabilities = null;
      _selectedPaperSize = null;
      _selectedPaperSource = null;
      _selectedOrientation = WindowsOrientation.portrait;
      _selectedColorMode = ColorMode.color;
      _selectedPrintQuality = PrintQuality.normal;
      _selectedDuplexMode = DuplexMode.singleSided;
      _selectedPdfRotation = PdfRotation.auto;
      _collate = true;
      _selectedPdfPath = null;
    });
    try {
      final printers = PrintingFfi.instance.listPrinters();
      setState(() {
        _printers = printers;
        if (printers.isNotEmpty) {
          _selectedPrinter = printers.firstWhere(
            (p) => p.isDefault,
            orElse: () => printers.first,
          );
          _onPrinterSelected(_selectedPrinter);
        }
      });
    } catch (e) {
      _showToast('Failed to get printers: $e', isError: true);
    } finally {
      setState(() {
        _isLoadingPrinters = false;
      });
    }
  }

  void _onPrinterSelected(Printer? printer) {
    if (printer == null) return;
    setState(() {
      _jobsSubscription?.cancel();
      _jobs = [];
      _selectedPrinter = printer;
      _subscribeToJobs();
      _fetchCupsOptions();
      _fetchWindowsCapabilities();
    });
  }

  void _subscribeToJobs() {
    if (_selectedPrinter == null) return;
    _jobsSubscription?.cancel();
    setState(() => _isLoadingJobs = true);
    _jobsSubscription = PrintingFfi.instance
        .listPrintJobsStream(_selectedPrinter!.name)
        .listen(
          (jobs) {
            if (!mounted) return;
            setState(() {
              _jobs = jobs;
              _isLoadingJobs = false;
            });
          },
          onError: (e) {
            if (!mounted) return;
            _showToast('Error fetching jobs: $e', isError: true);
            setState(() => _isLoadingJobs = false);
          },
        );
  }

  Future<void> _fetchCupsOptions() async {
    if (_selectedPrinter == null) return;
    setState(() {
      _isLoadingCupsOptions = true;
      _cupsOptions = null;
    });

    try {
      final options = await PrintingFfi.instance.getSupportedCupsOptions(
        _selectedPrinter!.name,
      );
      if (!mounted) return;
      final defaultOptions = <String, String>{};
      for (final option in options) {
        defaultOptions[option.name] = option.defaultValue;
      }
      setState(() {
        _cupsOptions = options;
        _selectedCupsOptions = defaultOptions;
      });
    } catch (e) {
      _showToast('Failed to get CUPS options: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isLoadingCupsOptions = false);
    }
  }

  Future<void> _fetchWindowsCapabilities() async {
    if (_selectedPrinter == null || !Platform.isWindows) return;
    setState(() => _isLoadingWindowsCaps = true);
    try {
      final caps = await PrintingFfi.instance.getWindowsPrinterCapabilities(
        _selectedPrinter!.name,
      );
      if (!mounted) return;
      setState(() {
        _windowsCapabilities = caps;
        // Set defaults
        if (caps?.paperSizes.isNotEmpty ?? false) {
          _selectedPaperSize = caps!.paperSizes.first;
        }
        if (caps?.paperSources.isNotEmpty ?? false) {
          _selectedPaperSource = caps!.paperSources.first;
        }
        _selectedOrientation = WindowsOrientation.portrait;
      });
    } catch (e) {
      _showToast('Failed to get Windows capabilities: $e', isError: true);
    } finally {
      if (mounted) setState(() => _isLoadingWindowsCaps = false);
    }
  }

  // Builds the list of options to be sent to the native print functions.
  List<PrintOption> _buildPrintOptions({Map<String, String>? cupsOptions}) {
    final options = <PrintOption>[];
    if (Platform.isWindows) {
      if (_selectedPaperSize != null) {
        options.add(WindowsPaperSizeOption(_selectedPaperSize!.id));
      }
      if (_selectedPaperSource != null) {
        options.add(WindowsPaperSourceOption(_selectedPaperSource!.id));
      }
      options.add(AlignmentOption(_selectedAlignment));
    }
    options.add(OrientationOption(_selectedOrientation));
    options.add(ColorModeOption(_selectedColorMode));
    options.add(PrintQualityOption(_selectedPrintQuality));
    options.add(DuplexOption(_selectedDuplexMode));
    options.add(PdfRotationOption(_selectedPdfRotation));

    if (Platform.isWindows &&
        (_windowsCapabilities?.mediaTypes.any((t) => t.name == 'Photo') ??
            false)) {
      // Example of setting a specific media type if available
    }

    if (cupsOptions != null) {
      cupsOptions.forEach((key, value) {
        options.add(GenericCupsOption(key, value));
      });
    }
    // Include collate option for multiple copies (applies on both Windows and CUPS where supported)
    // This controls whether complete copies are printed together or all copies of each page
    options.add(CollateOption(_collate));
    return options;
  }

  ({PageRange? pageRange, PdfPrintScaling? scaling})? _parsePrintJobSettings() {
    // Parse Page Range
    final pageRangeString = _pageRangeController.text;
    PageRange? pageRange;
    if (pageRangeString.trim().isNotEmpty) {
      try {
        pageRange = PageRange.parse(pageRangeString);
      } on ArgumentError catch (e) {
        _showToast('Invalid page range: ${e.message}', isError: true);
        return null;
      }
    }

    // Parse Scaling
    final PdfPrintScaling scaling;
    if (_selectedScaling is CustomScaling) {
      final scaleValue = double.tryParse(_customScaleController.text);
      if (scaleValue == null || scaleValue <= 0) {
        _showToast(
          'Invalid custom scale value. It must be a positive number.',
          isError: true,
        );
        return null;
      }
      scaling = PdfPrintScaling.custom(scaleValue);
    } else {
      scaling = _selectedScaling as PdfPrintScaling;
    }
    return (pageRange: pageRange, scaling: scaling);
  }

  Future<String?> _getPdfPath() async {
    if (_selectedPdfPath != null) {
      return _selectedPdfPath;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
    );

    if (result != null && result.files.single.path != null) {
      final path = result.files.single.path!;
      setState(() {
        _selectedPdfPath = path;
      });
      return path;
    }
    return null;
  }

  Future<void> _printPdf({
    Map<String, String>? cupsOptions,
    required int copies,
  }) async {
    if (_selectedPrinter == null) {
      _showToast('No printer selected!', isError: true);
      return;
    }
    final settings = _parsePrintJobSettings();
    if (settings == null) return;

    final path = await _getPdfPath();
    if (path != null) {
      try {
        final options = _buildPrintOptions(cupsOptions: cupsOptions);
        _showToast('Printing PDF...');

        final success = await PrintingFfi.instance.printPdf(
          _selectedPrinter!.name,
          path,
          docName: 'My Flutter PDF',
          options: options,
          scaling: settings.scaling!,
          copies: copies,
          pageRange: settings.pageRange,
        );
        if (!mounted) return;
        if (success) {
          _showToast('PDF sent to printer successfully!');
        }
      } on PrintingFfiException catch (e) {
        _showToast('Failed to print PDF: ${e.message}', isError: true);
      } catch (e) {
        _showToast(
          'An unexpected error occurred while printing: $e',
          isError: true,
        );
      }
    }
  }

  /// Picks an image file and submits it to the selected printer via the new
  /// generic file-submit path (CUPS auto-detects the MIME type). This is the
  /// precursor to DNP dye-sub photo printing.
  ///
  /// NOTE: real image rendering (image -> printer raster) needs the
  /// cups-filters / Gutenprint image filters, which are NOT bundled yet. On a
  /// raw queue the image is sent unfiltered — the point here is that the submit
  /// path works and CUPS accepts the job.
  Future<void> _pickAndPrintImage() async {
    if (_selectedPrinter == null) {
      _showToast('No printer selected!', isError: true);
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
    );
    if (result == null || result.files.single.path == null) {
      return;
    }
    final path = result.files.single.path!;
    final fileName = result.files.single.name;

    if (!mounted) return;
    try {
      _showToast('Submitting image "$fileName"...');
      final jobId = await PrintingFfi.instance.printImage(
        printerName: _selectedPrinter!.name,
        imagePath: path,
        docName: fileName,
      );
      if (!mounted) return;
      if (jobId > 0) {
        _showToast('Image submitted (job $jobId). Note: raw queues send it unfiltered.');
      } else {
        _showToast('Image submit returned no job id.', isError: true);
      }
    } on PrintingFfiException catch (e) {
      _showToast('Failed to submit image: ${e.message}', isError: true);
    } catch (e) {
      _showToast('Unexpected error submitting image: $e', isError: true);
    }
  }

  /// Picks an image and prints it to the given auto-detected DNP queue. Wraps the
  /// submit in a foreground service so Android keeps the app (cupsd + fd-server +
  /// USB connection) alive across the multi-second dye-sub job.
  Future<void> _printImageToDnp(DnpUsbPrinter dnp) async {
    if (!dnp.ready) {
      _showToast('DNP queue not ready yet.', isError: true);
      return;
    }
    final result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result == null || result.files.single.path == null) return;
    final path = result.files.single.path!;
    final fileName = result.files.single.name;
    if (!mounted) return;

    await DnpUsb.instance.beginForegroundJob(text: 'Printing "$fileName" to ${dnp.modelName}');
    try {
      _showToast('Submitting "$fileName" to ${dnp.queueName}...');
      final jobId = await PrintingFfi.instance.printImage(
        printerName: dnp.queueName,
        imagePath: path,
        docName: fileName,
      );
      if (!mounted) return;
      if (jobId > 0) {
        _showToast('Image submitted to DNP (job $jobId).');
      } else {
        _showToast('DNP image submit returned no job id.', isError: true);
      }
    } on PrintingFfiException catch (e) {
      _showToast('Failed to print to DNP: ${e.message}', isError: true);
    } catch (e) {
      _showToast('Unexpected error printing to DNP: $e', isError: true);
    } finally {
      // Give the backend a moment to pick up the job before dropping the FGS.
      // (A production app would keep the FGS up until the job leaves the queue.)
      await Future<void>.delayed(const Duration(seconds: 2));
      await DnpUsb.instance.endForegroundJob();
    }
  }

  Future<void> _printPdfAndTrack() async {
    if (_selectedPrinter == null) {
      _showToast('No printer selected!', isError: true);
      return;
    }
    final path = await _getPdfPath();
    if (path != null) {
      final settings = _parsePrintJobSettings();
      if (settings == null) return;

      final copies = int.tryParse(_copiesController.text) ?? 1;
      final options = _buildPrintOptions();

      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => PrintStatusDialog(
          onToast: _showToast,
          printerName: _selectedPrinter!.name,
          jobStream: PrintingFfi.instance.printPdfAndStreamStatus(
            _selectedPrinter!.name,
            path,
            options: options,
            scaling: settings.scaling!,
            copies: copies,
            pageRange: settings.pageRange,
          ),
        ),
      );
    }
  }

  Future<void> _printRawDataAndTrack() async {
    if (_selectedPrinter == null) {
      _showToast('No printer selected!', isError: true);
      return;
    }
    // Use the raw text from the input field directly.
    final rawCommand = _rawDataController.text;
    if (rawCommand.isEmpty) {
      _showToast('Please enter some raw data to print.', isError: true);
      return;
    }
    final data = Uint8List.fromList(rawCommand.codeUnits);

    final options = _buildPrintOptions(cupsOptions: _selectedCupsOptions);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PrintStatusDialog(
        onToast: _showToast,
        printerName: _selectedPrinter!.name,
        jobStream: PrintingFfi.instance.rawDataToPrinterAndStreamStatus(
          _selectedPrinter!.name,
          data,
          docName: 'My Tracked ZPL Label',
          options: options,
        ),
      ),
    );
  }

  Future<void> _printRawData() async {
    if (_selectedPrinter == null) {
      _showToast('No printer selected!', isError: true);
      return;
    }
    // Use the raw text from the input field directly.
    final rawCommand = _rawDataController.text;
    if (rawCommand.isEmpty) {
      _showToast('Please enter some raw data to print.', isError: true);
      return;
    }
    final data = Uint8List.fromList(rawCommand.codeUnits);

    final options = _buildPrintOptions(cupsOptions: _selectedCupsOptions);
    _showToast('Sending raw ZPL data...');
    final success = await PrintingFfi.instance.rawDataToPrinter(
      _selectedPrinter!.name,
      data,
      docName: 'My ZPL Label',
      options: options,
    );
    if (!mounted) return;
    if (success) {
      _showToast('Raw data sent successfully!');
    } else {
      _showToast('Failed to send raw data.', isError: true);
    }
  }

  Future<void> _manageJob(int jobId, String action) async {
    if (_selectedPrinter == null) return;
    bool success = false;
    try {
      switch (action) {
        case 'pause':
          success = await PrintingFfi.instance.pausePrintJob(
            _selectedPrinter!.name,
            jobId,
          );
          break;
        case 'resume':
          success = await PrintingFfi.instance.resumePrintJob(
            _selectedPrinter!.name,
            jobId,
          );
          break;
        case 'cancel':
          success = await PrintingFfi.instance.cancelPrintJob(
            _selectedPrinter!.name,
            jobId,
          );
          break;
      }
      if (!mounted) return;
      _showToast(
        'Job $action ${success ? 'succeeded' : 'failed'}.',
        isError: !success,
      );
    } catch (e) {
      _showToast('Error managing job: $e', isError: true);
    }
  }

  Future<void> _printFileWithDialog() async {
    final path = await _getPdfPath();
    if (path == null) {
      _showToast('No file selected.', isError: true);
      return;
    }

    try {
      _showToast('Opening system print dialog...');
      final success = await PrintingFfi.instance.printFileWithDialog(
        path,
        docName: 'System Dialog Print Job',
      );
      if (!mounted) return;
      if (success) {
        _showToast('Print dialog opened successfully.');
      } else {
        // The native code sets a detailed error message.
        _showToast('Could not open print dialog.', isError: true);
      }
    } on PrintingFfiException catch (e) {
      print(e);
      _showToast(e.message, isError: true);
    }
  }

  Future<void> _printFileWithDialogAndTrack() async {
    final path = await _getPdfPath();
    if (path == null) {
      _showToast('No file selected.', isError: true);
      return;
    }

    try {
      _showToast('Opening system print dialog...');
      final success = await PrintingFfi.instance.printFileWithDialog(
        path,
        docName: 'Tracked System Dialog Print Job',
      );
      if (!mounted) return;
      if (success) {
        _showToast(
          'Print dialog opened successfully. Check print queue for status.',
        );
      } else {
        _showToast('Could not open print dialog.', isError: true);
      }
    } on PrintingFfiException catch (e) {
      _showToast(e.message, isError: true);
    }
  }

  Future<void> _showWindowsCapabilities() async {
    if (_selectedPrinter == null || !Platform.isWindows) return;

    final capabilities = await PrintingFfi.instance
        .getWindowsPrinterCapabilities(_selectedPrinter!.name);

    if (!mounted) return;

    if (capabilities == null) {
      _showToast(
        'Could not retrieve capabilities for this printer.',
        isError: true,
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Capabilities for ${_selectedPrinter!.name}'),
        content: SizedBox(
          width: 400,
          height: 500,
          child: ListView(
            children: [
              Text(
                'Paper Sizes (${capabilities.paperSizes.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final paper in capabilities.paperSizes)
                ListTile(
                  dense: true,
                  title: Text(paper.name),
                  subtitle: Text(
                    'ID: ${paper.id}, ${paper.widthMillimeters.toStringAsFixed(1)} x ${paper.heightMillimeters.toStringAsFixed(1)} mm',
                  ),
                ),
              const Divider(),
              Text(
                'Paper Sources (${capabilities.paperSources.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final paper in capabilities.paperSources)
                ListTile(
                  dense: true,
                  title: Text(paper.name),
                  subtitle: Text(paper.toString()),
                ),
              const Divider(),
              Text(
                'Media Types (${capabilities.mediaTypes.length})',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final media in capabilities.mediaTypes)
                ListTile(
                  dense: true,
                  title: Text(media.name),
                  subtitle: Text('ID: ${media.id}'),
                ),
              const Divider(),
              Text(
                'Supported Resolutions',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              for (final res in capabilities.resolutions)
                ListTile(title: Text(res.toString())),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Printing FFI Example'),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: ShadSelect<AppColorScheme>(
                selectedOptionBuilder: (context, value) => Text(value.name),
                initialValue: widget.selectedScheme,
                onChanged: widget.onSchemeChange,
                options: availableColorSchemes
                    .map(
                      (scheme) =>
                          ShadOption(value: scheme, child: Text(scheme.name)),
                    )
                    .toList(),
              ),
            ),
            // Android: open the bundled cupsd admin/settings page (/admin) in the
            // plugin's in-app WebView. One call, no app-built widget.
            if (Platform.isAndroid)
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                tooltip: 'CUPS settings',
                onPressed: () => PrintingFfi.instance.openCupsSettings(context),
              ),
            IconButton(
              icon: const Icon(Icons.brightness_6_outlined),
              onPressed: widget.onThemeToggle,
            ),
            IconButton(
              icon: const Icon(Icons.refresh_outlined),
              onPressed: _refreshPrinters,
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(icon: Icon(Icons.print_outlined), text: 'Standard'),
              Tab(
                icon: Icon(Icons.settings_applications),
                text: 'Advanced (CUPS)',
              ),
            ],
          ),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // The Android CUPS/DNP banners can grow (DNP list, URI field,
              // buttons). Cap them to a fraction of the screen and let them
              // scroll internally so they never overflow or squeeze out the
              // tabs below. Everything stays reachable.
              if (Platform.isAndroid)
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.42,
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildCupsAndroidBanner(),
                        const SizedBox(height: 12),
                        _buildDnpUsbBanner(),
                      ],
                    ),
                  ),
                ),
              if (Platform.isAndroid) const SizedBox(height: 12),
              _buildPrinterSelector(),
              const SizedBox(height: 20),
              Expanded(
                child: TabBarView(
                  physics: const NeverScrollableScrollPhysics(),
                  children: [_buildSimpleTab(), _buildAdvancedTab()],
                ),
              ),
              if (_isLoadingPrinters)
                const Center(child: CircularProgressIndicator()),
              if (!_isLoadingPrinters && _printers.isEmpty)
                const Center(
                  child: Text('No printers found. Press refresh to try again.'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// A collapsible banner card: an always-visible header (title + one-line status +
  /// expand/collapse chevron) and a [body] shown only when expanded. Collapsed by
  /// default so the Android banners stay compact at the top of the screen.
  Widget _collapsibleBanner({
    required Color color,
    required String title,
    required Widget statusLine,
    required bool expanded,
    required VoidCallback onToggle,
    required Widget body,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 2),
                        DefaultTextStyle.merge(
                          style: const TextStyle(fontSize: 12),
                          child: statusLine,
                        ),
                      ],
                    ),
                  ),
                  Icon(expanded ? Icons.expand_less : Icons.expand_more),
                ],
              ),
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: body,
            ),
        ],
      ),
    );
  }

  Widget _buildCupsAndroidBanner() {
    return _collapsibleBanner(
      color: Colors.indigo,
      title: 'Bundled CUPS (in-app cupsd)',
      statusLine: ValueListenableBuilder<String>(
        valueListenable: CupsAndroidBoot.status,
        builder: (context, value, _) =>
            Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      expanded: _cupsBannerExpanded,
      onToggle: () =>
          setState(() => _cupsBannerExpanded = !_cupsBannerExpanded),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _cupsUriController,
            decoration: const InputDecoration(
              labelText: 'Device URI (e.g. socket://<host>:9100)',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ElevatedButton(
                onPressed: () async {
                  final uri = _cupsUriController.text.trim();
                  final ok = await CupsAndroidBoot.addTestPrinter(
                    name: 'test',
                    deviceUri: uri,
                  );
                  if (!mounted) return;
                  _showToast(
                    ok ? 'Added queue: $uri' : 'Add failed (see banner/logcat)',
                    isError: !ok,
                  );
                  await _refreshPrinters();
                },
                child: const Text('Add raw socket:// queue'),
              ),
              OutlinedButton(
                onPressed: () => _refreshPrinters(),
                child: const Text('Refresh printers'),
              ),
              ElevatedButton.icon(
                onPressed: _pickAndPrintImage,
                icon: const Icon(Icons.image, size: 16),
                label: const Text('Pick & print image'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// DNP dye-sub USB auto-detect status + detected-printer list. Plug a DNP printer
  /// in (grant permission when prompted) and it auto-adds a CUPS queue here.
  Widget _buildDnpUsbBanner() {
    return _collapsibleBanner(
      color: Colors.teal,
      title: 'DNP dye-sub (USB auto-detect)',
      statusLine: ValueListenableBuilder<String>(
        valueListenable: DnpUsb.instance.status,
        builder: (context, value, _) =>
            Text(value, maxLines: 2, overflow: TextOverflow.ellipsis),
      ),
      expanded: _dnpBannerExpanded,
      onToggle: () => setState(() => _dnpBannerExpanded = !_dnpBannerExpanded),
      body: ValueListenableBuilder<List<DnpUsbPrinter>>(
        valueListenable: DnpUsb.instance.printers,
        builder: (context, list, _) {
          if (list.isEmpty) {
            return const Text(
              'No DNP printer detected. Plug one in and grant USB permission.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final dnp in list)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      Icon(
                        dnp.ready ? Icons.check_circle : Icons.usb,
                        size: 18,
                        color: dnp.ready ? Colors.green : Colors.orange,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${dnp.modelName.isNotEmpty ? dnp.modelName : dnp.queueName}'
                          '${dnp.serial.isNotEmpty ? ' (${dnp.serial})' : ''}'
                          '${dnp.ready ? '' : ' — connecting…'}',
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed:
                            dnp.ready ? () => _printImageToDnp(dnp) : null,
                        icon: const Icon(Icons.print, size: 16),
                        label: const Text('Print image'),
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSimpleTab() {
    if (_selectedPrinter == null) {
      return const Center(
        child: Text('Please select a printer to see standard actions.'),
      );
    }
    return ListView(
      children: [
        const PrintingMethodsInfo(),
        const SizedBox(height: 20),
        StandardActionsCard(
          selectedScaling: _selectedScaling,
          onScalingChanged: (newSelection) {
            setState(() {
              _selectedScaling = newSelection.first;
            });
          },
          customScaleController: _customScaleController,
          selectedPdfPath: _selectedPdfPath,
          onClearPdfPath: () {
            setState(() {
              _selectedPdfPath = null;
            });
          },
          onPrintPdf:
              ({required copies, cupsOptions, required pageRangeString}) {
                _printPdf(copies: copies, cupsOptions: cupsOptions);
              },
          copiesController: _copiesController,
          pageRangeController: _pageRangeController,
          collate: _collate,
          onCollateChanged: (v) => setState(() => _collate = v),
          onPrintPdfAndTrack: _printPdfAndTrack,
          onShowWindowsCapabilities: _showWindowsCapabilities,
          rawDataController: _rawDataController,
          onPrintRawData: _printRawData,
          onPrintRawDataAndTrack: _printRawDataAndTrack,
          selectedRawDataType: _selectedRawDataType,
          onRawDataTypeChanged: _onRawDataTypeChanged,
          extraActions: [
            ShadButton.outline(
              leading: const Icon(Icons.open_in_new, size: 16),
              onPressed: _printFileWithDialog,
              child: const Text('Print File with System Dialog'),
            ),
            const SizedBox(height: 8),
            ShadButton.secondary(
              leading: const Icon(Icons.track_changes, size: 16),
              onPressed: _printFileWithDialogAndTrack,
              child: const Text('Print File with Dialog & Track'),
            ),
            const SizedBox(height: 8),
            ShadButton.outline(
              leading: const Icon(Icons.image, size: 16),
              onPressed: _pickAndPrintImage,
              child: const Text('Pick & print image'),
            ),
          ],
          platformSettings: _buildPlatformSettings(),
        ),
        const SizedBox(height: 20),
        JobsList(
          isLoading: _isLoadingJobs,
          jobs: _jobs,
          onManageJob: _manageJob,
        ),
      ],
    );
  }

  Widget _buildPrinterSelector() {
    return PrinterSelector(
      printers: _printers,
      selectedPrinter: _selectedPrinter,
      onChanged: _onPrinterSelected,
    );
  }

  Widget _buildPlatformSettings() {
    return PlatformSettings(
      isLoading: _isLoadingWindowsCaps,
      windowsCapabilities: _windowsCapabilities,
      selectedPaperSize: _selectedPaperSize,
      onPaperSizeChanged: (p) => setState(() => _selectedPaperSize = p),
      selectedPaperSource: _selectedPaperSource,
      onPaperSourceChanged: (s) => setState(() => _selectedPaperSource = s),
      selectedAlignment: _selectedAlignment,
      onAlignmentChanged: (a) =>
          setState(() => _selectedAlignment = a ?? PdfPrintAlignment.center),
      selectedPrintQuality: _selectedPrintQuality,
      onPrintQualityChanged: (q) =>
          setState(() => _selectedPrintQuality = q ?? PrintQuality.normal),
      selectedColorMode: _selectedColorMode,
      onColorModeChanged: (c) =>
          setState(() => _selectedColorMode = c ?? ColorMode.color),
      selectedOrientation: _selectedOrientation,
      onOrientationChanged: (o) => setState(
        () => _selectedOrientation = o ?? WindowsOrientation.portrait,
      ),
      selectedDuplexMode: _selectedDuplexMode,
      onDuplexModeChanged: (d) =>
          setState(() => _selectedDuplexMode = d ?? DuplexMode.singleSided),
      selectedPdfRotation: _selectedPdfRotation,
      onPdfRotationChanged: (r) =>
          setState(() => _selectedPdfRotation = r ?? PdfRotation.auto),
      onOpenProperties: () async {
        if (_selectedPrinter == null) return;
        // Android: open the bundled cupsd web interface for this printer via the
        // plugin's in-app settings page (the desktop openPrinterProperties is a
        // no-op there). No app-built widget needed.
        if (Platform.isAndroid) {
          if (!mounted) return;
          await PrintingFfi.instance.openCupsPrinterSettings(
            context,
            printerName: _selectedPrinter!.name,
          );
          return;
        }
        try {
          final result = await PrintingFfi.instance.openPrinterProperties(
            _selectedPrinter!.name,
            hwnd: 0,
          );
          if (!mounted) return;
          switch (result) {
            case PrinterPropertiesResult.ok:
              _showToast('Printer properties updated successfully.');
              _fetchWindowsCapabilities();
              break;
            case PrinterPropertiesResult.cancel:
              _showToast(
                'Printer properties dialog was cancelled.',
                isError: false,
              );
              break;
            case PrinterPropertiesResult.error:
              _showToast('Could not open printer properties.', isError: true);
              break;
          }
        } catch (e) {
          _showToast('Error opening properties: $e', isError: true);
        }
      },
      onShowCapabilities: _showWindowsCapabilities,
    );
  }

  Widget _buildAdvancedTab() {
    if (_selectedPrinter == null) {
      return const Center(
        child: Text('Please select a printer to see advanced options.'),
      );
    }
    return AdvancedTab(
      isLoading: _isLoadingCupsOptions,
      cupsOptions: _cupsOptions,
      selectedCupsOptions: _selectedCupsOptions,
      onOptionChanged: (key, value) {
        setState(() {
          _selectedCupsOptions[key] = value;
        });
      },
      onPrint: () => _printPdf(
        cupsOptions: _selectedCupsOptions,
        copies: int.tryParse(_copiesController.text) ?? 1,
      ),
    );
  }
}
