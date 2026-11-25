# Question 8 — Transport Fleet Maintenance

**Script:** [`q08_fleet.sql`](q08_fleet.sql) · **Schema:** `q08_fleet` · **DBMS:** PostgreSQL 14+ with pg_cron

## How to run

pgAdmin: open the Query Tool, open `q08_fleet.sql` and press **F5**. Results appear in *Data Output*; the test messages (`RAISE NOTICE`) appear in *Messages*.

```bash
psql -d ict371 -f q08_fleet.sql
```

The script drops and recreates the `q08_fleet` schema, so it can be run as many times as you like. Part (g) needs pg_cron (setup steps are in the [main README](../README.md#setting-up-pg_cron-part-g)).

## What each part does

| Part | Object | How it meets the requirement |
|------|--------|------------------------------|
| (a) Database & seed [6] | `vehicles`, `trips`, `service_alerts` | Odometers `>= 0` and `CHECK (last_service_odometer <= current_odometer)`. Three vehicles at 2 000, 3 500 and 500 km since service. Six trips are added **through the procedure after the trigger exists**. |
| (b) Function [6] | `fn_service_due(p_vehicle_id) RETURNS BOOLEAN` | `current − last_service >= 5000`. An unknown vehicle raises an error. |
| (c) Procedure [8] | `pr_record_trip(p_vehicle_id, p_trip_on, p_start, p_end)` | Validates the vehicle and requires `end > start`, then inserts the trip. It deliberately does **not** update the odometer. |
| (d) Trigger [8] | `trg_trips_odometer` (BEFORE INSERT, FOR EACH ROW) | Locks the vehicle row, checks `start_odometer = current_odometer`, rejects invalid mileage, then sets `current_odometer = NEW.end_odometer`. That is one update per trip, so it happens exactly once. A wrong start through the procedure or through direct SQL is rejected. |
| (e) View [5] | `v_service_due` | Registration and km since service for vehicles at or above 5 000 km. |
| (f) Index [5] | `idx_trips_vehicle_trip_on (vehicle_id, trip_on)` | Equality on vehicle first, date range second, which matches one vehicle's logbook for a period. |
| (g) Job [6] | `pr_refresh_service_alerts()` + cron `0 6 * * 1` | An upsert keeps one alert per due vehicle and refreshes its km. A `DELETE … USING vehicles` removes alerts for vehicles no longer due after a service. The job runs every Monday at 06:00. |

## Expected results (verified on PostgreSQL 16)

Odometers finish at 13 100 / 49 900 / 31 240. BAZ 5555 is due at 5 400 km. Its alert is created, stays single on rerun, and is removed after the service update.

Dates are written relative to `CURRENT_DATE`, so the views and summaries show data whenever the script is run.
