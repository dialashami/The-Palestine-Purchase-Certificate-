--------------------------------------------------------------------
---------------------------------------- 1.Create DB
-------------------------------------------------------------------------

IF DB_ID('PalestinePurchaseDB') IS NULL
    CREATE DATABASE PalestinePurchaseDB;
GO
USE PalestinePurchaseDB;
GO

-------------------------------------------------------------------
----------------------------------------- 2.Drop procedures
-----------------------------------------------------------------------

IF OBJECT_ID('dbo.ValidateStagingStructure', 'P') IS NOT NULL
    DROP PROCEDURE dbo.ValidateStagingStructure;
GO

IF OBJECT_ID('dbo.ProcessParcels', 'P') IS NOT NULL
    DROP PROCEDURE dbo.ProcessParcels;
GO

IF OBJECT_ID('dbo.ProcessPurchaseCertificates', 'P') IS NOT NULL
    DROP PROCEDURE dbo.ProcessPurchaseCertificates;
GO

IF OBJECT_ID('dbo.ExportPurchaseCertificates', 'P') IS NOT NULL
    DROP PROCEDURE dbo.ExportPurchaseCertificates;
GO

-----------------------------------------------------------------------
----------------3.Drop FK constraints (if exist) then drop tables
-----------------------------------------------------------------------

IF OBJECT_ID('dbo.Parcels', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_Parcels_PurchaseCertificates')
        ALTER TABLE dbo.Parcels DROP CONSTRAINT FK_Parcels_PurchaseCertificates;
END
GO

IF OBJECT_ID('dbo.PurchaseCertificates', 'U') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.foreign_keys WHERE name = 'FK_PurchaseCertificates_Orders')
        ALTER TABLE dbo.PurchaseCertificates DROP CONSTRAINT FK_PurchaseCertificates_Orders;
END
GO

IF OBJECT_ID('dbo.StagingUpload', 'U') IS NOT NULL DROP TABLE dbo.StagingUpload;
GO
IF OBJECT_ID('dbo.AdminPageSettings', 'U') IS NOT NULL DROP TABLE dbo.AdminPageSettings;
GO
IF OBJECT_ID('dbo.Parcels', 'U') IS NOT NULL DROP TABLE dbo.Parcels;
GO
IF OBJECT_ID('dbo.PurchaseCertificates', 'U') IS NOT NULL DROP TABLE dbo.PurchaseCertificates;
GO
IF OBJECT_ID('dbo.Orders', 'U') IS NOT NULL DROP TABLE dbo.Orders;
GO

-----------------------------------------------------------------------
---------------------------------------- 4.Create tables
-----------------------------------------------------------------------

CREATE TABLE dbo.Orders
(
    OrderId NVARCHAR(50) NOT NULL PRIMARY KEY,
    ShipDate DATE NULL
);
GO

CREATE TABLE dbo.PurchaseCertificates
(
    CertificateId INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    OrderId NVARCHAR(50) NOT NULL,
    PurchaseCertificateNumber NVARCHAR(50) NOT NULL,
    ShipDate DATE NULL,
    ParcelRowsCount INT NOT NULL CONSTRAINT DF_PurchaseCertificates_ParcelRowsCount DEFAULT (0),
    TotalCertificatePrice DECIMAL(18,2) NOT NULL CONSTRAINT DF_PurchaseCertificates_TotalPrice DEFAULT (0),
    Status NVARCHAR(30) NOT NULL CONSTRAINT DF_PurchaseCertificates_Status DEFAULT ('READY'),
    IsDownloaded BIT NOT NULL CONSTRAINT DF_PurchaseCertificates_IsDownloaded DEFAULT (0),
    DownloadedAt DATETIME NULL,

    CONSTRAINT UQ_PurchaseCertificates_PCN UNIQUE (PurchaseCertificateNumber)
);
GO

ALTER TABLE dbo.PurchaseCertificates
ADD CONSTRAINT FK_PurchaseCertificates_Orders
FOREIGN KEY (OrderId) REFERENCES dbo.Orders(OrderId);
GO

