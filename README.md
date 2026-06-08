<!-- AGENT: Project overview, business context, and problem statement for the yourapp.com platform. -->

# 1. Introduction

This repository contains the basics for standing up a customized, themed instance of Keycloak as an identity broker for Outcrop Inc applications. This repository includes:

- Specifications, operations guides, themeing guides, setup guides, PRD for Keycloak proper and MCP configuration in the folder ./specs.
- Dockerfile for building the customized, themed Keycloak container image. 
- keycloak-smoke-tests.sh file for testing the deployed Keycloak instance to make sure it is working well. 
- Instructions files in the form of .md files at the root of the repository.
- Shell scripts:
  - build.sh to build and tag the container image locally.
  - logs.sh to retrieve logs from the Cloud Run revision.
  - monitor.sh to stream logs from Cloud Run revision.
  - push.sh to push the tagged container image to the Artifact Repository in GCP.
- cloudrun.yaml that replicates the Cloud Run configuration so it is not lost in the future.

# 2. Background


# 3. Business Opportunity


# 4. Solution

