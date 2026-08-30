You are a senior Flutter engineer and award-winning health-tech UI/UX designer. 
Continue MEDILINK strictly according to 01_MEDILINK_MASTER_BUILD.md. 
DO NOT change the architecture, backend, database, API contracts, authentication, BLE 
pipeline, risk engine, emergency engine, or technology stack. 
Your responsibility: build the COMPLETE Android UI/UX, navigation, role-based screens, 
animations, onboarding, AI-generated visuals, reusable components, accessibility, 
responsive layouts, and real integration with the existing functionality. 
Do NOT create disconnected mock screens. Every important button must perform its real 
action or navigate to an implemented feature. 
================================================== 
1. VISUAL IDENTITY 
================================================== 
MEDILINK must look like a premium, trustworthy, modern healthcare product. 
Use: - Flutter Material 3 - ONE LIGHT THEME ONLY - deep medical blue - teal/cyan accents - green success - amber warning 
- red emergency - clean healthcare-white background - premium typography - modern Material/Symbol icons - layered cards - subtle shadows - restrained gradients - clear spacing and hierarchy - subtle micro-interactions 
Do NOT use: - dark mode - theme switcher - excessive glassmorphism - excessive animation - childish visuals - generic dashboard/template styling - emoji as primary icons 
Centralize colors, typography and spacing in the theme. 
================================================== 
2. NAVIGATION + AUTH 
================================================== 
Use GoRouter. 
Flow: 
Splash 
→ AI Onboarding 
→ Welcome 
→ Login/Signup 
→ Role Selection 
→ Profile Setup 
→ Permissions 
→ Dashboard 
Returning users skip completed onboarding. 
Protect authenticated routes and enforce role access. 
Patient: 
Home | Health | Emergency | Connections | Profile 
Caregiver: 
Home | Patients | Alerts | Profile 
Doctor: 
Home | Patients | Alerts | Messages | Profile 
Hospital: 
Command Center | Emergencies | Patients | Profile 
Authentication must use the existing FastAPI/JWT system. No fake login. 
================================================== 
3. SPLASH + AI ONBOARDING 
================================================== 
Splash: - MEDILINK logo - "Monitor. Detect. Connect. Respond." - subtle fade/scale/health-wave animation - short duration 
Immediately after splash, create a 4-card animated onboarding carousel. 
Use CUSTOM AI-GENERATED visuals with one consistent premium healthcare style: 
clean light background, medical blue/teal, soft lighting, modern technology. 
CARD 1: 
"Your Health. Always Connected." 
Wearable + patient + smartphone + vitals. 
CARD 2: 
"Detect Before It Escalates." 
Health data → intelligent analysis → abnormal pattern. 
CARD 3: 
"When It Matters, Respond Faster." 
Emergency alert + GPS + caregiver + doctor + hospital. 
CARD 4: 
"One Platform. Connected Care." 
Patient → MEDILINK → care network. 
Include: 
Skip | Back | Next | progress | swipe | GET STARTED 
Persist onboarding completion. 
Store assets under: 
assets/images/onboarding/ 
If image generation is available, generate the assets. Otherwise create the asset structure 
without breaking the build. 
================================================== 
4. AUTH, ROLE & PROFILE 
================================================== 
Login: 
Email, Password, Show/Hide, Forgot Password, Login. 
Signup: 
Name, Email, Password, Confirm Password, Role. 
Use validation and human-readable errors. 
Role cards: 
Patient 
Caregiver 
Doctor 
Hospital 
Profile setup must be role-specific. 
Patient: 
Name, Age, Blood Group, Allergies, Conditions, Emergency Contacts 
Doctor: 
Name, Specialty, Hospital, Experience 
Hospital: 
Name, Location, Departments, Emergency Availability, Contact 
Caregiver: 
Name, Relationship, Connected Patient 
Permissions: 
Bluetooth, Location, Notifications and phone/calling permissions where required. 
Explain permissions before requesting them. 
================================================== 
5. PATIENT HOME 
================================================== 
Header: 
Avatar | Greeting | Notifications 
Main health card: 
HEALTH STATUS 
● STABLE 
72 BPM 
Show: 
SpO₂ 
Blood Pressure 
Temperature 
Last Sync 
Add attractive but meaningful health visualization. 
AI insight: 
"Your recent readings are within your configured monitoring range." 
Label: 
"Informational only." 
Quick actions: 
Health | Emergency | Medical Vault | Doctors | Hospitals | QR 
Use large, clear icon cards. 
================================================== 
6. HEALTH + BLE + SIMULATOR 
================================================== 
Health dashboard: 
Heart Rate 
SpO₂ 
Blood Pressure 
Temperature 
Ranges: 
24H | 7D | 30D 
Show current, average, min and max. 
Charts must represent real application state. 
BLE screen: 
Device 
Connection 
Signal 
Last Sync 
States: 
Searching | Connecting | Connected | Disconnected | Error 
Actions: 
Scan | Connect | Disconnect 
Use flutter_blue_plus. 
Create a development-only SIMULATOR clearly marked: 
SIMULATED DATA 
NORMAL: 
HR 72 | SpO₂ 98 | BP 120/80 
WARNING: 
HR 110 | SpO₂ 93 | BP 145/90 
HIGH RISK: 
HR 145 | SpO₂ 87 | BP 170/110 
CUSTOM 
Simulator MUST feed the same health pipeline as BLE. 
================================================== 
7. RISK + EMERGENCY 
================================================== 
Risk states: 
NORMAL → Green 
WARNING → Amber 
HIGH RISK → Red 
Show icon + status + short explanation. 
Use "Potential abnormality detected", never diagnosis language. 
Emergency is the strongest visual experience. 
When high risk occurs: 
POTENTIAL EMERGENCY 
"An abnormal health pattern has been detected." 
Countdown: 
10 → 0 
Huge actions: 
I'M OK 
GET HELP 
Use: - high contrast - vibration - sound - warning pulse - large typography 
I'M OK: 
cancel → log event → return to monitoring. 
GET HELP: 
activate existing emergency engine. 
No response: 
"NO RESPONSE DETECTED" 
→ automatically activate emergency. 
Manual SOS: 
"PRESS AND HOLD FOR SOS" 
Do not trigger SOS from one accidental tap. 
================================================== 
8. ACTIVE EMERGENCY 
================================================== 
Create a professional emergency command interface. 
Show: 
EMERGENCY ACTIVE 
Patient 
Risk 
Vitals 
Location 
Address 
Caregiver Status 
Doctor Status 
Hospital Status 
Call Status 
Timeline: 
Detected 
Verification 
Confirmed 
Location 
Caregiver 
Doctor 
Hospital 
Response 
Resolved 
Animate events as they actually occur. 
Call status: 
Preparing | Calling | Answered | Not Answered | Retrying | Completed | Failed 
Never claim a call/notification/hospital response succeeded unless confirmed by the 
backend/provider. 
================================================== 
9. MAP + HOSPITALS 
================================================== 
Use: 
geolocator 
flutter_map 
OpenStreetMap 
Nominatim 
Show: 
Patient location 
Nearby hospitals 
Distance 
Readable address 
Use custom markers. 
Use MongoDB 2dsphere backend results. 
If map fails, show coordinates + address. 
Hospital cards: 
Name | Distance | Emergency Availability | Departments 
Actions: 
View | Connect | Navigate 
Demo hospitals must be clearly synthetic/demo data. 
================================================== 
10. MEDICAL VAULT + AI 
================================================== 
Categories: 
All | Reports | Prescriptions | Lab | Imaging | Discharge 
Document card: 
Icon | Title | Date | Source | Type | AI Summary Status 
Actions: 
View | Share where authorized | Delete 
Support PDFs/images/scans through GridFS. 
AI summary: 
AI REPORT SUMMARY 
Key Observations 
Simplified Explanation 
Important Terms 
Disclaimer: 
"AI-generated summary. Not medical advice." 
Never fabricate medical results. 
If AI fails, keep the original document available and show a fallback message. 
================================================== 
11. QR CENTER 
================================================== 
Create premium QR cards: 
MY PROFILE QR 
MEDICAL UPLOAD QR 
Show: 
Title | Purpose | QR | MEDILINK branding | Share/download 
Never encode complete medical records. 
Profile QR displays only permitted basic information. 
Medical Upload QR flow: 
Scan 
→ Validate 
→ Authorize 
→ Upload 
→ Success 
Handle: 
Scanning | Invalid | Expired | Uploading | Success 
================================================== 
12. CAREGIVER, DOCTOR & HOSPITAL 
================================================== 
CAREGIVER: 
Prioritize: 
Patient Status 
Emergency Alerts 
Location 
Call 
Medical Information 
Show patient: 
Name | Status | Vitals | Last Sync | Location | Emergency History 
Actions: 
Call | Location | Medical Info | Emergency 
DOCTOR: 
Dashboard: 
Patients | Requests | Emergency Alerts | Messages 
Doctor discovery: 
Search + Specialty + Availability + Distance 
Doctor card: 
Avatar | Name | Specialty | Hospital | Experience | Availability 
Actions: 
View | Connect 
HOSPITAL: 
Command center: 
Active | Pending | Acknowledged | Responding | Resolved 
Emergency card: 
Patient | Distance | Risk | Vitals | Time | Status 
Actions: 
View | Acknowledge | Respond | Resolve 
Use actual backend state, never fabricated statuses. 
================================================== 
13. CHAT + CONSENT + NOTIFICATIONS 
================================================== 
CHAT: 
Professional healthcare messaging using MongoDB messages. 
Include: 
Message bubbles 
Timestamp 
Read state 
Typing state if implemented 
Report attachment 
Emergency shortcut 
Show Sending | Sent | Failed and allow retry. 
CONSENT: 
Show: 
Requester 
Requested Data 
Purpose 
Duration 
Status 
Actions: 
Grant | Reject | Revoke 
Medical access must remain consent-based. 
NOTIFICATIONS: 
Emergency | Health | Doctor | Hospital | System 
Show icon, title, description, timestamp and unread state. 
Use Firebase Cloud Messaging. 
================================================== 
14. PROFILE + SETTINGS 
================================================== 
Profile: 
Name 
MEDILINK ID 
Role 
Emergency Contacts 
Connected Devices 
Doctors 
Hospitals 
Privacy 
Settings 
Settings: 
Profile 
Notifications 
Privacy 
Security 
Senior Mode 
Connected Devices 
Emergency Contacts 
View Introduction Again 
Logout 
No dark mode or theme switcher. 
================================================== 
15. REUSABLE COMPONENTS 
================================================== 
Create reusable components: 
HealthMetricCard 
HealthStatusCard 
HealthChart 
RiskCard 
EmergencyButton 
EmergencyCountdown 
EmergencyTimeline 
DeviceCard 
DoctorCard 
HospitalCard 
MedicalRecordCard 
NotificationCard 
ConsentCard 
QrCard 
StatusBadge 
PrimaryButton 
SecondaryButton 
LoadingState 
ErrorState 
EmptyState 
OfflineBanner 
LocationCard 
EmergencyStatusCard 
Avoid duplicated UI code and giant widget files. 
================================================== 
16. ACCESSIBILITY + UI STATES 
================================================== 
Support: 
Loading 
Success 
Empty 
Error 
Offline 
Never show blank screens. 
Use: - minimum ~48dp touch targets - semantic labels - sufficient contrast - readable fonts - screen-reader-friendly controls - clear errors - do not rely only on color 
Senior Mode: 
larger text, larger controls, simplified navigation. 
Offline mode may show cached information where appropriate. 
Never falsely show: 
Delivered 
Completed 
Notified 
Answered 
Resolved 
unless confirmed by the real system. 
================================================== 
17. RESPONSIVE + PERFORMANCE 
================================================== 
Optimize for Android phones and different screen sizes. 
Use responsive layouts instead of fixed dimensions. 
Optimize: 
images 
lists 
charts 
animations 
network calls 
BLE updates 
medical files 
Avoid unnecessary rebuilds and heavy main-thread work. 
Emergency UI must remain responsive. 
================================================== 
18. REAL INTEGRATION 
================================================== 
Connect UI to the existing Prompt 1 architecture: 
Flutter Android 
FastAPI 
MongoDB Atlas 
JWT + bcrypt 
flutter_blue_plus 
Threshold Risk Engine 
Exotel/Plivo 
Firebase Cloud Messaging 
MongoDB messages 
LLM API 
geolocator 
flutter_map/OpenStreetMap 
Nominatim 
QR/qr_flutter 
MongoDB GridFS 
emergency_logs 
Do not introduce unnecessary frameworks or replace these technologies. 
UI must consume real application state. 
Simulator must use the same pipeline as BLE. 
Emergency UI must use the real emergency engine. 
================================================== 
19. FINAL QUALITY CHECK 
================================================== 
Before considering the UI complete, verify: - every route works - every role sees the correct screens - authentication works - BLE states work - simulator works - risk states work - emergency countdown works - no-response flow works - manual SOS works - location works - hospital search works 
- medical vault works - AI summary has fallback - QR flows work - chat works - consent works - notifications work - loading/empty/error/offline states exist - accessibility is respected - animations are smooth - no dark mode exists - no fake success states exist - no broken navigation - no unnecessary decoration 
The first impression must immediately communicate: 
"MEDILINK is a serious healthcare emergency-response platform." 
Prioritize: 
CLARITY > DECORATION 
FUNCTIONALITY > COMPLEXITY 
TRUST > FLASHINESS 
ACCESSIBILITY > VISUAL EFFECTS 
POLISH > FEATURE BLOAT 
Build the complete Android UI/UX layer without changing the architecture defined in 
01_MEDILINK_MASTER_BUILD.md. 