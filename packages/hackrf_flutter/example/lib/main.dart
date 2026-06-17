import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:hackrf_flutter/hackrf_flutter.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  // Plugin and state variables
  final _hackrfFlutterPlugin = HackrfFlutter();
  String _status = 'Initializing...';
  bool _isInitialized = false;
  bool _isTransmitting = false;
  bool _isReceiving = false;

  // RX Stream management
  StreamSubscription<Uint8List>? _rxSubscription;

  // UI
  final List<String> _logMessages = [];
  final ScrollController _logScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _initHackrfDevice();
  }

  @override
  void dispose() {
    // Clean up resources
    _rxSubscription?.cancel();
    if (_isTransmitting) _hackrfFlutterPlugin.stopTx();
    if (_isReceiving) _hackrfFlutterPlugin.stopRx();
    super.dispose();
  }

  /// Adds a message to the on-screen log.
  void _log(String message) {
    if (!mounted) return;
    final timestamp = DateTime.now().toIso8601String().split('T').last.substring(0, 12);
    setState(() {
      _logMessages.insert(0, '$timestamp: $message'); // Add to top of list
      if (_logMessages.length > 100) {
        _logMessages.removeLast();
      }
    });
  }

  /// Initializes the HackRF device on app startup.
  Future<void> _initHackrfDevice() async {
    _log('Attempting to initialize HackRF...');
    try {
      bool? isInitialized = await _hackrfFlutterPlugin.init();
      if (mounted) {
        if (isInitialized ?? false) {
          int? boardId = await _hackrfFlutterPlugin.getBoardId();
          setState(() {
            _isInitialized = true;
            _status = 'HackRF Ready! Board ID: $boardId';
          });
          _log('HackRF Initialized Successfully.');
        } else {
          setState(() {
            _isInitialized = false;
            _status = 'Failed to initialize. Is HackRF connected?';
          });
          _log('HackRF initialization failed.');
        }
      }
    } catch (e) {
      _log('ERROR during init: ${e.toString()}');
      if (mounted) {
        setState(() => _status = 'Error: ${e.toString()}');
      }
    }
  }

  /// Toggles the transmission of a simple carrier wave.
  Future<void> _toggleTransmit() async {
    if (_isReceiving) {
      _log("Cannot transmit while receiving. Stop RX first.");
      return;
    }

    if (_isTransmitting) {
      // --- STOP TRANSMITTING ---
      _log("Stopping transmission...");
      setState(() => _isTransmitting = false); // This will break the TX loop
      await _hackrfFlutterPlugin.stopTx();
      _log("TX stopped.");
      setState(() => _status = "TX Stopped.");
      return;
    }

    // --- START TRANSMITTING ---
    _log("Starting transmission...");
    setState(() {
      _isTransmitting = true;
      _status = "Configuring TX...";
    });

    try {
      // 1. Configure HackRF
      _log("Setting frequency to 145.1 MHz...");
      await _hackrfFlutterPlugin.setFrequency(145100000);
      _log("Setting sample rate to 8 MSPS...");
      await _hackrfFlutterPlugin.setSampleRate(8000000);
      _log("Setting TX gain to 30...");
      await _hackrfFlutterPlugin.setTxVgaGain(30);

      // 2. Generate a simple carrier wave packet
      // For a carrier, I is a cosine wave and Q is a sine wave.
      // We send a constant packet of this wave.
      const packetSize = 262144;
      final iqData = Int8List(packetSize);
      for (int i = 0; i < packetSize; i += 2) {
        final angle = 2 * 3.14159 * (i / 2) / 20.0; // 20 samples per cycle
        iqData[i] = (127 * cos(angle)).round(); // I component
        iqData[i + 1] = (127 * sin(angle)).round(); // Q component
      }

      // 3. Start transmitter and begin sending data
      await _hackrfFlutterPlugin.startTx();
      _log("TX Started. Sending data...");

      // 4. Transmission loop
      while (_isTransmitting && mounted) {
        await _hackrfFlutterPlugin.sendData(iqData.buffer.asUint8List());
        if (mounted) {
          setState(() => _status = "TRANSMITTING...");
        }
        await Future.delayed(Duration.zero); // Yield to UI thread
      }
    } catch (e) {
      _log("ERROR during TX: ${e.toString()}");
      if (mounted) {
        setState(() => _status = "TX Error.");
      }
    } finally {
      if (mounted) {
        setState(() => _isTransmitting = false);
      }
    }
  }

  /// Toggles the receiver on and off.
  Future<void> _toggleReceive() async {
    if (_isTransmitting) {
      _log("Cannot receive while transmitting. Stop TX first.");
      return;
    }

    if (_isReceiving) {
      // --- STOP RECEIVING ---
      _log("Stopping receiver...");
      await _rxSubscription?.cancel();
      _rxSubscription = null;
      // The onCancel callback in the native code handles stopping the HackRF
      setState(() {
        _isReceiving = false;
        _status = "RX Stopped.";
      });
      _log("RX stopped.");
      return;
    }

    // --- START RECEIVING ---
    _log("Starting receiver...");
    setState(() {
      _isReceiving = true;
      _status = "Configuring RX...";
    });

    try {
      // 1. Configure HackRF
      _log("Setting frequency to 145.1 MHz...");
      await _hackrfFlutterPlugin.setFrequency(145100000);
      _log("Setting sample rate to 8 MSPS...");
      await _hackrfFlutterPlugin.setSampleRate(8000000);
      _log("Setting RX LNA (RF) gain to 32...");
      await _hackrfFlutterPlugin.setRxLnaGain(32);
      _log("Setting RX VGA (Baseband) gain to 30...");
      await _hackrfFlutterPlugin.setRxVgaGain(30);

      // 2. Start listening to the stream
      final rxStream = _hackrfFlutterPlugin.startRx();
      _rxSubscription = rxStream.listen(
        (data) {
          // On data received, log a snippet
          final snippet = data.sublist(0, min(32, data.length)).join(', ');
          _log("RX Data (${data.length} bytes): [$snippet...]");
        },
        onError: (error) {
          _log("RX Stream ERROR: $error");
          _toggleReceive(); // Attempt to stop on error
        },
        onDone: () {
          _log("RX stream closed by native side.");
          if (mounted && _isReceiving) {
            _toggleReceive(); // Ensure state is updated
          }
        },
        cancelOnError: true,
      );

      setState(() => _status = "RECEIVING...");
      _log("Now listening for RX data...");

    } catch (e) {
      _log("ERROR starting RX: ${e.toString()}");
      if (mounted) {
        setState(() {
          _isReceiving = false;
          _status = "RX Error.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          title: const Text('HackRF Flutter Demo'),
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            children: <Widget>[
              Text('Status: $_status', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  ElevatedButton.icon(
                    icon: Icon(_isTransmitting ? Icons.stop_circle_outlined : Icons.play_circle_outline),
                    label: Text(_isTransmitting ? 'Stop TX' : 'Start TX'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isTransmitting ? Colors.red : Colors.green,
                      minimumSize: const Size(140, 50),
                    ),
                    onPressed: _isInitialized ? _toggleTransmit : null,
                  ),
                  ElevatedButton.icon(
                    icon: Icon(_isReceiving ? Icons.stop_circle_outlined : Icons.sensors),
                    label: Text(_isReceiving ? 'Stop RX' : 'Start RX'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _isReceiving ? Colors.red : Colors.blue,
                      minimumSize: const Size(140, 50),
                    ),
                    onPressed: _isInitialized ? _toggleReceive : null,
                  ),
                ],
              ),
              const Divider(height: 30),
              const Text('Logs', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              Expanded(
                child: Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.all(8.0),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade400),
                    borderRadius: BorderRadius.circular(5.0),
                  ),
                  child: ListView.builder(
                    controller: _logScrollController,
                    itemCount: _logMessages.length,
                    itemBuilder: (context, index) {
                      return Text(
                        _logMessages[index],
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                      );
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}