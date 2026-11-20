import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:medilink/features/dashboard.dart';

BleVitals? parse(String packet) => BleVitals.tryParse(utf8.encode(packet));

void main() {
  test('abnormal test packet parses every supplied value', () {
    final v = parse('DATA|ID=MEDILINK-01|HR=180|SPO2=82|BP=190/120|TEMP=39.8')!;
    expect([v.heartRate, v.spo2, v.systolicBP, v.diastolicBP], [180, 82, 190, 120]);
    expect(v.temperature, 39.8);
    expect(v.deviceId, 'MEDILINK-01');
    expect(v.eventType, 'VITALS');
  });

  test('normal test packet parses every supplied value', () {
    final v = parse('DATA|ID=MEDILINK-01|HR=75|SPO2=98|BP=120/80|TEMP=36.6')!;
    expect([v.heartRate, v.spo2, v.systolicBP, v.diastolicBP], [75, 98, 120, 80]);
    expect(v.temperature, 36.6);
  });

  test('decimal SpO2/HR are rounded, not rejected', () {
    final v = parse('DATA|HR=72.4|SPO2=97.5|BP=120/80|TEMP=36.6')!;
    expect([v.heartRate, v.spo2], [72, 98]);
  });

  test('missing or invalid fields are rejected, never filled in', () {
    expect(parse('DATA|HR=75|SPO2=98|TEMP=36.6'), isNull); // no BP
    expect(parse('DATA|HR=75|SPO2=abc|BP=120/80|TEMP=36.6'), isNull);
    expect(parse('DATA|HR=75|SPO2=98|BP=120/80|TEMP=98.6'), isNull); // not °C
    expect(parse('TYPE=NORMAL,HR=75,SPO2=98,TEMP=36.6,MOTION=RESTING'), isNull);
  });

  test('SOS packet keeps its SOS event type', () {
    expect(parse('SOS|HR=150|SPO2=88|BP=160/100|TEMP=38.2')!.isSos, isTrue);
  });
}
