package com.example.hackrf_flutter

import android.util.Log
import androidx.annotation.NonNull
import com.mantz_it.hackrf_android.Hackrf
import com.mantz_it.hackrf_android.HackrfCallbackInterface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.*
import java.util.concurrent.ArrayBlockingQueue

class HackrfFlutterPlugin : FlutterPlugin, MethodCallHandler {
    private val TAG = "HackrfPlugin"

    private lateinit var channel: MethodChannel
    private lateinit var rxEventChannel: EventChannel
    private var pluginBinding: FlutterPlugin.FlutterPluginBinding? = null
    private var hackrf: Hackrf? = null
    private var pendingInitResult: Result? = null
    private var txQueue: ArrayBlockingQueue<ByteArray>? = null
    private var isTransmitting = false

    private val hackrfCallback = object : HackrfCallbackInterface {
        override fun onHackrfReady(hackrfInstance: Hackrf) {
            Log.d(TAG, "✅ onHackrfReady: Device is ready!")
            this@HackrfFlutterPlugin.hackrf = hackrfInstance
            pendingInitResult?.success(true)
            pendingInitResult = null
        }

        override fun onHackrfError(message: String) {
            Log.e(TAG, "❌ onHackrfError: $message")
            pendingInitResult?.error("HACKRF_ERROR", message, null)
            pendingInitResult = null
        }
    }

    override fun onAttachedToEngine(@NonNull flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        this.pluginBinding = flutterPluginBinding
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "hackrf_flutter_channel")
        channel.setMethodCallHandler(this)

        // Setup the EventChannel for RX data
        rxEventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "hackrf_flutter_rx_channel")
        rxEventChannel.setStreamHandler(rxStreamHandler)

        Log.d(TAG, "Plugin attached to engine.")
    }

    override fun onMethodCall(@NonNull call: MethodCall, @NonNull result: Result) {
        // We run most calls on a background thread to avoid blocking the UI thread
        CoroutineScope(Dispatchers.IO).launch {
            try {
                when (call.method) {
                    "init" -> {
                        pendingInitResult = result
                        val context = pluginBinding?.applicationContext ?: run {
                            Log.e(TAG, "Context is unavailable.")
                            result.error("CONTEXT_UNAVAILABLE", "Android context is not available.", null)
                            return@launch
                        }
                        Hackrf.initHackrf(context, hackrfCallback, 10) // 10 is queue size
                        Log.d(TAG, "initHackrf called.")
                    }
                    "getBoardId" -> result.success(hackrf?.boardID?.toInt())
                    "setFrequency" -> {
                        val freq = (call.argument<Any>("freq") as? Number)?.toLong() ?: 0L
                        result.success(hackrf?.setFrequency(freq))
                    }
                    "setSampleRate" -> {
                        val rate = ((call.argument<Any>("rate") as? Number)?.toLong() ?: 0L).toInt()
                        result.success(hackrf?.setSampleRate(rate, 1))
                    }
                    // --- TX Methods ---
                    "setTxVgaGain" -> {
                        val gain = ((call.argument<Any>("gain") as? Number)?.toLong() ?: 0L).toInt()
                        result.success(hackrf?.setTxVGAGain(gain))
                    }
                    "startTx" -> {
                        txQueue = hackrf?.startTX()
                        isTransmitting = (txQueue != null)
                        result.success(isTransmitting)
                    }
                    "stopTx" -> {
                        hackrf?.stop()
                        isTransmitting = false
                        txQueue = null
                        result.success(true)
                    }
                    "sendData" -> {
                        val data = call.argument<ByteArray>("data")
                        if (isTransmitting && data != null) {
                            txQueue?.put(data) // This is a blocking call
                            result.success(null)
                        } else {
                            result.error("TX_ERROR", "Not transmitting or data is null.", null)
                        }
                    }
                    // --- RX Methods ---
                    "setRxLnaGain" -> {
                        val gain = ((call.argument<Any>("gain") as? Number)?.toLong() ?: 0L).toInt()
                        result.success(hackrf?.setRxLNAGain(gain))
                    }
                    "setRxVgaGain" -> {
                        val gain = ((call.argument<Any>("gain") as? Number)?.toLong() ?: 0L).toInt()
                        result.success(hackrf?.setRxVGAGain(gain))
                    }
                    "stopRx" -> {
                        hackrf?.stop()
                        // The stream handler's onCancel will also be called, cleaning up the job
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.e(TAG, "❌ EXCEPTION in onMethodCall for ${call.method}: ${e.message}", e)
                result.error("NATIVE_ERROR", e.message, e.stackTraceToString())
            }
        }
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        rxEventChannel.setStreamHandler(null)
        hackrf?.stop()
        Log.d(TAG, "Plugin detached from engine.")
        hackrf = null
        pluginBinding = null
        pendingInitResult = null
    }

    // --- Stream Handler for RX Data ---
    private val rxStreamHandler = object : EventChannel.StreamHandler {
        private var dataJob: Job? = null

        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            Log.d(TAG, "RX Stream: onListen called. Starting RX data job.")
            // Create a coroutine to poll the queue and send data to Flutter
            dataJob = CoroutineScope(Dispatchers.IO).launch {
                try {
                    val rxQueue = hackrf?.startRX()
                    if (rxQueue == null) {
                        events.error("RX_ERROR", "Failed to start receiver.", null)
                        return@launch
                    }
                    // Loop indefinitely while the coroutine is active
                    while (isActive) {
                        val data = rxQueue.take() // This blocks until data is available
                        // Switch to the main thread to send the event, as required by Flutter
                        withContext(Dispatchers.Main) {
                            events.success(data)
                        }
                    }
                } catch (e: InterruptedException) {
                    Log.d(TAG, "RX data job interrupted. Closing stream.")
                    // This is expected when the job is cancelled
                } catch (e: Exception) {
                    Log.e(TAG, "❌ EXCEPTION in RX data job: ${e.message}", e)
                    withContext(Dispatchers.Main) {
                        events.error("RX_STREAM_ERROR", e.message, e.stackTraceToString())
                    }
                } finally {
                     withContext(Dispatchers.Main) {
                        events.endOfStream()
                    }
                }
            }
        }

        override fun onCancel(arguments: Any?) {
            Log.d(TAG, "RX Stream: onCancel called. Stopping RX data job.")
            dataJob?.cancel()
            dataJob = null
            try {
                // Also explicitly stop the HackRF
                hackrf?.stop()
            } catch (e: Exception) {
                Log.e(TAG, "Error while stopping HackRF on stream cancel: ${e.message}")
            }
        }
    }
}