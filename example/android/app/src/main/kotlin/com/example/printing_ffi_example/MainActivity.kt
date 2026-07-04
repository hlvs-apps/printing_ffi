package com.example.printing_ffi_example

import io.flutter.embedding.android.FlutterActivity

/**
 * Plain FlutterActivity. All the CUPS / DNP USB native glue now lives in the
 * printing_ffi plugin (PrintingFfiPlugin, a FlutterPlugin + ActivityAware), which
 * auto-registers via the Flutter plugin registrant. The consumer app hosts no
 * custom Kotlin — see the plugin's PrintingFfiPlugin.kt.
 */
class MainActivity : FlutterActivity()