CREATE TABLE dbo.Parcels
(
    ParcelId INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    CertificateId INT NOT NULL,
    ParcelCode NVARCHAR(50) NOT NULL,
    ParcelPrice DECIMAL(18,2) NOT NULL CONSTRAINT DF_Parcels_ParcelPrice DEFAULT (0),

    CONSTRAINT FK_Parcels_PurchaseCertificates
    FOREIGN KEY (CertificateId) REFERENCES dbo.PurchaseCertificates(CertificateId)
);
GO

CREATE TABLE dbo.StagingUpload
(
    UploadId INT IDENTITY(1,1) NOT NULL PRIMARY KEY,
    OrderId NVARCHAR(50) NULL,
    ParcelCode NVARCHAR(50) NULL,
    PurchaseCertificateNumber NVARCHAR(50) NULL,
    ParcelPrice DECIMAL(18,2) NULL,
    ShipDate DATE NULL,

    IsProcessed BIT NOT NULL CONSTRAINT DF_StagingUpload_IsProcessed DEFAULT (0),
    ValidationMessage NVARCHAR(255) NULL
);
GO

CREATE TABLE dbo.AdminPageSettings
(
    AdminPageId INT IDENTITY(1,1) PRIMARY KEY,
    MerchantAdminPageName NVARCHAR(100) NOT NULL
);
GO

INSERT INTO dbo.AdminPageSettings (MerchantAdminPageName)
VALUES ('PalestineMerchantAdmin');
GO

-----------------------------------------------------------------------
------------- 5.Stored Procedure: ValidateStagingStructure
-----------------------------------------------------------------------

CREATE PROCEDURE dbo.ValidateStagingStructure
AS
BEGIN
    SET NOCOUNT ON;

    -------------------------------------------------------------------
    -- Step 1: validate staging table columns exist
    -------------------------------------------------------------------
    IF COL_LENGTH('dbo.StagingUpload', 'OrderId') IS NULL
       OR COL_LENGTH('dbo.StagingUpload', 'ParcelCode') IS NULL
       OR COL_LENGTH('dbo.StagingUpload', 'PurchaseCertificateNumber') IS NULL
       OR COL_LENGTH('dbo.StagingUpload', 'ParcelPrice') IS NULL
       OR COL_LENGTH('dbo.StagingUpload', 'ShipDate') IS NULL
       OR COL_LENGTH('dbo.StagingUpload', 'IsProcessed') IS NULL
       OR COL_LENGTH('dbo.StagingUpload', 'ValidationMessage') IS NULL
    BEGIN
        RAISERROR('Invalid staging table structure: one or more required columns are missing.', 16, 1);
        RETURN;
    END;

    -------------------------------------------------------------------
    -- Step 2: validate that uploaded file/staging is not empty
    -------------------------------------------------------------------
    IF NOT EXISTS (SELECT 1 FROM dbo.StagingUpload)
    BEGIN
        RAISERROR('Uploaded file is empty: no rows found in staging table.', 16, 1);
        RETURN;
    END;

    -------------------------------------------------------------------
    -- Step 3: mark rows that are completely empty
    -------------------------------------------------------------------
    UPDATE dbo.StagingUpload
    SET
        IsProcessed = 1,
        ValidationMessage = 'Dropped: Empty row in uploaded file'
    WHERE IsProcessed = 0
      AND (OrderId IS NULL OR LTRIM(RTRIM(OrderId)) = '')
      AND (ParcelCode IS NULL OR LTRIM(RTRIM(ParcelCode)) = '')
      AND (PurchaseCertificateNumber IS NULL OR LTRIM(RTRIM(PurchaseCertificateNumber)) = '')
      AND ParcelPrice IS NULL
      AND ShipDate IS NULL;

    PRINT 'Staging table structure is valid.';
END;
GO

-----------------------------------------------------------------------
---------------------- 6.Stored Procedure: ProcessPurchaseCertificates
-----------------------------------------------------------------------

