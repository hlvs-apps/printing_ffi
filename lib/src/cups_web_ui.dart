import 'dart:io';

import 'package:flutter/material.dart';
import 'package:printing_ffi/printing_ffi.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// Full-screen in-app WebView that renders a page from the bundled Android cupsd
/// web interface (served by the in-app cupsd on `http://127.0.0.1:<port>`).
///
/// Apps normally do not construct this directly. Use the helpers on
/// [PrintingFfi] instead:
///
/// ```dart
/// PrintingFfi.instance.openCupsSettings(context);                     // /admin
/// PrintingFfi.instance.openCupsPrinterSettings(context,               // /printers/<name>
///     printerName: printer.name);
/// ```
///
/// The WebView sends the device's own `Accept-Language`, so cupsd localizes the
/// UI to the phone's locale (falling back to the English base templates).
class CupsWebView extends StatefulWidget {
  const CupsWebView({super.key, required this.url, required this.title});

  /// Absolute URL on the in-app cupsd, e.g. `http://127.0.0.1:55813/admin`.
  final String url;

  /// AppBar title.
  final String title;

  @override
  State<CupsWebView> createState() => _CupsWebViewState();
}

class _CupsWebViewState extends State<CupsWebView> {
  late final WebViewController _controller;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (err) {
            if (mounted) {
              setState(() {
                _loading = false;
                _error = 'Failed to load: ${err.description}';
              });
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(widget.url));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Reload',
            onPressed: () => _controller.reload(),
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            )
          else if (_loading)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}

/// Android web-UI helpers: open the bundled cupsd web interface in-app so a
/// consuming app never has to build its own settings screen.
///
/// All are no-ops (return without pushing) when the bundled cupsd is not running
/// ([PrintingFfi.cupsServerPort] is `null`) or off Android; they surface a
/// SnackBar so the failure is visible rather than silent.
extension CupsWebUi on PrintingFfi {
  /// Opens the general CUPS admin/settings page (`/admin`) in a full-screen
  /// in-app WebView.
  Future<void> openCupsSettings(
    BuildContext context, {
    String title = 'CUPS Settings',
  }) {
    return _open(context, cupsSettingsUrl, title);
  }

  /// Opens a single printer's properties/maintenance page
  /// (`/printers/<name>`) in a full-screen in-app WebView.
  Future<void> openCupsPrinterSettings(
    BuildContext context, {
    required String printerName,
    String? title,
  }) {
    return _open(context, cupsPrinterSettingsUrl(printerName), title ?? printerName);
  }

  Future<void> _open(BuildContext context, String? url, String title) async {
    if (!Platform.isAndroid || url == null) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('CUPS server is not running yet.')),
        );
      }
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => CupsWebView(url: url, title: title),
      ),
    );
  }
}
