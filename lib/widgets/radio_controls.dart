import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/radio_provider.dart';
import '../models/app_theme.dart';
import '../models/waterfall_settings.dart';
import '../models/sdr_type.dart';

class PttButton extends StatelessWidget {
  const PttButton({super.key});

  @override
  Widget build(BuildContext context) {
    final radio = context.watch<RadioProvider>();
    final canTx = radio.selectedMode.supportsTransmit && radio.connectionStatus == ConnectionStatus.connected;
    final isTx = radio.isTransmitting;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('PTT', style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Colors.grey[600], letterSpacing: 1.5, fontWeight: FontWeight.w600,
        )),
        const SizedBox(height: 8),
        GestureDetector(
          onTapDown: canTx ? (_) => radio.startTransmit() : null,
          onTapUp: isTx ? (_) => radio.stopTransmit() : null,
          onTapCancel: isTx ? radio.stopTransmit : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 100,
            height: 100,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isTx
                  ? AppTheme.txColor
                  : canTx
                      ? AppTheme.primary
                      : Colors.grey[300],
              boxShadow: isTx
                  ? [BoxShadow(color: AppTheme.txColor.withValues(alpha: 0.5), blurRadius: 16, spreadRadius: 4)]
                  : [BoxShadow(color: Colors.black.withValues(alpha: 0.2), blurRadius: 8)],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  isTx ? Icons.mic : Icons.mic_none,
                  color: Colors.white,
                  size: 32,
                ),
                const SizedBox(height: 2),
                Text(
                  isTx ? 'TX' : 'TAP',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 12),
                ),
              ],
            ),
          ),
        ),
        if (!canTx && !radio.isTransmitting)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              radio.connectionStatus != ConnectionStatus.connected ? 'Not connected' : 'RX only',
              style: TextStyle(fontSize: 11, color: Colors.grey[500]),
            ),
          ),
      ],
    );
  }
}

class RadioControls extends StatelessWidget {
  const RadioControls({super.key});

  @override
  Widget build(BuildContext context) {
    final radio = context.watch<RadioProvider>();

    final sliders = Column(
      children: [
        _LabeledSlider(
          label: 'RX Volume',
          icon: radio.muteRx ? Icons.volume_off : Icons.volume_up,
          value: radio.rxVolume,
          onChanged: radio.setRxVolume,
          onIconTap: radio.toggleMuteRx,
          activeColor: AppTheme.rxColor,
        ),
        const SizedBox(height: 8),
        _LabeledSlider(
          label: 'TX Power',
          icon: Icons.power,
          value: radio.txPower,
          onChanged: radio.setTxPower,
          activeColor: AppTheme.txColor,
        ),
        const SizedBox(height: 8),
        _LabeledSlider(
          label: 'Squelch',
          icon: Icons.graphic_eq,
          value: radio.squelch,
          onChanged: radio.setSquelch,
          activeColor: AppTheme.accent,
        ),
      ],
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('CONTROLS', style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Colors.grey[600], letterSpacing: 1.5, fontWeight: FontWeight.w600,
            )),
            const SizedBox(height: 12),
            LayoutBuilder(builder: (context, constraints) {
              // Side-by-side only when we have enough horizontal space for sliders + PTT
              if (constraints.maxWidth >= 280) {
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: sliders),
                    const SizedBox(width: 16),
                    const PttButton(),
                  ],
                );
              }
              // Narrow: stack PTT on top, sliders below
              return Column(
                children: [
                  const PttButton(),
                  const SizedBox(height: 12),
                  sliders,
                ],
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  final String label;
  final IconData icon;
  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback? onIconTap;
  final Color activeColor;

  const _LabeledSlider({
    required this.label,
    required this.icon,
    required this.value,
    required this.onChanged,
    required this.activeColor,
    this.onIconTap,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        GestureDetector(
          onTap: onIconTap,
          child: Icon(icon, size: 20, color: activeColor),
        ),
        const SizedBox(width: 4),
        Flexible(
          flex: 0,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 56),
            child: Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(activeTrackColor: activeColor, thumbColor: activeColor),
            child: Slider(value: value, onChanged: onChanged),
          ),
        ),
        SizedBox(
          width: 30,
          child: Text('${(value * 100).toInt()}%', style: const TextStyle(fontSize: 11), textAlign: TextAlign.right),
        ),
      ],
    );
  }
}

// ── Spectrum / Waterfall inline controls ─────────────────────────────────────

class SpectrumControls extends StatelessWidget {
  const SpectrumControls({super.key});

