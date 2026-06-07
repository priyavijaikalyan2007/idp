# Keycloak ↔ MCP Integration Design Notes

**Status:** Draft v0.3 (brainstorm output, pre-PRD)
**Last Updated:** 2026-06-08
**Companion to:** `specs/infra/keycloak.prd.md` (v1.6), `specs/mcp/layer-1-mcp-server-v3.md`, `specs/library.prd.md` (§10 Permissions)
**Purpose:** Capture the design decisions from the MCP × Keycloak brainstorm so the MCP PRD (v4) and the Keycloak PRD (v1.7) can absorb them. This file is the durable artifact of the open questions resolved during the session; once both PRDs are updated, this becomes a historical record.

**Changelog:**
- v0.1 (2026-06-07): scope vocabulary + bundle ladder + per-tenant-token decision (A); tenant-picker implementation left open as paths (i) vs (ii).
- v0.2 (2026-06-08): tenant-picker implementation **locked: path (iii)** — Keycloak still owns OAuth, picker + consent UI hosted by YourApp web. Adds the 3-step consent wizard, trust-signal hardening, and three sub-decisions (default bundle, Connected Agents entry point, negative-list generation strategy).
- v0.3 (2026-06-08): five implementation-spec clarifications. **(Q1)** Removed the misleading `yourapp-{env}-mcp-server` "fourth client" framing; correct model is realm-level DCR with `mcp-dcr-policy` Client Registration Policy + `mcp-default` Client Scope + per-install DCR-generated `client_id`s; MCP server is a resource server identified by audience `yourapp-mcp-api`. **(Q2)** YourApp web session at `/mcp/consent` is established via `prompt=none` silent OIDC, not by hand-waving over the SSO session. **(Q3)** Locked new Keycloak authentication flow `browser-mcp-tenant-pick` (duplicate of `browser-federated-only` + SPI Authenticator step), auto-bound to DCR'd clients via the Client Registration Policy; the web flow is untouched. **(Q4)** Empty-membership state explicit: block consent with two-branch messaging (domain-known but no membership → "ask your admin"; no domain match → "create a workspace"). **(Q5)** Added §2.8 explicitly distinguishing the Authenticator+RRP SPI (in scope for MCP v1) from the parked Event Listener SPI (Keycloak PRD §15 Future Work). Updated §3 cross-spec deltas accordingly.

---

## 0. Scope of this document

Two design questions were resolved during this session:

1. **OAuth scope vocabulary** exposed by the YourApp MCP server — what scopes exist, how they bundle for consent, how they map to MCP protocol primitives, and how they dovetail with YourApp's existing RBAC/FGAC.
2. **Per-tenant token issuance** under the v1.6 Keycloak architecture, which dropped Keycloak Organizations and so invalidated the tenant-picker mechanism the MCP v3 PRD assumed.

Both decisions feed forward into a v4 revision of the MCP PRD. This document does not re-state the MCP PRD's content; it states only what changes.

---

## 1. OAuth scope vocabulary

### 1.1 Decision

The MCP server exposes a **6-atom semantic scope vocabulary** in the `yourapp:` namespace, surfaced to users (and tenant admins) through a **5-bundle consent ladder** that strictly nests, with raw scopes available behind an "expand" affordance for advanced configuration.

### 1.2 Raw scope vocabulary (6 atoms)

| Scope | Verb semantics |
|---|---|
| `yourapp:read` | View resources the user has read access to. |
| `yourapp:comment` | Post comments / suggestions on resources the user has comment access to. |
| `yourapp:curate` | Tag, classify, organize, link (cross-app ontology relationships), archive/restore, move, rename. *Acts on existing resources; strictly reversible; no creation, no destruction.* Library `Curate` role (§10.3) is the canonical specification of this verb set. |
| `yourapp:write` | Create new resources, edit content, delete. *Generative and destructive on the resource itself.* |
| `yourapp:share` | Grant or revoke access to others (RBAC-adjacent permission mutations). |
| `yourapp:admin` | Tenant-level administration: user management, role configuration, tenant settings, MCP enable/disable per role, audit-log configuration, etc. |

App-level subsets are available for clients that want narrower consent:
`yourapp:thinker:read`, `yourapp:thinker:curate`, `yourapp:thinker:write`, etc. These are emitted only when a client explicitly requests them; the default consent surface uses the platform-level scopes above.

### 1.3 Consent bundle ladder (5 bundles, strictly nested)

