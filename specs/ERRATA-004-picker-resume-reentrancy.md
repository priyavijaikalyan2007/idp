# Errata 004 — The tenant-picker authenticator must be re-entrant on resume

**Date:** 2026-07-07
**Status:** Root cause confirmed in production (redirect loop); SPI-side fix applied + tested. **No app-side change.**
**Applies to:** `KEYCLOAK_MCP_SPI_DESIGN.md` (§5.1, §5.3).
**Companion to:** ERRATA-003 (picker-result correlation echo). This is its *sibling*: ERRATA-003's fix is what let the flow get far enough to expose this one.

---

## Why this errata

With ERRATA-003 in place (the app now echoes `kc_client_id` / `kc_tab_id` / `auth_session_id`), the `mcp-picker-callback` endpoint stopped returning HTTP 400 and started **resuming the flow** — and immediately exposed an infinite redirect loop between `/mcp/consent` and Keycloak.

The captured chain (HAR) is unambiguous:

1. `POST /api/v1/mcp/consent/authorize` → 200 — app builds the picker-**result** and navigates the browser to the callback.
2. `GET /realms/{realm}/mcp-picker-callback?picker_result=…` → **303** — callback validates the result, writes the tenant/scope session notes, and redirects to `getLastExecutionUrl` (`/login-actions/authenticate?execution=…`). **This is the fix from ERRATA-003 working.**
3. `GET /login-actions/authenticate?execution=…` → **303** → `/mcp/consent?token=<FRESH picker-REQUEST>`.
4. `GET /mcp/consent?token=…` → 200 — wizard renders again → user submits → back to step 1 → **loop**.

**Root cause:** Keycloak resumes a *challenged* execution by re-invoking the authenticator's **`authenticate()`** (NOT `action()`), because the resume rides a redirect to the last-execution URL, not a form POST to the action URL. `McpTenantPickerAuthenticator.authenticate()` was not re-entrant: for an MCP client with an authenticated user it *unconditionally* built a fresh picker-request and re-challenged. It never checked whether the callback had already recorded the consent. So every resume issued a new picker-request → 303 to `/mcp/consent` → loop, and the flow never advanced to token issuance.

The design (§5.3) even *stated* the intent — "Keycloak's flow engine re-enters the CHALLENGED authenticator execution and finishes the flow" — but the implementation had no resume guard to *finish* it.

---

## The decision (what's true now)

1. **The tenant-picker authenticator is a suspend/resume step and MUST be re-entrant.** Its first action in `authenticate()` is a resume guard: if the out-of-band consent has already completed, finish the step (`context.success()`) instead of re-challenging.

2. **The completion signal is an explicit auth-session note**, `yourapp.mcp.picker.completed = "true"`, written by the callback (`McpPickerCallbackResourceProvider`) once it has validated the picker-result and recorded the consent. The authenticator reads it via `authSession.getAuthNote(...)`.
   - **Why an explicit marker, not "is `yourapp_tenant_id` set?"** The validator deserializes the picker-result via Jackson (`readJsonContent`), which bypasses the builder's `requireString`, so a signed-but-malformed result could carry a null tenant and still loop. A dedicated marker is correct-by-construction regardless of tenant nullability, and self-documenting.
   - The key is a single shared constant (`McpTenantPickerAuthenticator.AUTH_NOTE_PICKER_COMPLETED`); the callback references it, so writer and reader cannot drift.

3. **No resume re-architecture.** We did NOT move the return path onto the authenticator's `action()` URL / `session_code` (the alternative considered in ERRATA-003). The callback-resource + last-execution-URL resume is retained; it only needed the missing re-entrancy guard.

4. **No app-side change.** The app's redirect target, claim set, and echo are all correct. This errata is entirely SPI-side.

---

## Changes by document

### `KEYCLOAK_MCP_SPI_DESIGN.md`
- **§5.1 (tenant-picker authenticator)** — document the resume guard as the FIRST step of `authenticate()`, and the general rule that a challenge-based authenticator suspending to external UI must be re-entrant (Keycloak resumes via `authenticate()`, not `action()`).
- **§5.3 (callback resume)** — the callback also sets the `yourapp.mcp.picker.completed` auth note; the resumed `authenticate()` reads it and finishes.

### SPI code (applied)
- `McpTenantPickerAuthenticator` — new public constant `AUTH_NOTE_PICKER_COMPLETED`; resume guard at the top of `authenticate()`. 2 new unit tests (finishes-without-challenge with the note; still-challenges without it).
- `McpPickerCallbackResourceProvider` — `writeSessionNotes` also sets the completion auth note. 1 new unit test asserts it.

---

## One-line summary

The `/mcp/consent` ⇄ Keycloak loop is a **missing re-entrancy guard**, not a callback bug: Keycloak resumes the suspended step via `authenticate()`, so the authenticator must detect the callback-recorded completion (auth note `yourapp.mcp.picker.completed`) and finish the step instead of issuing a fresh picker-request. The loop was *evidence that ERRATA-003 works* — it got far enough to resume.
