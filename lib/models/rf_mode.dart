class RfMode {
  final String id;
  final String name;
  final String description;
  final bool supportsTransmit;
  final bool supportsReceive;
  final double defaultBandwidthHz;

  const RfMode({
    required this.id,
    required this.name,
    required this.description,
    this.supportsTransmit = true,
    this.supportsReceive = true,
    required this.defaultBandwidthHz,
  });

  static const List<RfMode> builtInModes = [
    RfMode(id: 'am', name: 'AM', description: 'Amplitude Modulation', defaultBandwidthHz: 10000),
    RfMode(id: 'nfm', name: 'NFM', description: 'Narrow FM', defaultBandwidthHz: 12500),
    RfMode(id: 'wfm', name: 'WFM', description: 'Wideband FM', supportsTransmit: false, defaultBandwidthHz: 200000),
    RfMode(id: 'usb', name: 'USB', description: 'Upper Sideband', defaultBandwidthHz: 3000),
    RfMode(id: 'lsb', name: 'LSB', description: 'Lower Sideband', defaultBandwidthHz: 3000),
    RfMode(id: 'cw', name: 'CW', description: 'Continuous Wave (Morse)', defaultBandwidthHz: 500),
    RfMode(id: 'psk31', name: 'PSK31', description: 'Phase Shift Keying 31 baud', defaultBandwidthHz: 62),
    RfMode(id: 'rtty', name: 'RTTY', description: 'Radio Teletype', defaultBandwidthHz: 170),
    RfMode(id: 'ft8', name: 'FT8', description: 'Franke-Taylor 8-tone', defaultBandwidthHz: 50),
    RfMode(id: 'wspr', name: 'WSPR', description: 'Weak Signal Propagation Reporter', defaultBandwidthHz: 6),
    RfMode(id: 'dstar', name: 'D-STAR', description: 'Digital Smart Technologies for Amateur Radio', defaultBandwidthHz: 6250),
    RfMode(id: 'dmr', name: 'DMR', description: 'Digital Mobile Radio', defaultBandwidthHz: 12500),
    RfMode(id: 'custom', name: 'Custom', description: 'User-defined mode', defaultBandwidthHz: 10000),
  ];
}
