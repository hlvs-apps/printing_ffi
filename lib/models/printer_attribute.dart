/// Represents a single printer attribute retrieved from CUPS.
///
/// An attribute can have a single value or multiple values (array).
/// Use [isSingleValue] to check if the attribute has a single value.
/// Access [value] for single-valued attributes or [values] for multi-valued ones.
class PrinterAttribute {
  /// The name of the attribute (e.g., 'printer-state', 'printer-make-and-model')
  final String name;

  /// The single value of the attribute (null if this is a multi-valued attribute)
  final String? value;

  /// The array of values for multi-valued attributes (null if this is single-valued)
  final List<String>? values;

  /// Number of values in this attribute
  final int valueCount;

  const PrinterAttribute({
    required this.name,
    this.value,
    this.values,
    required this.valueCount,
  });

  /// Returns true if this attribute has a single value
  bool get isSingleValue => valueCount == 1 && value != null;

  /// Returns true if this attribute has multiple values
  bool get isMultiValue => valueCount > 1 && values != null;

  @override
  String toString() {
    if (isSingleValue) {
      return 'PrinterAttribute($name: $value)';
    } else if (isMultiValue) {
      return 'PrinterAttribute($name: [${values!.join(', ')}])';
    } else {
      return 'PrinterAttribute($name: empty)';
    }
  }
}
