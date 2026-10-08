-- Platform control tables used by the ADF metadata-driven ingestion framework.
IF SCHEMA_ID('ctl') IS NULL EXEC('CREATE SCHEMA ctl');
GO

CREATE TABLE ctl.ingestion_config (
    table_name        VARCHAR(100) NOT NULL PRIMARY KEY,   -- e.g. LETTER_OF_CREDIT
    source_schema     VARCHAR(30)  NOT NULL DEFAULT 'tf',
    load_type         CHAR(1)      NOT NULL,               -- F=full refresh, I=watermark incremental, A=append
    watermark_column  VARCHAR(100) NULL,
    watermark_type    VARCHAR(10)  NULL,                   -- datetime2 / bigint
    primary_key       VARCHAR(200) NOT NULL,               -- comma separated
    is_active         BIT          NOT NULL DEFAULT 1,
    CONSTRAINT ck_load_type CHECK (load_type IN ('F','I','A')),
    CONSTRAINT ck_wm CHECK (load_type = 'F' OR (watermark_column IS NOT NULL AND watermark_type IS NOT NULL))
);

CREATE TABLE ctl.watermark_control (
    table_name       VARCHAR(100) NOT NULL PRIMARY KEY REFERENCES ctl.ingestion_config (table_name),
    last_watermark   VARCHAR(40)  NOT NULL,
    updated_at       DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);

CREATE TABLE ctl.batch_audit (
    audit_id         BIGINT IDENTITY(1,1) PRIMARY KEY,
    batch_id         VARCHAR(50)  NOT NULL,                -- ADF pipeline run id
    table_name       VARCHAR(100) NOT NULL,
    load_type        CHAR(1)      NOT NULL,
    watermark_from   VARCHAR(40)  NULL,
    watermark_to     VARCHAR(40)  NULL,
    rows_copied      BIGINT       NOT NULL,
    status           VARCHAR(15)  NOT NULL,
    logged_at        DATETIME2(3) NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

INSERT INTO ctl.ingestion_config (table_name, load_type, watermark_column, watermark_type, primary_key) VALUES
 ('BANK',              'F', NULL,         NULL,        'bank_id'),
 ('CURRENCY_FX',       'F', NULL,         NULL,        'currency_code'),
 ('PARTY',             'I', 'updated_at', 'datetime2', 'party_id'),
 ('LETTER_OF_CREDIT',  'I', 'updated_at', 'datetime2', 'lc_id'),
 ('LC_PARTY_ROLE',     'I', 'updated_at', 'datetime2', 'lc_id,party_id,role'),
 ('LC_AMENDMENT',      'I', 'updated_at', 'datetime2', 'amendment_id'),
 ('LC_EXPOSURE_EVENT', 'A', 'event_id',   'bigint',    'event_id');

INSERT INTO ctl.watermark_control (table_name, last_watermark)
SELECT table_name,
       CASE watermark_type WHEN 'datetime2' THEN '1900-01-01 00:00:00.000'
                           WHEN 'bigint'    THEN '0'
                           ELSE 'n/a' END
FROM ctl.ingestion_config;
GO

-- Called by ADF after a successful copy: advances the watermark and writes the audit row.
CREATE OR ALTER PROCEDURE ctl.usp_complete_load
    @table_name     VARCHAR(100),
    @batch_id       VARCHAR(50),
    @rows_copied    BIGINT,
    @new_watermark  VARCHAR(40) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @load_type CHAR(1), @old VARCHAR(40);
    SELECT @load_type = load_type FROM ctl.ingestion_config WHERE table_name = @table_name;
    SELECT @old = last_watermark FROM ctl.watermark_control WHERE table_name = @table_name;

    BEGIN TRAN;
    IF @load_type <> 'F' AND @new_watermark IS NOT NULL
        UPDATE ctl.watermark_control
           SET last_watermark = @new_watermark, updated_at = SYSUTCDATETIME()
         WHERE table_name = @table_name;

    INSERT ctl.batch_audit (batch_id, table_name, load_type, watermark_from, watermark_to, rows_copied, status)
    VALUES (@batch_id, @table_name, @load_type, @old, COALESCE(@new_watermark, @old), @rows_copied, 'SUCCEEDED');
    COMMIT;
END;
GO
