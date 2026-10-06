package com.example.ai_meal_app

import android.Manifest
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Telephony
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "trackyo/sms"
    private val smsPermissionRequestCode = 7124
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var permissionWasPreviouslyRequested = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "requestReadPermission" -> requestReadPermission(result)
                "readRecentMessages" -> readRecentMessages(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun requestReadPermission(result: MethodChannel.Result) {
        if (!packageManager.hasSystemFeature(PackageManager.FEATURE_TELEPHONY)) {
            result.error("unsupported_device", "SMS is not supported on this device.", null)
            return
        }
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_SMS) == PackageManager.PERMISSION_GRANTED) {
            result.success(mapOf("granted" to true, "permanentlyDenied" to false))
            return
        }
        if (pendingPermissionResult != null) {
            result.error("permission_request_in_progress", "An SMS permission request is already active.", null)
            return
        }
        val preferences = getSharedPreferences("trackyo_permissions", MODE_PRIVATE)
        permissionWasPreviouslyRequested =
            preferences.getBoolean("read_sms_requested", false)
        if (permissionWasPreviouslyRequested &&
            !ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.READ_SMS)
        ) {
            result.success(mapOf("granted" to false, "permanentlyDenied" to true))
            return
        }
        preferences.edit().putBoolean("read_sms_requested", true).apply()
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.READ_SMS), smsPermissionRequestCode)
    }

    private fun readRecentMessages(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.READ_SMS) != PackageManager.PERMISSION_GRANTED) {
            result.error("permission_denied", "SMS read permission has not been granted.", null)
            return
        }
        val rows = mutableListOf<Map<String, Any>>()
        try {
            val thirtyDaysAgo = System.currentTimeMillis() - 30L * 24 * 60 * 60 * 1000
            contentResolver.query(
                Uri.parse("content://sms/inbox"),
                arrayOf(
                    Telephony.Sms._ID,
                    Telephony.Sms.ADDRESS,
                    Telephony.Sms.BODY,
                    Telephony.Sms.DATE,
                ),
                "${Telephony.Sms.DATE} >= ?",
                arrayOf(thirtyDaysAgo.toString()),
                "${Telephony.Sms.DATE} DESC",
            )?.use {
                val idColumn = it.getColumnIndex(Telephony.Sms._ID)
                val addressColumn = it.getColumnIndex(Telephony.Sms.ADDRESS)
                val bodyColumn = it.getColumnIndex(Telephony.Sms.BODY)
                val dateColumn = it.getColumnIndex(Telephony.Sms.DATE)
                var count = 0
                var scanned = 0
                while (it.moveToNext() && count < 100 && scanned < 1000) {
                    scanned++
                    val body = if (bodyColumn >= 0) it.getString(bodyColumn) else null
                    val address =
                        if (addressColumn >= 0) it.getString(addressColumn) else ""
                    if (!body.isNullOrBlank() &&
                        !isNonTransactionMessage(body) &&
                        isPotentialFinancialMessage(body)
                    ) {
                        rows.add(
                            mapOf(
                                "id" to (if (idColumn >= 0) it.getString(idColumn) else ""),
                                "address" to address,
                                "body" to body,
                                "date" to (if (dateColumn >= 0) it.getLong(dateColumn) else 0L),
                            ),
                        )
                        count++
                    }
                }
            }
            result.success(rows)
        } catch (error: SecurityException) {
            result.error("permission_denied", "SMS permission was denied.", null)
        } catch (_: Exception) {
            result.error("sms_read_failed", "Unable to read SMS messages.", null)
        }
    }

    private fun isPotentialFinancialMessage(body: String): Boolean {
        val transactionMarker =
            Regex("\\b(debited|credited|withdrawn|withdrawal|spent|paid|purchase|received|deposit|transferred|transfer|sent)\\b", RegexOption.IGNORE_CASE)
                .containsMatchIn(body)
        val financialContext =
            Regex("\\b(account|a/c|card|upi|imps|neft|rtgs|transaction|payment|bank|wallet|transfer|sent|received)\\b", RegexOption.IGNORE_CASE)
                .containsMatchIn(body)
        val amount =
            Regex("(?:INR|Rs\\.?|₹)\\s*[0-9][0-9,]*(?:\\.[0-9]{1,2})?|[0-9][0-9,]*(?:\\.[0-9]{1,2})?\\s*(?:INR|Rs\\.?|₹)", RegexOption.IGNORE_CASE)
                .containsMatchIn(body)
        return transactionMarker && financialContext && amount
    }

    private fun isNonTransactionMessage(body: String): Boolean =
        Regex(
            "\\b(otp|one[- ]time password|verification code|promo(?:tion)?|offer|unsubscribe|click here|limited time|win a|congratulations)\\b",
            RegexOption.IGNORE_CASE,
        ).containsMatchIn(body)

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == smsPermissionRequestCode) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED
            val permanentlyDenied = !granted &&
                permissionWasPreviouslyRequested &&
                !ActivityCompat.shouldShowRequestPermissionRationale(this, Manifest.permission.READ_SMS)
            pendingPermissionResult?.success(
                mapOf("granted" to granted, "permanentlyDenied" to permanentlyDenied),
            )
            pendingPermissionResult = null
        }
    }
}
