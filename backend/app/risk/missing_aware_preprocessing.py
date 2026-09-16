"""
Missing-aware preprocessing layer for MediLink's Isolation Forest.

Takes a raw reading (a dict that may have ANY subset of the sensors in
sensor_schema.json present) and produces a fixed-length feature vector
that the Isolation Forest can always accept, regardless of which sensors
happened to be available for that particular reading.

For every sensor in the schema, two columns are produced:
  <sensor>_value    — the real value if present, or the imputed default
                       if missing. NEVER left blank.
  <sensor>_missing  — 1 if this value was imputed (not real), 0 if real.

The missing flag is fed to the model as a real feature, not just
logged — this lets the tree-based Isolation Forest learn to treat
imputed values differently from real ones (e.g. weight an imputed
SpO2 less heavily than a real one), which is the actual mechanism that
makes this "missing-aware" rather than just "doesn't crash."

Usage:
    from missing_aware_preprocessing import load_schema, reading_to_vector

    schema = load_schema("sensor_schema.json")
    vector, feature_names = reading_to_vector(
        {"heart_rate_bpm": 82, "motion_level": 3},  # spo2 missing here
        schema,
    )
"""

import json


def load_schema(path="sensor_schema.json"):
    with open(path) as f:
        data = json.load(f)
    return data["sensors"]


def feature_names(schema):
    """Returns the ordered list of feature column names — value+missing
    pair per sensor, in a fixed, stable order. Every script that builds
    or reads a feature vector must use THIS function for the column
    order, so nothing ever gets misaligned."""
    names = []
    for sensor in sorted(schema.keys()):
        names.append(f"{sensor}_value")
        names.append(f"{sensor}_missing")
    return names


def reading_to_vector(reading, schema):
    """Converts one raw reading (dict, any subset of sensors present)
    into a fixed-length numeric feature vector, in the fixed order from
    feature_names(). Returns (vector, ordered_feature_names)."""
    vector = []
    names = feature_names(schema)

    for sensor in sorted(schema.keys()):
        spec = schema[sensor]
        if sensor in reading and reading[sensor] is not None:
            value = float(reading[sensor])
            missing = 0
        else:
            value = float(spec["impute_default"])
            missing = 1
        vector.append(value)
        vector.append(missing)

    return vector, names


def check_missing_required(reading, schema):
    """Returns a list of warnings for any REQUIRED sensor that's absent
    from this reading — required sensors can still be imputed and
    processed fine, but a missing required sensor is worth flagging
    (e.g. logging) since it likely means a hardware/connectivity
    problem, not just an optional sensor that was never installed."""
    warnings = []
    for sensor, spec in schema.items():
        if spec.get("required") and (sensor not in reading or reading[sensor] is None):
            warnings.append(f"Required sensor '{sensor}' missing from reading — "
                             f"imputed with default {spec['impute_default']}, "
                             f"but check device/connectivity.")
    return warnings


if __name__ == "__main__":
    # Quick self-test
    schema = load_schema()
    print("Feature columns:", feature_names(schema))

    complete_reading = {
        "heart_rate_bpm": 128, "spo2_percent": 91, "motion_level": 0.5,
        "temperature_c": 37.2, "respiratory_rate_bpm": 22,
    }
    vec, names = reading_to_vector(complete_reading, schema)
    print("\nComplete reading:", dict(zip(names, vec)))

    partial_reading = {"heart_rate_bpm": 128, "motion_level": 0.5}
    vec2, names2 = reading_to_vector(partial_reading, schema)
    print("\nPartial reading (spo2, temp, resp missing):", dict(zip(names2, vec2)))

    warnings = check_missing_required(partial_reading, schema)
    print("\nWarnings:", warnings)
