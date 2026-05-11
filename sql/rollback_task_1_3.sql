-- Полный откат задания 1.3 в БД bank_ds (объекты из sql/00–01 и следы в LOGS).
-- Схемы "DS" и "LOGS" не трогаются; витрины 1.2 (DM_ACCOUNT_*) не трогаются.

BEGIN;

DROP PROCEDURE IF EXISTS "DM".fill_f101_round_f(date);

DROP TABLE IF EXISTS "DM"."DM_F101_ROUND_F" CASCADE;

DELETE FROM "LOGS".etl_log
WHERE COALESCE(extra->>'procedure', '') = 'dm.fill_f101_round_f'
   OR COALESCE(extra->>'mart', '') = 'DM_F101_ROUND_F';

COMMIT;
