// Sends one row from panic_dataset_v5_blind_shuffled.csv to POST /api/health/readings
// every 5s, logging timestamp / true category / model's predicted class (risk.tierPrediction).
//
// SAFETY: if a real_panic row is sent to an account with real emergency contacts configured,
// the backend's emergency escalation (real call/SMS) can fire for real. Confirm with the account
// owner before running against anything but a fully isolated test account.
//
// Usage (PowerShell):
//   $env:MEDILINK_API_BASE="http://localhost:8000/api"
//   $env:MEDILINK_TOKEN="<access token for the safe test account>"
//   $env:MEDILINK_PATIENT_ID="<that account's patientId>"
//   $env:MEDILINK_DEVICE_ID="TEST-DEVICE-LIVEFEED-01"
//   node live_feed_test.js --rows 60 --gap 5000
//
// Or log in inline instead of MEDILINK_TOKEN:
//   $env:MEDILINK_IDENTIFIER="test@account.example"; $env:MEDILINK_PASSWORD="..."
//
// Requires Node 18+ (global fetch).

const fs = require("fs");
const path = require("path");

function arg(name, def) {
  const i = process.argv.indexOf(`--${name}`);
  return i === -1 ? def : process.argv[i + 1];
}

const API_BASE = process.env.MEDILINK_API_BASE || "http://localhost:8000/api";
const ROWS = Number(arg("rows", 60));
const GAP_MS = Number(arg("gap", 5000));
const START_AT = Number(arg("start", 0));
const CSV_PATH = arg("csv", path.join(__dirname, "panic_dataset_v5_blind_shuffled.csv"));
const LOG_PATH = arg("log", path.join(__dirname, `live_feed_run_${Date.now()}.log.jsonl`));

const DEVICE_ID = process.env.MEDILINK_DEVICE_ID || "TEST-DEVICE-LIVEFEED-01";

function loadRows(csvPath, start, count) {
  const lines = fs.readFileSync(csvPath, "utf8").trim().split("\n");
  const header = lines[0].split(",");
  const idx = Object.fromEntries(header.map((h, i) => [h, i]));
  return lines
    .slice(1 + start, 1 + start + count)
    .map((l) => l.split(","))
    .map((r) => ({
      category: r[idx.category],
      row_label: r[idx.row_label],
      heart_rate_bpm: Number(r[idx.heart_rate_bpm]),
      spo2_percent: Number(r[idx.spo2_percent]),
      motion_level: Number(r[idx.motion_level]),
      eda_gsr_level: Number(r[idx.eda_gsr_level]),
      skin_temp_c: Number(r[idx.skin_temp_c]),
      prv_ms: Number(r[idx.prv_ms]),
    }));
}

async function getTokenAndPatientId() {
  if (process.env.MEDILINK_TOKEN && process.env.MEDILINK_PATIENT_ID) {
    return { token: process.env.MEDILINK_TOKEN, patientId: process.env.MEDILINK_PATIENT_ID };
  }
  const identifier = process.env.MEDILINK_IDENTIFIER;
  const password = process.env.MEDILINK_PASSWORD;
  if (!identifier || !password) {
    console.error(
      "Set MEDILINK_TOKEN + MEDILINK_PATIENT_ID, or MEDILINK_IDENTIFIER + MEDILINK_PASSWORD to log in."
    );
    process.exit(1);
  }
  const res = await fetch(`${API_BASE}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ identifier, password }),
  });
  if (!res.ok) {
    console.error("Login failed:", res.status, await res.text());
    process.exit(1);
  }
  const body = await res.json();
  return { token: body.tokens.accessToken, patientId: body.user.id };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function main() {
  const rows = loadRows(CSV_PATH, START_AT, ROWS);
  if (rows.length === 0) {
    console.error("No rows loaded — check --csv/--start/--rows.");
    process.exit(1);
  }
  const hasRealPanic = rows.some((r) => r.category === "real_panic");
  console.log(
    `Loaded ${rows.length} rows. Categories present: ${[...new Set(rows.map((r) => r.category))].join(", ")}.` +
      (hasRealPanic ? " *** includes real_panic rows ***" : "")
  );

  const { token, patientId: PATIENT_ID } = await getTokenAndPatientId();
  const logStream = fs.createWriteStream(LOG_PATH, { flags: "a" });
  console.log(`Logging to ${LOG_PATH}`);

  for (let i = 0; i < rows.length; i++) {
    const row = rows[i];
    const sentAt = new Date().toISOString();
    const payload = {
      heartRate: Math.round(row.heart_rate_bpm),
      spo2: Math.round(row.spo2_percent),
      systolicBP: 120,
      diastolicBP: 80,
      temperature: 37.0,
      deviceId: DEVICE_ID,
      patientId: PATIENT_ID,
      source: "WEARABLE",
      eda_gsr_level: row.eda_gsr_level,
      skin_temp_c: row.skin_temp_c,
      prv_ms: row.prv_ms,
    };

    let entry;
    try {
      const res = await fetch(`${API_BASE}/health/readings`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${token}`,
        },
        body: JSON.stringify(payload),
      });
      const body = await res.json().catch(() => ({}));
      const predicted = body?.reading?.risk?.tierPrediction ?? null;
      entry = {
        index: i,
        sentAt,
        trueCategory: row.category,
        trueRowLabel: row.row_label,
        httpStatus: res.status,
        predictedClass: predicted,
        emergencyCreated: !!body?.emergency,
        emergency: body?.emergency ?? null,
      };
    } catch (err) {
      entry = { index: i, sentAt, trueCategory: row.category, error: String(err) };
    }

    console.log(
      `[${entry.sentAt}] #${i} true=${entry.trueCategory} predicted=${entry.predictedClass} status=${entry.httpStatus}${
        entry.emergencyCreated ? "  !! EMERGENCY CREATED !!" : ""
      }`
    );
    logStream.write(JSON.stringify(entry) + "\n");

    if (i < rows.length - 1) await sleep(GAP_MS);
  }

  logStream.end();
  console.log("Done.");
}

main();
