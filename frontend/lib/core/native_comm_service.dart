import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'api_client.dart';

/// Real native SMS/calling for the continuous caretaker escalation loop. No paid call/SMS
/// provider is used anywhere in this app -- when the backend relays an `escalation.attempt`
/// event to this device, this service fires an actual SMS and phone call over the device's own
/// SIM (via Android's SmsManager / ACTION_CALL through MainActivity.kt) and reports back exactly
/// what happened. Never claims success it didn't observe.
class NativeCommService {
  static const _channel = MethodChannel('medilink/native_comm');

  Future<Map<String, dynamic>> sendSms(String phone, String message) async {
    final granted = await Permission.sms.request();
    if (!granted.isGranted) {
      return {'status': 'UNAVAILABLE', 'errorMessage': 'SMS permission not granted'};
    }
    try {
      final result = await _channel.invokeMethod('sendSms', {'phone': phone, 'message': message});
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'status': 'FAILED', 'errorMessage': e.toString()};
    }
  }

  Future<Map<String, dynamic>> placeCall(String phone) async {
    final granted = await Permission.phone.request();
    if (!granted.isGranted) {
      return {'status': 'UNAVAILABLE', 'errorMessage': 'Phone permission not granted'};
    }
    try {
      final result = await _channel.invokeMethod('placeCall', {'phone': phone});
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      return {'status': 'FAILED', 'errorMessage': e.toString()};
    }
  }

  /// Handles one `escalation.attempt` WS payload end to end: fires the real SMS + call, then
  /// reports both outcomes back to the backend so the emergency timeline reflects what the
  /// device actually did.
  Future<void> handleEscalationAttempt(ApiClient api, String emergencyId, Map<String, dynamic> attempt) async {
    final phone = attempt['contactPhone']?.toString();
    final message = attempt['message']?.toString();
    final cycle = attempt['cycle'];
    final priority = attempt['priority'];
    if (phone == null || message == null) return;

    final smsResult = await sendSms(phone, message);
    await _reportResult(api, emergencyId, 'sms', phone, cycle, priority, smsResult);

    final callResult = await placeCall(phone);
    await _reportResult(api, emergencyId, 'call', phone, cycle, priority, callResult);
  }

  Future<void> _reportResult(
    ApiClient api,
    String emergencyId,
    String channel,
    String phone,
    dynamic cycle,
    dynamic priority,
    Map<String, dynamic> result,
  ) async {
    try {
      await api.post('/emergencies/$emergencyId/comm-result', body: {
        'channel': channel,
        'status': result['status'],
        'contactPhone': phone,
        'cycle': cycle,
        'priority': priority,
        if (result['errorMessage'] != null) 'errorMessage': result['errorMessage'],
      });
    } catch (_) {
      // Best-effort reporting -- if the network call itself fails there's nothing further to do;
      // the next escalation cycle will retry the whole contact anyway.
    }
  }
}
