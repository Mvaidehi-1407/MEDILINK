// Lists this patient's emergencies and cancels any still-open one via the normal
// patient-facing /cancel lifecycle endpoint (no emergency-creation/calling logic touched).
const OPEN_STATUSES = ["VERIFICATION", "SUPERVISION", "CONFIRMED"];

async function login() {
  const res = await fetch(`${process.env.MEDILINK_API_BASE}/auth/login`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      identifier: process.env.MEDILINK_IDENTIFIER,
      password: process.env.MEDILINK_PASSWORD,
    }),
  });
  if (!res.ok) throw new Error(`login failed: ${res.status} ${await res.text()}`);
  const body = await res.json();
  return { token: body.tokens.accessToken, patientId: body.user.id };
}

async function main() {
  const { token, patientId } = await login();
  const headers = { "Content-Type": "application/json", Authorization: `Bearer ${token}` };

  const listRes = await fetch(`${process.env.MEDILINK_API_BASE}/emergencies/patient/${patientId}`, { headers });
  const emergencies = await listRes.json();
  console.log(`Found ${emergencies.length} emergencies for patient ${patientId}`);

  const open = emergencies.filter((e) => OPEN_STATUSES.includes(e.status));
  console.log(`Open/stale: ${open.length}`, open.map((e) => ({ id: e.id, status: e.status, createdAt: e.createdAt })));

  for (const e of open) {
    const res = await fetch(`${process.env.MEDILINK_API_BASE}/emergencies/${e.id}/cancel`, {
      method: "POST",
      headers,
      body: JSON.stringify({ patientResponse: "IM_OK", reason: "test cleanup: stale emergency from prior automated test run" }),
    });
    const body = await res.json().catch(() => ({}));
    console.log(`Cancelled ${e.id}: status=${res.status} newStatus=${body.status}`);
  }

  const recheckRes = await fetch(`${process.env.MEDILINK_API_BASE}/emergencies/patient/${patientId}`, { headers });
  const recheck = await recheckRes.json();
  const stillOpen = recheck.filter((e) => OPEN_STATUSES.includes(e.status));
  console.log(`After cleanup, still-open count: ${stillOpen.length}`);
  if (stillOpen.length > 0) {
    console.error("WARNING: still-open emergencies remain:", stillOpen.map((e) => e.id));
    process.exit(1);
  }
  console.log("self-check passed: no open emergencies remain for this patient");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
