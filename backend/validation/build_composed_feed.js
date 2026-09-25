// Builds composed_demo_feed.csv: whole sequences selected per category, ordered in
// BLOCKS (all normal, then all false_alarm, then all real_panic), each sequence kept
// in its original internal time order.
//
// NOTE on the percentage targets (60-70% normal / 10-15% false_alarm / 20-25% real_panic)
// vs the ~80-120 row budget: real sequences run 40-70 rows each (no smaller unit exists
// in the source dataset), so a single false_alarm sequence alone is already ~33% of a
// 120-row total -- hitting both constraints at once is mathematically impossible.
// Per user decision, this keeps the ~80-120 row budget and picks the smallest available
// sequence in each category, accepting a roughly 33/33/33 split instead of 60/13/23.
const fs = require("fs");
const path = require("path");

const dir = __dirname;
const src = path.join(dir, "panic_dataset_v5.csv");
const lines = fs.readFileSync(src, "utf8").trim().split("\n");
const header = lines[0].split(",");
const rows = lines.slice(1).map((l) => l.split(","));

const sidIdx = header.indexOf("sequence_id");
const catIdx = header.indexOf("category");
const seqs = new Map();
for (const r of rows) {
  const sid = r[sidIdx];
  if (!seqs.has(sid)) seqs.set(sid, { cat: r[catIdx], rows: [] });
  seqs.get(sid).rows.push(r);
}

const byCat = { normal: [], false_alarm: [], real_panic: [] };
for (const [sid, v] of seqs) byCat[v.cat].push({ sid, len: v.rows.length });
for (const cat of Object.keys(byCat)) byCat[cat].sort((a, b) => a.len - b.len);

const chosen = {
  normal: [byCat.normal[0].sid],
  false_alarm: [byCat.false_alarm[0].sid],
  real_panic: [byCat.real_panic[0].sid],
};

const outRows = [];
const counts = {};
for (const cat of ["normal", "false_alarm", "real_panic"]) {
  for (const sid of chosen[cat]) {
    const seqRows = seqs.get(sid).rows;
    outRows.push(...seqRows);
    counts[cat] = (counts[cat] || 0) + seqRows.length;
  }
}

const outPath = path.join(dir, "composed_demo_feed.csv");
fs.writeFileSync(outPath, [header.join(","), ...outRows.map((r) => r.join(","))].join("\n") + "\n");

const total = outRows.length;
console.log("Chosen sequences:", chosen);
console.log("Row counts:", counts);
console.log(
  "Percentages:",
  Object.fromEntries(Object.entries(counts).map(([k, v]) => [k, ((v / total) * 100).toFixed(1) + "%"]))
);
console.log("Total rows:", total);

// self-check: rows appear in requested block order (normal block, then false_alarm, then real_panic)
const catSeq = outRows.map((r) => r[catIdx]);
const order = ["normal", "false_alarm", "real_panic"];
let orderIdx = 0;
for (const c of catSeq) {
  while (order[orderIdx] !== c) {
    orderIdx++;
    console.assert(orderIdx < order.length, "category out of block order: " + c);
  }
}
console.log("self-check passed: rows are in normal -> false_alarm -> real_panic block order");
