package com.example.medilink

import android.content.pm.PackageManager
import android.content.Intent
import android.net.Uri
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Native SMS/calling for the continuous caretaker escalation loop (Phase 3). No paid call/SMS
 * provider is used anywhere in this app -- these methods place a real SMS/call over the device's
 * own SIM and report back exactly what happened (never a fabricated success).
 */
class MainActivity : FlutterActivity() {
    private val channelName = "medilink/native_comm"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "sendSms" -> {
                    val phone = call.argument<String>("phone")
                    val message = call.argument<String>("message")
                    result.success(sendSms(phone, message))
                }
                "placeCall" -> {
                    val phone = call.argument<String>("phone")
                    result.success(placeCall(phone))
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasSim(): Boolean {
        val tm = getSystemService(TELEPHONY_SERVICE) as? TelephonyManager
        return tm != null && tm.simState == TelephonyManager.SIM_STATE_READY
    }

    private fun sendSms(phone: String?, message: String?): Map<String, Any?> {
        if (phone.isNullOrBlank() || message.isNullOrBlank()) {
            return mapOf("status" to "FAILED", "errorMessage" to "Missing phone number or message")
        }
        if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            return mapOf("status" to "UNAVAILABLE", "errorMessage" to "SEND_SMS permission not granted")
        }
        if (!hasSim()) {
            return mapOf("status" to "UNAVAILABLE", "errorMessage" to "No active SIM detected")
        }
        return try {
            val smsManager = SmsManager.getDefault()
            val parts = smsManager.divideMessage(message)
            if (parts.size > 1) {
                smsManager.sendMultipartTextMessage(phone, null, parts, null, null)
            } else {
                smsManager.sendTextMessage(phone, null, message, null, null)
            }
            // sendTextMessage is fire-and-forget at the radio layer; SENT here means the OS
            // accepted and queued it for the modem, not a delivery receipt.
            mapOf("status" to "SENT")
        } catch (e: Exception) {
            mapOf("status" to "FAILED", "errorMessage" to (e.message ?: e.toString()))
        }
    }

    private fun placeCall(phone: String?): Map<String, Any?> {
        if (phone.isNullOrBlank()) {
            return mapOf("status" to "FAILED", "errorMessage" to "Missing phone number")
        }
        if (ContextCompat.checkSelfPermission(this, android.Manifest.permission.CALL_PHONE) != PackageManager.PERMISSION_GRANTED) {
            return mapOf("status" to "UNAVAILABLE", "errorMessage" to "CALL_PHONE permission not granted")
        }
        if (!hasSim()) {
            return mapOf("status" to "UNAVAILABLE", "errorMessage" to "No active SIM detected")
        }
        return try {
            val intent = Intent(Intent.ACTION_CALL, Uri.parse("tel:$phone"))
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            // ACTION_CALL launching without throwing means the OS placed the call request; we
            // have no further signal on whether it connected.
            mapOf("status" to "INITIATED")
        } catch (e: Exception) {
            mapOf("status" to "FAILED", "errorMessage" to (e.message ?: e.toString()))
        }
    }
}