CREATE PROCEDURE dbo.ProcessPurchaseCertificates
AS
BEGIN
    SET NOCOUNT ON;

    -------------------------------------------------------------------
    -- Step 0: validate staging structure before business processing
    -------------------------------------------------------------------
    EXEC dbo.ValidateStagingStructure;

    -------------------------------------------------------------------
    -- Step 1: validate required fields row-by-row
    -------------------------------------------------------------------
    UPDATE dbo.StagingUpload
    SET
        ValidationMessage = 'Dropped: OrderId is missing',
        IsProcessed = 1
    WHERE IsProcessed = 0
      AND (OrderId IS NULL OR LTRIM(RTRIM(OrderId)) = '');

    UPDATE dbo.StagingUpload
    SET
        ValidationMessage = 'Dropped: PurchaseCertificateNumber is missing',
        IsProcessed = 1
    WHERE IsProcessed = 0
      AND (PurchaseCertificateNumber IS NULL OR LTRIM(RTRIM(PurchaseCertificateNumber)) = '');

    UPDATE dbo.StagingUpload
    SET
        ValidationMessage = 'Dropped: ParcelCode is missing',
        IsProcessed = 1
    WHERE IsProcessed = 0
      AND (ParcelCode IS NULL OR LTRIM(RTRIM(ParcelCode)) = '');

    -------------------------------------------------------------------
    -- Step 2: normalize values
    -------------------------------------------------------------------
    UPDATE dbo.StagingUpload
    SET ParcelPrice = 0
    WHERE IsProcessed = 0
      AND ParcelPrice IS NULL;

    -------------------------------------------------------------------
    -- Step 3: reject certificates already downloaded
    -------------------------------------------------------------------
    UPDATE s
    SET
        s.IsProcessed = 1,
        s.ValidationMessage = 'Dropped: Certificate already downloaded and cannot be reprocessed'
    FROM dbo.StagingUpload s
    JOIN dbo.PurchaseCertificates pc
      ON pc.PurchaseCertificateNumber = s.PurchaseCertificateNumber
    WHERE s.IsProcessed = 0
      AND pc.IsDownloaded = 1;

    -------------------------------------------------------------------
    -- Step 4: aggregate valid uploaded rows by certificate
    -------------------------------------------------------------------
    IF OBJECT_ID('tempdb..#Agg') IS NOT NULL DROP TABLE #Agg;

    SELECT
        OrderId,
        PurchaseCertificateNumber,
        MAX(ShipDate) AS ShipDate,
        COUNT(*) AS ParcelRowsCount,
        SUM(ParcelPrice) AS TotalCertificatePrice
    INTO #Agg
    FROM dbo.StagingUpload
    WHERE IsProcessed = 0
    GROUP BY OrderId, PurchaseCertificateNumber;

    -------------------------------------------------------------------
    -- Step 5: insert missing orders
    -------------------------------------------------------------------
    INSERT INTO dbo.Orders (OrderId, ShipDate)
    SELECT a.OrderId, a.ShipDate
    FROM #Agg a
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM dbo.Orders o
        WHERE o.OrderId = a.OrderId
    );

    -------------------------------------------------------------------
    -- Step 6: update existing orders
    -------------------------------------------------------------------
    UPDATE o
    SET o.ShipDate = a.ShipDate
    FROM dbo.Orders o
    JOIN #Agg a
      ON a.OrderId = o.OrderId
    WHERE o.ShipDate IS NULL
       OR o.ShipDate <> a.ShipDate;

    -------------------------------------------------------------------
    -- Step 7: update existing certificates before download
    -------------------------------------------------------------------
    UPDATE pc
    SET
        pc.OrderId = a.OrderId,
        pc.ShipDate = a.ShipDate,
        pc.ParcelRowsCount = a.ParcelRowsCount,
        pc.TotalCertificatePrice = a.TotalCertificatePrice,
        pc.Status =
            CASE
                WHEN pc.IsDownloaded = 1 THEN 'DOWNLOADED'
                WHEN a.ParcelRowsCount <> 4 THEN 'INVALID'
                ELSE 'READY'
            END
    FROM dbo.PurchaseCertificates pc
    JOIN #Agg a
      ON pc.PurchaseCertificateNumber = a.PurchaseCertificateNumber
    WHERE pc.IsDownloaded = 0;

    -------------------------------------------------------------------
    -- Step 8: insert new certificates
    -------------------------------------------------------------------
    INSERT INTO dbo.PurchaseCertificates
    (
        OrderId,
        PurchaseCertificateNumber,
        ShipDate,
        ParcelRowsCount,
        TotalCertificatePrice,
        Status,
        IsDownloaded
    )
    SELECT
        a.OrderId,
        a.PurchaseCertificateNumber,
        a.ShipDate,
        a.ParcelRowsCount,
        a.TotalCertificatePrice,
        CASE
            WHEN a.ParcelRowsCount <> 4 THEN 'INVALID'
            ELSE 'READY'
        END,
        0
    FROM #Agg a
    WHERE NOT EXISTS
    (
        SELECT 1
        FROM dbo.PurchaseCertificates pc
        WHERE pc.PurchaseCertificateNumber = a.PurchaseCertificateNumber
    );
