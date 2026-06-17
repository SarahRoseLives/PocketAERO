import 'dart:math' as math;
import 'dart:typed_data';

/// Processes a block of raw HackRF I/Q bytes into a dB spectrum.
///
/// [iqBytes]: raw bytes from hackrf_flutter, interleaved signed int8 I/Q.
/// [fftSize]: must be a power of 2 (e.g. 2048).
/// Returns Float32List of [fftSize] dB values, frequency-shifted (DC centred).
Float32List processHackrfIq(Uint8List iqBytes, int fftSize) {
  final window = _hannWindow(fftSize);
  final re = List<double>.filled(fftSize, 0.0);
  final im = List<double>.filled(fftSize, 0.0);

  final available = math.min(iqBytes.length ~/ 2, fftSize);
  for (int i = 0; i < available; i++) {
    // HackRF delivers signed int8; Dart Uint8List stores them as unsigned.
    // Reinterpret via two's complement: values >=128 are negative.
    final iRaw = iqBytes[i * 2];
    final qRaw = iqBytes[i * 2 + 1];
    final iSigned = iRaw >= 128 ? iRaw - 256 : iRaw;
    final qSigned = qRaw >= 128 ? qRaw - 256 : qRaw;
    re[i] = (iSigned / 128.0) * window[i];
    im[i] = (qSigned / 128.0) * window[i];
  }

  _fftInPlace(re, im);

  // FFT-shift: put DC in centre, compute dB magnitude
  final out  = Float32List(fftSize);
  final half = fftSize ~/ 2;
  for (int i = 0; i < fftSize; i++) {
    final s   = (i + half) % fftSize;
    final mag = math.sqrt(re[s] * re[s] + im[s] * im[s]);
    out[i] = 20.0 * math.log(mag / fftSize + 1e-10) / math.ln10;
  }
  return out;
}

List<double> _hannWindow(int n) =>
    List.generate(n, (i) => 0.5 * (1.0 - math.cos(2.0 * math.pi * i / (n - 1))));

/// In-place radix-2 Cooley-Tukey FFT.
void _fftInPlace(List<double> re, List<double> im) {
  final n = re.length;

  // Bit-reversal permutation
  for (int i = 1, j = 0; i < n; i++) {
    int bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      var t = re[i]; re[i] = re[j]; re[j] = t;
      t = im[i]; im[i] = im[j]; im[j] = t;
    }
  }

  // Butterfly stages
  for (int len = 2; len <= n; len <<= 1) {
    final ang = -2.0 * math.pi / len;
    final wRe = math.cos(ang);
    final wIm = math.sin(ang);
    for (int i = 0; i < n; i += len) {
      double urRe = 1.0, urIm = 0.0;
      final half = len >> 1;
      for (int j = 0; j < half; j++) {
        final uRe = re[i + j];
        final uIm = im[i + j];
        final vRe = re[i + j + half] * urRe - im[i + j + half] * urIm;
        final vIm = re[i + j + half] * urIm + im[i + j + half] * urRe;
        re[i + j]        = uRe + vRe;
        im[i + j]        = uIm + vIm;
        re[i + j + half] = uRe - vRe;
        im[i + j + half] = uIm - vIm;
        final nextUrRe = urRe * wRe - urIm * wIm;
        urIm = urRe * wIm + urIm * wRe;
        urRe = nextUrRe;
      }
    }
  }
}
