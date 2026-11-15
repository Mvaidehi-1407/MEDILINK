# Running MediLink on a physical phone ("Can't reach MediLink servers")

**Cause (VERIFIED by reading the code):** the app's default server address is
`http://10.0.2.2:8000/api` (`frontend/lib/core/api_client.dart`, `MEDILINK_API_URL`).
`10.0.2.2` only exists inside the Android emulator. On a real phone it points nowhere, so
the backend ping fails and the banner shows. The app already reads a saved override
(`medilink_api_url`), but nothing in the app could set it until now.

**Fix in the app:** *Login → Server settings*, or *Profile → App Settings → Server address*.
Enter your computer's address, tap **Test connection**, then **Save**. It takes effect
immediately, with no restart needed.

## Option A: Wi-Fi (phone and PC on the same network)
1. Start the backend so other devices can reach it:
   `uvicorn app.main:app --host 0.0.0.0 --port 8000` (run from `backend/`).
2. Find the PC's IPv4 address: `ipconfig` → *Wireless LAN adapter Wi-Fi → IPv4 Address*.
3. Allow port 8000 through Windows Firewall (Private network):
   `New-NetFirewallRule -DisplayName "MediLink 8000" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow -Profile Private`
4. In the app, set Server address to `http://<that IP>:8000/api`.

## Option B: USB cable
1. `adb reverse tcp:8000 tcp:8000`
2. In the app, set Server address to `http://127.0.0.1:8000/api`.

## Option C: build-time default
`flutter run --dart-define=MEDILINK_API_URL=http://<PC IP>:8000/api`

Cleartext HTTP is already allowed (`android:usesCleartextTraffic="true"`).
