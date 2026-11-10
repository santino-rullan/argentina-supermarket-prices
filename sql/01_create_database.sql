/* =====================================================================
   01 - Create database, schemas, staging tables and star schema
   Run ONCE.
   stg = raw text exactly as published by SEPA (one load at a time)
   dw  = clean star schema that accumulates every weekly snapshot
   ===================================================================== */

IF DB_ID('SepaPrices') IS NULL
    CREATE DATABASE SepaPrices;
GO
USE SepaPrices;
GO
IF SCHEMA_ID('stg') IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('dw')  IS NULL EXEC('CREATE SCHEMA dw');
GO

/* ---------- Staging: all text, same column order as the consolidated files ---------- */

DROP TABLE IF EXISTS stg.stores_chains;
CREATE TABLE stg.stores_chains (
    snapshot_date                  NVARCHAR(20),
    source_folder                  NVARCHAR(200),
    id_comercio                    NVARCHAR(50),
    id_bandera                     NVARCHAR(50),
    comercio_cuit                  NVARCHAR(50),
    comercio_razon_social          NVARCHAR(300),
    comercio_bandera_nombre        NVARCHAR(300),
    comercio_bandera_url           NVARCHAR(500),
    comercio_ultima_actualizacion  NVARCHAR(100),
    comercio_version_sepa          NVARCHAR(20)
);

DROP TABLE IF EXISTS stg.stores;
CREATE TABLE stg.stores (
    snapshot_date                          NVARCHAR(20),
    source_folder                          NVARCHAR(200),
    id_comercio                            NVARCHAR(50),
    id_bandera                             NVARCHAR(50),
    id_sucursal                            NVARCHAR(50),
    sucursales_nombre                      NVARCHAR(300),
    sucursales_tipo                        NVARCHAR(50),
    sucursales_calle                       NVARCHAR(300),
    sucursales_numero                      NVARCHAR(50),
    sucursales_latitud                     NVARCHAR(50),
    sucursales_longitud                    NVARCHAR(50),
    sucursales_observaciones               NVARCHAR(1000),
    sucursales_barrio                      NVARCHAR(200),
    sucursales_codigo_postal               NVARCHAR(20),
    sucursales_localidad                   NVARCHAR(200),
    sucursales_provincia                   NVARCHAR(50),
    sucursales_lunes_horario_atencion      NVARCHAR(100),
    sucursales_martes_horario_atencion     NVARCHAR(100),
    sucursales_miercoles_horario_atencion  NVARCHAR(100),
    sucursales_jueves_horario_atencion     NVARCHAR(100),
    sucursales_viernes_horario_atencion    NVARCHAR(100),
    sucursales_sabado_horario_atencion     NVARCHAR(100),
    sucursales_domingo_horario_atencion    NVARCHAR(100)
);

DROP TABLE IF EXISTS stg.prices;
CREATE TABLE stg.prices (
    snapshot_date                         NVARCHAR(20),
    source_folder                         NVARCHAR(200),
    id_comercio                           NVARCHAR(50),
    id_bandera                            NVARCHAR(50),
    id_sucursal                           NVARCHAR(50),
    id_producto                           NVARCHAR(50),
    productos_ean                         NVARCHAR(10),
    productos_descripcion                 NVARCHAR(1000),
    productos_cantidad_presentacion       NVARCHAR(50),
    productos_unidad_medida_presentacion  NVARCHAR(50),
    productos_marca                       NVARCHAR(300),
    productos_precio_lista                NVARCHAR(50),
    productos_precio_referencia           NVARCHAR(50),
    productos_cantidad_referencia         NVARCHAR(50),
    productos_unidad_medida_referencia    NVARCHAR(50),
    productos_precio_unitario_promo1      NVARCHAR(50),
    productos_leyenda_promo1              NVARCHAR(2000),
    productos_precio_unitario_promo2      NVARCHAR(50),
    productos_leyenda_promo2              NVARCHAR(2000)
);
GO

/* ---------- Star schema ---------- */

