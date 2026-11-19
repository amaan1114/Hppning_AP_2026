-- =============================================================================
-- dbms/04_queries.sql  —  Hppning
-- Every SQL query the app issues (PostgreSQL, via Drizzle ORM), each marked
-- -- READ or -- WRITE. $1, $2, ... are bound parameters.
--
-- Source of truth:
--   apps/api/src/modules/auth/auth.repo.js
--   apps/api/src/modules/events/event.repo.js
--   apps/api/src/modules/registrations/registration.repo.js
--
-- Schema (apps/api/drizzle/*.sql):
--   users(id, name, email UNIQUE, password, is_verified)
--   events(id, user_id -> users.id  [the event ADMIN], name, description,
--          is_active, location, date, time, created_at, updated_at)
--   registrations(id, user_id -> users.id, event_id -> events.id ON DELETE CASCADE,
--          registered_at, UNIQUE(user_id, event_id))
--
-- Sections 1-3 are the queries exactly as the repo layer runs them.
-- Section 4 are JOIN versions that collapse the service layer's
-- "fetch event, check it, then fetch more" round-trips into single statements.
-- =============================================================================


-- =============================================================================
-- 1. AUTH  (auth.repo.js)
-- =============================================================================

-- Q1.1  getUserByEmail — sign-in, sign-up duplicate check, verify-email
-- READ
SELECT id, name, email, password, is_verified
FROM   users
WHERE  email = $1
LIMIT  1;

-- Q1.2  getUserById — GET /auth/me, token refresh
-- READ
SELECT id, name, email, password, is_verified
FROM   users
WHERE  id = $1
LIMIT  1;

-- Q1.3  createUser — POST /auth/signup  (is_verified defaults to false)
-- WRITE
INSERT INTO users (name, email, password)
VALUES ($1, $2, $3)
RETURNING id, name, email, password, is_verified;

-- Q1.4  setUserVerified — POST /auth/verify-email
-- WRITE
UPDATE users
SET    is_verified = true
WHERE  email = $1
RETURNING id, name, email, password, is_verified;


-- =============================================================================
-- 2. EVENTS  (event.repo.js)
-- =============================================================================

-- Q2.1  getEvents — GET /events  (list all events)
-- READ
SELECT id, user_id, name, description, is_active, location, date, time,
       created_at, updated_at
FROM   events;

-- Q2.2  getEventById — GET /events/:id; also used as an existence/ownership
--       pre-check by registration + event update/delete services
-- READ
SELECT id, user_id, name, description, is_active, location, date, time,
       created_at, updated_at
FROM   events
WHERE  id = $1
LIMIT  1;

-- Q2.3  createEvent — POST /events  (user_id = authenticated admin)
-- WRITE
INSERT INTO events (user_id, name, description, location, date, time, is_active)
VALUES ($1, $2, $3, $4, $5, $6, COALESCE($7, true))
RETURNING id, user_id, name, description, is_active, location, date, time,
          created_at, updated_at;

-- Q2.4  updateEvent — PATCH/PUT /events/:id  (only the owning admin matches;
--       the SET list contains only the fields the client sent, shown in full here)
-- WRITE
UPDATE events
SET    name        = COALESCE($3, name),
       description = COALESCE($4, description),
       location    = COALESCE($5, location),
       date        = COALESCE($6, date),
       time        = COALESCE($7, time),
       is_active   = COALESCE($8, is_active)
       -- NOTE: updated_at has no trigger and the app does not set it today.
WHERE  id = $1
  AND  user_id = $2
RETURNING id, user_id, name, description, is_active, location, date, time,
          created_at, updated_at;

-- Q2.5  deleteEvent — DELETE /events/:id  (only the owning admin matches;
--       registrations rows are removed by ON DELETE CASCADE)
-- WRITE
DELETE FROM events
WHERE  id = $1
  AND  user_id = $2
RETURNING id, user_id, name, description, is_active, location, date, time,
          created_at, updated_at;


-- =============================================================================
-- 3. REGISTRATIONS  (registration.repo.js)
-- =============================================================================

-- Q3.1  createRegistration — POST /registrations/:eventId
--       Duplicate (user_id, event_id) is silently skipped; zero rows returned
--       means "already registered" (HTTP 409).
-- WRITE
INSERT INTO registrations (user_id, event_id)
VALUES ($1, $2)
ON CONFLICT DO NOTHING
RETURNING id, user_id, event_id, registered_at;

-- Q3.2  deleteRegistration — DELETE /registrations/:eventId  (unregister)
-- WRITE
DELETE FROM registrations
WHERE  user_id  = $1
  AND  event_id = $2
RETURNING id, user_id, event_id, registered_at;

-- Q3.3  getRegistrationsByUser — GET /registrations/me
-- READ
SELECT id, user_id, event_id, registered_at
FROM   registrations
WHERE  user_id = $1;

-- Q3.4  getRegistrationsByEvent — GET /registrations/event/:eventId
--       (attendee list; JOIN registrations -> users)
-- READ
SELECT r.id,
       u.id            AS user_id,
       u.name,
       u.email,
       r.registered_at
FROM   registrations r
INNER JOIN users u ON u.id = r.user_id
WHERE  r.event_id = $1;


-- =============================================================================
-- 4. JOIN VERSIONS
--    Single-statement equivalents of multi-step service logic. These are the
--    queries to prefer going forward; they return the same data in one trip.
-- =============================================================================

-- Q4.1  Attendee list WITH admin authorization in one query
--       Replaces: Q2.2 (fetch event, compare event.adminId) + Q3.4.
--       Zero rows => event missing OR caller is not its admin (service then
--       distinguishes 404/403 with Q2.2 only on the empty case).
-- READ
SELECT r.id,
       u.id            AS user_id,
       u.name,
       u.email,
       r.registered_at
FROM   events e
INNER JOIN registrations r ON r.event_id = e.id
INNER JOIN users         u ON u.id       = r.user_id
WHERE  e.id      = $1     -- event id
  AND  e.user_id = $2     -- authenticated user must be the admin
ORDER  BY r.registered_at;

-- Q4.2  "My registrations" with event details (what the registrations page shows)
--       Replaces: Q3.3 + one Q2.2 per row (N+1).
-- READ
SELECT r.id            AS registration_id,
       r.registered_at,
       e.id            AS event_id,
       e.name,
       e.description,
       e.location,
       e.date,
       e.time,
       e.is_active,
       a.name          AS admin_name
FROM   registrations r
INNER JOIN events e ON e.id = r.event_id
INNER JOIN users  a ON a.id = e.user_id
WHERE  r.user_id = $1
ORDER  BY e.date, e.time;

-- Q4.3  Event list with admin name and registration count
--       Replaces: Q2.1 (+ per-event admin and count lookups).
--       LEFT JOIN keeps events that have zero registrations.
-- READ
SELECT e.id,
       e.name,
       e.description,
       e.location,
       e.date,
       e.time,
       e.is_active,
       e.created_at,
       e.updated_at,
       a.id            AS admin_id,
       a.name          AS admin_name,
       COUNT(r.id)     AS registration_count
FROM   events e
INNER JOIN users a        ON a.id = e.user_id
LEFT  JOIN registrations r ON r.event_id = e.id
GROUP  BY e.id, a.id
ORDER  BY e.date, e.time;

-- Q4.4  Event detail for a signed-in viewer: admin, count, and whether the
--       viewer is already registered (drives the Register / Unregister button).
-- READ
SELECT e.id,
       e.name,
       e.description,
       e.location,
       e.date,
       e.time,
       e.is_active,
       a.id            AS admin_id,
       a.name          AS admin_name,
       (SELECT COUNT(*) FROM registrations rc WHERE rc.event_id = e.id) AS registration_count,
       EXISTS (
         SELECT 1 FROM registrations rm
         WHERE  rm.event_id = e.id AND rm.user_id = $2
       )               AS is_registered
FROM   events e
INNER JOIN users a ON a.id = e.user_id
WHERE  e.id = $1;

-- Q4.5  Register only if the event exists AND is active — one atomic statement
--       Replaces: Q2.2 (check exists / is_active) + Q3.1. Zero rows => event
--       missing/inactive, or already registered (service re-checks Q2.2 to tell
--       404 / 400 / 409 apart).
-- WRITE
INSERT INTO registrations (user_id, event_id)
SELECT $1, e.id
FROM   events e
WHERE  e.id = $2
  AND  e.is_active = true
ON CONFLICT DO NOTHING
RETURNING id, user_id, event_id, registered_at;

-- Q4.6  Events created by an admin, with attendee counts (admin dashboard)
-- READ
SELECT e.id,
       e.name,
       e.date,
       e.time,
       e.is_active,
       COUNT(r.id) AS registration_count
FROM   events e
LEFT  JOIN registrations r ON r.event_id = e.id
WHERE  e.user_id = $1
GROUP  BY e.id
ORDER  BY e.date, e.time;
