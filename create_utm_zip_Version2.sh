#!/usr/bin/env bash
set -euo pipefail

ROOTDIR="UTM_scaffold"
ZIPNAME="utm_scaffold.zip"

rm -rf "$ROOTDIR" "$ZIPNAME"
mkdir -p "$ROOTDIR/backend/app" "$ROOTDIR/docs"

cat > "$ROOTDIR/README.md" <<'EOF'
# UTM — Drone Watch

Prototype Unmanned Traffic Management (UTM) platform to detect, register, and track drones using a combination of cellphone-based sensing, edge collectors, and server-side processing. This repository contains a runnable scaffold (backend + simulator) to get started.

Goals
- Register any drone observed by the system (via cellphone-assisted sensing and other COTS sensors).
- Track drone operations from pre-flight/inception through in-air telemetry and post-flight logs.
- Use commodity (COTS) and low-cost hardware and software. Provide a defensive "moat" design (conceptual) inspired by capabilities similar to advanced systems (e.g., secure sensor fusion, attestation, and tamper-resistant edge nodes) without using proprietary designs.

Quick start (local)
1. docker compose up --build
2. The backend will be reachable at http://localhost:8000
3. Run the simulator to send example telemetry: python3 backend/app/simulator.py

Architecture and next steps: see docs/architecture.md

---
EOF

cat > "$ROOTDIR/docs/architecture.md" <<'EOF'
# Architecture Overview

This scaffold implements a minimal, extensible UTM (Unmanned Traffic Management) design focused on drone detection and registration using cellphone-assisted sensing and commodity components.

Core components
- Mobile/Cellphone participants: A lightweight app (or web client) that can report sightings, passive RF scans, camera-based detections, or cooperative ADS-B-style broadcasts emitted by DOT/OTA-capable drones.
- Edge collectors: Raspberry Pi / low-cost single-board computers that aggregate local sensor feeds (Wi-Fi/Bluetooth sniffers, SDR/RTL-SDR for RF, cheap cameras) and run local attestation checks before forwarding.
- Ingest & API service: Central backend (FastAPI) that registers drones, stores telemetry and events, provides search and history APIs.
- Database: Durable storage for drone registrations, telemetry, audit logs (Postgres or SQLite for prototypes).
- Indexing & live view: Time-series store or pub/sub (Redis, Kafka) and a frontend to visualize tracks.

Sensor fusion and "moat" (conceptual)
We describe a defensible architecture (a "moat") for reliability, provenance and tamper resistance without copying proprietary systems.
- Edge attestation: Each edge collector has a hardware root of trust (TPM/secure element) and signs forwarded messages. This prevents easy spoofing of whole-edge data.
- Multi-source fusion: Combine cellphone reports, edge collectors, and remote telemetry to cross-validate sightings.
- Reputation & anomalies: Track reporter reputation, use ML to flag anomalies (impossible speeds/altitudes), and quarantine suspicious reports.
- Open interfaces and data escrow: Signed telemetry + append-only logs for auditability.

Privacy & legal
- Respect local privacy and data-protection laws. Collect minimal PII, and store ephemeral sensor payloads only when needed.

Next steps
- Add a React frontend for live tracking
- Add mobile app (React Native or Flutter) to collect sightings and allow voluntary pilot registration
- Implement Postgres + Redis for production readiness
- Add device attestation and signing on edge nodes
EOF

cat > "$ROOTDIR/docker-compose.yml" <<'EOF'
version: "3.8"
services:
  backend:
    build: ./backend
    ports:
      - "8000:8000"
    volumes:
      - ./backend:/app
    environment:
      - DATABASE_URL=sqlite:///./data/utm.db
    depends_on: []
EOF

cat > "$ROOTDIR/backend/Dockerfile" <<'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY backend/requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY backend /app
CMD ["uvicorn","app.main:app","--host","0.0.0.0","--port","8000"]
EOF

cat > "$ROOTDIR/backend/requirements.txt" <<'EOF'
fastapi
uvicorn[standard]
sqlmodel
requests
python-dotenv
EOF

cat > "$ROOTDIR/backend/app/main.py" <<'EOF'
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlmodel import SQLModel, Field, create_engine, Session, select
from typing import Optional, List
from datetime import datetime

DATABASE_URL = "sqlite:///./data/utm.db"
engine = create_engine(DATABASE_URL, echo=False)