IF OBJECT_ID('dw.dim_province') IS NULL
BEGIN
    CREATE TABLE dw.dim_province (
        province_code  NVARCHAR(10)  NOT NULL PRIMARY KEY,   -- ISO 3166-2
        province_name  NVARCHAR(100) NOT NULL,
        region         NVARCHAR(50)  NOT NULL
    );
    INSERT INTO dw.dim_province (province_code, province_name, region) VALUES
    (N'AR-C', N'Ciudad Autónoma de Buenos Aires', N'AMBA'),
    (N'AR-B', N'Buenos Aires',            N'Pampeana'),
    (N'AR-X', N'Córdoba',                 N'Pampeana'),
    (N'AR-S', N'Santa Fe',                N'Pampeana'),
    (N'AR-E', N'Entre Ríos',              N'Pampeana'),
    (N'AR-L', N'La Pampa',                N'Pampeana'),
    (N'AR-M', N'Mendoza',                 N'Cuyo'),
    (N'AR-J', N'San Juan',                N'Cuyo'),
    (N'AR-D', N'San Luis',                N'Cuyo'),
    (N'AR-F', N'La Rioja',                N'NOA'),
    (N'AR-K', N'Catamarca',               N'NOA'),
    (N'AR-T', N'Tucumán',                 N'NOA'),
    (N'AR-G', N'Santiago del Estero',     N'NOA'),
    (N'AR-A', N'Salta',                   N'NOA'),
    (N'AR-Y', N'Jujuy',                   N'NOA'),
    (N'AR-H', N'Chaco',                   N'NEA'),
    (N'AR-N', N'Misiones',                N'NEA'),
    (N'AR-W', N'Corrientes',              N'NEA'),
    (N'AR-P', N'Formosa',                 N'NEA'),
    (N'AR-Q', N'Neuquén',                 N'Patagonia'),
    (N'AR-R', N'Río Negro',               N'Patagonia'),
    (N'AR-U', N'Chubut',                  N'Patagonia'),
    (N'AR-Z', N'Santa Cruz',              N'Patagonia'),
    (N'AR-V', N'Tierra del Fuego',        N'Patagonia');
END;

IF OBJECT_ID('dw.dim_chain') IS NULL
CREATE TABLE dw.dim_chain (
    chain_key     INT IDENTITY(1,1) PRIMARY KEY,
    retailer_id   INT           NOT NULL,   -- id_comercio
    banner_id     INT           NOT NULL,   -- id_bandera
    chain_name    NVARCHAR(300) NULL,       -- comercio_bandera_nombre
    company_name  NVARCHAR(300) NULL,       -- comercio_razon_social
    tax_id        NVARCHAR(50)  NULL,       -- comercio_cuit
    CONSTRAINT uq_dim_chain UNIQUE (retailer_id, banner_id)
);

IF OBJECT_ID('dw.dim_store') IS NULL
CREATE TABLE dw.dim_store (
    store_key      INT IDENTITY(1,1) PRIMARY KEY,
    retailer_id    INT           NOT NULL,
    banner_id      INT           NOT NULL,
    store_id       NVARCHAR(50)  NOT NULL,   -- id_sucursal
    chain_key      INT           NULL REFERENCES dw.dim_chain(chain_key),
    store_name     NVARCHAR(300) NULL,
    store_type     NVARCHAR(50)  NULL,       -- Hipermercado, Supermercado, Autoservicio, Tradicional, Web
    street         NVARCHAR(300) NULL,
    street_number  NVARCHAR(50)  NULL,
    neighborhood   NVARCHAR(200) NULL,
    city           NVARCHAR(200) NULL,
    postal_code    NVARCHAR(20)  NULL,
    province_code  NVARCHAR(10)  NULL,
    latitude       DECIMAL(9,6)  NULL,
    longitude      DECIMAL(9,6)  NULL,
    CONSTRAINT uq_dim_store UNIQUE (retailer_id, banner_id, store_id)
);

IF OBJECT_ID('dw.dim_product') IS NULL
CREATE TABLE dw.dim_product (
    product_key   INT IDENTITY(1,1) PRIMARY KEY,
    product_code  NVARCHAR(80)  NOT NULL,   -- barcode without leading zeros, or R<retailer>-<internal code>
    is_ean        BIT           NOT NULL,   -- 1 = barcode, comparable across chains
    description   NVARCHAR(300) NULL,
    brand         NVARCHAR(100) NULL,
    size_qty      DECIMAL(18,3) NULL,
    size_unit     NVARCHAR(20)  NULL,
    category      NVARCHAR(100) NULL,       -- filled later: SEPA files do not include a category
    CONSTRAINT uq_dim_product UNIQUE (product_code)
);

IF OBJECT_ID('dw.dim_date') IS NULL
CREATE TABLE dw.dim_date (
    date_key      DATE         NOT NULL PRIMARY KEY,
    [year]        INT          NOT NULL,
    [month]       INT          NOT NULL,
    month_name    NVARCHAR(20) NOT NULL,
    iso_week      INT          NOT NULL,
    day_of_week   NVARCHAR(20) NOT NULL
);

IF OBJECT_ID('dw.fact_price') IS NULL
BEGIN
    CREATE TABLE dw.fact_price (
        snapshot_date    DATE          NOT NULL,
        store_key        INT           NOT NULL,
        product_key      INT           NOT NULL,
        list_price       DECIMAL(14,2) NOT NULL,
        reference_price  DECIMAL(14,2) NULL,
        reference_qty    DECIMAL(14,3) NULL,
        reference_unit   NVARCHAR(20)  NULL,
        promo1_price     DECIMAL(14,2) NULL,   -- general promotion (for everyone)
        promo1_text      NVARCHAR(300) NULL,
        promo2_price     DECIMAL(14,2) NULL,   -- special promotion (cards, loyalty, segments)
        promo2_text      NVARCHAR(300) NULL
    );
    -- Columnstore: compresses millions of rows and makes aggregations fast
    CREATE CLUSTERED COLUMNSTORE INDEX cci_fact_price ON dw.fact_price;
END;
GO
