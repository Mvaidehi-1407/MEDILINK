// Builds panic_dataset_v5_blind_shuffled.csv from panic_dataset_v5.csv.
// panic_dataset_v5_blind_shuffled.csv referenced in the test brief doesn't exist yet —
// only panic_dataset_v5.csv (labeled) does, with sequences already interleaved
// normal/false_alarm/real_panic in fixed triplets. This shuffles the SEQUENCE order
// (keeping each sequence's rows in original time order, since the model needs the
// trend within an incident) so category order becomes non-deterministic.
//
// Usage: node build_shuffled_dataset.js [seed]
const fs = require("fs");
const path = require("path");

const SEED = Number(process.argv[2]) || 42;
function mulberry32(a) {
  return function () {
    a |= 0; a = (a + 0x6D2B79F5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

const dir = __dirname;
const src = path.join(dir, "panic_dataset_v5.csv");
const lines = fs.readFileSync(src, "utf8").trim().split("\n");
const header = lines[0].split(",");
const rows = lines.slice(1).map((l) => l.split(","));

const sidIdx = header.indexOf("sequence_id");
const seqs = new Map();
for (const r of rows) {
  const sid = r[sidIdx];
  if (!seqs.has(sid)) seqs.set(sid, []);
  seqs.get(sid).push(r);
}

const rand = mulberry32(SEED);
const seqIds = [...seqs.keys()];
for (let i = seqIds.length - 1; i > 0; i--) {
  const j = Math.floor(rand() * (i + 1));
  [seqIds[i], seqIds[j]] = [seqIds[j], seqIds[i]];
}

const outRows = [];
for (const sid of seqIds) outRows.push(...seqs.get(sid));

const outHeader = header.join(",");
const outLines = [outHeader, ...outRows.map((r) => r.join(","))];
const outPath = path.join(dir, "panic_dataset_v5_blind_shuffled.csv");
fs.writeFileSync(outPath, outLines.join("\n") + "\n");
console.log(`Wrote ${outRows.length} rows across ${seqIds.length} shuffled sequences to ${outPath}`);

// self-check: same total rows, same category counts as source
const cat = header.indexOf("category");
const before = {}, after = {};
for (const r of rows) before[r[cat]] = (before[r[cat]] || 0) + 1;
for (const r of outRows) after[r[cat]] = (after[r[cat]] || 0) + 1;
const sortedKeys = (o) => JSON.stringify(o, Object.keys(o).sort());
console.assert(rows.length === outRows.length, "row count mismatch");
console.assert(sortedKeys(before) === sortedKeys(after), "category count mismatch");
console.log("self-check passed:", after);
