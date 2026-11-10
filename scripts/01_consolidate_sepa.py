"""
Consolidate one daily SEPA snapshot into three clean, pipe-delimited files
ready for BULK INSERT into SQL Server.

The SEPA download contains one folder (or .zip) per retailer, each with
comercio.csv, sucursales.csv and productos.csv. Every file ends with a blank
line plus an "Última actualización: ..." footer that must be dropped.

Columns are matched BY NAME using each file's own header, so a retailer that
publishes columns in a different order, or with an extra or missing column,
is still loaded correctly. Output always follows the official column order.

Usage:
    python scripts/01_consolidate_sepa.py data/raw/sepa_viernes/2026-11-06

Output (in data/processed/<date>/):
    stores_chains.csv, stores.csv, prices.csv,
    load_report.txt, rejected_rows_sample.txt (only if rows were rejected)
"""

import csv
import io
import re
import sys
import unicodedata
import zipfile
from collections import Counter, defaultdict
from pathlib import Path

csv.field_size_limit(10_000_000)

# Official column order (Anexo II, Res. 678/2020)
SCHEMA = {
    "comercio.csv": ("stores_chains.csv", [
        "id_comercio", "id_bandera", "comercio_cuit", "comercio_razon_social",
        "comercio_bandera_nombre", "comercio_bandera_url",
        "comercio_ultima_actualizacion", "comercio_version_sepa",
    ]),
    "sucursales.csv": ("stores.csv", [
        "id_comercio", "id_bandera", "id_sucursal", "sucursales_nombre", "sucursales_tipo",
        "sucursales_calle", "sucursales_numero", "sucursales_latitud", "sucursales_longitud",
        "sucursales_observaciones", "sucursales_barrio", "sucursales_codigo_postal",
        "sucursales_localidad", "sucursales_provincia",
        "sucursales_lunes_horario_atencion", "sucursales_martes_horario_atencion",
        "sucursales_miercoles_horario_atencion", "sucursales_jueves_horario_atencion",
        "sucursales_viernes_horario_atencion", "sucursales_sabado_horario_atencion",
        "sucursales_domingo_horario_atencion",
    ]),
    "productos.csv": ("prices.csv", [
        "id_comercio", "id_bandera", "id_sucursal", "id_producto", "productos_ean",
        "productos_descripcion", "productos_cantidad_presentacion",
        "productos_unidad_medida_presentacion", "productos_marca", "productos_precio_lista",
        "productos_precio_referencia", "productos_cantidad_referencia",
        "productos_unidad_medida_referencia", "productos_precio_unitario_promo1",
        "productos_leyenda_promo1", "productos_precio_unitario_promo2",
        "productos_leyenda_promo2",
    ]),
}
SAMPLES_PER_SOURCE = 5
MAX_FRAGMENTS = 25  # a record split into more lines than this is rejected, not repaired


def normalize(text: str) -> str:
    """Lowercase, trim and remove accents: 'Última Actualización' -> 'ultima actualizacion'."""
    text = unicodedata.normalize("NFKD", text.strip().lower())
    return "".join(c for c in text if not unicodedata.combining(c))


def is_blank(row) -> bool:
    """True for empty lines, including lines holding only invisible characters (BOM, zero-width space)."""
    text = "".join(row)
    return all(ch.isspace() or unicodedata.category(ch) in ("Cf", "Cc") for ch in text)


def is_footer(row) -> bool:
    first = row[0] if row else ""
    # "ltima actualizaci" also catches broken encodings of "Última actualización"
    return "ltima actualizaci" in first.lower() or normalize(first).startswith("ultima actualizacion")


def iter_zip(zip_path: Path, retailer: str, problems: list):
    """Yield the SEPA CSVs inside a zip. Broken or empty zips are logged and skipped."""
    try:
        with zipfile.ZipFile(zip_path) as zf:
            members = [m for m in zf.namelist() if Path(m).name in SCHEMA]
            if not members:
                problems.append(f"{zip_path.name}: zip without SEPA files")
            for member in members:
                with zf.open(member) as raw:
                    text = io.TextIOWrapper(raw, encoding="utf-8-sig", errors="replace", newline="")
                    yield retailer, Path(member).name, text
    except zipfile.BadZipFile:
        size = zip_path.stat().st_size
        problems.append(f"{zip_path.name}: not a valid zip ({size:,} bytes), skipped")


def iter_sources(snapshot_dir: Path, problems: list):
    """Yield (retailer_name, file_name, text_stream) for every CSV of every retailer."""
    for entry in sorted(snapshot_dir.iterdir()):
        if entry.is_dir():
            found = False
            for name in SCHEMA:
                for path in sorted(entry.rglob(name)):
                    found = True
                    with open(path, encoding="utf-8-sig", errors="replace", newline="") as fh:
                        yield entry.name, name, fh
            if not found:
                zips = sorted(entry.rglob("*.zip"))
                for zip_path in zips:
                    yield from iter_zip(zip_path, entry.name, problems)
                if not zips:
                    problems.append(f"{entry.name}: folder without SEPA files, skipped")
        elif entry.suffix.lower() == ".zip":
            yield from iter_zip(entry, entry.stem, problems)


