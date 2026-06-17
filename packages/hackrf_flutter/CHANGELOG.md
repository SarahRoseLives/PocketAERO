0.0.2

    FEAT: Implemented full transmit (TX) and receive (RX) functionality.

    FEAT: Added an EventChannel to support continuous streaming of I/Q data for RX.

    FEAT: Added methods to control TX and RX gains (setTxVgaGain, setRxVgaGain, setRxLnaGain).

    FIX: Resolved major performance issues by moving all signal processing to a background Isolate, preventing UI lag.

    DOCS: Created a comprehensive example application to demonstrate all library features.

    DOCS: Wrote a detailed README.md with setup and usage instructions.

0.0.1

    Initial release of the hackrf_flutter plugin.

    Established the MethodChannel bridge to native Android code.

    Included basic functionality for device initialization (init, getBoardId).