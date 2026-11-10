# Argentina Supermarket Price Intelligence

> **Work in progress.** Data pipeline ready; analysis and dashboard coming next.

How much does the same product cost across supermarket chains and provinces in Argentina, one of the world's highest-inflation economies? This project turns the official daily price feed of Argentine retailers (SEPA, about 12 million price records per day) into a SQL Server star schema and a Power BI dashboard.

**Resumen en español:** análisis de precios de supermercados de toda Argentina a partir de la base oficial SEPA (Precios Claros). Compara cadenas y provincias para el mismo producto, arma una canasta para ver dónde conviene comprar y mide la profundidad de las promociones.

## Business questions

1. **Price dispersion:** how much does the price of the same product (same barcode) vary across chains and provinces?
2. **Basket:** which chain is cheapest for a standard basket, in Rosario and nationwide?
3. **Promotions:** how frequent and how deep are promotions by chain?
4. **Price evolution** (v2): which products rise fastest, using weekly snapshots collected by this project.

## Data

- **Source:** [Precios Claros - Base SEPA](https://datos.produccion.gob.ar/dataset/6f47ec76-d1ce-4e34-a7e1-621fe9b1d0b5), published by Argentina's Undersecretariat for Consumer Protection. License CC BY 4.0.
- Retailers must publish their prices every day. Each download holds one folder per retailer with three pipe-delimited files: chains, stores and prices.
- The portal only keeps the last seven days, so the historical series is built by downloading one snapshot per week.

## Pipeline

```
SEPA daily zip ──► 01_consolidate_sepa.py ──► stg (raw text) ──► dw (star schema) ──► Power BI
                    drops footers, merges       02_load_staging     03_build_star_schema
                    all retailers               (BULK INSERT)       04_data_quality_checks
```

**Star schema (`dw`):** `fact_price` (one row per store, product and snapshot date, stored as a clustered columnstore) with `dim_store`, `dim_chain`, `dim_product`, `dim_province` and `dim_date`.

## How to reproduce

1. Download a daily zip from the SEPA portal and unzip it into `data/raw/`.
2. Consolidate it:
   ```
   python scripts/01_consolidate_sepa.py data/raw/sepa_viernes/2026-11-06
   ```
3. In SQL Server (2017 or later), run `sql/01_create_database.sql` once.
4. For each snapshot, set the folder path in `sql/02_load_staging.sql`, then run `02`, `03` and `04`.

## Tools

SQL Server (T-SQL) · Python · Power BI (DAX, Power Query) · Git

## Author

**Santino Rullán** · [LinkedIn](https://www.linkedin.com/in/TU-USUARIO) · santinorullan06@gmail.com
