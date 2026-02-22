#!/usr/bin/env python3
import csv
import hashlib
import os
import sys
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from typing import List, Dict, Iterable

import psycopg2

# ---- CONFIG ----

REQUIRED_COLS = {"date", "serial_number", "model"}
MASTER_TABLE = "bb.drive_stats_raw"

# Set to 1 to print every rejected row (missing required fields)
REJECT_LOG = os.environ.get("BB_REJECT_LOG", "0") == "1"

# Master columns in the *order you want to COPY*
MASTER_COLS: List[str] = [
    "source_file",
    "ingested_at",
    "date",
    "serial_number",
    "model",
    "capacity_bytes",
    "failure",
    "datacenter",
    "cluster_id",
    "vault_id",
    "pod_id",
    "pod_slot_num",
    "is_legacy_format",

    # SMART columns...
    "smart_1_normalized", "smart_1_raw",
    "smart_2_normalized", "smart_2_raw",
    "smart_3_normalized", "smart_3_raw",
    "smart_4_normalized", "smart_4_raw",
    "smart_5_normalized", "smart_5_raw",
    "smart_7_normalized", "smart_7_raw",
    "smart_8_normalized", "smart_8_raw",
    "smart_9_normalized", "smart_9_raw",
    "smart_10_normalized", "smart_10_raw",
    "smart_11_normalized", "smart_11_raw",
    "smart_12_normalized", "smart_12_raw",
    "smart_13_normalized", "smart_13_raw",
    "smart_15_normalized", "smart_15_raw",
    "smart_16_normalized", "smart_16_raw",
    "smart_17_normalized", "smart_17_raw",
    "smart_18_normalized", "smart_18_raw",
    "smart_22_normalized", "smart_22_raw",
    "smart_23_normalized", "smart_23_raw",
    "smart_24_normalized", "smart_24_raw",
    "smart_27_normalized", "smart_27_raw",
    "smart_71_normalized", "smart_71_raw",
    "smart_82_normalized", "smart_82_raw",
    "smart_90_normalized", "smart_90_raw",
    "smart_160_normalized", "smart_160_raw",
    "smart_161_normalized", "smart_161_raw",
    "smart_163_normalized", "smart_163_raw",
    "smart_164_normalized", "smart_164_raw",
    "smart_165_normalized", "smart_165_raw",
    "smart_166_normalized", "smart_166_raw",
    "smart_167_normalized", "smart_167_raw",
    "smart_168_normalized", "smart_168_raw",
    "smart_169_normalized", "smart_169_raw",
    "smart_170_normalized", "smart_170_raw",
    "smart_171_normalized", "smart_171_raw",
    "smart_172_normalized", "smart_172_raw",
    "smart_173_normalized", "smart_173_raw",
    "smart_174_normalized", "smart_174_raw",
    "smart_175_normalized", "smart_175_raw",
    "smart_176_normalized", "smart_176_raw",
    "smart_177_normalized", "smart_177_raw",
    "smart_178_normalized", "smart_178_raw",
    "smart_179_normalized", "smart_179_raw",
    "smart_180_normalized", "smart_180_raw",
    "smart_181_normalized", "smart_181_raw",
    "smart_182_normalized", "smart_182_raw",
    "smart_183_normalized", "smart_183_raw",
    "smart_184_normalized", "smart_184_raw",
    "smart_187_normalized", "smart_187_raw",
    "smart_188_normalized", "smart_188_raw",
    "smart_189_normalized", "smart_189_raw",
    "smart_190_normalized", "smart_190_raw",
    "smart_191_normalized", "smart_191_raw",
    "smart_192_normalized", "smart_192_raw",
    "smart_193_normalized", "smart_193_raw",
    "smart_194_normalized", "smart_194_raw",
    "smart_195_normalized", "smart_195_raw",
    "smart_196_normalized", "smart_196_raw",
    "smart_197_normalized", "smart_197_raw",
    "smart_198_normalized", "smart_198_raw",
    "smart_199_normalized", "smart_199_raw",
    "smart_200_normalized", "smart_200_raw",
    "smart_201_normalized", "smart_201_raw",
    "smart_202_normalized", "smart_202_raw",
    "smart_206_normalized", "smart_206_raw",
    "smart_210_normalized", "smart_210_raw",
    # Backblaze typos preserved:
    "smart_211_normailized", "smart_211_raw",
    "smart_212_normailized", "smart_212_raw",
    "smart_218_normalized", "smart_218_raw",
    "smart_220_normalized", "smart_220_raw",
    "smart_222_normalized", "smart_222_raw",
    "smart_223_normalized", "smart_223_raw",
    "smart_224_normalized", "smart_224_raw",
    "smart_225_normalized", "smart_225_raw",
    "smart_226_normalized", "smart_226_raw",
    "smart_230_normalized", "smart_230_raw",
    "smart_231_normalized", "smart_231_raw",
    "smart_232_normalized", "smart_232_raw",
    "smart_233_normalized", "smart_233_raw",
    "smart_234_normalized", "smart_234_raw",
    "smart_235_normalized", "smart_235_raw",
    "smart_240_normalized", "smart_240_raw",
    "smart_241_normalized", "smart_241_raw",
    "smart_242_normalized", "smart_242_raw",
    "smart_244_normalized", "smart_244_raw",
    "smart_245_normalized", "smart_245_raw",
    "smart_246_normalized", "smart_246_raw",
    "smart_247_normalized", "smart_247_raw",
    "smart_248_normalized", "smart_248_raw",
    "smart_250_normalized", "smart_250_raw",
    "smart_251_normalized", "smart_251_raw",
    "smart_252_normalized", "smart_252_raw",
    "smart_254_normalized", "smart_254_raw",
    "smart_255_normalized", "smart_255_raw",
]

