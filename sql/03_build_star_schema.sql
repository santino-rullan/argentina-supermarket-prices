/* =====================================================================
   03 - Move the staged snapshot into the star schema
   Run after 02. Safe to re-run: the snapshot's fact rows are replaced.
   ===================================================================== */

USE SepaPrices;
GO
SET NOCOUNT ON;

/* ---------- 1. Typed, cleaned copy of the prices (computed once) ---------- */

DROP TABLE IF EXISTS #p;

SELECT
    TRY_CAST(snapshot_date AS DATE)  AS snapshot_date,
    TRY_CAST(id_comercio AS INT)     AS retailer_id,
    TRY_CAST(id_bandera AS INT)      AS banner_id,
    LTRIM(RTRIM(id_sucursal))        AS store_id,
    -- Barcodes lose their leading zeros so the same product matches across chains.
    -- Internal codes are only unique inside one retailer, so they get its id as prefix.
    CASE
        WHEN productos_ean = '1' AND PATINDEX('%[^0]%', id_producto) > 0
            THEN SUBSTRING(id_producto, PATINDEX('%[^0]%', id_producto), 80)
        ELSE CONCAT('R', id_comercio, '-', id_producto)
    END                              AS product_code,
    CASE WHEN productos_ean = '1' THEN 1 ELSE 0 END AS is_ean,
    LEFT(productos_descripcion, 300) AS description,
    LEFT(productos_marca, 100)       AS brand,
    TRY_CAST(productos_cantidad_presentacion AS DECIMAL(18,3))  AS size_qty,
    LOWER(LEFT(productos_unidad_medida_presentacion, 20))       AS size_unit,
    TRY_CAST(productos_precio_lista AS DECIMAL(14,2))           AS list_price,
    TRY_CAST(productos_precio_referencia AS DECIMAL(14,2))      AS reference_price,
    TRY_CAST(productos_cantidad_referencia AS DECIMAL(14,3))    AS reference_qty,
    LOWER(LEFT(productos_unidad_medida_referencia, 20))         AS reference_unit,
    TRY_CAST(NULLIF(productos_precio_unitario_promo1, '') AS DECIMAL(14,2)) AS promo1_price,
    NULLIF(LEFT(productos_leyenda_promo1, 300), '')             AS promo1_text,
    TRY_CAST(NULLIF(productos_precio_unitario_promo2, '') AS DECIMAL(14,2)) AS promo2_price,
    NULLIF(LEFT(productos_leyenda_promo2, 300), '')             AS promo2_text
INTO #p
FROM stg.prices;

/* ---------- 2. Chains ---------- */

;WITH src AS (
    SELECT
        TRY_CAST(id_comercio AS INT) AS retailer_id,
        TRY_CAST(id_bandera AS INT)  AS banner_id,
        comercio_bandera_nombre      AS chain_name,
        comercio_razon_social        AS company_name,
        comercio_cuit                AS tax_id,
        ROW_NUMBER() OVER (PARTITION BY TRY_CAST(id_comercio AS INT), TRY_CAST(id_bandera AS INT)
                           ORDER BY (SELECT NULL)) AS rn
    FROM stg.stores_chains
    WHERE TRY_CAST(id_comercio AS INT) IS NOT NULL AND TRY_CAST(id_bandera AS INT) IS NOT NULL
)
MERGE dw.dim_chain AS t
USING (SELECT * FROM src WHERE rn = 1) AS s
    ON t.retailer_id = s.retailer_id AND t.banner_id = s.banner_id
WHEN MATCHED THEN UPDATE SET
    t.chain_name = s.chain_name, t.company_name = s.company_name, t.tax_id = s.tax_id
WHEN NOT MATCHED THEN
    INSERT (retailer_id, banner_id, chain_name, company_name, tax_id)
    VALUES (s.retailer_id, s.banner_id, s.chain_name, s.company_name, s.tax_id);

/* ---------- 3. Stores ---------- */

;WITH src AS (
    SELECT
        TRY_CAST(s.id_comercio AS INT) AS retailer_id,
        TRY_CAST(s.id_bandera AS INT)  AS banner_id,
        LTRIM(RTRIM(s.id_sucursal))    AS store_id,
        s.sucursales_nombre            AS store_name,
        s.sucursales_tipo              AS store_type,
        s.sucursales_calle             AS street,
        s.sucursales_numero            AS street_number,
        NULLIF(s.sucursales_barrio, '')        AS neighborhood,
        s.sucursales_localidad         AS city,
        s.sucursales_codigo_postal     AS postal_code,
        UPPER(LTRIM(RTRIM(s.sucursales_provincia))) AS province_code,
        TRY_CAST(s.sucursales_latitud  AS DECIMAL(9,6)) AS latitude,
        TRY_CAST(s.sucursales_longitud AS DECIMAL(9,6)) AS longitude,
        ROW_NUMBER() OVER (PARTITION BY TRY_CAST(s.id_comercio AS INT), TRY_CAST(s.id_bandera AS INT),
                                        LTRIM(RTRIM(s.id_sucursal))
                           ORDER BY (SELECT NULL)) AS rn
    FROM stg.stores AS s
    WHERE TRY_CAST(s.id_comercio AS INT) IS NOT NULL AND TRY_CAST(s.id_bandera AS INT) IS NOT NULL
)
MERGE dw.dim_store AS t
USING (
    SELECT src.*, c.chain_key
    FROM src
    LEFT JOIN dw.dim_chain AS c
        ON c.retailer_id = src.retailer_id AND c.banner_id = src.banner_id
    WHERE src.rn = 1
) AS s
    ON t.retailer_id = s.retailer_id AND t.banner_id = s.banner_id AND t.store_id = s.store_id