END;
GO

-----------------------------------------------------------------------
------------- 7.Stored Procedure: ProcessParcels
-----------------------------------------------------------------------

CREATE PROCEDURE dbo.ProcessParcels
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE dbo.StagingUpload
    SET ParcelPrice = 0
    WHERE IsProcessed = 0
      AND ParcelPrice IS NULL;

    -------------------------------------------------------------------
    -- Update existing parcels for certificates not downloaded
    -------------------------------------------------------------------
    UPDATE p
    SET p.ParcelPrice = s.ParcelPrice
    FROM dbo.Parcels p
    JOIN dbo.PurchaseCertificates pc
      ON pc.CertificateId = p.CertificateId
    JOIN dbo.StagingUpload s
      ON s.PurchaseCertificateNumber = pc.PurchaseCertificateNumber
     AND s.ParcelCode = p.ParcelCode
    WHERE s.IsProcessed = 0
      AND pc.IsDownloaded = 0;

    -------------------------------------------------------------------
    -- Insert new parcels if they do not exist
    -------------------------------------------------------------------
    INSERT INTO dbo.Parcels (CertificateId, ParcelCode, ParcelPrice)
    SELECT
        pc.CertificateId,
        s.ParcelCode,
        s.ParcelPrice
    FROM dbo.StagingUpload s
    JOIN dbo.PurchaseCertificates pc
      ON pc.OrderId = s.OrderId
     AND pc.PurchaseCertificateNumber = s.PurchaseCertificateNumber
    WHERE s.IsProcessed = 0
      AND pc.IsDownloaded = 0
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.Parcels p
          WHERE p.CertificateId = pc.CertificateId
            AND p.ParcelCode = s.ParcelCode
      );

    -------------------------------------------------------------------
    -- Delete old parcels removed in re-upload before download
    -------------------------------------------------------------------
    DELETE p
    FROM dbo.Parcels p
    JOIN dbo.PurchaseCertificates pc
      ON pc.CertificateId = p.CertificateId
    WHERE pc.IsDownloaded = 0
      AND EXISTS
      (
          SELECT 1
          FROM dbo.StagingUpload s1
          WHERE s1.IsProcessed = 0
            AND s1.PurchaseCertificateNumber = pc.PurchaseCertificateNumber
      )
      AND NOT EXISTS
      (
          SELECT 1
          FROM dbo.StagingUpload s2
          WHERE s2.IsProcessed = 0
            AND s2.PurchaseCertificateNumber = pc.PurchaseCertificateNumber
            AND s2.ParcelCode = p.ParcelCode
      );

    -------------------------------------------------------------------
    -- Mark valid staging rows as processed
    -------------------------------------------------------------------
    UPDATE s
    SET
        s.IsProcessed = 1,
        s.ValidationMessage = ISNULL(s.ValidationMessage, 'Processed successfully')
    FROM dbo.StagingUpload s
    JOIN dbo.PurchaseCertificates pc
      ON pc.OrderId = s.OrderId
     AND pc.PurchaseCertificateNumber = s.PurchaseCertificateNumber
    WHERE s.IsProcessed = 0
      AND pc.IsDownloaded = 0;
