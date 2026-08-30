You are now the senior backend engineer, integration engineer, QA engineer and release 
engineer for MEDILINK. 
Continue from: 
01_MEDILINK_MASTER_BUILD.md 
02_MEDILINK_ANDROID_UI.md 
Do not rebuild working functionality unnecessarily. 
Your task is to connect everything into one reliable, functional application. 
================================================== 
1. FASTAPI BACKEND 
================================================== 
Implement a clean FastAPI backend. 
Required structure: 
backend/ 
app/ 
main.py 
config.py 
dependencies.py 
        api/ 
            auth.py 
            users.py 
            patients.py 
            doctors.py 
            hospitals.py 
            caregivers.py 
            health.py 
            devices.py 
            emergencies.py 
            medical_records.py 
            messages.py 
            consents.py 
            notifications.py 
            qr.py 
            location.py 
 
        models/ 
        schemas/ 
        services/ 
        repositories/ 
        integrations/ 
        risk/ 
        emergency/ 
        utils/ 
 
tests/ 
requirements.txt 
.env.example 
================================================== 
2. API RULES 
================================================== 
All API endpoints must: - validate input - authenticate where required - authorize by role - return appropriate HTTP status - return structured JSON - handle exceptions - log meaningful backend errors 
Do not expose internal stack traces to users. 
================================================== 
3. AUTH API 
================================================== 
Implement: 
POST /api/auth/register 
POST /api/auth/login 
POST /api/auth/refresh 
POST /api/auth/logout 
GET /api/auth/me 
Use: 
JWT 
bcrypt 
Passwords must never be stored in plaintext. 
================================================== 
4. HEALTH API 
================================================== 
Implement: 
POST /api/health/readings 
GET /api/health/current/{patientId} 
GET /api/health/history/{patientId} 
GET /api/health/trends/{patientId} 
Health data must be timestamped. 
================================================== 
5. RISK ENGINE 
================================================== 
Create: 
risk_service.py 
Input: 
HealthReading 
Output: 
RiskResult 
Example: 
{ 
"riskLevel": "HIGH_RISK", 
"riskScore": 92, 
"detectedSignals": [ 
"elevated_heart_rate", 
"low_spo2" 
] 
} 
Keep thresholds configurable. 
================================================== 
6. EMERGENCY SERVICE 
================================================== 
Create: 
emergency_service.py 
Responsibilities: - create emergency - verification - confirmation - cancellation - GPS capture - hospital discovery - notification - call/SMS - logging - status updates - resolution 
Endpoints: 
POST /api/emergencies 
GET /api/emergencies/{id} 
POST /api/emergencies/{id}/confirm 
POST /api/emergencies/{id}/cancel 
POST /api/emergencies/{id}/acknowledge 
POST /api/emergencies/{id}/resolve 
GET /api/emergencies/patient/{patientId} 
================================================== 
7. EMERGENCY STATE MACHINE 
================================================== 
Use a predictable state machine. 
Potential: 
DETECTED 
Then: 
VERIFICATION 
Then either: 
CANCELLED 
or: 
CONFIRMED 
Then: 
ACKNOWLEDGED 
RESPONDING 
RESOLVED 
Do not allow invalid state transitions. 
================================================== 
8. EMERGENCY LOGGING 
================================================== 
Every transition must update: 
emergency_logs 
The emergency timeline shown in Flutter must come from backend state. 
Do not hard-code timeline completion. 
================================================== 
9. HOSPITAL GEO SEARCH 
================================================== 
Implement: 
GET /api/hospitals/nearby 
Inputs: 
latitude 
longitude 
radius 
Use MongoDB 2dsphere. 
Return: 
hospital 
distance 
location 
departments 
emergencyAvailability 
================================================== 
10. LOCATION SERVICE 
================================================== 
Implement Nominatim integration server-side where appropriate. 
Input: 
latitude 
longitude 
Output: 
readable address 
Add timeout and fallback handling. 
Do not make the emergency workflow fail entirely because reverse geocoding failed. 
================================================== 
11. NOTIFICATION SERVICE 
================================================== 
Create: 
notification_service.py 
Support: 
FCM 
Functions: 
notifyCaregiver() 
notifyDoctor() 
notifyHospital() 
notifyPatient() 
Create a provider abstraction. 
If credentials are absent, use demo mode and visibly label it as such. 
================================================== 
12. CALLING SERVICE 
================================================== 
Create: 
calling_service.py 
Interface: 
EmergencyCallProvider 
Implement: 
Exotel 
Plivo 
Demo 
The emergency workflow must not crash when the external provider is unavailable. 
Store: 
callStatus 
provider 
timestamp 
recipient 
errorMessage where appropriate 
================================================== 
13. MEDICAL RECORD API 
================================================== 
Implement: 
POST /api/medical-records/upload 
GET /api/medical-records 
GET /api/medical-records/{id} 
DELETE /api/medical-records/{id} 
GET /api/medical-records/{id}/summary 
Use MongoDB GridFS. 
Validate file type and size. 
Do not allow unauthorized users to download records. 
================================================== 
14. AI SUMMARY 
================================================== 
Create: 
report_summary_service.py 
Flow: 
Uploaded file 
→ text extraction 
→ LLM API 
→ summary 
→ database 
If AI fails: 
return: 
summaryStatus = "UNAVAILABLE" 
The original document must remain available. 
Never fabricate a summary. 
================================================== 
15. QR API 
================================================== 
Create secure QR identities. 
Do not encode: - medical records - passwords - JWTs - private information 
Use identifiers or short-lived upload tokens where appropriate. 
================================================== 
16. CONSENT API 
================================================== 
Implement: 
POST /api/consents/request 
POST /api/consents/{id}/grant 
POST /api/consents/{id}/reject 
POST /api/consents/{id}/revoke 
GET /api/consents 
Authorization must be checked server-side on every medical-data request. 
================================================== 
17. CHAT API 
================================================== 
Implement: 
GET /api/messages/{conversationId} 
POST /api/messages 
PATCH /api/messages/{id}/read 
Persist: 
conversationId 
senderId 
receiverId 
message 
timestamp 
readStatus 
================================================== 
18. FCM 
================================================== 
Store device tokens securely. 
Implement notification events for: 
Emergency 
Consent 
Doctor request 
Hospital alert 
Chat 
System 
================================================== 
19. DATABASE 
================================================== 
Create indexes. 
Required: 
users.email 
health_readings.patientId + timestamp 
messages.conversationId + timestamp 
emergency_logs.patientId + timestamp 
hospitals.location 2dsphere 
Use database repositories instead of putting MongoDB queries directly inside routes. 
================================================== 
20. FLUTTER API LAYER 
================================================== 
Create centralized: 
ApiClient 
Handle: 
GET 
POST 
PUT 
PATCH 
DELETE 
Add: 
AuthInterceptor 
Automatically attach JWT. 
If 401: 
attempt refresh or redirect to login. 
================================================== 
21. STATE MANAGEMENT 
================================================== 
Use Riverpod or BLoC consistently. 
Recommended logical providers: 
authProvider 
patientProvider 
healthProvider 
bleProvider 
riskProvider 
emergencyProvider 
locationProvider 
medicalVaultProvider 
doctorProvider 
hospitalProvider 
chatProvider 
consentProvider 
notificationProvider 
Do not mix multiple state-management architectures unnecessarily. 
================================================== 
22. REAL-TIME UPDATES 
================================================== 
Health UI should update when new BLE readings arrive. 
Emergency state should update without requiring manual refresh. 
Chat should update in near real time where implemented. 
Hospital emergency dashboards should reflect emergency state changes. 
Use WebSockets only where they add meaningful value. 
================================================== 
23. DEMO DATA 
================================================== 
Create safe synthetic data. 
Example: 
PATIENT: 
Ananya Rao 
CAREGIVER: 
Ravi Rao 
DOCTOR: 
Dr. Arjun Mehta 
HOSPITAL: 
MediCare Central Hospital 
Create additional fictional records. 
Clearly mark demo/synthetic data. 
================================================== 
24. ANALYTICS 
================================================== 
For product analytics, add a lightweight analytics abstraction. 
Track events such as: 
app_opened 
signup_completed 
login_completed 
ble_connected 
health_viewed 
emergency_triggered 
emergency_cancelled 
emergency_confirmed 
hospital_viewed 
doctor_connected 
report_uploaded 
ai_summary_generated 
qr_scanned 
Do not collect unnecessary sensitive medical information as analytics event properties. 
================================================== 
25. ERROR HANDLING 
================================================== 
Test: 
Backend unavailable 
MongoDB unavailable 
BLE disconnected 
GPS unavailable 
Map unavailable 
Nominatim unavailable 
FCM unavailable 
Calling provider unavailable 
LLM unavailable 
File upload failure 
Unauthorized access 
Expired JWT 
Invalid QR 
Invalid input 
Every error must have: - useful backend response - useful Flutter UI - retry where appropriate - no application crash 
================================================== 
26. SECURITY CHECKLIST 
================================================== 
Verify: 
[ ] bcrypt password hashing 
[ ] JWT authentication 
[ ] JWT expiration 
[ ] role authorization 
[ ] consent enforcement 
[ ] medical-record authorization 
[ ] secure GridFS access 
[ ] no secrets in Flutter 
[ ] no secrets in Git 
[ ] .env ignored 
[ ] CORS configured 
[ ] input validation 
[ ] file validation 
[ ] QR does not expose private data 
[ ] MongoDB credentials protected 
[ ] external API keys protected 
================================================== 
27. TESTING 
================================================== 
Create backend tests for: 
Authentication 
Risk engine 
Emergency state transitions 
Hospital search 
Consent 
Medical-record authorization 
Flutter tests for critical state logic where practical. 
Most important test: 
Health abnormality 
→ High risk 
→ Verification 
→ No response 
→ Emergency confirmed 
→ Location 
→ Notifications 
→ Emergency log 
→ Hospital acknowledgement 
→ Resolution 
================================================== 
28. BUILD VALIDATION 
================================================== 
Before completion: 
Run Flutter analyzer. 
Fix all critical errors. 
Run Flutter tests. 
Build Android APK. 
Run FastAPI. 
Verify MongoDB connection. 
Verify API endpoints. 
Verify authentication. 
Verify BLE. 
Verify emergency workflow. 
Do not declare completion if the application does not compile. 
================================================== 
29. PROJECT CLEANLINESS 
================================================== 
Remove: 
unused imports 
dead files 
unused dependencies 
debug print statements 
hard-coded credentials 
temporary secrets 
broken routes 
placeholder TODOs in critical functionality 
Keep demo controls clearly separated from production functionality. 
================================================== 
30. FINAL ACCEPTANCE CRITERIA 
================================================== 
MEDILINK is considered complete only when: 
1. User can register. 
2. User can log in. 
3. Correct role dashboard opens. 
4. Patient can connect Phone 2. 
5. BLE health readings appear. 
6. Health dashboard updates. 
7. Risk engine classifies readings. 
8. High-risk state triggers verification. 
9. Patient can cancel emergency. 
10. Patient can request help. 
11. No-response automatically confirms. 
12. GPS location is captured. 
13. Nearby registered hospitals are found. 
14. Caregiver notification works or clearly falls back to demo mode. 
15. Doctor notification works or clearly falls back to demo mode. 
16. Hospital receives/records emergency. 
17. Emergency timeline updates. 
18. Emergency is logged. 
19. Hospital can acknowledge. 
20. Emergency can be resolved. 
21. Medical reports can be uploaded. 
22. GridFS stores documents. 
23. AI summary works or gracefully falls back. 
24. QR profile works. 
25. Medical upload QR works. 
26. Doctor connection works. 
27. Consent works. 
28. Chat works. 
29. Dark mode works. 
30. Loading/error/empty states work. 
31. Android APK builds successfully. 
32. No critical runtime crashes. 
33. No secrets are committed. 
================================================== 
31. FINAL PRODUCT PRINCIPLE 
================================================== 
Do not build MEDILINK as a huge collection of features. 
Build a small number of deeply connected features. 
The central product experience must always remain: 
LIVE HEALTH DATA 
→ RISK DETECTION 
→ EMERGENCY VERIFICATION 
→ EMERGENCY CONFIRMATION 
→ LOCATION 
→ CAREGIVER 
→ DOCTOR 
→ HOSPITAL 
→ RESPONSE 
→ LOG 
Every additional feature must support this central story. 
Build smart. 
Build stable. 
Build polished. 
Build for judges to understand the value immediately. 
Do not sacrifice working functionality for unnecessary technical complexity. 