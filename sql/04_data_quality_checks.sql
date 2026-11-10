/* =====================================================================
   04 - Data quality checks
   Run after 03. Share the results before starting the analysis:
   they decide which cleaning rules the project needs.
   ===================================================================== */

USE SepaPrices;
GO

-- 1. Rows that could not be typed (bad numbers or dates in the raw file)
SELECT
    SUM(CASE WHEN TRY_CAST(productos_precio_lista AS DECIMAL(14,2)) IS NULL THEN 1 ELSE 0 END) AS bad_list_price,
    SUM(CASE WHEN TRY_CAST(productos_precio_lista AS DECIMAL(14,2)) <= 0  THEN 1 ELSE 0 END) AS zero_or_negative_price,
    SUM(CASE WHEN TRY_CAST(id_comercio AS INT) IS NULL THEN 1 ELSE 0 END)                    AS bad_retailer_id,
    COUNT(*)                                                                                  AS total_rows
FROM stg.prices;

-- 2. Price rows whose store is missing from sucursales.csv (lost in the fact load)
SELECT TOP 20 p.id_comercio, p.id_bandera, COUNT(*) AS orphan_rows
FROM stg.prices AS p
LEFT JOIN dw.dim_store AS s
    ON s.retailer_id = TRY_CAST(p.id_comercio AS INT)
   AND s.banner_id   = TRY_CAST(p.id_bandera AS INT)
   AND s.store_id    = LTRIM(RTRIM(p.id_sucursal))
WHERE s.store_key IS NULL
GROUP BY p.id_comercio, p.id_bandera
ORDER BY orphan_rows DESC;

-- 3. Province codes that do not match the ISO list
SELECT s.province_code, COUNT(*) AS stores
FROM dw.dim_store AS s
LEFT JOIN dw.dim_province AS p ON p.province_code = s.province_code
WHERE p.province_code IS NULL
GROUP BY s.province_code
ORDER BY stores DESC;

-- 4. Size of each chain in the latest snapshot
DECLARE @last DATE = (SELECT MAX(snapshot_date) FROM dw.fact_price);
SELECT
    c.chain_name,
    COUNT(DISTINCT f.store_key)   AS stores,
    COUNT(DISTINCT f.product_key) AS products,
    COUNT(*)                      AS price_rows,
    CAST(100.0 * SUM(CASE WHEN f.promo1_price IS NOT NULL OR f.promo2_price IS NOT NULL THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,1)) AS pct_rows_with_promo
FROM dw.fact_price AS f
JOIN dw.dim_store AS s ON s.store_key = f.store_key
JOIN dw.dim_chain AS c ON c.chain_key = s.chain_key
WHERE f.snapshot_date = @last
GROUP BY c.chain_name
ORDER BY price_rows DESC;

-- 5. Share of rows with a real barcode (only those compare across chains)
SELECT
    pr.is_ean,
    COUNT(*) AS price_rows,
    CAST(100.0 * COUNT(*) / SUM(COUNT(*)) OVER () AS DECIMAL(5,1)) AS pct
FROM dw.fact_price AS f
JOIN dw.dim_product AS pr ON pr.product_key = f.product_key
WHERE f.snapshot_date = @last
GROUP BY pr.is_ean;

-- 6. Basket candidates: barcodes sold by the most chains
SELECT TOP 50
    pr.product_code,
    pr.description,
    pr.brand,
    COUNT(DISTINCT s.chain_key) AS chains_selling_it,
    COUNT(DISTINCT f.store_key) AS stores_selling_it,
    MIN(f.list_price)           AS min_price,
    MAX(f.list_price)           AS max_price
FROM dw.fact_price AS f
JOIN dw.dim_product AS pr ON pr.product_key = f.product_key
JOIN dw.dim_store   AS s  ON s.store_key = f.store_key
WHERE f.snapshot_date = @last
  AND pr.is_ean = 1
GROUP BY pr.product_code, pr.description, pr.brand
ORDER BY chains_selling_it DESC, stores_selling_it DESC;
GO