WHEN MATCHED THEN UPDATE SET
    t.chain_key = s.chain_key, t.store_name = s.store_name, t.store_type = s.store_type,
    t.street = s.street, t.street_number = s.street_number, t.neighborhood = s.neighborhood,
    t.city = s.city, t.postal_code = s.postal_code, t.province_code = s.province_code,
    t.latitude = s.latitude, t.longitude = s.longitude
WHEN NOT MATCHED THEN
    INSERT (retailer_id, banner_id, store_id, chain_key, store_name, store_type, street, street_number,
            neighborhood, city, postal_code, province_code, latitude, longitude)
    VALUES (s.retailer_id, s.banner_id, s.store_id, s.chain_key, s.store_name, s.store_type, s.street,
            s.street_number, s.neighborhood, s.city, s.postal_code, s.province_code, s.latitude, s.longitude);

/* ---------- 4. Products: one row per product, most common description wins ---------- */

;WITH counted AS (
    SELECT product_code, is_ean, description, brand, size_qty, size_unit, COUNT(*) AS n
    FROM #p
    WHERE product_code IS NOT NULL
    GROUP BY product_code, is_ean, description, brand, size_qty, size_unit
),
ranked AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY product_code ORDER BY n DESC, description) AS rn
    FROM counted
)
MERGE dw.dim_product AS t
USING (SELECT * FROM ranked WHERE rn = 1) AS s
    ON t.product_code = s.product_code
WHEN MATCHED THEN UPDATE SET
    t.description = s.description, t.brand = s.brand, t.size_qty = s.size_qty, t.size_unit = s.size_unit
WHEN NOT MATCHED THEN
    INSERT (product_code, is_ean, description, brand, size_qty, size_unit)
    VALUES (s.product_code, s.is_ean, s.description, s.brand, s.size_qty, s.size_unit);

/* ---------- 5. Dates ---------- */

MERGE dw.dim_date AS t
USING (SELECT DISTINCT snapshot_date FROM #p WHERE snapshot_date IS NOT NULL) AS s
    ON t.date_key = s.snapshot_date
WHEN NOT MATCHED THEN
    INSERT (date_key, [year], [month], month_name, iso_week, day_of_week)
    VALUES (s.snapshot_date, YEAR(s.snapshot_date), MONTH(s.snapshot_date),
            FORMAT(s.snapshot_date, 'MMMM', 'en-US'), DATEPART(ISO_WEEK, s.snapshot_date),
            FORMAT(s.snapshot_date, 'dddd', 'en-US'));

/* ---------- 6. Fact: replace this snapshot, one row per store-product ---------- */

DELETE FROM dw.fact_price
WHERE snapshot_date IN (SELECT DISTINCT snapshot_date FROM #p);

;WITH joined AS (
    SELECT
        p.snapshot_date, st.store_key, pr.product_key, p.list_price, p.reference_price,
        p.reference_qty, p.reference_unit, p.promo1_price, p.promo1_text, p.promo2_price, p.promo2_text,
        ROW_NUMBER() OVER (PARTITION BY p.snapshot_date, st.store_key, pr.product_key
                           ORDER BY p.list_price) AS rn
    FROM #p AS p
    JOIN dw.dim_store   AS st ON st.retailer_id = p.retailer_id
                             AND st.banner_id   = p.banner_id
                             AND st.store_id    = p.store_id
    JOIN dw.dim_product AS pr ON pr.product_code = p.product_code
    WHERE p.snapshot_date IS NOT NULL
      AND p.list_price > 0
)
INSERT INTO dw.fact_price WITH (TABLOCK)
    (snapshot_date, store_key, product_key, list_price, reference_price, reference_qty,
     reference_unit, promo1_price, promo1_text, promo2_price, promo2_text)
SELECT snapshot_date, store_key, product_key, list_price, reference_price, reference_qty,
       reference_unit, promo1_price, promo1_text, promo2_price, promo2_text
FROM joined
WHERE rn = 1;

/* ---------- 7. Summary ---------- */

SELECT
    (SELECT COUNT(*) FROM dw.dim_chain)   AS chains,
    (SELECT COUNT(*) FROM dw.dim_store)   AS stores,
    (SELECT COUNT(*) FROM dw.dim_product) AS products,
    (SELECT COUNT(*) FROM dw.fact_price
      WHERE snapshot_date IN (SELECT DISTINCT snapshot_date FROM #p)) AS fact_rows_this_snapshot;

DROP TABLE #p;
GO