# Columns that need coercion
BOOL_COLS = {"failure", "is_legacy_format"}

# ---- DB HELPERS ----

def ensure_ingest_log(cur) -> None:
    cur.execute("""
        CREATE TABLE IF NOT EXISTS bb.ingest_log (
            path text PRIMARY KEY,
            file_size bigint,
            sha256 text,
            ingested_at timestamptz NOT NULL DEFAULT now(),
            rows_loaded bigint,
            rows_skipped bigint
        );
    """)
    # If the table already existed from older runs, ensure the column exists
    cur.execute("ALTER TABLE bb.ingest_log ADD COLUMN IF NOT EXISTS rows_skipped bigint;")

def already_loaded(cur, path: str, size: int, sha: str) -> bool:
    cur.execute(
        "SELECT 1 FROM bb.ingest_log WHERE path=%s AND file_size=%s AND sha256=%s",
        (path, size, sha),
    )
    return cur.fetchone() is not None

def mark_loaded(cur, path: str, size: int, sha: str, rows: int, skipped: int = 0) -> None:
    cur.execute("""
        INSERT INTO bb.ingest_log(path, file_size, sha256, rows_loaded, rows_skipped)
        VALUES (%s,%s,%s,%s,%s)
        ON CONFLICT (path) DO UPDATE
          SET file_size=EXCLUDED.file_size,
              sha256=EXCLUDED.sha256,
              ingested_at=now(),
              rows_loaded=EXCLUDED.rows_loaded,
              rows_skipped=EXCLUDED.rows_skipped;
    """, (path, size, sha, rows, skipped))

# ---- CSV COERCION ----

def is_int_like_column(col: str) -> bool:
    # capacity_bytes + all smart columns (raw + normalized + misspellings)
    return col == "capacity_bytes" or col.startswith("smart_")

def coerce_bool(val: str) -> str:
    """Return Postgres-friendly boolean literals ('t'/'f') or '' for NULL."""
    if val is None:
        return ""
    v = val.strip()
    if v == "":
        return ""
    if v in ("1", "t", "T", "true", "TRUE", "True", "yes", "YES", "y", "Y", "on", "ON"):
        return "t"
    if v in ("0", "f", "F", "false", "FALSE", "False", "no", "NO", "n", "N", "off", "OFF"):
        return "f"
    return ""  # unexpected junk -> NULL

def coerce_int(val: str) -> str:
    """Return canonical integer string or '' for NULL. Handles scientific notation."""
    if val is None:
        return ""
    v = val.strip()
    if v == "":
        return ""

    # Remove thousands separators if they appear
    if "," in v:
        v = v.replace(",", "")

    # Fast path: plain integer
    if v.isdigit() or (v[0] == "-" and v[1:].isdigit()):
        return v

    # Scientific / decimal / other numeric forms
    try:
        d = Decimal(v)
        # Round to nearest integer to avoid weird fractional artifacts
        d = d.to_integral_value(rounding=ROUND_HALF_UP)
        return str(int(d))
    except (InvalidOperation, ValueError, OverflowError):
        return ""

def normalize_row(
    row: Dict[str, str],
    header_set: set,
    source_file: str,
    ingested_at_iso: str,
    master_cols: List[str]
) -> List[str]:
    out: List[str] = []
    for col in master_cols:
        if col == "source_file":
            out.append(source_file)
            continue
        if col == "ingested_at":
            out.append(ingested_at_iso)
            continue

        if col in header_set:
            val = row.get(col, "")
            if col in BOOL_COLS:
                out.append(coerce_bool(val))
            elif is_int_like_column(col):
                out.append(coerce_int(val))
            else:
                out.append(val if val is not None else "")
        else:
            # Column not present in this file's schema -> NULL/default
            if col == "is_legacy_format":
                out.append("f")  # treat missing as false
            else:
                out.append("")
    return out