def main():
    if len(sys.argv) != 2:
        sys.exit("Usage: python scripts/01_consolidate_sepa.py <snapshot folder>")

    snapshot_dir = Path(sys.argv[1])
    match = re.search(r"\d{4}-\d{2}-\d{2}", str(snapshot_dir))
    if not match:
        sys.exit("Could not infer the snapshot date from the folder name (expected YYYY-MM-DD).")
    snapshot_date = match.group(0)

    out_dir = Path("data/processed") / snapshot_date
    out_dir.mkdir(parents=True, exist_ok=True)

    handles, writers = {}, {}
    for in_name, (out_name, columns) in SCHEMA.items():
        handles[out_name] = open(out_dir / out_name, "w", encoding="utf-8", newline="")
        writers[out_name] = csv.writer(handles[out_name], delimiter="|", lineterminator="\n")
        writers[out_name].writerow(["snapshot_date", "source_folder"] + columns)

    rows_ok, rows_bad, rows_repaired = Counter(), Counter(), Counter()
    retailers, problems, header_notes = set(), [], []
    samples = defaultdict(list)

    try:
        for retailer, in_name, stream in iter_sources(snapshot_dir, problems):
            retailers.add(retailer)
            out_name, columns = SCHEMA[in_name]
            reader = csv.reader(stream, delimiter="|", quotechar='"')
            header, positions = None, None
            pending, pending_parts, pending_line = None, 0, 0

            def reject(row, line_no):
                rows_bad[(out_name, retailer)] += 1
                if len(samples[(out_name, retailer)]) < SAMPLES_PER_SOURCE:
                    samples[(out_name, retailer)].append(
                        f"line {line_no}: expected {len(header)} columns, got {len(row)} -> "
                        + "|".join(row)[:500]
                    )

            for row in reader:
                line_no = reader.line_num
                if not row or is_blank(row):
                    continue
                if is_footer(row):
                    break
                if header is None:
                    header = [normalize(c) for c in row]
                    missing = [c for c in columns if c not in header]
                    extra = [c for c in header if c not in columns]
                    if missing or extra or header != columns:
                        header_notes.append(
                            f"{retailer} / {in_name}: "
                            + (f"missing {missing} " if missing else "")
                            + (f"extra {extra} " if extra else "")
                            + ("(different column order)" if not missing and not extra else "")
                        )
                    positions = [header.index(c) if c in header else None for c in columns]
                    continue
                # Repair records split by stray line breaks inside a field:
                # glue each fragment to the previous one until the column count matches.
                if pending is not None:
                    row = pending[:-1] + [pending[-1] + row[0]] + row[1:]
                    pending_parts += 1
                else:
                    pending_line, pending_parts = line_no, 1
                if len(row) < len(header) and pending_parts < MAX_FRAGMENTS:
                    pending = row
                    continue
                pending = None
                if len(row) != len(header):
                    reject(row, pending_line)
                    continue
                if pending_parts > 1:
                    rows_repaired[(out_name, retailer)] += 1
                writers[out_name].writerow(
                    [snapshot_date, retailer]
                    + [row[i].strip() if i is not None else "" for i in positions]
                )
                rows_ok[out_name] += 1

            if pending is not None:          # file ended in the middle of a split record
                reject(pending, pending_line)
    finally:
        for fh in handles.values():
            fh.close()

    lines = [f"Snapshot date: {snapshot_date}", f"Retailer folders: {len(retailers)}", ""]
    for out_name, _ in SCHEMA.values():
        lines.append(f"{out_name}: {rows_ok[out_name]:,} rows loaded")
    if problems:
        lines += ["", "Sources skipped:"] + [f"  {p}" for p in problems]
    if header_notes:
        lines += ["", "Headers different from the official spec (loaded by column name):"]
        lines += [f"  {n}" for n in header_notes]
    if rows_repaired:
        lines += ["", "Records repaired (split across lines by stray line breaks):"]
        lines += [f"  {o} | {r}: {n:,}" for (o, r), n in sorted(rows_repaired.items())]
    if rows_bad:
        lines += ["", "Rows skipped (wrong number of columns, examples in rejected_rows_sample.txt):"]
        lines += [f"  {o} | {r}: {n:,}" for (o, r), n in sorted(rows_bad.items())]
        sample_lines = []
        for (o, r), rows in sorted(samples.items()):
            sample_lines.append(f"== {o} | {r}")
            sample_lines += rows
            sample_lines.append("")
        (out_dir / "rejected_rows_sample.txt").write_text("\n".join(sample_lines), encoding="utf-8")

    report = "\n".join(lines)
    (out_dir / "load_report.txt").write_text(report, encoding="utf-8")
    print(report)
    print(f"\nFiles written to {out_dir.resolve()}")


if __name__ == "__main__":
    main()
