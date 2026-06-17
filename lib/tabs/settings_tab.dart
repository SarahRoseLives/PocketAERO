import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/theme_provider.dart';
import '../providers/radio_provider.dart';
import '../providers/aero_provider.dart';
import '../models/waterfall_settings.dart';
import '../services/version_check.dart';

class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final theme = context.watch<ThemeProvider>();
    final radio = context.watch<RadioProvider>();
    final aero = context.watch<AeroProvider>();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // ── Appearance ──────────────────────────────────────────────────
        _sectionHeader('Appearance', Icons.palette, cs),
        _tile(
          icon: theme.isDark ? Icons.dark_mode : Icons.light_mode,
          title: 'Theme',
          subtitle: theme.isDark ? 'Dark mode' : 'Light mode',
          trailing: Switch(
            value: theme.isDark,
            onChanged: (_) => theme.toggle()),
          cs: cs,
        ),
        _tile(
          icon: Icons.water_drop,
          title: 'Waterfall Colormap',
          subtitle: '${radio.wfSettings.colorScheme.name}',
          trailing: DropdownButton<WaterfallColorScheme>(
            value: radio.wfSettings.colorScheme,
            underline: const SizedBox(),
            items: WaterfallColorScheme.values.map((s) =>
              DropdownMenuItem(value: s, child: Text(s.name,
                style: const TextStyle(fontSize: 12)))).toList(),
            onChanged: (v) {
              if (v != null) radio.updateWaterfallSettings(
                radio.wfSettings.copyWith(colorScheme: v));
            },
          ),
          cs: cs,
        ),
        SizedBox(height: _spacing),
        Text('Display Range: ${radio.wfSettings.minDb.toInt()} to ${radio.wfSettings.maxDb.toInt()} dB',
          style: TextStyle(fontSize: 11, color: cs.onSurface.withValues(alpha: 0.6))),
        RangeSlider(
          values: RangeValues(radio.wfSettings.minDb, radio.wfSettings.maxDb),
          min: -140, max: 0,
          divisions: 140,
          labels: RangeLabels('${radio.wfSettings.minDb.toInt()}', '${radio.wfSettings.maxDb.toInt()}'),
          onChanged: (v) => radio.updateWaterfallSettings(
            radio.wfSettings.copyWith(minDb: v.start, maxDb: v.end)),
        ),
        const Divider(height: 24),

        // ── Decoder ─────────────────────────────────────────────────────
        _sectionHeader('Decoder', Icons.memory, cs),
        _tile(
          icon: Icons.phone_in_talk,
          title: 'Voice Follow',
          subtitle: aero.voiceFollow ? 'Auto-tune on C_ASSIGN' : 'Manual tuning only',
          trailing: Switch(
            value: aero.voiceFollow,
            onChanged: (v) => aero.setVoiceFollow(v),
            activeColor: Colors.purpleAccent),
          cs: cs,
        ),
        _tile(
          icon: Icons.water_drop,
          title: 'FFT Size',
          subtitle: '${radio.wfSettings.fftSize.bins} bins',
          trailing: DropdownButton<FftSize>(
            value: radio.wfSettings.fftSize,
            underline: const SizedBox(),
            items: FftSize.values.map((s) =>
              DropdownMenuItem(value: s, child: Text('${s.bins}', style: const TextStyle(fontSize: 12)))).toList(),
            onChanged: (v) {
              if (v != null) radio.updateWaterfallSettings(
                radio.wfSettings.copyWith(fftSize: v));
            },
          ),
          cs: cs,
        ),
        _tile(
          icon: Icons.texture,
          title: 'Waterfall Rows',
          subtitle: '${radio.wfSettings.waterfallRows}',
          trailing: DropdownButton<int>(
            value: radio.wfSettings.waterfallRows,
            underline: const SizedBox(),
            items: [100, 150, 200, 250, 300, 400].map((r) =>
              DropdownMenuItem(value: r, child: Text('$r', style: const TextStyle(fontSize: 12)))).toList(),
            onChanged: (v) {
              if (v != null) radio.updateWaterfallSettings(
                radio.wfSettings.copyWith(waterfallRows: v));
            },
          ),
          cs: cs,
        ),
        _tile(
          icon: Icons.tune,
          title: 'Sample Rate',
          subtitle: '${(radio.wfSettings.sampleRateHz / 1e6).toStringAsFixed(3)} Msps',
          trailing: DropdownButton<int>(
            value: radio.wfSettings.sampleRateHz,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 240000, child: Text('0.240', style: TextStyle(fontSize: 12))),
              DropdownMenuItem(value: 1024000, child: Text('1.024', style: TextStyle(fontSize: 12))),
              DropdownMenuItem(value: 2048000, child: Text('2.048', style: TextStyle(fontSize: 12))),
              DropdownMenuItem(value: 2400000, child: Text('2.400', style: TextStyle(fontSize: 12))),
            ],
            onChanged: (v) {
              if (v != null) {
                radio.updateWaterfallSettings(
                  radio.wfSettings.copyWith(sampleRateHz: v));
              }
            },
          ),
          cs: cs,
        ),
        const Divider(height: 24),

        // ── About ───────────────────────────────────────────────────────
        _sectionHeader('About', Icons.info_outline, cs),
        _tile(icon: Icons.info, title: 'Version', subtitle: '1.0.3',
          trailing: TextButton(onPressed: () async {
            final vc = VersionCheckService();
            await vc.check();
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                content: Text(vc.updateAvailable
                  ? 'Update available: v${vc.remoteVersion}'
                  : 'Up to date'),
                duration: const Duration(seconds: 2)));
            }
          }, child: const Text('Check', style: TextStyle(fontSize: 12))),
          cs: cs),
        _tile(icon: Icons.code, title: 'License', subtitle: 'GPL v3.0', cs: cs),
        _tile(icon: Icons.person, title: 'Author', subtitle: 'SarahRoseLives', cs: cs),
        const SizedBox(height: 12),
        Text('Credits: JAERO, inmarsat-sniffer, librtlsdr, mbelib, libaeroambe',
          style: TextStyle(fontSize: 10, color: cs.onSurface.withValues(alpha: 0.4))),
        const SizedBox(height: 24),
      ]),
    );
  }

  static const _spacing = 4.0;

  Widget _sectionHeader(String title, IconData icon, ColorScheme cs) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        Icon(icon, size: 16, color: cs.primary),
        const SizedBox(width: 8),
        Text(title, style: TextStyle(
          fontSize: 13, fontWeight: FontWeight.w600, color: cs.primary)),
      ]),
    );
  }

  Widget _tile({
    required IconData icon,
    required String title,
    required String subtitle,
    required ColorScheme cs,
    Widget? trailing,
  }) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, size: 18, color: cs.onSurface.withValues(alpha: 0.7)),
      title: Text(title, style: const TextStyle(fontSize: 12)),
      subtitle: Text(subtitle, style: TextStyle(
        fontSize: 10, color: cs.onSurface.withValues(alpha: 0.5))),
      trailing: trailing,
    );
  }
}
