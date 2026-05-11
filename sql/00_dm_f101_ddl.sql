-- Витрина формы 101: DM.DM_F101_ROUND_F

CREATE SCHEMA IF NOT EXISTS "DM";

CREATE TABLE IF NOT EXISTS "DM"."DM_F101_ROUND_F" (
    from_date           date NOT NULL,
    to_date             date NOT NULL,
    chapter             char(1) NOT NULL,
    ledger_account      char(5) NOT NULL,
    characteristic      char(1) NOT NULL,
    balance_in_rub      numeric(23, 8) NOT NULL DEFAULT 0,
    balance_in_val      numeric(23, 8) NOT NULL DEFAULT 0,
    balance_in_total    numeric(23, 8) NOT NULL DEFAULT 0,
    turn_deb_rub        numeric(23, 8) NOT NULL DEFAULT 0,
    turn_deb_val        numeric(23, 8) NOT NULL DEFAULT 0,
    turn_deb_total      numeric(23, 8) NOT NULL DEFAULT 0,
    turn_cre_rub        numeric(23, 8) NOT NULL DEFAULT 0,
    turn_cre_val        numeric(23, 8) NOT NULL DEFAULT 0,
    turn_cre_total      numeric(23, 8) NOT NULL DEFAULT 0,
    balance_out_rub     numeric(23, 8) NOT NULL DEFAULT 0,
    balance_out_val     numeric(23, 8) NOT NULL DEFAULT 0,
    balance_out_total   numeric(23, 8) NOT NULL DEFAULT 0,
    PRIMARY KEY (from_date, to_date, ledger_account, characteristic)
);