END;
GO

-----------------------------------------------------------------------
------------- 8.Stored Procedure: ExportPurchaseCertificates
-----------------------------------------------------------------------

CREATE PROCEDURE dbo.ExportPurchaseCertificates
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MerchantAdminPageName NVARCHAR(100);
    DECLARE @ExportFileName NVARCHAR(200);

    SELECT TOP 1 @MerchantAdminPageName = MerchantAdminPageName
    FROM dbo.AdminPageSettings;

    SET @ExportFileName =
        @MerchantAdminPageName + '_PurchaseCertificates_' +
        CONVERT(NVARCHAR(8), GETDATE(), 112) + '.csv';

    -------------------------------------------------------------------
    -- Export only READY certificates with exactly 4 parcel rows
    -------------------------------------------------------------------
    SELECT
        @ExportFileName AS ExportFileName,
        pc.PurchaseCertificateNumber,
        pc.OrderId,
        pc.ShipDate,
        pc.TotalCertificatePrice,
        p.ParcelCode,
        p.ParcelPrice
    FROM dbo.PurchaseCertificates pc
    JOIN dbo.Parcels p
      ON pc.CertificateId = p.CertificateId
    WHERE pc.IsDownloaded = 0
      AND pc.ParcelRowsCount = 4
      AND pc.Status = 'READY'
    ORDER BY pc.PurchaseCertificateNumber, p.ParcelCode;

    -------------------------------------------------------------------
    -- Mark exported certificates as downloaded
    -------------------------------------------------------------------
    UPDATE dbo.PurchaseCertificates
    SET
        IsDownloaded = 1,
        DownloadedAt = GETDATE(),
        Status = 'DOWNLOADED'
    WHERE IsDownloaded = 0
      AND ParcelRowsCount = 4
      AND Status = 'READY';
END;
GO

-----------------------------------------------------------------------
-- Clean previous test data
-----------------------------------------------------------------------

TRUNCATE TABLE dbo.StagingUpload;
DELETE FROM dbo.Parcels;
DELETE FROM dbo.PurchaseCertificates;
DELETE FROM dbo.Orders;
GO

-----------------------------------------------------------------------
------------------------------------ 9.Sample Upload Data --> STAGING ONLY
-----------------------------------------------------------------------

INSERT INTO dbo.StagingUpload
(OrderId, ParcelCode, PurchaseCertificateNumber, ParcelPrice, ShipDate)
VALUES
-- Valid certificate ex
('ORD100', 'CODE1', 'PC100', 400, '2026-03-20'),
('ORD100', 'CODE2', 'PC100', 300, '2026-03-20'),
('ORD100', 'CODE3', 'PC100', 200, '2026-03-20'),
('ORD100', 'CODE4', 'PC100', 100, '2026-03-20');

---------------------------------------------------

--Invalid certificate #rows NOT 4.
--('ORD200', 'CODE1', 'PC200', 250, '2026-03-21'),
--('ORD200', 'CODE2', 'PC200', 350, '2026-03-21'),
--('ORD200', 'CODE3', 'PC200', 150, '2026-03-21');

-------------------------------------------------------

-- Rows with NULL values 
--(NULL,    'CODE1', 'PC300', 100, '2026-03-22'), 
--('ORD300', NULL,   'PC300', 200, '2026-03-22'),   
--('ORD300', 'CODE3', NULL,    300, '2026-03-22'), 
--('ORD300', 'CODE4', 'PC300', NULL, '2026-03-22'),
--('ORD300', 'CODE5', 'PC300', 150, '2026-03-22');

