import 'dart:math';

/// Generates plausible vitals with natural, mean-reverting variation and occasional
/// threshold-breaching spikes -- not flat presets and not pure random noise. Used only by the
/// Dev Mode simulator; every reading it produces still flows through the real `/api/health`
/// pipeline so the backend (not this generator) is the source of truth for risk classification.
class SimulatedVitals {
  const SimulatedVitals({
    required this.heartRate,
    required this.spo2,
    required this.systolicBP,
    required this.diastolicBP,
    required this.temperature,
    required this.regime,
  });
  final int heartRate;
  final int spo2;
  final int systolicBP;
  final int diastolicBP;
  final double temperature;
  final String regime; // NORMAL | WARNING_SPIKE | HIGH_RISK_SPIKE, for on-screen context only
}

class VitalsSimulatorEngine {
  VitalsSimulatorEngine({Random? random}) : _random = random ?? Random();
  final Random _random;

  double _hr = 72;
  double _spo2 = 97.5;
  double _systolic = 118;
  double _diastolic = 78;
  double _temp = 36.8;

  int _spikeTicksRemaining = 0;
  String _spikeRegime = 'NORMAL';

  double _walk(double current, double baseline, double noise, double min, double max) {
    final reverted = current + (baseline - current) * 0.25;
    final next = reverted + (_random.nextDouble() * 2 - 1) * noise;
    return next.clamp(min, max);
  }

  SimulatedVitals next() {
    if (_spikeTicksRemaining <= 0) {
      // 6% chance of a warning-level excursion, 2% chance of a high-risk one, each tick.
      final roll = _random.nextDouble();
      if (roll < 0.02) {
        _spikeRegime = 'HIGH_RISK_SPIKE';
        _spikeTicksRemaining = 2 + _random.nextInt(3);
      } else if (roll < 0.08) {
        _spikeRegime = 'WARNING_SPIKE';
        _spikeTicksRemaining = 2 + _random.nextInt(3);
      } else {
        _spikeRegime = 'NORMAL';
      }
    }

    double hrBaseline = 72, spo2Baseline = 97.5, sysBaseline = 118, diaBaseline = 78, tempBaseline = 36.8;
    if (_spikeRegime == 'WARNING_SPIKE') {
      hrBaseline = 118;
      spo2Baseline = 93;
      sysBaseline = 148;
      diaBaseline = 92;
      tempBaseline = 38.2;
    } else if (_spikeRegime == 'HIGH_RISK_SPIKE') {
      hrBaseline = 148;
      spo2Baseline = 87;
      sysBaseline = 176;
      diaBaseline = 108;
      tempBaseline = 39.3;
    }

    _hr = _walk(_hr, hrBaseline, 4, 45, 190);
    _spo2 = _walk(_spo2, spo2Baseline, 1, 75, 100);
    _systolic = _walk(_systolic, sysBaseline, 3, 85, 210);
    _diastolic = _walk(_diastolic, diaBaseline, 2, 50, 130);
    _temp = _walk(_temp, tempBaseline, 0.15, 35.5, 40.5);

    if (_spikeTicksRemaining > 0) _spikeTicksRemaining--;

    return SimulatedVitals(
      heartRate: _hr.round(),
      spo2: _spo2.round().clamp(0, 100),
      systolicBP: _systolic.round(),
      diastolicBP: _diastolic.round(),
      temperature: double.parse(_temp.toStringAsFixed(1)),
      regime: _spikeRegime,
    );
  }
}
