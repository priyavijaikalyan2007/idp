<!-- AGENT: Project overview, business context, and problem statement for the Knobby.io platform. -->

This repository contains the basics for standing up a customized, themed instance of Keycloak as an identity broker for Outcrop Inc applications. Outcrop Inc. properties use a AI-native development model with a AI-friendly and AI-enabled product. This means that we we must support protocols such as A2A and MCP for agents and tools and offer MCP endpoints for LLM harnesses to invoke. This in turn requires support for DCR, OAuth 2.1, a MCP consent flow and other capabilities. 

However, most hosted identity providers such as Auth0 and Amazon Cognito either offer these advanced capabilities only under high cost plan tiers or they don't support them outright. This is cost prohibitive for "run my own software" shops, pre-PMF web properoties and small niche startups. Outcrop Inc. web properties fall into these buckets. Hence, to keep cost down and own our own fate with regards to customization, we run our Keycloak instances. 

This repository contains all the necessary themes, providers, mappers, Dockerfiles, scripts etc. necessary to customize, build, deploy, run and monitor a full Keycloak identity broker for Outcrop Inc. web properties.

