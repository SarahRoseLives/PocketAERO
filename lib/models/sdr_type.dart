/// Hardware SDR types supported by RFStudio.
enum SdrType {
  rtlSdr,
  hackRf,
  plutoSdr;

  String get displayName => switch (this) {
    SdrType.rtlSdr   => 'RTL-SDR',
    SdrType.hackRf   => 'HackRF',
    SdrType.plutoSdr => 'PlutoSDR',
  };

  String get shortName => switch (this) {
    SdrType.rtlSdr   => 'RTL',
    SdrType.hackRf   => 'HRF',
    SdrType.plutoSdr => 'PLT',
  };
}

/// Convenience typedef — a set of SDR types that support a given feature.
typedef SdrCompat = Set<SdrType>;

/// Pre-defined compat sets used by nav items.
class SdrSets {
  SdrSets._();

  static const SdrCompat all       = {SdrType.rtlSdr, SdrType.hackRf, SdrType.plutoSdr};
  static const SdrCompat rxOnly    = {SdrType.rtlSdr, SdrType.hackRf};
  static const SdrCompat rtlOnly   = {SdrType.rtlSdr};
  static const SdrCompat hackRfOnly = {SdrType.hackRf};
  static const SdrCompat txCapable = {SdrType.hackRf, SdrType.plutoSdr};
  static const SdrCompat rtlAndHrf = {SdrType.rtlSdr, SdrType.hackRf};
}