-----------------------------------------------------
-- TC#1
--(NULL, 'CODE1', 'PC100', 100, '2026-03-20');
---------------------------------------------------------
--TC#2
--('ORD100', 'CODE1', NULL, 100, '2026-03-20');
--------------------------------------------------------------
--TC#3
---('ORD100', NULL, 'PC100', 100, '2026-03-20');
------------------------------------------------------------
--TC#4
--('ORD100', 'CODE1', 'PC100', NULL, '2026-03-20'),
--('ORD100', 'CODE2', 'PC100', 200,  '2026-03-20'),
--('ORD100', 'CODE3', 'PC100', 300,  '2026-03-20'),
--('ORD00', 'CODE4', 'PC100', 400,  '2026-03-20');
---------------------------------------------------------------
--TC5
--('ORD100', 'CODE1', 'PC100', 400, '2026-03-20'),
--('ORD100', 'CODE2', 'PC100', 300, '2026-03-20'),
--('ORD100', 'CODE3', 'PC100', 200, '2026-03-20'),
--('ORD100', 'CODE4', 'PC100', 100, '2026-03-20');
----------------------------------------------------------------
--TC6
--('ORD200', 'CODE1', 'PC200', 250, '2026-03-21'),
--('ORD200', 'CODE2', 'PC200', 350, '2026-03-21'),
--('ORD200', 'CODE3', 'PC200', 150, '2026-03-21');
---------------------------------------------------------------------
--TC7
--('ORD100', 'CODE1', 'PC100', 400, '2026-03-20'),
--('ORD100', 'CODE2', 'PC100', 300, '2026-03-20'),
--('ORD100', 'CODE3', 'PC100', 200, '2026-03-20'),
--('ORD100', 'CODE4', 'PC100', 100, '2026-03-20'),
--('ORD100', 'CODE5', 'PC100', 100, '2026-03-20');
---------------------------------------------------------------
---TC8
--('ORD100', 'CODE1', 'PC100', 100, '2026-03-20'),
--('ORD100', 'CODE2', 'PC100', 200, '2026-03-20'),
--('ORD100', 'CODE3', 'PC100', 300, '2026-03-20'),
--('ORD100', 'CODE4', 'PC100', 400, '2026-03-20');

--********--
--('ORD100', 'CODE1', 'PC100', 150, '2026-03-25'),
--('ORD100', 'CODE2', 'PC100', 250, '2026-03-25'),
--('ORD100', 'CODE3', 'PC100', 350, '2026-03-25'),
--('ORD100', 'CODE4', 'PC100', 450, '2026-03-25');
---------------------------------------------------
--TC9
--('ORD100', 'CODE1', 'PC100', 100, '2026-03-20'),
--('ORD100', 'CODE2', 'PC100', 200, '2026-03-20'),
--('ORD100', 'CODE3', 'PC100', 300, '2026-03-20'),
--('ORD100', 'CODE4', 'PC100', 400, '2026-03-20');
--*****************---
--('ORD100', 'CODE1', 'PC100', 100, '2026-03-22'),
--('ORD100', 'CODE2', 'PC100', 999, '2026-03-22'),
--('ORD100', 'CODE4', 'PC100', 400, '2026-03-22'),
--('ORD100', 'CODE5', 'PC100', 500, '2026-03-22');
------------------------------------------------------
--TC10
-- ('ORD100', 'CODE1', 'PC100', 100, '2026-03-20'),
--('ORD100', 'CODE2', 'PC100', 200, '2026-03-20'),
---('ORD100', 'CODE3', 'PC100', 300, '2026-03-20'),
--('ORD100', 'CODE4', 'PC100', 400, '2026-03-20'),

-- Invalid certificate\
--('ORD200', 'CODE1', 'PC200', 100, '2026-03-20'),
--('ORD200', 'CODE2', 'PC200', 200, '2026-03-20'),
--('ORD200', 'CODE3', 'PC200', 300, '2026-03-20');
GO

-----------------------------------------------------------------------
--------------------------------- 10.RUN
-----------------------------------------------------------------------

EXEC dbo.ProcessPurchaseCertificates;
EXEC dbo.ProcessParcels;
EXEC dbo.ExportPurchaseCertificates;
GO

-----------------------------------------------------------------------
--------------------------------- 11.View results
-----------------------------------------------------------------------

SELECT * FROM dbo.AdminPageSettings;
SELECT * FROM dbo.Orders;
SELECT * FROM dbo.PurchaseCertificates;
SELECT * FROM dbo.Parcels;
SELECT * FROM dbo.StagingUpload;
 
GO