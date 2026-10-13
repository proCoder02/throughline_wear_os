package com.throughline.throughline_wearos

import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import androidx.health.services.client.HealthServices
import androidx.health.services.client.MeasureCallback
import androidx.health.services.client.data.Availability
import androidx.health.services.client.data.DataPointContainer
import androidx.health.services.client.data.DataType
import androidx.health.services.client.data.DeltaDataType
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.Instant
import java.util.concurrent.Executor

class MainActivity : FlutterActivity() {
	private val methodChannelName = "throughline/health"
	private val eventChannelName = "throughline/heart-rate"
	private val heartRatePermissionRequestCode = 7314
	private val mainThreadExecutor = Executor { command -> runOnUiThread(command) }

	private var eventSink: EventChannel.EventSink? = null
	private var pendingPermissionResult: MethodChannel.Result? = null
	private var isMeasuringHeartRate = false

	private val measureClient by lazy {
		HealthServices.getClient(this).measureClient
	}

	private val heartRateCallback = object : MeasureCallback {
		override fun onAvailabilityChanged(
			dataType: DeltaDataType<*, *>,
			availability: Availability,
		) {
			eventSink?.success(
				mapOf("type" to "availability", "state" to availability.toString()),
			)
		}

		override fun onDataReceived(data: DataPointContainer) {
			val bootInstant = Instant.ofEpochMilli(
				System.currentTimeMillis() - SystemClock.elapsedRealtime(),
			)
			data.getData(DataType.HEART_RATE_BPM).forEach { point ->
				eventSink?.success(
					mapOf(
						"type" to "sample",
						"bpm" to point.value.toDouble(),
						"measuredAt" to point.getTimeInstant(bootInstant).toString(),
						"accuracy" to point.accuracy?.toString(),
						"source" to "wear_health_services",
					),
				)
			}
		}

		override fun onRegistrationFailed(throwable: Throwable) {
			isMeasuringHeartRate = false
			eventSink?.error(
				"heart_rate_registration_failed",
				throwable.message ?: "The watch could not start heart-rate measurement.",
				null,
			)
		}
	}

	override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
		super.configureFlutterEngine(flutterEngine)

		MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
			.setMethodCallHandler { call, result ->
				when (call.method) {
					"isHeartRateSupported" -> checkHeartRateSupport(result)
					"hasHeartRatePermission" ->
						result.success(checkSelfPermission(heartRatePermission()) == PackageManager.PERMISSION_GRANTED)
					"requestHeartRatePermission" -> requestHeartRatePermission(result)
					"startHeartRate" -> startHeartRate(result)
					"stopHeartRate" -> stopHeartRate(result)
					"relayHeartRateViaBluetooth" -> relayHeartRateViaBluetooth(call, result)
					else -> result.notImplemented()
				}
			}

		EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
			.setStreamHandler(object : EventChannel.StreamHandler {
				override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
					eventSink = events
				}

				override fun onCancel(arguments: Any?) {
					eventSink = null
				}
			})
	}

	private fun heartRatePermission(): String =
		if (Build.VERSION.SDK_INT >= 36) {
			"android.permission.health.READ_HEART_RATE"
		} else {
			"android.permission.BODY_SENSORS"
		}

	private fun requestHeartRatePermission(result: MethodChannel.Result) {
		if (checkSelfPermission(heartRatePermission()) == PackageManager.PERMISSION_GRANTED) {
			result.success(true)
			return
		}
		if (pendingPermissionResult != null) {
			result.error("permission_request_active", "A permission request is already active.", null)
			return
		}
		pendingPermissionResult = result
		requestPermissions(arrayOf(heartRatePermission()), heartRatePermissionRequestCode)
	}

	private fun checkHeartRateSupport(result: MethodChannel.Result) {
		val future = measureClient.getCapabilitiesAsync()
		future.addListener(
			{
				try {
					result.success(
						future.get().supportedDataTypesMeasure.contains(DataType.HEART_RATE_BPM),
					)
				} catch (exception: Exception) {
					result.error(
						"health_services_unavailable",
						exception.message ?: "Could not check watch sensor support.",
						null,
					)
				}
			},
			mainThreadExecutor,
		)
	}

	private fun startHeartRate(result: MethodChannel.Result) {
		if (checkSelfPermission(heartRatePermission()) != PackageManager.PERMISSION_GRANTED) {
			result.error("heart_rate_permission_required", "Heart-rate permission is required.", null)
			return
		}
		if (isMeasuringHeartRate) {
			result.success(null)
			return
		}

		val future = measureClient.getCapabilitiesAsync()
		future.addListener(
			{
				try {
					val isSupported =
						future.get().supportedDataTypesMeasure.contains(DataType.HEART_RATE_BPM)
					if (!isSupported) {
						result.error(
							"heart_rate_not_supported",
							"This watch does not provide live heart-rate measurements.",
							null,
						)
						return@addListener
					}
					measureClient.registerMeasureCallback(
						DataType.HEART_RATE_BPM,
						heartRateCallback,
					)
					isMeasuringHeartRate = true
					result.success(null)
				} catch (exception: Exception) {
					result.error(
						"heart_rate_start_failed",
						exception.message ?: "Could not start heart-rate measurement.",
						null,
					)
				}
			},
			mainThreadExecutor,
		)
	}

	private fun stopHeartRate(result: MethodChannel.Result) {
		if (!isMeasuringHeartRate) {
			result.success(null)
			return
		}
		isMeasuringHeartRate = false
		val future = measureClient.unregisterMeasureCallbackAsync(
			DataType.HEART_RATE_BPM,
			heartRateCallback,
		)
		future.addListener({ result.success(null) }, mainThreadExecutor)
	}

	/**
	 * Fallback sync path (see main.dart's _stopHeartRateMeasurement): used
	 * only when the direct POST /health/heart-rate call fails -- e.g. the
	 * watch has no network of its own. Puts the session JSON on the Wear OS
	 * Data Layer, which the platform delivers to the paired phone over
	 * Bluetooth automatically, even if this watch app isn't foregrounded.
	 * The phone's HeartRateRelayListenerService picks it up and forwards it
	 * to the backend using its own cached auth (see NativeAuthStore.kt on
	 * the phone side) -- this call never needs the phone app to be running
	 * either.
	 */
	private fun relayHeartRateViaBluetooth(call: MethodCall, result: MethodChannel.Result) {
		val sessionJson = call.argument<String>("sessionJson")
		val sessionId = call.argument<String>("sessionId")
		if (sessionJson == null || sessionId == null) {
			result.error("invalid_argument", "sessionJson and sessionId are required.", null)
			return
		}
		val request = PutDataMapRequest.create("/throughline/heart-rate-relay/$sessionId").apply {
			dataMap.putString("session_json", sessionJson)
			dataMap.putLong("relayed_at", System.currentTimeMillis())
		}
		Wearable.getDataClient(this)
			.putDataItem(request.asPutDataRequest().setUrgent())
			.addOnSuccessListener { result.success(null) }
			.addOnFailureListener { e ->
				result.error("relay_failed", e.message ?: "Could not relay via Bluetooth.", null)
			}
	}

	override fun onRequestPermissionsResult(
		requestCode: Int,
		permissions: Array<out String>,
		grantResults: IntArray,
	) {
		super.onRequestPermissionsResult(requestCode, permissions, grantResults)
		if (requestCode == heartRatePermissionRequestCode) {
			pendingPermissionResult?.success(
				grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED,
			)
			pendingPermissionResult = null
		}
	}

	override fun onDestroy() {
		if (isMeasuringHeartRate) {
			measureClient.unregisterMeasureCallbackAsync(
				DataType.HEART_RATE_BPM,
				heartRateCallback,
			)
			isMeasuringHeartRate = false
		}
		super.onDestroy()
	}
}
