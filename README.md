# Introduction

KeyCloak setup for Outcrop Inc (yourapp.com, trapius.ai). This repository contains 
the basic information necessary to setup a proper IdP using KeyCloak to serve
the authentication needs for the Outcrop applications hosted at yourapp.com and
trapius.ai. 

# Phase 1

In Phase 1, the infrastructure is largely managed.

- Database: PostgreSQL using Neon on the free plan.
- Service: Small Cloud Run container using an idle to zero configuration (512mb, 1 vCPU).
- Telemetry: Grafana Cloud with OpenTelemetry on the free plan.

# Phase 2

- Database: PostgreSQL using Neon on the free plan.
- Service: Small Docker container (brought up with docker compose) using (4GB, 2 vCPU).
- Telemetry: Local Grafana with OpenTelemetry collector running in Docker.