| Bundle | Adds | RBAC mirror | Default? | Elevation? |
|---|---|---|---|---|
| **Viewer** | `read` | viewer | — | — |
| **Reviewer** | `+ comment` | (commenter / editor-light) | — | — |
| **Curator** | `+ curate` | (n/a as a single role; corresponds to Library's `Curate` role) | — | — |
| **Author** | `+ write, + share` | editor / owner | **Default consent** | — |
| **Admin** | `+ admin` | tenant admin | — | **Required; prominent consent UI** |

Strict nesting means a tenant admin configuring role limits picks a single "maximum bundle" rather than a set of toggles. The wire format is still raw scopes; bundles are a presentation/admin-mental-model layer.

#### Why these bundles, in plain English

- **Viewer** — see only.
- **Reviewer** — see plus give feedback (the human reviewer or the assistive-agent reviewer pattern).
- **Curator** — the **agent-safe long-lived role**. Acts only on what exists. Safe for autonomous nightly tagging, classification, link-curation. Library §10.3 codified this first; the pattern will recur in Strukture (tagging), Diagrams (label organization), Thinker (cross-session linking).
- **Author** — what a human's AI tool needs to draft a PRD, file work items, share a diagram. Default for Claude Code, Codex, Gemini CLI when a human installs them as their working assistant.
- **Admin** — tenant administration. Distinct elevation tier because the blast radius is tenant-wide, not resource-scoped. RBAC can't catch tenant-admin abuse the way it catches resource-level abuse.

#### What is *not* a separate bundle, and why

- **No separate "Owner" bundle for delete.** RBAC already gates who can delete what (a viewer who grants Author still can't delete; RBAC denies). Putting `delete` behind a scope-elevation step would train users to over-grant ("just give Claude Code Owner, the Author bundle isn't enough"). The OAuth cap should target *what RBAC can't catch* (tenant-wide admin), not *what users do every day* (deleting their own drafts).
- **No separate "Sharer" bundle for share.** Same reasoning. RBAC gates who can grant access to what. Sharing a workitem you own is a normal editor act in the existing `ResourceSharingController`. Tenants who want to ban *agent-initiated sharing* specifically can strip `share` from Author via custom policy → "Author (custom — no share)".
- **No `yourapp:delete` outside `yourapp:write` for v1.** Conceptually distinct; practically, the design rule below (§1.5) doesn't justify the split, and the bundle ladder collapses delete into Author anyway.

### 1.4 Bundle ↔ raw scope semantics

- Bundles are a **presentation and admin-mental-model layer**, not a wire-format concern.
- Tokens carry raw scopes (e.g., `yourapp:read yourapp:comment yourapp:write yourapp:share`). MCP metadata endpoints, audit payloads, and tenant role-limit checks all operate in raw-scope terms.
- The consent screen, the "Connected Agents" UI, and the tenant-admin role editor all display bundles by default with an expand affordance to show raw scopes.
- A custom bundle composition (e.g., Author minus `share`) renders as **"Custom — based on Author"**, never silently as "Author". Otherwise the bundle name lies about the grant.
- Bundle definitions are **locked at grant time**. When a new scope is added later (e.g., a future `yourapp:export`), existing `Author` grants keep their original scope set; new consent flows show `Author@v2` with the added scope highlighted as new. Matches OAuth's standard "re-consent on widening" behaviour. Avoids both silent authority widening and disruptive forced re-consent for harmless additions.

### 1.5 Design rule for adding scopes

> A scope is the unit of consent. Add a new scope only if a meaningful consent decision exists — i.e., if a user might reasonably grant one capability but not the other. If splitting two capabilities into separate scopes would never produce a meaningful consent decision (no one would grant one without the other), they should share a scope.

This rule is the test future scope additions must pass. Applied to the 6-atom vocabulary:

| Adjacent pair | Meaningful consent decision? | Evidence |
|---|---|---|
| `read` vs `comment` | Yes | Review-only sessions exist; some users grant read alone for research mode. |
| `comment` vs `curate` | Yes | Library §10.3: tagging agents don't post comments. Different agent shapes. |
| `curate` vs `write` | Yes | Library §10.3's entire rationale — `curate` is the least-privilege agent bucket; `write` is generative/destructive and human-tier. |
| `write` vs `share` | Yes | Compliance-strict tenants may ban agent-initiated sharing while allowing content authoring. |
| `share` vs `admin` | Yes | Library §10.1: non-admin power-users field access requests without needing tenant-admin authority. |

Every adjacent pair passes. The vocabulary is right-sized.

### 1.6 Why the semantic axis, not the MCP-protocol axis

A natural strawman (and one Claude.ai's connector design rule suggests as a first cut) is to organize scopes by MCP protocol primitive:

```
mcp:tools:read         # list available tools
mcp:tools:execute      # invoke tools
mcp:resources:read     # fetch resources
mcp:resources:write    # mutate resources
mcp:prompts:read       # access prompt templates
```

Pressure-testing this cut against its own design rule:

- `mcp:tools:read` vs `mcp:tools:execute` — listing without executing is useless. No meaningful consent decision. Collapses.
- `mcp:resources:read` vs `mcp:tools:execute` (when the tool returns data) — same underlying authority (YourApp data into AI context), different MCP primitive. The user cannot meaningfully distinguish "fetched via URI" from "fetched via tool call." No meaningful consent decision.
- `mcp:resources:write` — Resources are read-only by the MCP spec. All writes go through Tools. Empty bucket.

Collapsing, the MCP-axis cut reduces to roughly `mcp:read + mcp:write` — which is the v3 PRD's original coarse vocabulary, already rejected because `share`, `delete`, `comment`, and `curate` have distinct blast radii.

The MCP-protocol-axis cut works for a **provider-agnostic** scope vocabulary: it's the only handle available when the semantic surface is unknown. YourApp's RBAC defines a **specific** semantic surface (read / comment / curate / write / share / admin), and the same design rule pulls scopes onto that axis instead. Same rule, different ground truth, different result.

**What the MCP protocol axis still gives us:** the `requiredScope` field in the MCP tool schema is the bridge. Each tool declares the scope it requires; the server enforces at call time. The 6-atom semantic vocabulary maps to N tools without scope proliferation.

### 1.7 Mapping the vocabulary onto MCP primitives

| MCP capability | Scope mapping | Notes |
|---|---|---|
| **Tools** | Per-tool `requiredScope` drawn from the 6 atoms. `thinker.get_session` → `read`; `thinker.tag_session` → `curate`; `thinker.create_session` → `write`; `thinker.add_comment` → `comment`; `thinker.share_session` → `share`; `tenant_admin.set_role` → `admin`. | Tool schemas generated from existing API contracts; `requiredScope` annotation added at schema-generation time. |
| **Resources** (URI-addressable content) | All gated by `yourapp:read`. | Resources are read-only by MCP spec. No per-resource-type scope split in v1 — Library §10.5 explicitly bans per-entry overrides for the same reason (cognitive cost outweighs benefit pre-PMF). |
| **Prompts** (parameterized templates) | Inherited from the tools the prompt invokes. No dedicated scope. | A prompt is a guided tool invocation; the tools it calls are themselves scope-gated. Adding a separate prompt scope would not produce a meaningful consent decision. |
| **Sampling** (server-initiated LLM completion) | Future. Add `yourapp:mcp:sampling` when MCP sampling ships in v1+. | Sampling is the one MCP capability that introduces a consent question RBAC cannot express: *"this server can spend your AI tokens on your behalf."* It does not reduce to a YourApp authority verb, so it gets its own protocol-axis scope when it lands. |
| **Roots** | No scope. | Client-side anchors; no server-side authority surface. |

### 1.8 Namespace decision

`yourapp:` (not `mcp:`). Rationale:

- Scopes describe **YourApp authority**, not the MCP protocol surface. They map 1:1 onto the existing RBAC vocabulary maintained in `PermissionMappingRegistry.AccessLevelInfo`.
- A `mcp:` namespace would suggest the scopes are about the protocol primitives (which they aren't, per §1.6) and would obscure the RBAC mapping.
- `yourapp:` is also the namespace the v3 MCP PRD already uses.
- The one exception is `yourapp:mcp:sampling` (future, §1.7) — the nested `:mcp:` segment signals "this is an MCP-spec-aligned scope, not a YourApp-authority scope."

### 1.9 RBAC dovetail and cognitive overload

Effective authority at any MCP call site:

```
RBAC.allows(user, resource, action)  AND  token.scopes.includes(action)
```

Scopes are a **cap**, never a grant. RBAC is the authoritative gate. This means:

- A user who grants `Author` to Claude Code, but whose RBAC role is `viewer` on a particular resource, cannot write that resource through Claude Code. RBAC denies.
- A user who grants `Viewer` to Claude Code, but whose RBAC role is `editor` everywhere, cannot write anything through Claude Code. Scope caps.

#### Three audiences, three anxiety vectors, three mitigations

| Audience | "What can my agent / tool actually do?" | Mitigation |
|---|---|---|
| **End user** | Did I grant deletion authority? | Bundle vocabulary mirrors RBAC vocabulary (Viewer / Reviewer / Curator / Author / Admin). Consent screen reads "Claude Code can act like an Author on your behalf — not an Admin." A per-user *Connected Agents* page surfaces last-action and resource-count per agent, not raw scopes. |
| **Team lead** | What can my team's agents touch? | Lead with the **MCP Activity feed** (v3 §5.6 / Foundation 2). "Agents in your team did N actions in the last 7 days, here's who and what." The permission set is a debugging tool; the activity feed is the primary lens. |
| **Tenant admin** | Audit MCP exposure tenant-wide. | Display bundles by default in the role-limit editor; expand for raw scopes. Admins reason about 5 bundles, not 6 platform scopes × N apps × bundle-customization permutations. |

#### Bundle ↔ RBAC mapping table is a first-class deliverable

Generate a **5×N grid** (Bundle × RBAC role → effective authority) from `PermissionMappingRegistry.AccessLevelInfo` and publish it in the MCP PRD. This grid answers ~80% of "what can the agent do for me?" questions across all three audiences. Generating it from `AccessLevelInfo` (rather than hand-maintaining) prevents drift between RBAC and OAuth scope semantics.

#### "Via Claude Code" must surface as a first-class UI chip

Activities emitted by MCP-driven actions carry MCP-entry-point metadata (v3 §7.1). The Activity-rendering UI must surface this metadata as a first-class chip ("via Claude Code"), not buried in JSON. Otherwise admins lose the ability to distinguish human-initiated from agent-initiated actions — a trust-signal regression vs. the web-only world.

### 1.10 Default consent request (when client doesn't specify)

When an MCP client registered via DCR doesn't explicitly request a scope set, the consent screen pre-selects **Author**.

Rationale (locked over a "Reviewer default" alternative):
- The expected install pattern is "AI assistant that works on the user's behalf," not "AI assistant that only researches." Author matches that expectation.
- A Reviewer default would force every user through a re-consent loop on first useful action (write, share, etc.). That friction is exactly what trains people to grant Admin preemptively on the next install — the over-grant pattern the elevation tier is meant to prevent.
- Author draws the right qualitative line: *"act as me"* vs. *"administer the tenant"* (Admin). The default sits at "act as me."
- RBAC remains the real per-resource gate. Author for a user whose RBAC role is `viewer` on a particular resource still equals view-only effective authority on that resource. The default doesn't widen authority; it just doesn't artificially narrow it below "work like me."

The default-defaults heuristic: **match the expected use case; require explicit choice for departures from it.** "Be conservative" is the wrong heuristic when "conservative" doesn't match what users are installing the tool to do.

---

## 2. Per-tenant token issuance under v1.6 Keycloak

### 2.1 Decision: per-tenant tokens, re-auth on tenant switch

The v3 PRD's per-tenant token model is retained for v1, on enterprise-safety grounds:

- A consultant working across multiple client tenants (acme.corp, contoso.com) should not be able to accidentally take an action in the wrong tenant because Claude Code auto-resolved tenant context from the session.
- The cost — switching tenants requires re-authentication — is bounded and acceptable. Most users work in one tenant most of the time. Multi-tenant consultants experience this as a minor extra step; users in single tenants experience zero friction in the cognitive sense (the picker still shows for explicit confirmation per §2.5, but with no choice to make).
- Cross-IdP linking (Keycloak PRD §11.4 first-broker-login-no-prompt auto-linking by email) means a single Keycloak `sub` may carry stale `microsoftTenantId` from a prior session. Per-tenant binding at issuance time eliminates the per-call risk surface this would otherwise create.

### 2.2 The mechanism problem

The v3 MCP PRD assumed the tenant picker would be Keycloak's Organizations feature. v1.6 of the Keycloak PRD **dropped Keycloak Organizations** (Invariant 8). The tenant picker now has no native home in Keycloak. Three implementation paths were considered.

### 2.3 Locked approach: path (iii) — Keycloak owns OAuth; YourApp web hosts the picker and consent UI

**Architectural intent:**
- Keycloak remains the OAuth authorization server from the MCP client's perspective (`auth.yourapp.com`). Same identity authority as the web client.
- The tenant picker and the bundle/consent screens are **regular YourApp web pages**, served from `prod.yourapp.com` (or `dev.yourapp.com`), using the existing Bootstrap + CDN component library and design system.
- A small custom Keycloak Authenticator SPI orchestrates a redirect: federated auth completes → 302 to YourApp web for tenant + consent → 302 back to Keycloak with a signed return token → Keycloak writes the claims and mints the OAuth token.

**Why (iii) over (i):** the picker and consent screens are *product UX surfaces* — iterated often, need rich data (tenant logo, role, last activity), need design polish, and naturally extend over time (Connected Agents UI, elevation flows, role-based scope limits). YourApp's web codebase is built for that. Keycloakify is not. Path (i)'s SPI would have to call YourApp's API anyway to fetch tenants, then render in a separate framework with a separate design system; path (iii) moves the render to where the data already lives and where the design system already exists.

**Why (iii) over (ii):** path (ii) would have YourApp implement its own OAuth 2.1 + DCR authorization server in .NET, becoming a second token issuer. That breaks v1.6 Keycloak's "YourApp is application-layer; Keycloak is the thin IdP broker" charter, fragments the identity surface (web client validates against Keycloak JWKS; MCP server would validate against YourApp JWKS), and introduces substantial new security-critical code (refresh rotation with reuse detection, PKCE, JWKS rotation, DCR per RFC 7591, MCP-spec error format). The benefits — YourApp controls token semantics, no Keycloak SPI — don't justify the cost when (iii) achieves the same UX outcome with a small SPI module.

#### 2.3.1 Keycloak realm structure for MCP

This is one of the two implementation-spec clarifications most often misread. There is **no fourth Keycloak client** dedicated to MCP. Instead:

| Concept | Realm-level artifact | Purpose |
|---|---|---|
| DCR enablement | **Client Registration Policy** named `mcp-dcr-policy` | Controls what MCP clients may register (allowed redirect URI patterns, default scopes, default Client Scope assignments, max token lifetimes, authentication flow override defaults). DCR itself is realm-level. |
| Per-install client identity | **Auto-generated `client_id`** issued by Keycloak on each DCR registration | One MCP client install = one Keycloak client. Claude Code on your laptop, Claude Code on a colleague's laptop, Codex CLI on your laptop, Gemini CLI on a tablet — each gets its own client_id and its own client_secret (or PKCE-only). |
| Shared MCP configuration | **Client Scope** named `mcp-default` | Default-scope assignment that every DCR'd MCP client inherits. Includes the `audience` protocol mapper (sets `aud=yourapp-mcp-api`), the scope-vocabulary client scopes, and the `tenant` / overridden `scope` mappers that read the session notes written by the SPI. |
| Authentication flow binding | `authenticationFlowBindingOverrides.browser = browser-mcp-tenant-pick` (set as a default by `mcp-dcr-policy`) | Every DCR'd MCP client is auto-bound to the new MCP-specific authentication flow (§2.3.2). The web client (`yourapp-{env}-web`) remains on `browser-federated-only`. No conditional branching inside a shared flow. |
| YourApp MCP server identity | **Resource server**, identified by audience `yourapp-mcp-api` | The MCP server is *not* a Keycloak client; it's a protected resource that validates `aud=yourapp-mcp-api` on every incoming token. Same pattern OAuth 2.1 uses to separate the authorization server from the resource server. |

The existing top-level Keycloak clients (`yourapp-{env}-web`, `yourapp-{env}-admin-api`) are unchanged. v0.2 of this document referred to `yourapp-{env}-mcp-server` as if it were a fourth client; that was a misleading framing and has been removed.

#### 2.3.2 Authentication flow: `browser-mcp-tenant-pick` (new)

A **new Keycloak authentication flow** named `browser-mcp-tenant-pick` is created as a duplicate of `browser-federated-only`, with the custom SPI Authenticator appended as the final step.

Why a new flow (not a modified `browser-federated-only`):

- Web users' auth flow stays untouched. The MCP picker step never runs for web sessions. No conditional branching inside a shared flow.
- The new flow auto-binds to DCR'd MCP clients via the `mcp-dcr-policy` Client Registration Policy — every registered MCP client gets `authenticationFlowBindingOverrides.browser = browser-mcp-tenant-pick` set as a registration default. No manual per-client step.
- Decouples iteration: future MCP flow changes (sampling consent, step-up auth for Admin elevation, future MCP-spec additions) extend the MCP flow without touching the web flow.

Cost: one additional Keycloak authentication flow to maintain (an extra page of admin UI config + IaC module). Acceptable for the clean separation.

#### 2.3.3 End-to-end flow

```
 1. MCP client (Claude Code) discovers YourApp MCP server.
 2. Client → OAuth /authorize at Keycloak (auth.yourapp.com). MCP client_id is the one it
    received from DCR registration; redirect_uri is one of the patterns allowed by
    mcp-dcr-policy; scope is what the client wants to request.
 3. Keycloak runs browser-mcp-tenant-pick flow (auto-bound per §2.3.2). Steps 3a-3c run
    in sequence:
    3a. Identity Provider Redirector → federated IdP (Google/Microsoft/...) → user auth
        completes → Keycloak establishes SSO session, user record fetched/created.
    3b. Custom Authenticator SPI ("tenant-pick-step") runs:
        - Reads user's sub from session.
        - HMAC-signs a small JWT (hereafter "picker-request token") containing:
            {
              jti, yourapp_sub, mcp_client_id, mcp_requested_scopes,
              redirect_state, nonce, exp(now+5min)
            }
        - 302s user's browser to:
            https://prod.yourapp.com/mcp/consent?token=<picker-request-token>
        - Authenticator step enters "waiting for callback" state.
 4. User's browser arrives at https://prod.yourapp.com/mcp/consent?token=<...>.
    YourApp web's standard auth middleware runs on this route (require authenticated).
    4a. No YourApp session cookie present (Keycloak SSO session ≠ YourApp web session
        cookie). Middleware initiates standard OIDC sign-in against Keycloak with
        prompt=none, preserving the picker-request token through OIDC state.
    4b. Keycloak sees the user has a fresh SSO session → silently returns an
        authorization code without any user interaction (typically ~100ms round-trip).
    4c. YourApp web exchanges code for token at /auth/callback, sets YourApp session
        cookie, redirects to:
            https://prod.yourapp.com/mcp/consent?token=<picker-request-token>
    4d. /mcp/consent now renders with a valid session — top bar shows user identity,
        app shell renders. The picker-request token validates against the HMAC handoff
        key.
 5. YourApp web runs the 3-step wizard (§2.5):
    Step 1 — Who & Where (client identity card + tenant card; always shown for
             confirmation per §2.5).
    Step 2 — What (5 bundle cards; Author default; expand-to-raw-scopes affordance).
    Step 3 — Review & Authorize (affirmative + negative list; summary).
 6. On [Authorize] in Step 3, YourApp backend:
    6a. Validates the picker-request token (HMAC, expiry, jti not consumed, user_sub
        matches the current session sub).
    6b. Validates the user's membership in the chosen tenant (RBAC).
    6c. HMAC-signs a "picker-result token" containing:
            {
              jti, picker_request_jti, chosen_tenant_id, granted_scopes[],
              user_sub_echo, nonce, exp(now+1min)
            }
    6d. 302s back to a callback URL handled by the Keycloak Realm Resource Provider:
            https://auth.yourapp.com/realms/yourapp-prod/mcp-picker-callback?
                picker_result=<picker-result-token>
 7. Keycloak SPI Realm Resource Provider receives the picker-result token:
    7a. Validates HMAC, expiry, jti not consumed.
    7b. Cross-checks: picker_request_jti matches the request that initiated the flow
        (anti-replay; ensures the result came from the same picker session).
    7c. Cross-checks: user_sub_echo matches the session's sub (anti-session-fixation).
    7d. Writes session notes:
            yourapp_tenant_id   = chosen_tenant_id
            yourapp_scopes       = granted_scopes (space-separated)
    7e. Resumes the suspended Authenticator step (§3b above) as SUCCESS.
 8. Keycloak finishes the auth flow normally:
    8a. Protocol Mappers on mcp-default Client Scope expose:
            yourapp_tenant_id  → `tenant` claim
            yourapp_scopes     → `scope` claim (overriding the requested scope set —
                                the user's actual choice wins)
            aud               → `yourapp-mcp-api`
    8b. Mints OAuth token with these claims.
    8c. 302s to MCP client's redirect URI with authorization code.
 9. MCP client exchanges code for access + refresh token at Keycloak's /token endpoint.
10. Subsequent MCP requests carry the token; MCP server validates against Keycloak
    JWKS, reads `tenant` claim, enforces `scope`, performs RBAC checks.
```

#### 2.3.4 Cross-system handoff token construction

Both tokens (picker-request and picker-result) are short-lived JWTs signed with a **symmetric key (HS256)** held by both the Keycloak SPI and the YourApp backend. Stored as a shared secret rotated quarterly (`yourapp-mcp-handoff-hmac-key-{env}` in GCP Secrets Manager, mirroring the Keycloak PRD §10.5 secrets convention).

**Why HMAC and not asymmetric:** both ends are first-party services owned by YourApp; symmetric is simpler, faster, and the operational story (one secret, rotated together) is cleaner than managing a key pair across systems.

**Why JWT:** standard format, easy to inspect during debugging, well-supported by both .NET and Java libraries, easy to extend with additional claims later.

**Replay protection:** every token carries a `nonce` and `jti`. The YourApp backend records consumed `jti`s for the picker-request side (5-min retention); the Keycloak SPI records consumed `jti`s for the picker-result side (1-min retention). A replay attempt fails validation.

**Tampering protection:** if the user (or a malicious browser extension) modifies the chosen tenant or scopes in the picker-result token, the HMAC fails. If the `user_sub_echo` claim is mismatched against the session sub, the SPI rejects.

**State-vs-claims separation:** the picker-request token carries the OAuth `redirect_state` value as one of its claims, so that YourApp web never sees `state` in the URL bar (avoids accidentally treating it as user-visible state). YourApp returns `redirect_state` to Keycloak inside the picker-result token; Keycloak then forwards it to the MCP client in the normal OAuth `state` callback param.

**Rotation pattern:** the handoff HMAC key supports two-key overlap (current + previous) so rotation completes without auth-flow downtime: the SPI and YourApp backend each accept either key for the overlap window (e.g., 24 hours), and after the window only the current key.

#### 2.3.5 What the Keycloak SPI module is, concretely

The SPI module — referred to throughout this document as "the path (iii) SPI" or "the Authenticator + RRP SPI" — has these characteristics:

- Roughly 150–250 lines of Java (or Kotlin) implementing the Keycloak SPI interfaces.
- Two interfaces implemented:
  1. **`Authenticator`** — the post-federation step in `browser-mcp-tenant-pick` that emits the picker-request token and 302s to YourApp web.
  2. **`RealmResourceProvider`** — the callback handler at `/realms/{realm}/mcp-picker-callback` that accepts the picker-result token and writes session notes.
- Three protocol mappers configured on the `mcp-default` Client Scope (not part of the SPI module proper, but installed alongside): `tenant` (from session note), `scope` override (from session note), and `audience` (`yourapp-mcp-api`).
- **No runtime HTTP calls from Keycloak to YourApp.** The picker flow goes through the user's browser end-to-end. The SPI does not need network access to YourApp; it only validates HMAC-signed tokens delivered via the user's browser. This decouples availability — a YourApp API outage does not break the SPI.

See §2.8 for explicit scope-of-this-SPI vs. parked Event Listener SPI.

#### 2.3.6 What the YourApp web side is, concretely

- A new sub-app at `prod.yourapp.com/mcp/consent` (path TBD, see §4 open items).
- Renders inside YourApp's standard authenticated app shell — top bar, workspace switcher, user menu, app launcher all visible. Per Q2 clarification: this session is established by the standard auth middleware via `prompt=none` silent OIDC against Keycloak (§2.3.3 step 4a-4c). No bespoke session-establishment path.
- Reuses existing Bootstrap shell, CDN components (FormDialog, **Stepper**, ribbon), workspace/user menu, dark-mode integration. Stepper component is the same primitive used in Strukture's Add Relationship Wizard.
- One new backend route (`POST /api/v1/mcp/consent/authorize`) that validates the picker-request token, validates user membership in the chosen tenant, and issues the picker-result token.
- One small HMAC handoff-key client used by that backend route. Same key is configured in the Keycloak SPI module.

### 2.4 Rejected alternatives

#### Path (i) — Custom Keycloak Authenticator with Keycloakify-themed picker

Considered and rejected. The SPI's Authenticator would call YourApp's Admin REST API at auth time to fetch tenants, then render a tenant picker page through a Keycloakify theme.

**Why rejected:**
- Picker UI fragments away from YourApp's design system into a Keycloakify theme codebase. Two codebases for similar consent surfaces.
- The consent screen (bundle selection, expand-to-raw-scopes, RBAC mapping grid) is iteration-heavy; Keycloakify iteration requires JAR rebuild + Docker rebuild + Keycloak restart vs. YourApp web's `npm run build` + Cloud Run deploy.
- Runtime coupling: the SPI makes an HTTP call to YourApp's API during the auth flow's critical path. If YourApp's API is degraded, auth fails. Path (iii) avoids this because the user's browser handles the cross-system traversal.
- Larger SPI surface (~800 lines vs ~200) — more code to maintain in a secondary language stack (Java/Kotlin) for the team.

Path (i) would still work as a fallback if path (iii)'s cross-redirect flow had to be abandoned (e.g., if SSO setups in some enterprise networks break the browser redirect chain in ways path (i) wouldn't). For v1 we accept that risk; if it materializes, path (i) is a clean fallback design.

#### Path (ii) — YourApp-hosted OAuth authorization server

Considered and rejected. YourApp would implement its own OAuth 2.1 + DCR authorization server in .NET; Keycloak demoted to "an IdP that YourApp federates to."

**Why rejected:**
- YourApp becomes a token issuer with its own JWKS, refresh rotation, DCR endpoint, revocation, and PKCE implementation — substantial new security-critical code that is exactly what mature SaaS providers use IdP brokers to avoid building.
- The identity surface fragments: the web client validates Keycloak-signed tokens; the MCP server would validate YourApp-signed tokens. Two issuers, two validation paths, two key rotation cadences.
- Breaks v1.6 Keycloak's explicit charter ("YourApp is application-layer; Keycloak is the thin IdP broker").
- The benefits (YourApp controls token semantics; no Keycloak SPI) don't justify the cost when path (iii) achieves equivalent UX with a small SPI module.

### 2.5 The 3-step consent wizard (YourApp-web side)

Hosted at `prod.yourapp.com/mcp/consent` (path TBD). Renders inside YourApp's standard authenticated app shell — top bar, workspace switcher, user menu, app launcher all visible. The YourApp web session cookie is established via the `prompt=none` silent OIDC round-trip described in §2.3.3 step 4 (not by hand-waving over the Keycloak SSO session).

Built on the **CDN Stepper component** (same primitive used in Strukture's Add Relationship Wizard). Three steps; cannot skip forward; back navigation always available.

#### Step 1 — Who & Where

Two cards on the page:

**Client identity card** (top, prominent):
- MCP client display name (from DCR registration metadata).
- Client URI / domain.
- Client logo (if registered; placeholder otherwise).
- **"Self-registered" badge** if the client was DCR'd (vs. pre-approved). Hover surface explaining what self-registration means.
- Redirect URI domain shown prominently next to the client name. The user must visually verify "this domain looks right."

**Tenant card:**
- Tenant logo, name, your role in this tenant, last activity timestamp, member count.
- **Always shown for explicit confirmation**, even for single-tenant users. Single-tenant users see one card with a "this is correct" affordance; multi-tenant users see a radio list of tenant cards.
- Explicit confirmation is the deliberate choice over auto-skip — it avoids the *"I didn't know I did that"* failure mode.

**Actions:** Primary [Continue]. Secondary [Cancel — Don't Connect].

#### Step 2 — What

Heading: *"What should {client name} be able to do for you in {tenant name}?"*

Five bundle cards stacked vertically: Viewer / Reviewer / Curator / Author / Admin. Each card shows:
- Bundle name + one-line description.
- 2–3 example actions ("Can read your work items," "Can comment on diagrams," "Cannot administer your tenant").
- RBAC mirror in small text ("Like the Editor role").

**Default selection: Author** (locked over Reviewer; see §1.10 for rationale).

**Expand affordance:** "Show advanced (individual scopes)" reveals the 6 raw atoms as checkboxes, with the active selection labelled "this is currently the Author bundle." Editing any checkbox flips the bundle label to "Custom — based on Author" (or whichever bundle was last selected).

**Admin elevation banner:** if the client's DCR registration explicitly requested Admin scope, a prominent warning banner appears above the cards: *"This app is requesting tenant administration access. Choose carefully — this allows changes to user roles, tenant settings, and audit configuration."*

**Actions:** Primary [Continue]. Secondary [Back].

#### Step 3 — Review & Authorize

Heading: *"Confirm: {client name} will be able to..."*

**Affirmative list** — what they CAN do under the chosen bundle. Generated from the Bundle ↔ RBAC mapping registry (see §1.9). Examples for Author:
- ✓ Read any resource you have access to
- ✓ Comment on resources you can comment on
- ✓ Create, edit, and delete resources you have edit access to
- ✓ Share resources you own with other users in this tenant
- ✓ Create cross-app links between resources

**Negative list** — what they CANNOT do. Crucial for trust; turns "I clicked through a consent screen" into "I knowingly granted Author, not Admin." Generated from the same Bundle ↔ RBAC mapping. Examples for Author:
- ✗ Administer this tenant (cannot manage users or roles)
- ✗ Change tenant-wide settings
- ✗ Access audit logs
- ✗ Act in any tenant other than {tenant name}

**Summary line:** *"Connecting {client name} to {tenant name} · Author bundle · until you disconnect."*

**Actions:** Primary [Authorize] (visually extra-prominent — e.g., larger size, distinct accent — when the chosen bundle is Admin). Secondary [Back] (returns to Step 2 preserving selection). Tertiary [Cancel — Don't Connect].

#### Negative-list generation strategy (sub-decision)

**Locked: generated from the Bundle ↔ RBAC mapping registry**, not hand-curated.

Rationale: hand-curated reads better but drifts as scopes and RBAC roles evolve. Generated from `PermissionMappingRegistry.AccessLevelInfo` (with the Bundle extension proposed in §1.9) means the affirmative/negative lists stay correct without editorial maintenance, at the cost of slightly less rhetorical polish. For consent UX the trust-of-correctness matters more than rhetorical polish.

A modest editorial layer is acceptable: each generated line can have a hand-written "friendly version" stored next to the scope definition, with the generator preferring the friendly version when available and falling back to a structural template ("Cannot {verb} {resource-type}s").

#### 2.5.5 Empty-membership state — user has no YourApp Organization memberships

When the user has just federated through Keycloak but has no membership in any YourApp Organization (a fresh sign-up via the federated IdP who has never been added to a tenant, or a user whose memberships were all revoked), the consent wizard cannot proceed past Step 1: there is no tenant to bind the token to. The YourApp backend detects this when validating the picker-request token and rendering the tenant card.

**Locked: option (a) "block with two-branch messaging,"** not (b) inline tenant onboarding or (c) personal pseudo-tenant.

**Why not (b) "self-service tenant creation embedded in the consent flow":** tenant onboarding has T&Cs, billing tier selection, role/seat assignment, tenant-name & domain configuration — heavyweight surfaces that don't belong in an OAuth consent dialog. Conflating the two flows makes both worse.

**Why not (c) "personal pseudo-tenant":** YourApp is B2B-shaped (Library §10's "Personal Library" is *per-tenant*, not a personal-tenant abstraction). Adding personal pseudo-tenants is a substantial product change; out of scope for MCP v1.

**Two-branch messaging,** based on whether the user's email domain matches a connected tenant directory binding (using the same `(idp, identifier)` resolution as Keycloak PRD §15):

**Case A — domain matches a connected tenant, but no membership yet:**

> Your domain ({acme.corp}) is connected to YourApp, but you haven't been added as a member yet. Please ask your administrator to invite you, then return here to connect {Claude Code}.

The page shows the tenant's display name + logo (read from the connected-tenant record), the tenant's admin contact if available, and a [Got it — close this window] action. No [Continue] available.

**Case B — no domain match, no pending invite:**

> You need a YourApp workspace to use {Claude Code} with YourApp.
>
> [Create a workspace at yourapp.com]   [Cancel — Don't Connect]

The [Create a workspace] CTA opens the normal sign-up / new-workspace flow in a new tab. After the user creates or joins a workspace, they restart the Claude Code connection from scratch (the consent flow is short-lived; re-running is the expected path).

This branching reuses YourApp's existing directory-binding work (Keycloak PRD §15) — the same `(idp, identifier)` tuple that resolves tenant context per session tells us whether the user's domain is known to a connected tenant they aren't a member of.

### 2.6 Connected Agents — disconnect / revoke UX

**Locked entry point:** top-level user menu → "Connected Agents".

Renders as a list under the user account surface, similar pattern to GitHub's "Authorized OAuth Apps" or Notion's "Connected Apps":
- Each row: client name + logo, tenant scope ("in {tenant name}"), bundle granted, last activity, [Disconnect] button.
- Disconnect action revokes the token via Keycloak's Admin REST API (session-level revocation per Keycloak PRD §8.7).
- Disconnect triggers an Activity emission (`AgentConnectionRevoked`) for audit.

Per-tenant: a Connected Agents view is also available in tenant admin surfaces (audits all connected agents across the tenant; tenant admin can disconnect on a user's behalf for security/offboarding scenarios).

### 2.7 Trust-signal hardening

The consent wizard depends on the user being able to verify they're on a legitimate YourApp consent surface (not a phishing site mirroring it) and that the client requesting access is the one they think it is.

**Surface-level trust signals:**
- Consent page renders inside YourApp's authenticated app shell with top bar, workspace switcher, user menu visible. *"I am signed in to yourapp.com as me, viewing a consent page within yourapp.com"* must be verifiable at a glance, before the user reads the consent text.
- The consent page URL is on `prod.yourapp.com` (or `dev.yourapp.com`), not a separate auth-only domain.

**Client-identity trust signals:**
- DCR client name displayed in a clearly bounded card, separated from the consent prompt.
- **"Self-registered" badge** for DCR clients until/unless they go through a publisher-verification process (analogous to Microsoft Entra publisher verification, Keycloak PRD §10.7). v1 ships the badge; a verification process is a v1+ track.
- Redirect URI domain displayed prominently next to the client name. The user is asked to confirm "this domain matches the app you're connecting." A redirect URI on a suspicious domain is the strongest signal of a phishing client.
- Future hardening: a tenant admin policy to require client verification for any DCR client requesting Author or higher; Reviewer/Viewer can be granted to unverified DCR clients but Author+ requires the verification badge.

**Cross-system handoff trust signals:**
- HMAC-signed tokens (§2.3.4) prevent tampering with chosen tenant or granted scopes.
- The `user_sub_echo` claim cross-check at the picker-result side prevents a different signed-in user from completing consent for the original authenticated user (defense in depth against session-fixation patterns).

### 2.8 Keycloak SPI modules — in scope vs. parked

The brainstorm pulls one Keycloak SPI module into v1 scope (the Authenticator + Realm Resource Provider that implements the path (iii) handoff). A different, previously parked SPI module (Event Listener for the platform event bus) remains parked. To prevent conflation:

| SPI module | Status | Purpose | Drives |
|---|---|---|---|
| **Custom `Authenticator` + `RealmResourceProvider`** (the path (iii) handoff) | **In scope for MCP v1 launch.** Implementation begins as part of the MCP PRD v4 / Keycloak PRD v1.7 work. | Post-federation step that orchestrates the 302 to YourApp web (`/mcp/consent`); callback handler at `/realms/{realm}/mcp-picker-callback` that validates the HMAC-signed picker-result token and writes session notes (`yourapp_tenant_id`, `yourapp_scopes`) read by protocol mappers. | The per-tenant MCP token issuance. Required for any MCP traffic to work. |
| **Custom Event Listener SPI** | **Parked.** Tracked in Keycloak PRD §15 Future Work; **not** part of MCP v1. | Bridge Keycloak events (login success/failure, IdP federation events, user CRUD, session termination, Admin API operations) into the platform event bus → Postgres transactional outbox → Audit Trail. | The general Keycloak audit pipeline. Independent of MCP. |

**Shared infrastructure:** both SPI modules, if/when both exist, deploy as JARs in the Keycloak Docker image (alongside the Keycloakify theme JAR). They share the build pipeline and the deployment cadence. **But they solve different problems, can ship independently, and must not be conflated in scope.**

**Risk if conflated:** scoping the Event Listener into MCP v1 inflates v1 scope by months and entangles MCP launch with the audit-pipeline track. Conversely, scoping the Authenticator+RRP into Future Work would block MCP v1 entirely. Treat each on its own schedule.

---

## 3. Cross-spec change requirements

When this design is absorbed into the formal PRDs:

### 3.1 Changes to MCP PRD (v3 → v4)

- **§2.5 (OAuth scope vocabulary):** replace coarse `read`/`write`/`admin` + app-level subsets with the 6-atom vocabulary and 5-bundle ladder from §1 of this doc. Add §1.5's design rule as an authoritative subsection.
- **§2.3 (Token validation):** remove the requirement for an `organization` claim; replace with the `tenant` claim (sourced from the picker flow per §2.3 of this doc). Tenant context is resolved against YourApp's directory-binding model (Keycloak PRD §15) for any per-call authorization. Audience to validate: `yourapp-mcp-api` (per §2.3.1).
- **§2.4 (Tenant context):** rewrite to describe the per-tenant-token model under v1.6 Keycloak; remove references to Keycloak Organizations; add the path (iii) flow as the locked mechanism; cite §2.5 of this doc for the consent wizard.
- **New §2.5a (Default consent):** add the §1.10 default-bundle rationale. v3's existing "default consent requests `yourapp:read` + `yourapp:write`, no admin" prose becomes "default consent requests the Author bundle, which raw-scopes to `read comment write share`."
- **New §2.5b (Empty-membership handling):** specify the two-branch messaging from §2.5.5 of this doc; reference the YourApp directory-binding model for domain-based context detection.
- **§5.4 (Required scopes per role):** tenant admins configure role limits as a single "maximum bundle" picker (Viewer / Reviewer / Curator / Author / Admin), with expand-to-raw-scopes for custom configurations.
- **§7.1, §7.2 (Audit):** add the "via Claude Code" first-class UI chip requirement (§1.9 of this doc).
- **New §10 or §5.x (Connected Agents UI):** specify the user-menu entry point and per-user list (§2.6 of this doc), plus tenant-admin view for org-wide auditing.

### 3.2 Changes to Keycloak PRD (v1.6 → v1.7)

- **New §5.x — MCP integration realm structure:** introduce `mcp-dcr-policy` (Client Registration Policy), `mcp-default` (Client Scope inherited by DCR'd MCP clients), and `yourapp-mcp-api` (resource server audience). **Explicitly note** that no `yourapp-{env}-mcp-server` client exists; each MCP install gets its own DCR-generated `client_id`.
- **New §6.x — `browser-mcp-tenant-pick` authentication flow:** a new flow duplicated from `browser-federated-only` with the SPI Authenticator step appended. Auto-bound to DCR'd MCP clients via `mcp-dcr-policy` defaults. Web users continue on `browser-federated-only` unchanged.
- **New §6.y — Authenticator + Realm Resource Provider SPI (path iii handoff):** specifies the Authenticator interface implementation, the Realm Resource Provider for the picker-result callback, the three protocol mappers (`tenant`, `scope` override, audience `yourapp-mcp-api`), and the HMAC handoff key management.
- **§10.5 secrets table:** add `yourapp-mcp-handoff-hmac-key-{env}`. (No `yourapp-keycloak-mcp-client-secret-{env}` — DCR'd clients have their own per-install secrets, not a shared one.)
- **§10.8 naming table:** add MCP-related rows — `mcp-dcr-policy`, `mcp-default`, `yourapp-mcp-api`, `browser-mcp-tenant-pick`, `mcp-handoff-hmac-key`, picker-flow URLs.
- **§11.x runbook:** setup steps for the DCR policy, the `mcp-default` client scope and its protocol mappers, the new auth flow, and the SPI JAR (baked into the Keycloak Docker image alongside the Keycloakify theme JAR per §11.15 Dockerfile).
- **§13 OpenTofu:** add `yourapp-realm-mcp/` module covering DCR policy + client scope + auth flow + protocol mappers (the SPI JAR is image-baked, not Tofu-managed).
- **§15 (Future Work):**
  - Add a sentence noting that the `tenant` claim issued by the MCP flow uses the same directory-binding identifier the future post-PMF model will adopt — so the polymorphic schema migration doesn't break MCP tokens.
  - **Explicitly preserve** the parked Event Listener SPI as Future Work, with a note that the path (iii) Authenticator + RRP SPI is *not* the same thing — they share infrastructure (Docker image, build pipeline) but solve different problems. See §2.8 of this doc.

### 3.3 Changes to Library PRD

None. Library §10 already specifies the Curate role pattern this design lifts to the platform-MCP layer.

### 3.4 Changes to YourApp web

- New sub-app at `prod.yourapp.com/mcp/consent` (or similar) hosting the 3-step consent wizard per §2.5 of this doc. Standard authenticated route; session established via `prompt=none` silent OIDC by the existing OIDC middleware (no bespoke auth path).
- New user-menu entry "Connected Agents" + corresponding page per §2.6 of this doc.
- New tenant-admin view "MCP Connections" listing all connected agents tenant-wide.
- Extension to `PermissionMappingRegistry.AccessLevelInfo` to surface the Bundle ↔ RBAC mapping grid for §1.9 / §2.5 consumption.
- New backend route `POST /api/v1/mcp/consent/authorize` that validates the picker-request token, validates tenant membership, and issues the picker-result token. Reuses the HMAC handoff key from `yourapp-mcp-handoff-hmac-key-{env}`.
- New domain-context detection helper that, given a federated user's email domain, returns whether it matches a connected tenant directory binding (drives the §2.5.5 Case A / Case B branching).

---

## 4. Open items for v0.4

- [ ] Specify the exact `tenant` claim shape (YourApp Organization UUID vs. slug vs. directory-binding ID per Keycloak PRD §15). Lean: directory-binding ID once §15 lands; UUID for the interim.
- [ ] Specify the DCR-time client metadata that determines which scope bundles a registering MCP client may request as default. Lean: trust the client's requested scopes but cap them at Author by default; require explicit user elevation for Admin regardless of client request.
- [ ] Decide the exact URL path for the consent wizard (`/mcp/consent` vs `/mcp/authorize` vs `/oauth/consent`). Lean: `/mcp/consent`.
- [ ] Decide the handoff key rotation cadence (quarterly proposed in §2.3.4) and confirm the two-key overlap window length.
- [ ] DCR client verification track — when and how unverified DCR clients are promoted to verified (Admin scope availability gate). v1 ships the "Self-registered" badge; the verification process is v1+.
- [ ] Editorial layer for the negative list — should each scope carry a hand-written "friendly version" string alongside its structural definition? If so, where does it live (RBAC registry, scope manifest, both)?
- [ ] Concrete tool catalog draft for v1 (per app, with `requiredScope` annotations) — separate deliverable; not a brainstorm artifact.
- [ ] Confirm the picker-callback URL pattern on Keycloak's side (`/realms/{realm}/mcp-picker-callback` proposed in §2.3.3) — needs cross-check against Keycloak's realm resource provider URL conventions.

### Resolved in v0.3
- ✅ MCP integration's identity in Keycloak (Q1) — corrected to DCR policy + client scope + audience, no `yourapp-{env}-mcp-server` client.
- ✅ YourApp web session establishment at `/mcp/consent` (Q2) — `prompt=none` silent OIDC.
- ✅ Which Keycloak auth flow MCP uses (Q3) — new `browser-mcp-tenant-pick` flow, auto-bound via DCR policy.
- ✅ First-time users with zero tenant memberships (Q4) — block with two-branch messaging; reuses directory-binding context detection.
- ✅ Authenticator+RRP SPI vs. parked Event Listener SPI (Q5) — explicit §2.8.

---

## 5. References

- `specs/infra/keycloak.prd.md` (v1.6) — IdP broker architecture, directory-binding tenancy model (§15), no Keycloak Organizations (Invariant 8).
- `specs/mcp/layer-1-mcp-server-v3.md` — current MCP PRD that this design supersedes in scopes / consent / tenant-token sections.
- `specs/library.prd.md` (§10 Permissions, §10.3 "Curate is the agent role") — canonical specification of the agent-safe long-lived role pattern.
- MCP Authorization Specification — https://modelcontextprotocol.io/specification/basic/authorization
- OAuth 2.0 Dynamic Client Registration (RFC 7591).
- OAuth 2.0 Authorization Server Metadata (RFC 8414).
- OAuth 2.0 Protected Resource Metadata (RFC 9728).
- YourApp `PermissionMappingRegistry.AccessLevelInfo` — single source of truth for RBAC access-level metadata; intended host for Bundle ↔ RBAC mapping.
- YourApp CDN Stepper component — `https://static.yourapp.com/docs/components/stepper/README.md` (used in Strukture's Add Relationship Wizard; reused for the MCP consent wizard per §2.5).
- Keycloak Custom Authenticator SPI — https://www.keycloak.org/docs/latest/server_development/#_auth_spi
- Keycloak Realm Resource Provider SPI — https://www.keycloak.org/docs/latest/server_development/#_realm_resource
- Keycloak Client Registration (DCR + Policies) — https://www.keycloak.org/docs/latest/securing_apps/#_client_registration
- Keycloak Authentication Flows — https://www.keycloak.org/docs/latest/server_admin/#_authentication-flows

---

*End of v0.3. v0.4 will land once the open items in §4 are resolved — likely after auth migration from Auth0 → Keycloak completes and the v1.7 Keycloak PRD update is drafted.*
