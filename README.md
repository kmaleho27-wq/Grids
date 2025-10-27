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