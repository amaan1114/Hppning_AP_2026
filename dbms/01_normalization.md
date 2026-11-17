# Normalization (1NF → 2NF → 3NF)

This document takes the project's tables through First, Second and Third Normal Form.

## Schema under review

```sql
users         (id PK, name, email UNIQUE, password, is_verified)
events        (id PK, user_id FK→users, name, description, is_active, location, date, time, created_at, updated_at)
registrations (id PK, user_id FK→users, event_id FK→events ON DELETE CASCADE, registered_at,
               UNIQUE(user_id, event_id))
```

Relationships:
- One user **organizes** many events (`events.user_id`).
- Users and events are **many-to-many** through `registrations` (a user registers for many events; an event has many registrants).

---

## Step 0 – Unnormalized form (UNF)

Before designing separate tables, imagine everything kept in one sheet:

| user_id | user_name | email | password | is_verified | events_organized | events_registered |
|---|---|---|---|---|---|---|
| 1 | Asha | asha@x.com | ... | true | "Hackathon, Workshop" | "Quiz, Meetup" |
| 2 | Ravi | ravi@x.com | ... | false | "Quiz" | "Hackathon" |

Problems: repeating groups and multi-valued cells (`events_organized`, `events_registered`), so nothing can be queried, constrained or updated cleanly.

---

## First Normal Form (1NF)

**Rules:** every column holds a single atomic value, no repeating groups or arrays, every row is uniquely identifiable by a primary key.

**Applying it:**
- Multi-valued `events_organized` / `events_registered` cells are split into rows in their own tables, so one row = one fact.
- Every table has a primary key: `users.id`, `events.id`, `registrations.id`.
- All columns are atomic: `date` and `time` are stored as separate `date` / `time` types (not a free-text "12 Nov, 5pm"), `email` is one value, `name` is one value.

**Result (1NF):**

```
users(id, name, email, password, is_verified)
events(id, user_id, name, description, is_active, location, date, time, created_at, updated_at)
registrations(id, user_id, event_id, registered_at)
```

Schema satisfies 1NF: no arrays, no repeating columns such as `event1, event2, …`, and each row is keyed.

---

## Second Normal Form (2NF)

**Rules:** must be in 1NF, and every non-key attribute must depend on the **whole** primary key (no partial dependency). This only matters when a table has a **composite** key.

**Applying it:**

The natural key of `registrations` is the composite `(user_id, event_id)`. Suppose we had stored extra details in it:

```
registrations(user_id, event_id, user_name, event_name, event_date, registered_at)
```

- `user_name` depends only on `user_id` → partial dependency 
- `event_name`, `event_date` depend only on `event_id` → partial dependency 
- Only `registered_at` depends on the full `(user_id, event_id)` 

Fix: move user attributes to `users`, event attributes to `events`, and keep only what depends on the full key in `registrations`.

**In the actual schema:**
- `registrations` keeps only `user_id`, `event_id`, `registered_at`. `registered_at` depends on the full pair (when *this user* registered for *this event*).
- The composite natural key is enforced by `UNIQUE(user_id, event_id)` (constraint `registrations_user_event_unique`), and a surrogate key `id` is used as the primary key. With a single-column PK, partial dependency cannot occur.
- `users` and `events` have single-column PKs (`id`), so they are in 2NF automatically.

**Result (2NF):** unchanged from the schema, with no user or event details duplicated in `registrations`.

---

## Third Normal Form (3NF)

**Rules:** must be in 2NF, and no non-key attribute may depend on another non-key attribute (no transitive dependency). Every non-key attribute depends on "the key, the whole key, and nothing but the key".

**Checking each table:**

### `users`
Functional dependencies:
- `id → name, email, password, is_verified`
- `email → id` (candidate key, since `email` is UNIQUE)

No non-key column determines another non-key column. `is_verified` is a flag about the user, not derived from anything else. 3NF

### `events`
Functional dependencies:
- `id → user_id, name, description, is_active, location, date, time, created_at, updated_at`

A violation would exist if organizer details were stored here:

```
events(id, user_id, organizer_name, organizer_email, ...)   -- 
-- id → user_id → organizer_name, organizer_email  (transitive)
```

The schema avoids this: only `user_id` (a foreign key) is stored; the organizer's name and email live in `users` and are reached via a join. 3NF

### `registrations`
Functional dependencies:
- `id → user_id, event_id, registered_at`
- `(user_id, event_id) → id, registered_at` (candidate key)

Only `registered_at` is a non-key attribute and it depends solely on the key.  3NF

---

## Final normalized schema

| Table | Primary key | Foreign keys | Candidate / unique keys | Normal form |
|---|---|---|---|---|
| `users` | `id` | none | `email` | 3NF |
| `events` | `id` | `user_id → users.id` | none | 3NF |
| `registrations` | `id` | `user_id → users.id`, `event_id → events.id` (cascade delete) | `(user_id, event_id)` | 3NF |

```
users 1 ───< events          (organizer)
users 1 ───< registrations >─── 1 events      (many-to-many resolved)
```

## Summary of what each form achieved

| Form | Problem removed | How this schema addresses it |
|---|---|---|
| 1NF | Multi-valued / repeating columns | Separate rows and tables; atomic columns; PKs everywhere |
| 2NF | Partial dependency on part of a composite key | `registrations` holds only attributes of the full `(user_id, event_id)` pair |
| 3NF | Transitive dependency between non-key attributes | Organizer and registrant details stored once in `users`, referenced by FK |

## Notes on design choices

- **Surrogate keys + unique constraint:** `registrations` uses `id` as PK and a `UNIQUE(user_id, event_id)` constraint to prevent duplicate registrations while keeping the table normalized.
- **Derived data is not stored:** attendee count per event is computed with `COUNT(*)` over `registrations`, not stored on `events`, which would create redundancy and update anomalies.
- **Delete behavior:** `registrations.event_id` uses `ON DELETE CASCADE` so removing an event removes its registrations; user FKs use `NO ACTION` to protect against deleting users who still own events or registrations.
- **Bonus (BCNF):** every determinant in all three tables is a candidate key, so the schema is also in BCNF.
