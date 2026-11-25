/* =====================================================================
   ICT371 Advanced Database — Question 8: Transport Fleet Maintenance
   DBMS : PostgreSQL 14+ (tested on PostgreSQL 16) with pg_cron
   Rules: service is due when (current_odometer - last_service_odometer) >= 5000 km.
          Each new trip must START at the vehicle's current odometer.
   ===================================================================== */

DROP SCHEMA IF EXISTS q08_fleet CASCADE;
CREATE SCHEMA q08_fleet;
SET search_path TO q08_fleet, public;

/* ---------------------------------------------------------------------
   (a) DATABASE — tables  [6 marks]
   --------------------------------------------------------------------- */
CREATE TABLE vehicles (
    vehicle_id             SERIAL      PRIMARY KEY,
    registration           VARCHAR(15) NOT NULL UNIQUE,
    current_odometer       INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer  INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT chk_service_not_after_current CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id         SERIAL  PRIMARY KEY,
    vehicle_id      INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on         DATE    NOT NULL,
    start_odometer  INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer    INTEGER NOT NULL,
    CONSTRAINT chk_trip_distance_positive CHECK (end_odometer > start_odometer)
);

CREATE TABLE service_alerts (
    vehicle_id        INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service  INTEGER NOT NULL,
    flagged_on        DATE    NOT NULL DEFAULT CURRENT_DATE
);

/* ---------------------------------------------------------------------
   (b) FUNCTION fn_service_due(p_vehicle_id) RETURNS BOOLEAN  [6 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
SET search_path = q08_fleet, public
AS $$
DECLARE
    v_current INTEGER;
    v_last    INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer INTO v_current, v_last
    FROM vehicles
    WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle % does not exist', p_vehicle_id USING ERRCODE = 'P0002';
    END IF;

    RETURN (v_current - v_last) >= 5000;
END;
$$;

/* ---------------------------------------------------------------------
   (c) PROCEDURE pr_record_trip(p_vehicle_id, p_trip_on, p_start, p_end)  [8 marks]
   Validates and inserts the trip ONLY. It does not touch the odometer —
   the trigger in (d) does that, so the odometer is moved exactly once.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      INTEGER,
    p_end        INTEGER
)
LANGUAGE plpgsql
SET search_path = q08_fleet, public
AS $$
DECLARE
    v_trip_id INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Trip rejected: vehicle % does not exist', p_vehicle_id USING ERRCODE = 'P0002';
    END IF;

    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip rejected: date, start and end odometer are all required' USING ERRCODE = '22023';
    END IF;

    IF p_end <= p_start THEN
        RAISE EXCEPTION 'Trip rejected: end odometer % must be greater than start %', p_end, p_start
              USING ERRCODE = '22023';
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end)
    RETURNING trip_id INTO v_trip_id;

    RAISE NOTICE 'Trip % recorded: vehicle %, % km', v_trip_id, p_vehicle_id, p_end - p_start;
END;
$$;

/* ---------------------------------------------------------------------
   (d) TRIGGER — BEFORE INSERT on trips  [8 marks]
   1. lock the vehicle row (two trips cannot start from the same reading)
   2. start must equal the current odometer; mileage must be positive
   3. move current_odometer to the trip end — exactly once per trip
   If the INSERT fails later, the whole statement (including this UPDATE)
   is rolled back.
   --------------------------------------------------------------------- */
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q08_fleet, public
AS $$
DECLARE
    v_current INTEGER;
BEGIN
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Vehicle % does not exist', NEW.vehicle_id USING ERRCODE = '23503';
    END IF;

    IF NEW.end_odometer IS NULL OR NEW.start_odometer IS NULL
       OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end %', NEW.start_odometer, NEW.end_odometer
              USING ERRCODE = '23514';
    END IF;

    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Trip must start at the current odometer % (got %)', v_current, NEW.start_odometer
              USING ERRCODE = '23514';
    END IF;

    UPDATE vehicles
    SET    current_odometer = NEW.end_odometer
    WHERE  vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

/* ---------------------------------------------------------------------
   (a) SEED DATA — 3 vehicles at different service positions, then
   6 trips added THROUGH the procedure (trigger already installed).
   --------------------------------------------------------------------- */
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 1234', 12000, 10000),   -- 2 000 km since service
    ('BAZ 5555', 48000, 44500),   -- 3 500 km since service (will pass 5 000)
    ('CAT 7777', 30500, 30000);   --   500 km since service (just serviced)

