-- Synthetic trade-finance source (MVP subset of the 24 proposed LC tables).
-- Run against the `tradefin_source` Azure SQL database.

IF SCHEMA_ID('tf') IS NULL EXEC('CREATE SCHEMA tf');
GO

CREATE TABLE tf.BANK (
    bank_id       INT           NOT NULL PRIMARY KEY,
    bic           VARCHAR(11)   NOT NULL,
    bank_name     NVARCHAR(200) NOT NULL,
    country       CHAR(2)       NOT NULL
);

CREATE TABLE tf.CURRENCY_FX (
    currency_code CHAR(3)       NOT NULL PRIMARY KEY,
    currency_name NVARCHAR(100) NOT NULL,
    rate_to_usd   DECIMAL(18,8) NOT NULL,   -- USD per 1 unit (static for the MVP)
    rate_date     DATE          NOT NULL
);

CREATE TABLE tf.PARTY (
    party_id      INT           NOT NULL PRIMARY KEY,
    party_name    NVARCHAR(200) NULL,       -- nullable on purpose: dirty-data test
    country       CHAR(2)       NOT NULL,
    party_type    VARCHAR(20)   NOT NULL,   -- CORPORATE / SME / FI
    risk_rating   VARCHAR(5)    NOT NULL,   -- AAA .. D
    created_at    DATETIME2(3)  NOT NULL,
    updated_at    DATETIME2(3)  NOT NULL
);
CREATE INDEX ix_party_updated_at ON tf.PARTY (updated_at);

CREATE TABLE tf.LETTER_OF_CREDIT (
    lc_id            BIGINT        NOT NULL PRIMARY KEY,
    lc_number        VARCHAR(30)   NOT NULL,
    issuing_bank_id  INT           NOT NULL REFERENCES tf.BANK (bank_id),  -- MVP simplification of LC_BANK_ROLE
    amount           DECIMAL(18,2) NOT NULL,
    currency         CHAR(3)       NOT NULL,  -- no FK on purpose: allows a bad-currency dirty row
    issue_date       DATE          NOT NULL,
    expiry_date      DATE          NOT NULL,
    payment_terms    VARCHAR(20)   NOT NULL,  -- SIGHT / USANCE_30 / USANCE_60 / USANCE_90
    status           VARCHAR(15)   NOT NULL,  -- ISSUED / AMENDED / PRESENTED / SETTLED / EXPIRED
    created_at       DATETIME2(3)  NOT NULL,
    updated_at       DATETIME2(3)  NOT NULL
);
CREATE INDEX ix_lc_updated_at ON tf.LETTER_OF_CREDIT (updated_at);

CREATE TABLE tf.LC_PARTY_ROLE (
    lc_id         BIGINT       NOT NULL REFERENCES tf.LETTER_OF_CREDIT (lc_id),
    party_id      INT          NOT NULL REFERENCES tf.PARTY (party_id),
    role          VARCHAR(15)  NOT NULL,      -- APPLICANT / BENEFICIARY
    valid_from    DATE         NOT NULL,
    valid_to      DATE         NULL,
    updated_at    DATETIME2(3) NOT NULL,
    PRIMARY KEY (lc_id, party_id, role)
);
CREATE INDEX ix_lcpr_updated_at ON tf.LC_PARTY_ROLE (updated_at);

CREATE TABLE tf.LC_AMENDMENT (
    amendment_id    BIGINT        NOT NULL PRIMARY KEY,
    lc_id           BIGINT        NOT NULL REFERENCES tf.LETTER_OF_CREDIT (lc_id),
    version_no      INT           NOT NULL,
    effective_at    DATETIME2(3)  NOT NULL,
    amount_delta    DECIMAL(18,2) NOT NULL,
    expiry_change   DATE          NULL,
    approval_status VARCHAR(15)   NOT NULL,   -- APPROVED / PENDING / REJECTED
    updated_at      DATETIME2(3)  NOT NULL
);
CREATE INDEX ix_amend_updated_at ON tf.LC_AMENDMENT (updated_at);

CREATE TABLE tf.LC_EXPOSURE_EVENT (
    event_id          BIGINT        NOT NULL PRIMARY KEY,   -- monotonically increasing: append watermark
    lc_id             BIGINT        NOT NULL REFERENCES tf.LETTER_OF_CREDIT (lc_id),
    exposure_amount   DECIMAL(18,2) NOT NULL,
    currency          CHAR(3)       NOT NULL,
    exposure_type     VARCHAR(15)   NOT NULL,               -- CONTINGENT / FUNDED
    lifecycle_status  VARCHAR(15)   NOT NULL,
    occurred_at       DATETIME2(3)  NOT NULL,
    source_event_ref  VARCHAR(40)   NOT NULL                -- idempotency key; replays reuse it
);
GO
