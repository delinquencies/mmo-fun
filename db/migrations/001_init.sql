-- 001: accounts, sessions, characters, items, containers, world objects.
-- Integrity lives in the database: one row per item (= one location), slot and
-- equip uniqueness, positive quantities, capacity and stack limits, FKs.

CREATE TABLE accounts (
    id              bigserial PRIMARY KEY,
    username        text NOT NULL CHECK (username ~ '^[a-z0-9_]{3,24}$'),
    password_hash   text NOT NULL,                -- Argon2id (argon2-cffi PHC string)
    status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'disabled')),
    failed_logins   int  NOT NULL DEFAULT 0 CHECK (failed_logins >= 0),
    locked_until    timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    last_login_at   timestamptz
);
CREATE UNIQUE INDEX accounts_username_uq ON accounts (username);

-- Authenticated account sessions (not world sessions). Only a SHA-256 of the
-- token is stored; the token itself exists only in the client's memory.
CREATE TABLE auth_sessions (
    token_hash  bytea PRIMARY KEY,
    account_id  bigint NOT NULL REFERENCES accounts (id) ON DELETE CASCADE,
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    revoked_at  timestamptz
);
CREATE INDEX auth_sessions_account_idx ON auth_sessions (account_id);

CREATE TABLE item_defs (
    id          text PRIMARY KEY,
    stackable   boolean NOT NULL,
    max_stack   int NOT NULL CHECK (max_stack >= 1),
    equip_slot  text,
    data        jsonb NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE characters (
    id              bigserial PRIMARY KEY,
    account_id      bigint NOT NULL REFERENCES accounts (id),
    name            text NOT NULL CHECK (name ~ '^[A-Za-z][A-Za-z'' ]{1,14}[A-Za-z]$' AND name !~ '  '),
    appearance      jsonb NOT NULL,
    attributes      jsonb NOT NULL,
    region          text NOT NULL,
    spawn_x         double precision NOT NULL,
    spawn_y         double precision NOT NULL,
    x               double precision NOT NULL,
    y               double precision NOT NULL,
    z               double precision NOT NULL DEFAULT 0,
    facing          smallint NOT NULL DEFAULT 0 CHECK (facing BETWEEN 0 AND 7),
    created_at      timestamptz NOT NULL DEFAULT now(),
    last_played_at  timestamptz,
    locked_by       text,              -- server instance currently controlling the character
    lock_heartbeat  timestamptz
);
CREATE UNIQUE INDEX characters_name_uq ON characters (lower(name));
CREATE INDEX characters_account_idx ON characters (account_id);

CREATE TABLE world_objects (
    id          text PRIMARY KEY,                      -- stable id from the map data
    region      text NOT NULL,
    kind        text NOT NULL,
    policy      text NOT NULL CHECK (policy IN ('permanent', 'resettable', 'temporary')),
    state       jsonb NOT NULL DEFAULT '{}',
    orphaned    boolean NOT NULL DEFAULT false,        -- no longer defined by the map
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE containers (
    id                  text PRIMARY KEY,              -- e.g. 'c12.backpack', 'cottage_chest.contents'
    kind                text NOT NULL CHECK (kind IN ('backpack', 'world')),
    capacity            int  NOT NULL CHECK (capacity BETWEEN 1 AND 200),
    owner_character_id  bigint REFERENCES characters (id),
    world_object_id     text REFERENCES world_objects (id),
    CHECK ((kind = 'backpack') = (owner_character_id IS NOT NULL)),
    CHECK ((kind = 'world') = (world_object_id IS NOT NULL))
);

CREATE SEQUENCE item_id_seq;

-- One row per item instance: its single authoritative location.
CREATE TABLE items (
    id            bigint PRIMARY KEY DEFAULT nextval('item_id_seq'),
    def_id        text NOT NULL REFERENCES item_defs (id),
    quantity      int  NOT NULL CHECK (quantity >= 1),
    loc_kind      text NOT NULL CHECK (loc_kind IN ('container', 'equipment', 'world')),
    container_id  text REFERENCES containers (id),
    slot          int CHECK (slot >= 0),
    character_id  bigint REFERENCES characters (id),
    equip_slot    text CHECK (equip_slot IN ('main_hand', 'off_hand')),
    region        text,
    x             double precision,
    y             double precision,
    spawn_id      text,                                -- set for map-spawned items
    version       int NOT NULL DEFAULT 1 CHECK (version >= 1),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    CHECK ((loc_kind = 'container') = (container_id IS NOT NULL)),
    CHECK ((loc_kind = 'container') = (slot IS NOT NULL)),
    CHECK ((loc_kind = 'equipment') = (character_id IS NOT NULL)),
    CHECK ((loc_kind = 'equipment') = (equip_slot IS NOT NULL)),
    CHECK ((loc_kind = 'world') = (region IS NOT NULL AND x IS NOT NULL AND y IS NOT NULL)),
    CHECK (loc_kind = 'world' OR (region IS NULL AND x IS NULL AND y IS NULL)),
    -- deferred so a swap inside one transaction is legal; checked at COMMIT
    CONSTRAINT items_slot_uq  UNIQUE (container_id, slot) DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT items_equip_uq UNIQUE (character_id, equip_slot) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX items_world_idx ON items (region) WHERE loc_kind = 'world';
CREATE INDEX items_spawn_idx ON items (spawn_id) WHERE spawn_id IS NOT NULL;

CREATE FUNCTION items_enforce_limits() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE cap int; maxs int; stk boolean;
BEGIN
    SELECT max_stack, stackable INTO maxs, stk FROM item_defs WHERE id = NEW.def_id;
    IF NEW.quantity > maxs OR (NOT stk AND NEW.quantity <> 1) THEN
        RAISE EXCEPTION 'quantity % exceeds stack rules for %', NEW.quantity, NEW.def_id USING ERRCODE = 'check_violation';
    END IF;
    IF NEW.loc_kind = 'container' THEN
        SELECT capacity INTO cap FROM containers WHERE id = NEW.container_id;
        IF NEW.slot >= cap THEN
            RAISE EXCEPTION 'slot % beyond capacity of %', NEW.slot, NEW.container_id USING ERRCODE = 'check_violation';
        END IF;
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER items_limits BEFORE INSERT OR UPDATE ON items FOR EACH ROW EXECUTE FUNCTION items_enforce_limits();

-- Every committed item mutation, keyed by a server-generated op id (idempotency
-- + crash resolution: "did op X commit?").
CREATE TABLE item_ops (
    op_id         uuid PRIMARY KEY,
    actor         text,
    kind          text NOT NULL,
    changes       jsonb NOT NULL,
    committed_at  timestamptz NOT NULL DEFAULT now()
);
