"""BLE + SOS freeze check. Compares frozen regions/files in the working tree with git a7eb01a
(line endings normalised, like `git diff` with core.autocrlf on Windows). Exit 1 on any difference."""
import hashlib, subprocess, sys, pathlib, re
ROOT = pathlib.Path(__file__).resolve().parents[2]
BASE = 'a7eb01a'
def head(p): return subprocess.run(['git','-C',str(ROOT),'show',f'{BASE}:{p}'],capture_output=True).stdout.decode('utf-8','replace')
def cur(p): return (ROOT/p).read_text(encoding='utf-8',errors='replace')
def norm(s): return s.replace('\r\n','\n')
def region(s, start, end):
    s = norm(s); a = s.index(start); b = s.index(end, a); return s[a:b]
def lines(s, pat): return '\n'.join(l for l in norm(s).split('\n') if re.search(pat, l))
D='frontend/lib/features/dashboard.dart'
checks = [
 ('BLE region dashboard.dart (BleVitals..BlePage)', lambda f: region(f(D), '/// One decoded vitals frame', 'class EmergencyPage extends')),
 ('SOS logic: EmergencyPage widget + state fields/handlers (up to build)', lambda f: region(f(D), 'class EmergencyPage extends', '  @override\n  Widget build(BuildContext context) => PageFrame(\n    title: \'Emergency\'') if f is head else region(f(D), 'class EmergencyPage extends', '  // ---- UI (build) ----')),
 ('SOS: RoleShell escalation/SOS listeners', lambda f: region(f(D), 'class _RoleShellState', '  @override\n  Widget build(BuildContext context) {\n    final session')),
 ('core/native_comm_service.dart', lambda f: norm(f('frontend/lib/core/native_comm_service.dart'))),
 ('core/realtime_service.dart', lambda f: norm(f('frontend/lib/core/realtime_service.dart'))),
 ('MainActivity.kt', lambda f: norm(f('frontend/android/app/src/main/kotlin/com/example/medilink/MainActivity.kt'))),
 ('Manifest permission lines', lambda f: lines(f('frontend/android/app/src/main/AndroidManifest.xml'), r'uses-permission|uses-feature')),
 ('pubspec BLE/SMS/call/permission deps', lambda f: lines(f('frontend/pubspec.yaml'), r'flutter_blue_plus|permission_handler|geolocator|url_launcher')),
]
fw = subprocess.run(['git','-C',str(ROOT),'ls-files','firmware'],capture_output=True,text=True).stdout.split()
for p in fw: checks.append((p, (lambda p: lambda f: norm(f(p)))(p)))
bad = 0; out = []
for name, fn in checks:
    try:
        h, c = fn(head), fn(cur)
    except Exception as e:
        out.append(f'ERROR {name}: {e}'); bad += 1; continue
    hh, ch = hashlib.sha256(h.encode()).hexdigest(), hashlib.sha256(c.encode()).hexdigest()
    ok = hh == ch; bad += 0 if ok else 1
    out.append(f"{'OK  ' if ok else 'DIFF'} {hh[:16]} {ch[:16]} {name}")
print('\n'.join(out)); print('RESULT:', 'FROZEN (no diff)' if not bad else f'{bad} DIFFERENCE(S)')
sys.exit(1 if bad else 0)
