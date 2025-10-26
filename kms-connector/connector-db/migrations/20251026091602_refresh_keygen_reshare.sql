CREATE TABLE IF NOT EXISTS refresh_keygen_reshare (
    prep_keygen_id BYTEA NOT NULL,
    key_id BYTEA NOT NULL,
    epoch_id BYTEA NOT NULL,
    params_type params_type NOT NULL,
    under_process BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMP NOT NULL DEFAULT NOW(),
    otlp_context BYTEA NOT NULL,
    PRIMARY KEY (key_id)
);

CREATE OR REPLACE FUNCTION notify_refresh_keygen_reshare()
    RETURNS trigger AS $$
BEGIN
    NOTIFY refresh_keygen_reshare_available;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER trigger_from_refresh_keygen_reshare_insertions
    AFTER INSERT
    ON refresh_keygen_reshare
    FOR EACH STATEMENT
    EXECUTE FUNCTION notify_refresh_keygen_reshare();
