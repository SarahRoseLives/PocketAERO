# HackRF Flutter Plugin

A Flutter plugin for interfacing with HackRF One software-defined radios on Android. This library bridges your Flutter app and the native [`hackrf_android`](https://github.com/demantz/hackrf_android) Java library, enabling direct control and transmission via HackRF from Dart.

Ideal for mobile SDR (Software Defined Radio) applications, remote-control transmitters, educational radio tools, and more.

---

## Features

- **Automatic Device Discovery:** Detects HackRF devices and requests required USB permissions.
- **Device Information:** Retrieve the board ID of the connected HackRF.
- **Transmission Control:**
  - Set transmission frequency (`setFrequency`)
  - Set sample rate (`setSampleRate`)
  - Set TX VGA (IF) gain (`setTxVgaGain`)
  - Start and stop transmission (`startTx`, `stopTx`)
- **Data Streaming:** Send I/Q data (`Uint8List` buffers) to HackRF for direct transmission.

---

## Requirements

### Hardware

- **HackRF One** (or compatible device, e.g., Rad1o)
- **Android device** with USB OTG support
- **USB OTG cable/adapter** to connect HackRF

### Software

- **Android only:** Uses native Android libraries (no iOS support)
- **Minimum Android SDK version:** `minSdkVersion` **21** or higher

---

## Installation

### 1. Add the Dependency

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  hackrf_flutter:
    path: ../hackrf_flutter  # Adjust path to your plugin location if necessary
```

Run:

```sh
flutter pub get
```

### 2. Android Configuration (**Required!**)

#### A. Update `minSdkVersion`

In `android/app/build.gradle`:

```groovy
android {
    defaultConfig {
        minSdkVersion 21
        // ...other config...
    }
}
```

#### B. Custom `MainActivity` for Plugin Registration

Create `android/app/src/main/kotlin/com/yourcompany/yourapp/MainActivity.kt` (adjust package name):

```kotlin
package com.yourcompany.yourapp // Change to your actual package name

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.sarahroselives.hackrf_flutter.HackrfFlutterPlugin // Import your plugin

class MainActivity: FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Register plugin
        flutterEngine.plugins.add(HackrfFlutterPlugin())
    }
}
```

#### C. Update `AndroidManifest.xml`

Ensure your manifest points to your new `MainActivity`:

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application ...>
        <activity
            android:name=".MainActivity"
            android:exported="true"
            ...>
            <!-- ...your intent filters... -->
        </activity>
        <!-- ... -->
    </application>
</manifest>
```

---

## Usage Example

Here's a basic example that initializes HackRF and starts transmission:

```dart
import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'dart:math';
import 'package:hackrf_flutter/hackrf_flutter.dart';

class RadioScreen extends StatefulWidget {
  const RadioScreen({super.key});

  @override
  State<RadioScreen> createState() => _RadioScreenState();
}

class _RadioScreenState extends State<RadioScreen> {
  final _hackrf = HackrfFlutter();
  bool _isInitialized = false;
  bool _isTransmitting = false;

  @override
  void initState() {
    super.initState();
    initDevice();
  }

  Future<void> initDevice() async {
    try {
      bool? success = await _hackrf.init();
      if (success ?? false) {
        setState(() => _isInitialized = true);
        print("HackRF Initialized!");
        int? boardId = await _hackrf.getBoardId();
        print("Board ID: $boardId");
      } else {
        print("Failed to initialize HackRF. Is it connected?");
      }
    } catch (e) {
      print("Error initializing HackRF: $e");
    }
  }

  Future<void> startTransmission() async {
    if (!_isInitialized) return;

    // Generate I/Q data (262,144 bytes)
    const packetSize = 262144;
    final iqData = Int8List(packetSize);
    for (int i = 0; i < packetSize; i += 2) {
      final angle = 2 * pi * (i / 2) / 100.0;
      iqData[i] = (sin(angle) * 127).round();   // I
      iqData[i + 1] = (cos(angle) * 127).round(); // Q
    }

    try {
      await _hackrf.setFrequency(433920000); // 433.92 MHz
      await _hackrf.setSampleRate(8000000);   // 8 MSPS
      await _hackrf.setTxVgaGain(30);         // 30 dB (0–47)
      await _hackrf.startTx();
      setState(() => _isTransmitting = true);
      print("TRANSMITTING...");
      while (_isTransmitting) {
        await _hackrf.sendData(iqData.buffer.asUint8List());
      }
    } catch (e) {
      print("Transmission error: $e");
    }
  }

  Future<void> stopTransmission() async {
    setState(() => _isTransmitting = false); // Breaks loop
    await _hackrf.stopTx();
    print("Transmission stopped.");
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: _isTransmitting ? stopTransmission : startTransmission,
          child: Text(_isTransmitting ? 'Stop Transmit' : 'Start Transmit'),
        ),
      ),
    );
  }
}
```

---

## How It Works

- **Flutter (Dart):** You call methods such as `_hackrf.setFrequency()`.
- **MethodChannel:** Dart sends method calls to the native side using Flutter MethodChannel.
- **Native Plugin (`HackrfFlutterPlugin.kt`):** Receives calls, delegates to Java code.
- **Java Library (`Hackrf.java` in [demantz/hackrf_android](https://github.com/demantz/hackrf_android)):** Handles USB communication with HackRF.
- **HackRF Device:** Executes the requested command.

This plugin is a direct bridge to [hackrf_android](https://github.com/demantz/hackrf_android)—all core SDR logic and USB handling is provided by that Java library.
