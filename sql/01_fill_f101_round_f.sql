-- Процедура dm.fill_f101_round_f(i_OnDate)
-- i_OnDate — первый день месяца после отчётного (январь 2018 → DATE '2018-02-01').

CREATE OR REPLACE PROCEDURE "DM".fill_f101_round_f(IN i_ondate date)
LANGUAGE plpgsql
AS $proc$
DECLARE
    v_log_id   integer;   -- ключ строки LOGS.etl_log для этого прогона
    v_rows     bigint;     -- число вставленных строк витрины (после INSERT)
    v_from     date;       -- первый день отчётного периода (напр. 2018-01-01)
    v_to       date;       -- последний день отчётного периода (напр. 2018-01-31)
    v_bal_in   date;       -- дата «входящих» остатков: день до v_from (напр. 2017-12-31)
    v_bal_out  date;       -- дата «исходящих» остатков: последний день периода (= v_to)
BEGIN
    -- Отчётная дата i_OnDate только 1-е число месяца.
    IF i_ondate IS NULL OR i_ondate <> date_trunc('month', i_ondate)::date THEN
        RAISE EXCEPTION
            'i_OnDate must be the first day of a calendar month (reporting anchor). Example: 2018-02-01 for January 2018.';
    END IF;

    -- Границы отчётного месяца: месяц, предшествующий i_OnDate.
    v_from := date_trunc('month', i_ondate - interval '1 month')::date;
    v_to := (date_trunc('month', i_ondate)::date - interval '1 day')::date;
    -- Остатки «на начало» формы — на конец дня перед первым днём периода.
    v_bal_in := v_from - interval '1 day';
    v_bal_out := v_to;


    INSERT INTO "LOGS".etl_log (started_at, status, extra)
    VALUES (
        now(),
        'Started',
        jsonb_build_object(
            'mart', 'DM_F101_ROUND_F',
            'procedure', 'dm.fill_f101_round_f',
            'on_date', i_ondate,
            'from_date', v_from,
            'to_date', v_to
        )
    )
    RETURNING etl_log_id INTO v_log_id;

    BEGIN
        -- Повторный запуск за тот же период: старые строки витрины убираем.
        DELETE FROM "DM"."DM_F101_ROUND_F"
        WHERE from_date = v_from AND to_date = v_to;

        -- Вставка одним INSERT WITH: три CTE готовят агрегаты, финальный SELECT собирает строку отчёта.
        INSERT INTO "DM"."DM_F101_ROUND_F" (
            from_date, to_date, chapter, ledger_account, characteristic,
            balance_in_rub, balance_in_val, balance_in_total,
            turn_deb_rub, turn_deb_val, turn_deb_total,
            turn_cre_rub, turn_cre_val, turn_cre_total,
            balance_out_rub, balance_out_val, balance_out_total
        )
        WITH
        -- keys: множество строк отчёта.
        -- la5 — первые 5 символов лицевого счёта.
        -- cht — характеристика счёта.
        -- Берём только счета, у которых версия справочника пересекается с отчётным интервалом [v_from, v_to].
        keys AS (
            SELECT DISTINCT
                left(trim(a.account_number), 5) AS la5,
                rtrim(ltrim(a.char_type::text))::char(1) AS cht
            FROM "DS".md_account_d a
            WHERE length(trim(a.account_number)) >= 5
              AND left(trim(a.account_number), 5) ~ '^[0-9]{5}$'
              AND a.data_actual_date <= v_to
              AND a.data_actual_end_date >= v_from
        ),
        -- bal: один проход по витрине остатков за две даты (вход и выход периода).
        -- Версия md_account_d подбирается на дату строки остатка (курс валюты/код для rub vs val).
        -- FILTER — условные суммы: rub (810/643), val (прочие валюты), total (все); отдельно для on_date = v_bal_in и v_bal_out.
        bal AS (
            SELECT
                left(trim(a.account_number), 5) AS la5,
                rtrim(ltrim(a.char_type::text))::char(1) AS cht,
                coalesce(sum(b.balance_out_rub) FILTER (
                    WHERE b.on_date = v_bal_in AND upper(trim(a.currency_code::text)) IN ('810', '643')), 0
                )::numeric(23, 8) AS balance_in_rub,
                coalesce(sum(b.balance_out_rub) FILTER (
                    WHERE b.on_date = v_bal_in AND upper(trim(a.currency_code::text)) NOT IN ('810', '643')), 0
                )::numeric(23, 8) AS balance_in_val,
                coalesce(sum(b.balance_out_rub) FILTER (WHERE b.on_date = v_bal_in), 0)::numeric(23, 8) AS balance_in_total,
                coalesce(sum(b.balance_out_rub) FILTER (
                    WHERE b.on_date = v_bal_out AND upper(trim(a.currency_code::text)) IN ('810', '643')), 0
                )::numeric(23, 8) AS balance_out_rub,
                coalesce(sum(b.balance_out_rub) FILTER (
                    WHERE b.on_date = v_bal_out AND upper(trim(a.currency_code::text)) NOT IN ('810', '643')), 0
                )::numeric(23, 8) AS balance_out_val,
                coalesce(sum(b.balance_out_rub) FILTER (WHERE b.on_date = v_bal_out), 0)::numeric(23, 8) AS balance_out_total
            FROM "DM"."DM_ACCOUNT_BALANCE_F" b
            JOIN "DS".md_account_d a ON a.account_rk = b.account_rk
                AND b.on_date BETWEEN a.data_actual_date AND a.data_actual_end_date
            WHERE b.on_date IN (v_bal_in, v_bal_out)
            GROUP BY 1, 2
        ),
        -- trn: обороты за все дни отчётного окна [v_from, v_to] в рублях витрины (debet/credit_amount_rub).
        -- Группировка та же (la5, cht); rub/val/total — по коду валюты версии счёта на дату проводки.
        trn AS (
            SELECT
                left(trim(a.account_number), 5) AS la5,
                rtrim(ltrim(a.char_type::text))::char(1) AS cht,
                coalesce(sum(t.debet_amount_rub) FILTER (WHERE upper(trim(a.currency_code::text)) IN ('810', '643')), 0
                )::numeric(23, 8) AS turn_deb_rub,
                coalesce(sum(t.debet_amount_rub) FILTER (WHERE upper(trim(a.currency_code::text)) NOT IN ('810', '643')), 0
                )::numeric(23, 8) AS turn_deb_val,
                coalesce(sum(t.debet_amount_rub), 0)::numeric(23, 8) AS turn_deb_total,
                coalesce(sum(t.credit_amount_rub) FILTER (WHERE upper(trim(a.currency_code::text)) IN ('810', '643')), 0
                )::numeric(23, 8) AS turn_cre_rub,
                coalesce(sum(t.credit_amount_rub) FILTER (WHERE upper(trim(a.currency_code::text)) NOT IN ('810', '643')), 0
                )::numeric(23, 8) AS turn_cre_val,
                coalesce(sum(t.credit_amount_rub), 0)::numeric(23, 8) AS turn_cre_total
            FROM "DM"."DM_ACCOUNT_TURNOVER_F" t
            JOIN "DS".md_account_d a ON a.account_rk = t.account_rk
                AND t.on_date BETWEEN a.data_actual_date AND a.data_actual_end_date
            WHERE t.on_date BETWEEN v_from AND v_to
            GROUP BY 1, 2
        )
        -- Сборка строки витрины: ключ из keys; суммы из bal/trn (LEFT JOIN — нет оборотов/остатков → нули).
        -- chapter: глава из md_ledger_account_s по числовому ledger_account = la5::integer на конец периода (v_to).
        SELECT
            v_from,
            v_to,
            coalesce(ch.chapter, ' ')::char(1),
            rpad(k.la5, 5, ' ')::char(5),
            k.cht,
            coalesce(bal.balance_in_rub, 0),
            coalesce(bal.balance_in_val, 0),
            coalesce(bal.balance_in_total, 0),
            coalesce(trn.turn_deb_rub, 0),
            coalesce(trn.turn_deb_val, 0),
            coalesce(trn.turn_deb_total, 0),
            coalesce(trn.turn_cre_rub, 0),
            coalesce(trn.turn_cre_val, 0),
            coalesce(trn.turn_cre_total, 0),
            coalesce(bal.balance_out_rub, 0),
            coalesce(bal.balance_out_val, 0),
            coalesce(bal.balance_out_total, 0)
        FROM keys k
        LEFT JOIN bal ON bal.la5 = k.la5 AND bal.cht = k.cht
        LEFT JOIN trn ON trn.la5 = k.la5 AND trn.cht = k.cht
        LEFT JOIN LATERAL (
            SELECT lac.chapter
            FROM "DS".md_ledger_account_s lac
            WHERE lac.ledger_account = k.la5::integer
              AND v_to >= lac.start_date
              AND (lac.end_date IS NULL OR v_to <= lac.end_date)
            ORDER BY lac.start_date DESC
            LIMIT 1
        ) AS ch ON true;

        GET DIAGNOSTICS v_rows = ROW_COUNT;

        -- Успех
        UPDATE "LOGS".etl_log
        SET
            finished_at = now(),
            status = 'Success',
            extra = jsonb_build_object(
                'mart', 'DM_F101_ROUND_F',
                'procedure', 'dm.fill_f101_round_f',
                'on_date', i_ondate,
                'from_date', v_from,
                'to_date', v_to,
                'rows_inserted', v_rows,
                'etl_log_id', v_log_id
            )
        WHERE etl_log_id = v_log_id;

    EXCEPTION
        WHEN OTHERS THEN
            -- Ошибка расчёта
            UPDATE "LOGS".etl_log
            SET
                finished_at = now(),
                status = 'Failed',
                error_message = SQLERRM,
                extra = COALESCE(extra, '{}'::jsonb) || jsonb_build_object(
                    'mart', 'DM_F101_ROUND_F',
                    'procedure', 'dm.fill_f101_round_f',
                    'on_date', i_ondate,
                    'failed', true
                )
            WHERE etl_log_id = v_log_id;
            RAISE;
    END;
END;
$proc$;
