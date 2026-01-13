# Server Provider Authentication (Advanced)

This page summarizes the official *Server Provider Authentication Guide*.

## When you need this

For hosting providers or server networks that want **automatic server authentication for 100+ servers**.

Without a provider entitlement, the official docs mention a default limit of **100 concurrent server sessions** per game license.

**Note**: When valid `HYTALE_SERVER_SESSION_TOKEN` and `HYTALE_SERVER_IDENTITY_TOKEN` are provided, the server skips the `/auth login device` flow entirely and authenticates automatically at startup.

## Prerequisites

The guide states that game server providers must contact Hytale Support and apply as a Game Server Provider.

Information requested includes:

- Hytale account (email or UUID)
- domain match between account email domain and store domain
- company registration proof
- website proof
- abuse/technical/administrative contacts (abuse contact with 24h SLA)

Upon approval, an account is entitled with:

- `sessions.unlimited_servers`
- `game.base` ownership

## High-level flow (from official TL;DR)

- obtain OAuth `refresh_token` once using Device Code Flow
- retrieve profiles: `GET /my-account/get-profiles`
- create server session: `POST /game-session/new` to obtain:
  - `sessionToken`
  - `identityToken`
- start each server instance with:

```text
java -jar HytaleServer.jar \
  --session-token "<sessionToken>" \
  --identity-token "<identityToken>"
```

The guide also mentions environment variables:

- `HYTALE_SERVER_SESSION_TOKEN`
- `HYTALE_SERVER_IDENTITY_TOKEN`

## Token lifecycle

The guide lists:

- OAuth access token: 1 hour
- OAuth refresh token: 30 days
- Game session: 1 hour

It notes servers auto-refresh sessions ~5 minutes before expiry and fall back to OAuth refresh if session refresh fails.

## API reference (as documented)

- Create session:
  - `POST /game-session/new` (host: `sessions.hytale.com`)
- Refresh session:
  - `POST /game-session/refresh` (host: `sessions.hytale.com`)
- Terminate session:
  - `DELETE /game-session` (host: `sessions.hytale.com`)
- Refresh OAuth token:
  - `POST https://oauth.accounts.hytale.com/oauth2/token`

## Error handling highlights

Common HTTP errors listed:

- `400` invalid request
- `401` unauthorized
- `403` forbidden (e.g. missing entitlement / session limit)
- `404` not found (invalid profile UUID, etc.)

Token validation failure example:

```text
Token validation failed. Server starting unauthenticated.
Use /auth login to authenticate.
```

## JWKS

Servers validate player JWTs using public keys from:

- `GET /.well-known/jwks.json` (host: `sessions.hytale.com`)
