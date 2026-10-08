# Forest Navigation System (Dead Reckoning & Patrol Tracking)

A comprehensive real-time forest ranger navigation, dead reckoning, and patrol monitoring platform designed for GPS-denied and degraded wilderness environments.

---

## Architecture Overview

The system consists of four primary subsystems:

```
forest-nav-system/
├── backend/          # FastAPI backend service with Supabase DB & WebSocket streaming
├── edge-engine/      # Python inertial dead reckoning & sensor fusion inference engine
├── mobile-app/       # Flutter cross-platform mobile ranger application
└── web-dashboard/    # Next.js 14 + Tailwind CSS real-time patrol command dashboard
```

---

### 1. `backend/`
- **Framework**: FastAPI (Python 3.11)
- **Database**: PostgreSQL (Supabase / asyncpg / SQLAlchemy)
- **Features**:
  - Real-time WebSocket broadcasting for live patrol tracking (`/ws/live`)
  - Geofence management & breach alerts (`/api/v1/geofence`)
  - Ranger patrol session logging and offline batch sync (`/api/v1/sync`)
  - Wildlife and incident sighting management (`/api/v1/sightings`)
  - Mission simulation tooling (`simulate_mission.py`)

### 2. `edge-engine/`
- **Engine**: Zero-velocity update (ZUPT), Pedestrian Dead Reckoning (PDR), and sensor fusion
- **Machine Learning**: Lightweight ONNX models for motion classification and speed estimation:
  - `motion_classifier.onnx`
  - `pedestrian_speed_estimator.onnx`
  - `universal_speed_estimator.onnx`
- **Features**:
  - Inertial sensor preprocessing (accelerometer, gyroscope, magnetometer, barometer)
  - Map matching and topographical constraint integration
  - Observability and trajectory validation harness

### 3. `mobile-app/`
- **Framework**: Flutter (Dart) / Android
- **Features**:
  - Offline-first ranger navigation dashboard
  - On-device sensor collection & real-time dead reckoning
  - Incident/sighting logging with offline caching
  - Tactical map interface with geofence warning triggers

### 4. `web-dashboard/`
- **Framework**: Next.js (React, TypeScript, Tailwind CSS, MapLibre GL)
- **Features**:
  - Live ranger patrol monitoring and real-time breadcrumb tracks
  - Mission playback & patrol replay analytics
  - Geofence boundary drawing and alert feed
  - Incident dispatch and emergency SOS coordination

---

## Setup & Getting Started

### Backend
```bash
cd backend
python -m venv venv
# Windows:
.\venv\Scripts\activate
# Linux/macOS:
source venv/bin/activate

pip install -r requirements.txt
cp .env.example .env
# Fill in your database and Supabase credentials in .env
uvicorn app.main:app --reload --port 8000
```

### Edge Engine
```bash
cd edge-engine
pip install -r requirements.txt
python -m api.inference_api
```

### Mobile App
```bash
cd mobile-app
flutter pub get
flutter run
```

### Web Dashboard
```bash
cd web-dashboard
npm install
npm run dev
```

---

## License

Proprietary / Forest Navigation Project