app = FastAPI(title="UTM Drone Watch API")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class Drone(SQLModel, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    uas_id: Optional[str] = Field(index=True, description="UAS ID if available (e.g., serial/registration)")
    description: Optional[str] = None
    first_seen: datetime = Field(default_factory=datetime.utcnow)
    last_seen: datetime = Field(default_factory=datetime.utcnow)
    reported_by: Optional[str] = None

class Telemetry(SQLModel, table=True):
    id: Optional[int] = Field(default=None, primary_key=True)
    drone_id: int = Field(foreign_key="drone.id")
    latitude: float
    longitude: float
    altitude_m: Optional[float] = None
    heading: Optional[float] = None
    speed_ms: Optional[float] = None
    seen_at: datetime = Field(default_factory=datetime.utcnow)
    source: Optional[str] = None

@app.on_event("startup")
def on_startup():
    SQLModel.metadata.create_all(engine)

@app.post("/register")
def register(drone: Drone):
    with Session(engine) as session:
        # try to find existing by uas_id
        if drone.uas_id:
            existing = session.exec(select(Drone).where(Drone.uas_id == drone.uas_id)).first()
            if existing:
                existing.last_seen = datetime.utcnow()
                session.add(existing)
                session.commit()
                session.refresh(existing)
                return existing
        session.add(drone)
        session.commit()
        session.refresh(drone)
        return drone

@app.post("/telemetry")
def ingest_telemetry(payload: dict):
    # expected payload: {"uas_id":..., "lat":..., "lon":..., "alt_m":..., "source":...}
    uas_id = payload.get("uas_id")
    lat = payload.get("lat")
    lon = payload.get("lon")
    if lat is None or lon is None:
        raise HTTPException(status_code=400, detail="lat and lon required")
    with Session(engine) as session:
        drone = None
        if uas_id:
            drone = session.exec(select(Drone).where(Drone.uas_id == uas_id)).first()
        if not drone:
            # create a new anonymous drone record
            drone = Drone(uas_id=uas_id, description=payload.get("description"), reported_by=payload.get("source"))
            session.add(drone)
            session.commit()
            session.refresh(drone)
        # add telemetry
        t = Telemetry(drone_id=drone.id, latitude=lat, longitude=lon, altitude_m=payload.get("alt_m"), heading=payload.get("heading"), speed_ms=payload.get("speed"), source=payload.get("source"))
        session.add(t)
        drone.last_seen = datetime.utcnow()
        session.add(drone)
        session.commit()
        session.refresh(t)
        return {"drone": drone, "telemetry": t}

@app.get("/drones", response_model=List[Drone])
def list_drones():
    with Session(engine) as session:
        drones = session.exec(select(Drone)).all()
        return drones

@app.get("/drones/{drone_id}")
def get_drone(drone_id: int):
    with Session(engine) as session:
        drone = session.get(Drone, drone_id)
        if not drone:
            raise HTTPException(status_code=404, detail="not found")
        return drone

@app.get("/health")
def health():
    return {"status": "ok"}
EOF

cat > "$ROOTDIR/backend/app/simulator.py" <<'EOF'
"""
Simple simulator that posts telemetry to the backend to demonstrate registration and tracking.
"""
import requests
import time
import random

API = "http://localhost:8000/telemetry"

def random_point(center=(37.7749, -122.4194), radius=0.01):
    lat = center[0] + (random.random()-0.5)*radius
    lon = center[1] + (random.random()-0.5)*radius
    return lat, lon

if __name__ == '__main__':
    uas_id = None
    for i in range(10):
        lat, lon = random_point()
        payload = {
            "uas_id": uas_id,
            "lat": lat,
            "lon": lon,
            "alt_m": random.uniform(5,120),
            "speed": random.uniform(0,20),
            "heading": random.uniform(0,360),
            "source": "simulated_cellphone_1"
        }
        r = requests.post(API, json=payload)
        print(i, r.status_code, r.text)
        time.sleep(1)
EOF

cat > "$ROOTDIR/.gitignore" <<'EOF'
__pycache__/
data/
.env
EOF

cat > "$ROOTDIR/LICENSE" <<'EOF'
MIT License

Copyright (c) 2025 kmaleho27-wq

Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
EOF

# create zip
pushd "$ROOTDIR" >/dev/null
zip -r "../$ZIPNAME" . >/dev/null
popd >/dev/null

echo "Created $ZIPNAME containing the scaffold in the $ROOTDIR/ directory."
echo
ls -lh "$ZIPNAME"