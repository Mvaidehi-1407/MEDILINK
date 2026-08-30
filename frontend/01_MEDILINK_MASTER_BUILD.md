You are a senior full-stack architect and Flutter/FastAPI engineer with 10+ years of 
experience building production-grade healthcare MVPs and hackathon-winning 
applications. 
Build MEDILINK as a fully functional Android healthcare monitoring and emergency
response MVP. 
IMPORTANT: 
Do NOT build a static UI. 
Do NOT create disconnected mock screens. 
Do NOT create fake core functionality. 
Do NOT leave core buttons as placeholders. 
Build the application as an integrated system. 
================================================== 
1. MEDILINK 
================================================== 
MEDILINK 
"Monitor. Detect. Connect. Respond." 
MEDILINK connects: 
Patient → Caregiver → Doctor → Hospital 
Core workflow: 
MONITOR → ANALYZE → DETECT → VERIFY → LOCATE 
→ NOTIFY → CONNECT → RESPOND → RESOLVE 
Current prototype: 
PHONE 1 = MEDILINK Android App 
PHONE 2 = BLE Wearable Simulator 
Phone 2 sends simulated health readings through Bluetooth/BLE. 
The BLE architecture must allow Phone 2 to later be replaced by 
a physical wearable without redesigning the application. 
================================================== 
2. PRIMARY DEMO FLOW 
================================================== 
Prioritize this complete working chain: 
Phone 2 
→ BLE 
→ Flutter MEDILINK 
→ FastAPI 
→ Risk Engine 
→ Emergency Verification 
→ Emergency Confirmation 
→ GPS 
→ Nearby Hospitals 
→ Caregiver/Doctor/Hospital Notifications 
→ Exotel/Plivo or Demo Provider 
→ Emergency Log 
→ Live Status Updates 
Build this flow before secondary features. 
================================================== 
3. FINAL TECHNOLOGY STACK 
================================================== 
ANDROID: 
Flutter + Dart 
STATE: 
Riverpod OR BLoC 
NAVIGATION: 
GoRouter 
BACKEND: 
Python + FastAPI + Pydantic 
DATABASE: 
MongoDB Atlas 
DATABASE LOCATION: 
MongoDB 2dsphere index for nearby hospital search 
AUTH: 
JWT + bcrypt 
BLE: 
flutter_blue_plus 
REAL-TIME: 
FastAPI WebSockets 
NOTIFICATIONS: 
Firebase Cloud Messaging 
CALL/SMS: 
Exotel OR Plivo 
CALL ABSTRACTION: 
ExotelProvider / PlivoProvider / DemoCallProvider 
MAP: 
flutter_map + OpenStreetMap 
LOCATION: 
geolocator 
GEOCODING: 
Nominatim 
QR: 
qr_flutter + appropriate QR scanner package 
FILES: 
MongoDB GridFS 
AI: 
Free-tier LLM API for medical-report summarization 
HTTP: 
Dio or equivalent 
Flutter must NEVER connect directly to MongoDB. 
Flutter must NEVER contain backend/API secrets. 
================================================== 
4. SYSTEM ARCHITECTURE 
================================================== 
PHONE 2 
↓ BLE 
PHONE 1 Flutter 
↓ HTTPS REST 
FastAPI 
↓ 
MongoDB Atlas 
FastAPI also connects to: 
Firebase FCM 
Exotel/Plivo 
Nominatim 
LLM API 
Use REST for normal operations. 
Use WebSocket for: - live health readings - risk changes - emergency timeline - emergency status - caregiver/doctor/hospital emergency updates - hospital command-center updates - real-time chat 
WebSocket must use authentication, authorization, reconnect handling, 
heartbeat/ping and graceful disconnect. 
MongoDB remains the source of truth. 
WebSocket is only the real-time delivery layer. 
================================================== 
5. USER ROLES 
================================================== 
Implement: 
PATIENT 
CAREGIVER 
DOCTOR 
HOSPITAL 
PATIENT: 
Health monitoring, BLE, emergency, SOS, medical profile, 
medical vault, doctors, hospitals, chat, QR, consent, 
emergency contacts and notifications. 
CAREGIVER: 
Assigned patients, patient status, alerts, location, 
important medical information, calling and acknowledgement. 
DOCTOR: 
Profile, patient connections, access requests, 
authorized medical data, emergency alerts, chat, 
reports and consultation history. 
HOSPITAL: 
Hospital profile, emergency command center, 
nearby emergencies, acknowledgement, response status, 
departments and authorized patient information. 
Use role-based authorization on the backend. 
================================================== 
6. AUTHENTICATION 
================================================== 
Implement: 
Signup 
Login 
Logout 
JWT access tokens 
Token expiration 
Secure token storage 
Session persistence 
bcrypt password hashing 
Role-based authorization 
Protected API routes 
Never store plaintext passwords. 
Never fake authentication through navigation. 
================================================== 
7. MONGODB 
================================================== 
Create collections: 
users 
patients 
caregivers 
doctors 
hospitals 
health_readings 
devices 
emergencies 
emergency_logs 
medical_records 
messages 
connections 
consents 
notifications 
qr_identities 
Add appropriate indexes. 
Hospital location: 
GeoJSON Point: 
[longitude, latitude] 
Create a 2dsphere index. 
Use MongoDB geospatial queries to find nearby registered hospitals 
and calculate/sort by distance. 
================================================== 
8. HEALTH MONITORING 
================================================== 
Health reading model: 
heartRate 
spo2 
systolicBP 
diastolicBP 
temperature 
activity 
timestamp 
deviceId 
patientId 
source 
Sources: 
BLE 
DEMO 
WEARABLE 
Phone 2 simulator must send readings through the same pipeline 
used by the real BLE device. 
Do not hard-code health values directly into UI widgets. 
================================================== 
9. RISK ENGINE 
================================================== 
Implement a transparent configurable threshold-based engine. 
States: 
NORMAL 
WARNING 
HIGH_RISK 
Return: 
riskLevel 
riskScore 
detectedSignals 
recommendation 
timestamp 
Never diagnose diseases. 
Use wording such as: 
"Potential abnormality detected." 
Thresholds must be configurable rather than scattered throughout 
the application. 
================================================== 
10. EMERGENCY ENGINE 
================================================== 
When HIGH_RISK is detected: 
1. Start emergency verification. 
2. Show emergency interface. 
3. Start 10-second countdown. 
4. Show: 
I'M OK 
GET HELP 
I'M OK: 
Cancel emergency → record event → continue monitoring. 
GET HELP: 
Confirm emergency → GPS → address → nearby hospitals → 
caregiver notification → doctor notification → hospital notification → 
call/SMS provider → emergency log. 
NO RESPONSE: 
Automatically confirm emergency when countdown reaches zero. 
MANUAL SOS: 
Use press-and-hold + confirmation. 
Manual SOS must use the same emergency engine as automatic emergencies. 
================================================== 
11. EMERGENCY LOGGING 
================================================== 
Store every emergency in: 
emergency_logs 
Include: 
detectionTime 
verificationStart 
patientResponse 
confirmationTime 
locationTime 
caregiverNotification 
doctorNotification 
hospitalNotification 
callStatus 
hospitalResponse 
resolutionTime 
finalStatus 
Statuses: 
ACTIVE 
CANCELLED 
CONFIRMED 
ACKNOWLEDGED 
RESPONDING 
RESOLVED 
Persist the event before/alongside real-time broadcasting. 
================================================== 
12. GPS + HOSPITALS 
================================================== 
Use: 
geolocator 
flutter_map 
OpenStreetMap 
Nominatim 
Flow: 
GPS coordinates 
→ Nominatim 
→ readable address 
Hospital flow: 
Patient coordinates 
→ FastAPI 
→ MongoDB 2dsphere 
→ nearby hospitals 
→ distance 
→ sorted results 
Seed fictional hospitals for the demo. 
Never falsely claim a real hospital received an alert. 
================================================== 
13. EMERGENCY CALLING 
================================================== 
Create: 
EmergencyCallProvider 
Implement: 
ExotelProvider 
OR 
PlivoProvider 
OR 
DemoCallProvider 
If real credentials are unavailable, DemoCallProvider must allow 
the complete demo flow to continue. 
Never put provider credentials in Flutter. 
Never claim a real call was completed unless confirmed by the provider. 
================================================== 
14. FCM NOTIFICATIONS 
================================================== 
Use Firebase Cloud Messaging for: 
Emergency alerts 
Caregiver alerts 
Doctor alerts 
Hospital alerts 
Connection requests 
Consent requests 
Chat notifications 
Medical-report notifications 
Create a notification service abstraction. 
================================================== 
15. MEDICAL VAULT + GRIDFS 
================================================== 
Use MongoDB GridFS for: 
PDFs 
Reports 
Prescriptions 
Lab reports 
Scans 
Discharge summaries 
Store metadata separately. 
Support upload, retrieval and deletion with authorization. 
If AI processing fails, the original document must remain available. 
================================================== 
16. AI REPORT SUMMARY 
================================================== 
Flow: 
Medical document 
→ FastAPI 
→ text extraction 
→ LLM API 
→ simplified summary 
→ database 
→ Flutter 
Show: 
Key Observations 
Simplified Explanation 
Important Terms 
Always display: 
"AI-generated summary. Not medical advice." 
Never fabricate medical results. 
================================================== 
17. QR SYSTEM 
================================================== 
Create: 
1. MEDICAL UPLOAD QR 
2. PROFILE QR 
QR codes contain secure identifiers/tokens only. 
Never place medical records inside QR data. 
Medical upload flow: 
Scan 
→ validate 
→ authorize 
→ upload 
→ store in GridFS 
→ success 
Profile QR: 
Scan 
→ identify user 
→ show permitted profile 
→ connect if authorized 
================================================== 
18. CONSENT + ACCESS CONTROL 
================================================== 
Implement: 
Request 
Grant 
Reject 
Review 
Revoke 
Expiration 
Example: 
Doctor requests access 
→ Patient receives request 
→ Patient grants 
→ Doctor receives permitted information 
Authorization MUST be enforced by FastAPI, not only hidden in Flutter. 
================================================== 
19. CHAT 
================================================== 
Use MongoDB messages. 
Support patient ↔ doctor messaging. 
Store: 
conversationId 
senderId 
receiverId 
message 
timestamp 
readStatus 
Use FastAPI WebSocket for real-time messages. 
Handle reconnect, failed sending and read status. 
================================================== 
20. BACKEND STRUCTURE 
================================================== 
Create: 
backend/ 
├── app/ 
│   ├── main.py 
│   ├── config.py 
│   ├── dependencies.py 
│   ├── api/ 
│   ├── models/ 
│   ├── schemas/ 
│   ├── services/ 
│   ├── repositories/ 
│   ├── auth/ 
│   ├── risk/ 
│   ├── emergency/ 
│   ├── websocket/ 
│   ├── integrations/ 
│   └── utils/ 
├── tests/ 
├── requirements.txt 
└── .env.example 
Create clean separation between API, business logic, database, 
authentication and integrations. 
================================================== 
21. API 
================================================== 
Implement appropriate REST endpoints for: 
/api/auth 
/api/users 
/api/patients 
/api/doctors 
/api/caregivers 
/api/hospitals 
/api/health 
/api/devices 
/api/emergencies 
/api/medical-records 
/api/messages 
/api/consents 
/api/notifications 
/api/qr 
/api/location 
Use Pydantic schemas and meaningful HTTP status codes. 
Add authenticated WebSocket endpoints for real-time events. 
================================================== 
22. ERROR HANDLING 
================================================== 
Every important operation must support: 
Loading 
Success 
Empty 
Error 
Offline 
Handle failures gracefully: 
BLE disconnect 
GPS unavailable 
Network failure 
MongoDB failure 
AI failure 
Upload failure 
FCM failure 
Call-provider failure 
WebSocket disconnect 
Never crash because an external service is unavailable. 
Provide demo fallbacks where appropriate. 
Never display fake success states. 
================================================== 
23. SECURITY 
================================================== 
Mandatory: 
bcrypt 
JWT 
Protected APIs 
Role authorization 
Consent authorization 
Secure token storage 
Environment variables 
No secrets in Git 
No credentials in Flutter 
Input validation 
Medical-data access control 
Protected QR tokens 
================================================== 
24. PROJECT FILES 
================================================== 
Create: 
01_MEDILINK_MASTER_BUILD.md 
02_MEDILINK_ANDROID_UI_UX.md 
03_MEDILINK_INTEGRATION_TESTING.md 
README.md 
.gitignore 
.env.example 
Create .env locally when required. 
Never commit .env. 
.gitignore must cover: 
.env 
.env.* 
!.env.example 
Python cache 
virtual environments 
Flutter/Dart generated files 
build files 
IDE files 
logs 
temporary files 
README must include: 
setup 
architecture 
environment variables 
MongoDB setup 
FastAPI setup 
Flutter setup 
Firebase setup 
BLE simulator setup 
external API setup 
testing 
demo instructions 
deployment 
known limitations 
================================================== 
25. DEVELOPMENT RULES 
================================================== 
Do not change the defined technology stack without a strong reason. 
Do not replace FastAPI with another backend. 
Do not replace MongoDB with another database. 
Do not connect Flutter directly to MongoDB. 
Do not create dead buttons. 
Do not create disconnected core features. 
Do not hard-code secrets. 
Do not duplicate business logic. 
Do not over-engineer secondary features. 
Build the critical emergency workflow first. 
Use modular, maintainable code. 
Fix compilation/runtime errors before moving forward. 
================================================== 
26. SUCCESS CRITERIA 
================================================== 
The core MVP must successfully demonstrate: 
Phone 2 
→ BLE health data 
→ Flutter receives readings 
→ FastAPI receives/processes data 
→ Risk Engine detects HIGH_RISK 
→ 10-second emergency verification 
→ GET HELP or NO RESPONSE 
→ GPS captured 
→ readable address obtained 
→ nearby hospitals found 
→ caregiver/doctor/hospital notifications triggered 
→ call/SMS provider or demo provider executed 
→ emergency_log created 
→ live WebSocket updates 
→ emergency status updated 
→ emergency resolved 
Build the critical chain first, then implement secondary modules. 
The application must be functional, modular, secure, stable and ready 
for Prompt 2 to implement the complete Android UI/UX without changing 
this architecture. 