# ---- STREAMING COPY ----

class CopyCSVStream:
    """
    File-like object that yields CSV rows in master column order, without loading everything in memory.
    psycopg2 COPY expects .read(size) interface.
    """
    def __init__(self, csv_path: Path, master_cols: List[str], source_file_tag: str):
        self.skipped = 0
        self._line_no = 1  # approximate; DictReader starts after header
        self.csv_path = csv_path
        self.master_cols = master_cols
        self.source_file_tag = source_file_tag

        self._fh = open(csv_path, newline="", encoding="utf-8")
        self._reader = csv.DictReader(self._fh)
        self._header_set = set(self._reader.fieldnames or [])

        self._buf = ""
        self.rows = 0
        self._ingested_at_iso = datetime.now(timezone.utc).isoformat()

        import io
        self._row_io = io.StringIO()
        self._writer = csv.writer(self._row_io, lineterminator="\n")

    def close(self):
        try:
            self._fh.close()
        except Exception:
            pass

    def read(self, size: int = 8192) -> str:
        while len(self._buf) < size:
            try:
                row = next(self._reader)
                self._line_no += 1

                # Skip rows missing required fields
                missing = []
                for k in REQUIRED_COLS:
                    v = row.get(k, "")
                    if v is None or v.strip() == "":
                        missing.append(k)

                if missing:
                    self.skipped += 1
                    if REJECT_LOG:
                        print(f"reject {self.csv_path}:{self._line_no} missing {missing}", file=sys.stderr)
                    continue

            except StopIteration:
                break

            out_row = normalize_row(
                row=row,
                header_set=self._header_set,
                source_file=self.source_file_tag,
                ingested_at_iso=self._ingested_at_iso,
                master_cols=self.master_cols
            )

            # Serialize row
            self._row_io.seek(0)
            self._row_io.truncate(0)
            self._writer.writerow(out_row)
            self._buf += self._row_io.getvalue()
            self.rows += 1

        chunk, self._buf = self._buf[:size], self._buf[size:]
        return chunk

# ---- UTIL ----

def sha256_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(chunk_size)
            if not b:
                break
            h.update(b)
    return h.hexdigest()

def iter_csv_files(root: Path) -> Iterable[Path]:
    for p in sorted(root.rglob("*")):
        if p.suffix.lower() != ".csv":
            continue
        if p.is_file():
            yield p

# ---- MAIN ----

def main():
    if len(sys.argv) < 3:
        print("usage: bb_load.py <postgres_dsn> <csv_dir> [source_tag_prefix]", file=sys.stderr)
        sys.exit(2)

    dsn = sys.argv[1]
    csv_dir = Path(sys.argv[2])
    tag_prefix = sys.argv[3] if len(sys.argv) > 3 else ""

    conn = psycopg2.connect(dsn)
    conn.autocommit = False

    with conn, conn.cursor() as cur:
        ensure_ingest_log(cur)

    total_files = 0
    total_rows = 0

    for csv_path in iter_csv_files(csv_dir):
        total_files += 1
        size = csv_path.stat().st_size
        sha = sha256_file(csv_path)
        rel = str(csv_path)

        source_tag = f"{tag_prefix}{csv_path.parent.name}"  # e.g. "data_Q1_2016"
        source_tag = source_tag[:255]

        with conn, conn.cursor() as cur:
            if already_loaded(cur, rel, size, sha):
                print(f"skip {rel} (already loaded)")
                continue

        stream = CopyCSVStream(csv_path, MASTER_COLS, source_tag)

        copy_sql = f"""
            COPY {MASTER_TABLE} ({",".join(MASTER_COLS)})
            FROM STDIN WITH (FORMAT csv, NULL '', QUOTE '\"', ESCAPE '\"');
        """

        try:
            with conn, conn.cursor() as cur:
                cur.copy_expert(copy_sql, stream)
                mark_loaded(cur, rel, size, sha, stream.rows, stream.skipped)
            conn.commit()
            total_rows += stream.rows
            if stream.skipped:
                print(f"loaded {rel}: {stream.rows} rows (skipped {stream.skipped})")
            else:
                print(f"loaded {rel}: {stream.rows} rows")
        except Exception as e:
            conn.rollback()
            print(f"ERROR loading {rel}: {e}", file=sys.stderr)
            raise
        finally:
            stream.close()

    print(f"done. files={total_files} rows={total_rows}")

if __name__ == "__main__":
    main()
