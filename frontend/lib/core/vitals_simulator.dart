import 'dart:math';

/// Generates biologically plausible vitals using a mean-reverting random walk
/// (Ornstein-Uhlenbeck stochastic process) with stochastic emergency spike regimes.
///
/// DESIGN PURPOSE:
/// Enables end-to-end testing of live graph UI, ML risk classification, and emergency triggers
/// without requiring an active Bluetooth physical medical pulse oximeter.

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
  final String regime; // NORMAL | WARNING_SPIKE | HIGH_RISK_SPIKE
}

class VitalsSimulatorEngine {
  VitalsSimulatorEngine({Random? random}) : _random = random ?? Random();
  final Random _random;

  // Baseline internal state
  double _hr = 72;
  double _spo2 = 97.5;
  double _systolic = 118;
  double _diastolic = 78;
  double _temp = 36.8;

  int _spikeTicksRemaining = 0;
  String _spikeRegime = 'NORMAL';
  int _tickCount = 0;

  /// Mean-Reverting Random Walk (Discrete Ornstein-Uhlenbeck process):
  /// Formula: next = current + drift_factor * (baseline - current) + gaussian_noise
  /// - drift_factor (0.25): Pulls the reading back toward physiological homeostasis.
  /// - noise: Adds natural heartbeat-to-heartbeat biometric variance.
  double _walk(double current, double baseline, double noise, double min, double max) {
    final reverted = current + (baseline - current) * 0.25;
    final next = reverted + (_random.nextDouble() * 2 - 1) * noise;
    return next.clamp(min, max);
  }

  SimulatedVitals next() {
    _tickCount++;
    if (_spikeTicksRemaining <= 0) {
      if (_tickCount % 5 == 0) {
        // Deterministic HIGH_RISK spike every 5th reading, so an emergency trigger is
        // reliably reproducible for testing/demo rather than left to a 2% dice roll.
        _spikeRegime = 'HIGH_RISK_SPIKE';
        _spikeTicksRemaining = 2 + _random.nextInt(3);
      } else {
        // Stochastic Regime Transition on the remaining ticks:
        // - 2% chance: Sudden HIGH_RISK spike (tachycardia + desaturation)
        // - 6% chance: Moderate WARNING spike (exertion / mild fever)
        // - 92% chance: Stable resting equilibrium
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