CALL pr_record_trip(2, CURRENT_DATE - 6, 48000, 48800);
CALL pr_record_trip(1, CURRENT_DATE - 5, 12000, 12650);
CALL pr_record_trip(3, CURRENT_DATE - 4, 30500, 30920);
CALL pr_record_trip(2, CURRENT_DATE - 3, 48800, 49900);   -- BAZ now 5 400 km since service
CALL pr_record_trip(1, CURRENT_DATE - 2, 12650, 13100);
CALL pr_record_trip(3, CURRENT_DATE - 1, 30920, 31240);

SELECT * FROM trips ORDER BY trip_id;
SELECT vehicle_id, registration, current_odometer, last_service_odometer,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles ORDER BY vehicle_id;     -- odometers moved once per trip

/* ---------------------------------------------------------------------
   TESTS for (b), (c), (d)
   --------------------------------------------------------------------- */
SELECT vehicle_id, fn_service_due(vehicle_id) AS service_due FROM vehicles ORDER BY 1;

DO $$
BEGIN
    BEGIN PERFORM fn_service_due(99);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'fn_service_due(99)    -> %', SQLERRM; END;
    BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Unknown vehicle       -> %', SQLERRM; END;
    BEGIN CALL pr_record_trip(1, CURRENT_DATE, 13100, 13100);
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'End not > start       -> %', SQLERRM; END;
    BEGIN CALL pr_record_trip(1, CURRENT_DATE, 12000, 12500);      -- old start reading
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Wrong start (proc)    -> %', SQLERRM; END;
    BEGIN INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
          VALUES (3, CURRENT_DATE, 40000, 40100);                   -- direct SQL, wrong start
    EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Wrong start (direct)  -> %', SQLERRM; END;
END $$;

SELECT COUNT(*) AS trips_still_6 FROM trips;
SELECT registration, current_odometer FROM vehicles ORDER BY vehicle_id;   -- unchanged

/* ---------------------------------------------------------------------
   (e) VIEW v_service_due  [5 marks]
   --------------------------------------------------------------------- */
CREATE OR REPLACE VIEW v_service_due AS
SELECT vehicle_id,
       registration,
       current_odometer - last_service_odometer AS km_since_service
FROM   vehicles
WHERE  current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;          -- BAZ 5555, 5 400 km

/* ---------------------------------------------------------------------
   (f) INDEX — one vehicle's trips within a trip_on date range  [5 marks]
   Justification: vehicle_id is matched with "=", trip_on with a range.
   (vehicle_id, trip_on) keeps each vehicle's trips together in date
   order, so the logbook query reads one short slice of the index.
   --------------------------------------------------------------------- */
CREATE INDEX idx_trips_vehicle_trip_on ON trips (vehicle_id, trip_on);
ANALYZE trips;

EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM   trips
WHERE  vehicle_id = 2
AND    trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;

BEGIN;
SET LOCAL enable_seqscan = off;
EXPLAIN ANALYZE
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM   trips
WHERE  vehicle_id = 2
AND    trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
COMMIT;

/* ---------------------------------------------------------------------
   (g) SCHEDULED JOB — pr_refresh_service_alerts()  [6 marks]
   Upsert one alert per due vehicle (flagged_on keeps the first date it was
   flagged; km is refreshed) and delete alerts for vehicles no longer due.
   --------------------------------------------------------------------- */
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
SET search_path = q08_fleet, public
AS $$
DECLARE
    v_upserted INTEGER;
    v_removed  INTEGER;
BEGIN
    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM   vehicles
    WHERE  current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
       SET km_since_service = EXCLUDED.km_since_service;
    GET DIAGNOSTICS v_upserted = ROW_COUNT;

    DELETE FROM service_alerts sa
    USING  vehicles v
    WHERE  v.vehicle_id = sa.vehicle_id
    AND    v.current_odometer - v.last_service_odometer < 5000;
    GET DIAGNOSTICS v_removed = ROW_COUNT;

    RAISE NOTICE 'service_alerts: % inserted/updated, % removed', v_upserted, v_removed;
END;
$$;

CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();          -- rerun: still one alert for BAZ 5555
SELECT * FROM service_alerts;

-- BAZ 5555 is serviced -> next refresh removes its alert
UPDATE vehicles SET last_service_odometer = current_odometer WHERE registration = 'BAZ 5555';
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;              -- empty

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule(
    'q08_refresh_service_alerts',
    '0 6 * * 1',                                   -- 06:00 every Monday (1 = Monday)
    $$CALL q08_fleet.pr_refresh_service_alerts()$$
);

SELECT jobid, jobname, schedule, command, active
FROM cron.job WHERE jobname = 'q08_refresh_service_alerts';
