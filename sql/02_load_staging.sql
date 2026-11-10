/* =====================================================================
   02 - Load one consolidated snapshot into staging
   Run once per snapshot, after scripts/01_consolidate_sepa.py.

   1. Change @folder to the full path of data/processed/<date>/
      (it must end with a backslash).
   2. The SQL Server service must be able to read that folder.
      If BULK INSERT says "access denied", give the folder read
      permission to the SQL Server service account, or move the
      files to a folder like C:\sepa\.
   Requires SQL Server 2017 or later (FORMAT = 'CSV').
   ===================================================================== */

USE SepaPrices;
GO

DECLARE @folder NVARCHAR(400) = N'C:\proyectos\argentina-supermarket-prices\data\processed\2026-11-06\';

TRUNCATE TABLE stg.stores_chains;
TRUNCATE TABLE stg.stores;
TRUNCATE TABLE stg.prices;

DECLARE @options NVARCHAR(400) = N'
    WITH (
        FORMAT = ''CSV'',
        FIELDQUOTE = ''"'',
        FIELDTERMINATOR = ''|'',
        ROWTERMINATOR = ''0x0a'',
        FIRSTROW = 2,
        CODEPAGE = ''65001'',
        TABLOCK
    );';

DECLARE @sql NVARCHAR(MAX);

SET @sql = N'BULK INSERT stg.stores_chains FROM ''' + @folder + N'stores_chains.csv''' + @options;
EXEC sp_executesql @sql;

SET @sql = N'BULK INSERT stg.stores FROM ''' + @folder + N'stores.csv''' + @options;
EXEC sp_executesql @sql;

SET @sql = N'BULK INSERT stg.prices FROM ''' + @folder + N'prices.csv''' + @options;
EXEC sp_executesql @sql;

SELECT 'stg.stores_chains' AS table_name, COUNT(*) AS rows_loaded FROM stg.stores_chains
UNION ALL SELECT 'stg.stores', COUNT(*) FROM stg.stores
UNION ALL SELECT 'stg.prices', COUNT(*) FROM stg.prices;
GO