  @override
  Widget build(BuildContext context) {
    final radio = context.watch<RadioProvider>();
    final s = radio.wfSettings;
    final theme = Theme.of(context);
    final sdrType = radio.backend?.connectedType;

    void update(WaterfallSettings ns) => radio.updateWaterfallSettings(ns);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('SPECTRUM', style: theme.textTheme.labelSmall?.copyWith(
              color: Colors.grey[600], letterSpacing: 1.5, fontWeight: FontWeight.w600,
            )),
            const SizedBox(height: 12),

            // ── dB display range (most important) ───────────────────────────
            Row(children: [
              _SLabel('Display Range'),
              const Spacer(),
              Text('${s.minDb.toInt()} → ${s.maxDb.toInt()} dBFS',
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace')),
            ]),
            RangeSlider(
              values: RangeValues(s.minDb, s.maxDb),
              min: -140, max: 0, divisions: 140,
              labels: RangeLabels('${s.minDb.toInt()}', '${s.maxDb.toInt()}'),
              onChanged: (r) {
                if (r.end - r.start < 10) return;
                update(s.copyWith(minDb: r.start, maxDb: r.end));
              },
            ),
            const SizedBox(height: 4),

            // ── Gain ────────────────────────────────────────────────────────
            Row(children: [
              _SLabel('Gain'),
              const Spacer(),
              Text(s.autoGain ? 'Auto' : '${s.gainDb.toStringAsFixed(1)} dB',
                  style: theme.textTheme.bodySmall),
              const SizedBox(width: 6),
              Transform.scale(
                scale: 0.8,
                child: Switch(
                  value: s.autoGain,
                  onChanged: (v) => update(s.copyWith(gainTenths: v ? -1 : 300)),
                ),
              ),
            ]),
            if (!s.autoGain) ...[
              Slider(
                value: s.gainTenths / 10.0,
                min: 0, max: 49.6, divisions: 124,
                label: '${s.gainDb.toStringAsFixed(1)} dB',
                onChanged: (v) => update(s.copyWith(gainTenths: (v * 10).round())),
              ),
              const SizedBox(height: 4),
            ],

            // ── Sample Rate ─────────────────────────────────────────────────
            _SLabel('Sample Rate'),
            const SizedBox(height: 6),
            Builder(builder: (context) {
              final rates = sdrType == SdrType.hackRf
                  ? WaterfallSettings.sampleRatesHackRf
                  : WaterfallSettings.sampleRatesRtl;
              final currentRate = rates.contains(s.sampleRateHz) ? s.sampleRateHz : rates.first;
              return DropdownButton<int>(
                isExpanded: true,
                value: currentRate,
                items: rates.map((hz) => DropdownMenuItem(
                  value: hz,
                  child: Text(WaterfallSettings.formatSampleRate(hz), style: const TextStyle(fontSize: 13)),
                )).toList(),
                onChanged: (v) { if (v != null) update(s.copyWith(sampleRateHz: v)); },
              );
            }),
            const SizedBox(height: 10),

            // ── Color Scheme ─────────────────────────────────────────────────
            _SLabel('Color'),
            const SizedBox(height: 6),
            Row(children: [
              for (final cs in WaterfallColorScheme.values)
                Padding(padding: const EdgeInsets.only(right: 4), child: ActionChip(
                  avatar: _colorSwatch(cs, 12),
                  label: Text(cs.name[0].toUpperCase() + cs.name.substring(1),
                    style: TextStyle(fontSize: 11, color: s.colorScheme == cs ? Colors.white : null)),
                  onPressed: () => update(s.copyWith(colorScheme: cs)),
                  backgroundColor: s.colorScheme == cs
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.surfaceContainerHighest,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                )),
            ]),
            const SizedBox(height: 10),

          ],
        ),
      ),
    );
  }
}

class _SLabel extends StatelessWidget {
  final String text;
  const _SLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(text,
      style: Theme.of(context).textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w600, color: Colors.grey[700]));
}

/// Tiny gradient swatch preview of the colormap.
Widget _colorSwatch(WaterfallColorScheme cs, double size) {
  final lut = _buildMiniLut(cs);
  return Container(
    width: size, height: size,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(3),
      gradient: LinearGradient(
        colors: lut.map((c) => Color(0xFF000000 | c)).toList(),
        begin: Alignment.bottomCenter, end: Alignment.topCenter,
      ),
    ),
  );
}

List<int> _buildMiniLut(WaterfallColorScheme scheme) {
  return List.generate(6, (i) {
    final t = i / 5.0;
    switch (scheme) {
      case WaterfallColorScheme.viridis:
        final r = (0.267 + 1.619 * t - 2.190 * t * t + 0.851 * t * t * t).clamp(0.0, 1.0);
        final g = (0.004 + 1.363 * t - 0.554 * t * t - 0.340 * t * t * t).clamp(0.0, 1.0);
        final b = (0.329 + 1.496 * t - 3.166 * t * t + 1.823 * t * t * t).clamp(0.0, 1.0);
        return (_f(r) << 16) | (_f(g) << 8) | _f(b);
      case WaterfallColorScheme.turbo:
        final r = (0.139 + 4.189 * t - 8.540 * t * t + 5.106 * t * t * t).clamp(0.0, 1.0);
        final g = (0.097 + 3.671 * t - 3.956 * t * t + 0.218 * t * t * t).clamp(0.0, 1.0);
        final b = (0.453 + 3.107 * t - 8.010 * t * t + 5.293 * t * t * t).clamp(0.0, 1.0);
        return (_f(r) << 16) | (_f(g) << 8) | _f(b);
      case WaterfallColorScheme.grayscale:
        final v = (t * 255).round();
        return (v << 16) | (v << 8) | v;
    }
  });
}

int _f(double v) => (v * 255).round().clamp(0, 255);
