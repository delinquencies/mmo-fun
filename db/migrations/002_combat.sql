-- 002 (Slice 005): character vitals and skills; corpse loot containers.
ALTER TABLE characters
    ADD COLUMN vitals jsonb NOT NULL DEFAULT '{}',   -- {"hp", "st", "mn", "dead"}
    ADD COLUMN skills jsonb NOT NULL DEFAULT '{}';   -- {"swordsmanship": 30.4, ...}
ALTER TABLE characters ADD CONSTRAINT characters_skills_obj CHECK (jsonb_typeof(skills) = 'object');
ALTER TABLE characters ADD CONSTRAINT characters_vitals_obj CHECK (jsonb_typeof(vitals) = 'object');
-- corpses are 'temporary' world objects holding generated loot until decay
CREATE INDEX world_objects_kind_idx ON world_objects (kind);
