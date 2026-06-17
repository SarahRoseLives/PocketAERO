import 'package:flutter/services.dart';

class HackrfFlutter {
  // The channel for one-off commands
  static const MethodChannel _channel = MethodChannel('hackrf_flutter_channel');

  // A dedicated channel for the continuous stream of received RX data
  static const EventChannel _rxEventChannel = EventChannel('hackrf_flutter_rx_channel');

  /// Initializes the HackRF device by finding it and requesting USB permission.
  /// Returns `true` on success, `false` on failure.
  Future<bool> init() async {
    final bool? isInitialized = await _channel.invokeMethod('init');
    return isInitialized ?? false;
  }

  /// Gets the Board ID from the HackRF device.
  Future<int?> getBoardId() async {
    final int? boardId = await _channel.invokeMethod('getBoardId');
    return boardId;
  }

  /// Sets the center frequency of the HackRF for both TX and RX.
  /// [freqHz] : Frequency in Hz.
  Future<bool> setFrequency(int freqHz) async {
    final bool? result = await _channel.invokeMethod('setFrequency', {'freq': freqHz});
    return result ?? false;
  }

  /// Sets the sample rate of the HackRF for both TX and RX.
  /// [rateHz] : Sample rate in Hz.
  Future<bool> setSampleRate(int rateHz) async {
    final bool? result = await _channel.invokeMethod('setSampleRate', {'rate': rateHz});
    return result ?? false;
  }

  // ---- TX Methods ----

  /// Sets the transmit VGA (IF) gain.
  /// [gain] : Gain value, 0-47.
  Future<bool> setTxVgaGain(int gain) async {
    final bool? result = await _channel.invokeMethod('setTxVgaGain', {'gain': gain});
    return result ?? false;
  }

  /// Starts the HackRF's transmitter.
  Future<bool> startTx() async {
    final bool? result = await _channel.invokeMethod('startTx');
    return result ?? false;
  }

  /// Stops the HackRF's transmitter.
  Future<bool> stopTx() async {
    final bool? result = await _channel.invokeMethod('stopTx');
    return result ?? false;
  }

  /// Sends a block of I/Q samples to the transmitter queue.
  /// The data should be an interleaved 8-bit signed integer `Uint8List`.
  Future<void> sendData(Uint8List data) async {
    await _channel.invokeMethod('sendData', {'data': data});
  }

  // ---- RX Methods ----

  /// Sets the receive LNA (RF) gain.
  /// [gain] : Gain value, 0-40 in steps of 8 (0, 8, 16, 24, 32, 40).
  Future<bool> setRxLnaGain(int gain) async {
    final bool? result = await _channel.invokeMethod('setRxLnaGain', {'gain': gain});
    return result ?? false;
  }

  /// Sets the receive VGA (Baseband) gain.
  /// [gain] : Gain value, 0-62 in steps of 2.
  Future<bool> setRxVgaGain(int gain) async {
    final bool? result = await _channel.invokeMethod('setRxVgaGain', {'gain': gain});
    return result ?? false;
  }

  /// Begins listening for received data from the HackRF.
  ///
  /// This method returns a broadcast stream. You should listen to this stream
  /// to get the incoming I/Q data packets as `Uint8List`.
  /// The underlying receiver is started only when the first listener subscribes.
  ///
  /// Example:
  /// ```dart
  /// final rxStream = hackrf.startRx();
  /// StreamSubscription? subscription;
  /// subscription = rxStream.listen((data) {
  ///   print("Received ${data.length} bytes");
  /// }, onDone: () {
  ///   print("RX stream closed.");
  /// }, onError: (e) {
  ///   print("RX stream error: $e");
  /// });
  ///
  /// // To stop later:
  /// // subscription?.cancel();
  /// ```
  Stream<Uint8List> startRx() {
    return _rxEventChannel.receiveBroadcastStream().cast<Uint8List>();
  }

  /// Stops the HackRF's receiver.
  /// This is often handled automatically when the stream subscription is cancelled,
  /// but can be called explicitly for safety.
  Future<bool> stopRx() async {
    final bool? result = await _channel.invokeMethod('stopRx');
    return result ?? false;
  }
}