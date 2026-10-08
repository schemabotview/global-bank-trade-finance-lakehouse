"""Synthetic trade-finance data generator for the Azure SQL source.

Two reproducible "days":

  day 1  initial load (parties, banks, FX, ~20k LCs and their lifecycle events)
  day 2  deltas for the next business date: rating downgrades, new parties and LCs,
         amendments, presentations, settlements, expiries, replayed events

Both days are derived from the same seed, so day 2 re-simulates day 1 in memory and
emits only the changes. Deliberately dirty rows are injected for the data-quality
checks (bad currency, negative amount, null party name, expiry before issue,
replayed source_event_ref).

Targets:
  --target csv   writes CSV files to --out-dir (no database needed; good for dry runs)
  --target sql   inserts/updates rows in Azure SQL (needs pyodbc + ODBC Driver 18);
                 password is read from the SQL_PASSWORD environment variable.
"""
from __future__ import annotations

import argparse
import csv
import os
import random
from datetime import date, datetime, timedelta
from pathlib import Path

RATINGS = ["AAA", "AA+", "AA", "AA-", "A+", "A", "A-", "BBB+", "BBB", "BBB-", "BB+", "BB", "B", "CCC"]
RATING_WEIGHTS = [1, 2, 4, 6, 9, 12, 12, 14, 12, 10, 7, 5, 4, 2]
CURRENCIES = {  # code: (name, USD per unit, weight)
    "USD": ("US Dollar", 1.0, 30),
    "EUR": ("Euro", 1.08, 22),
    "GBP": ("Pound Sterling", 1.27, 14),
    "JPY": ("Japanese Yen", 0.0064, 6),
    "CNY": ("Chinese Yuan", 0.138, 8),
    "INR": ("Indian Rupee", 0.012, 5),
    "AED": ("UAE Dirham", 0.2723, 4),
    "SGD": ("Singapore Dollar", 0.74, 4),
    "CHF": ("Swiss Franc", 1.12, 3),
    "AUD": ("Australian Dollar", 0.66, 2),
    "CAD": ("Canadian Dollar", 0.73, 1),
    "HKD": ("Hong Kong Dollar", 0.128, 1),
}
COUNTRIES = ["GB", "US", "DE", "FR", "IN", "CN", "AE", "SG", "JP", "NL", "CH", "BR", "ZA", "AU", "TR"]
PAYMENT_TERMS = ["SIGHT", "USANCE_30", "USANCE_60", "USANCE_90"]
PARTY_TYPES = ["CORPORATE", "CORPORATE", "SME", "FI"]
SEGMENTS = ["Trading", "Metals", "Textiles", "Energy", "Agri", "Logistics", "Machinery", "Chemicals", "Foods", "Electronics"]
SUFFIXES = ["Ltd", "GmbH", "Pte", "LLC", "SA", "Inc", "Co", "Group", "Holdings", "Exports"]

N_BANKS = 40
N_PARTIES = 2000
N_LCS = 20000

# table -> (primary key columns, ordered columns)
TABLES: dict[str, tuple[list[str], list[str]]] = {
    "BANK": (["bank_id"], ["bank_id", "bic", "bank_name", "country"]),
    "CURRENCY_FX": (["currency_code"], ["currency_code", "currency_name", "rate_to_usd", "rate_date"]),
    "PARTY": (["party_id"], ["party_id", "party_name", "country", "party_type", "risk_rating", "created_at", "updated_at"]),
    "LETTER_OF_CREDIT": (["lc_id"], ["lc_id", "lc_number", "issuing_bank_id", "amount", "currency", "issue_date",
                                     "expiry_date", "payment_terms", "status", "created_at", "updated_at"]),
    "LC_PARTY_ROLE": (["lc_id", "party_id", "role"], ["lc_id", "party_id", "role", "valid_from", "valid_to", "updated_at"]),
    "LC_AMENDMENT": (["amendment_id"], ["amendment_id", "lc_id", "version_no", "effective_at", "amount_delta",
                                        "expiry_change", "approval_status", "updated_at"]),
    "LC_EXPOSURE_EVENT": (["event_id"], ["event_id", "lc_id", "exposure_amount", "currency", "exposure_type",
                                         "lifecycle_status", "occurred_at", "source_event_ref"]),
}
INSERT_ORDER = ["BANK", "CURRENCY_FX", "PARTY", "LETTER_OF_CREDIT", "LC_PARTY_ROLE", "LC_AMENDMENT", "LC_EXPOSURE_EVENT"]


def at(d: date, rng: random.Random, start_hour: int = 8, end_hour: int = 18) -> datetime:
    """Random timestamp (ms precision) on date d between the given hours."""
    secs = rng.randint(start_hour * 3600, end_hour * 3600 - 1)
    return datetime(d.year, d.month, d.day) + timedelta(seconds=secs, milliseconds=rng.randint(0, 999))


class Delta:
    """Rows to insert / update per table."""

    def __init__(self) -> None:
        self.insert: dict[str, list[dict]] = {t: [] for t in TABLES}
        self.update: dict[str, list[dict]] = {t: [] for t in TABLES}


class World:
    def __init__(self, seed: int, day1: date) -> None:
        self.rng = random.Random(seed)
        self.day1 = day1
        self.parties: dict[int, dict] = {}
        self.lcs: dict[int, dict] = {}
        self.next_amendment_id = 1
        self.next_event_id = 1
        self.next_lc_id = 1_000_001
        self.next_party_id = 10_001
        self.pending_events: list[dict] = []  # events awaiting id assignment (sorted by time on flush)
        self.dirty_counter = 0

    # ------------------------------------------------------------------ helpers
    def _currency(self) -> str:
        codes = list(CURRENCIES)
        return self.rng.choices(codes, weights=[CURRENCIES[c][2] for c in codes])[0]

    def _event(self, lc: dict, ts: datetime, status: str, contingent: float | None, funded: float | None) -> None:
        """Queue exposure events. A None amount means 'no event for that exposure type'."""
        for etype, amount in (("CONTINGENT", contingent), ("FUNDED", funded)):
            if amount is None:
                continue
            ref = f"EVT-{lc['lc_id']}-{etype[0]}-{ts:%Y%m%d%H%M%S%f}"
            self.pending_events.append({
                "lc_id": lc["lc_id"], "exposure_amount": round(amount, 2), "currency": lc["currency"],
                "exposure_type": etype, "lifecycle_status": status, "occurred_at": ts, "source_event_ref": ref,
            })
        lc["last_ts"] = max(lc["last_ts"], ts)
        lc["status"] = status

    def _flush_events(self, delta: Delta) -> None:
        """Assign monotonically increasing event ids in time order; inject replayed duplicates."""
        events = sorted(self.pending_events, key=lambda e: (e["occurred_at"], e["lc_id"], e["exposure_type"]))
        for e in events:
            e["event_id"] = self.next_event_id
            self.next_event_id += 1
            delta.insert["LC_EXPOSURE_EVENT"].append(e)
        self.pending_events = []

    def _replay_events(self, delta: Delta, count: int) -> None:
        """Dirty data: the same business event published twice under a new event_id."""
        pool = delta.insert["LC_EXPOSURE_EVENT"][:]
        for e in self.rng.sample(pool, min(count, len(pool))):
            dup = dict(e)
            dup["event_id"] = self.next_event_id
            self.next_event_id += 1
            delta.insert["LC_EXPOSURE_EVENT"].append(dup)

    def _new_party(self, created: date, delta: Delta, null_name: bool = False) -> int:
        pid = self.next_party_id
        self.next_party_id += 1
        ts = at(created, self.rng)
        name = None if null_name else f"{self.rng.choice(['North','Blue','Atlas','Orion','Crest','Vega','Summit','Harbour','Delta','Pioneer'])} {self.rng.choice(SEGMENTS)} {self.rng.choice(SUFFIXES)} {pid}"
        row = {"party_id": pid, "party_name": name, "country": self.rng.choice(COUNTRIES),
               "party_type": self.rng.choice(PARTY_TYPES),
               "risk_rating": self.rng.choices(RATINGS, weights=RATING_WEIGHTS)[0],
               "created_at": ts, "updated_at": ts}
        self.parties[pid] = row
        delta.insert["PARTY"].append(row)
        return pid

    def _new_lc(self, issue: date, delta: Delta, today: date) -> dict:
        r = self.rng
        lc_id = self.next_lc_id
        self.next_lc_id += 1
        ccy = self._currency()
        amount = min(max(round(r.lognormvariate(13, 1.0), 2), 50_000), 50_000_000)
        ts = at(issue, r)
        lc = {"lc_id": lc_id, "lc_number": f"LC{issue:%y%m}{lc_id}", "issuing_bank_id": r.randint(1, N_BANKS),
              "amount": amount, "currency": ccy, "issue_date": issue,
              "expiry_date": issue + timedelta(days=r.randint(60, 365)),
              "payment_terms": r.choice(PAYMENT_TERMS), "status": "ISSUED", "created_at": ts, "updated_at": ts,
              # simulation state (not persisted)
              "current": amount, "last_ts": ts, "presented": False, "settled": False, "expired": False,
              "n_amend": 0}
        self.lcs[lc_id] = lc
        delta.insert["LETTER_OF_CREDIT"].append(lc)
        applicant, beneficiary = r.sample(list(self.parties), 2)
        for pid, role in ((applicant, "APPLICANT"), (beneficiary, "BENEFICIARY")):
            delta.insert["LC_PARTY_ROLE"].append({"lc_id": lc_id, "party_id": pid, "role": role,
                                                  "valid_from": issue, "valid_to": None, "updated_at": ts})
        self._event(lc, ts, "ISSUED", amount, None)
        return lc

    def _amend(self, lc: dict, day: date, delta: Delta) -> None:
        r = self.rng
        ts = at(day, r, 9, 17)
        lc["n_amend"] += 1
        delta_amt = round(lc["amount"] * r.uniform(-0.2, 0.3), 2)
        status = r.choices(["APPROVED", "PENDING", "REJECTED"], weights=[85, 10, 5])[0]
        expiry_change = lc["expiry_date"] + timedelta(days=30) if r.random() < 0.3 and status == "APPROVED" else None
        delta.insert["LC_AMENDMENT"].append({
            "amendment_id": self.next_amendment_id, "lc_id": lc["lc_id"], "version_no": lc["n_amend"] + 1,
            "effective_at": ts, "amount_delta": delta_amt, "expiry_change": expiry_change,
            "approval_status": status, "updated_at": ts})
        self.next_amendment_id += 1
        if status == "APPROVED":
            lc["current"] = round(lc["current"] + delta_amt, 2)
            if expiry_change:
                lc["expiry_date"] = expiry_change
            self._event(lc, ts, "AMENDED", lc["current"], None)
        else:
            lc["last_ts"] = max(lc["last_ts"], ts)

    def _present(self, lc: dict, day: date) -> None:
        ts = at(day, self.rng, 10, 16)
        lc["presented"] = True
        self._event(lc, ts, "PRESENTED", 0.0, lc["current"])  # contingent -> funded

    def _settle(self, lc: dict, day: date) -> None:
        ts = at(day, self.rng, 11, 17)
        lc["settled"] = True
        self._event(lc, ts, "SETTLED", None, 0.0)

    def _expire(self, lc: dict, day: date) -> None:
        ts = at(day, self.rng, 17, 18)
        lc["expired"] = True
        self._event(lc, ts, "EXPIRED", 0.0, None)

    def _emit_lc_updates(self, delta: Delta, touched: set[int]) -> None:
        for lc_id in sorted(touched):
            lc = self.lcs[lc_id]
            lc["updated_at"] = lc["last_ts"]
            delta.update["LETTER_OF_CREDIT"].append(lc)

    # ------------------------------------------------------------------ day 1
    def day_one(self) -> Delta:
        r, d1 = self.rng, self.day1
        delta = Delta()

        for i in range(1, N_BANKS + 1):
            delta.insert["BANK"].append({
                "bank_id": i, "bic": f"BK{i:02d}{r.choice(COUNTRIES)}2L", "bank_name": f"Synthetic Bank {i:02d}",
                "country": r.choice(COUNTRIES)})
        for code, (name, rate, _) in CURRENCIES.items():
            delta.insert["CURRENCY_FX"].append({"currency_code": code, "currency_name": name,
                                                "rate_to_usd": rate, "rate_date": d1})

        for _ in range(N_PARTIES):
            self._new_party(d1 - timedelta(days=r.randint(30, 1200)), delta)

        for _ in range(N_LCS):
            issue = d1 - timedelta(days=r.randint(0, 180))
            lc = self._new_lc(issue, delta, d1)
            horizon = min(lc["expiry_date"], d1)
            if issue < d1 and r.random() < 0.15:
                self._amend(lc, issue + timedelta(days=r.randint(1, max(1, (horizon - issue).days))), delta)
            last_day = lc["last_ts"].date()
            if (horizon - last_day).days >= 1 and r.random() < 0.35:
                pres_day = last_day + timedelta(days=r.randint(1, (horizon - last_day).days))
                self._present(lc, pres_day)
                if r.random() < 0.7:
                    settle_day = pres_day + timedelta(days=r.randint(2, 10))
                    if settle_day <= d1:
                        self._settle(lc, settle_day)
            if not lc["presented"] and lc["expiry_date"] <= d1:
                self._expire(lc, lc["expiry_date"])
            lc["updated_at"] = lc["last_ts"]

        self._inject_dirty(delta, parties=5, lcs=15, issue_day=d1)
        self._flush_events(delta)
        self._replay_events(delta, 20)
        return delta

    # ------------------------------------------------------------------ day 2
    def day_two(self, delta1: Delta) -> Delta:
        r, d2 = self.rng, self.day1 + timedelta(days=1)
        delta = Delta()
        touched: set[int] = set()

        # rating moves: mostly one-notch downgrades, a few upgrades
        for pid in r.sample(list(self.parties), 60):
            p = self.parties[pid]
            idx = RATINGS.index(p["risk_rating"])
            idx = min(idx + 1, len(RATINGS) - 1) if r.random() < 0.8 else max(idx - 1, 0)
            p["risk_rating"] = RATINGS[idx]
            p["updated_at"] = at(d2, r, 6, 9)
            delta.update["PARTY"].append(p)
        for _ in range(20):
            self._new_party(d2, delta)

        active = [lc for lc in self.lcs.values()
                  if not lc["settled"] and not lc["expired"]]
        open_unpresented = [lc for lc in active if not lc["presented"] and lc["expiry_date"] > d2]
        presented = [lc for lc in active if lc["presented"]]

        for lc in r.sample(open_unpresented, min(300, len(open_unpresented))):
            self._amend(lc, d2, delta)
            touched.add(lc["lc_id"])
        for lc in r.sample(open_unpresented, min(150, len(open_unpresented))):
            if not lc["presented"]:
                self._present(lc, d2)
                touched.add(lc["lc_id"])
        for lc in r.sample(presented, min(100, len(presented))):
            self._settle(lc, d2)
            touched.add(lc["lc_id"])
        for lc in active:
            if not lc["presented"] and not lc["settled"] and not lc["expired"] and lc["expiry_date"] <= d2:
                self._expire(lc, d2)
                touched.add(lc["lc_id"])

        for _ in range(500):
            self._new_lc(d2, delta, d2)
        new_ids = {lc["lc_id"] for lc in delta.insert["LETTER_OF_CREDIT"]}
        touched -= new_ids
        self._emit_lc_updates(delta, touched)

        self._inject_dirty(delta, parties=2, lcs=3, issue_day=d2)
        self._flush_events(delta)
        self._replay_events(delta, 30)
        return delta

    # ------------------------------------------------------------------ dirty data
    def _inject_dirty(self, delta: Delta, parties: int, lcs: int, issue_day: date) -> None:
        r = self.rng
        for _ in range(parties):
            self._new_party(issue_day, delta, null_name=True)
        kinds = ["bad_ccy", "neg_amount", "expiry_before_issue"]
        for i in range(lcs):
            lc = self._new_lc(issue_day, delta, issue_day)
            # these LCs keep their ISSUED event; the bad value is what the source holds
            kind = kinds[i % len(kinds)]
            if kind == "bad_ccy":
                lc["currency"] = "XXX"
            elif kind == "neg_amount":
                lc["amount"] = -abs(lc["amount"])
            else:
                lc["expiry_date"] = issue_day - timedelta(days=5)
            for e in self.pending_events:
                if e["lc_id"] == lc["lc_id"]:
                    e["currency"] = lc["currency"]
                    e["exposure_amount"] = lc["amount"] if kind == "neg_amount" else e["exposure_amount"]
            lc["expired"] = True  # keep dirty LCs out of later lifecycle simulation


# ---------------------------------------------------------------------- writers
def _fmt(v):
    if isinstance(v, datetime):
        return v.strftime("%Y-%m-%d %H:%M:%S.") + f"{v.microsecond // 1000:03d}"
    if isinstance(v, date):
        return v.isoformat()
    return v


def write_csv(delta: Delta, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    for table, (_, cols) in TABLES.items():
        for kind, rows in (("", delta.insert[table]), ("__updates", delta.update[table])):
            if not rows:
                continue
            with open(out_dir / f"{table}{kind}.csv", "w", newline="") as fh:
                w = csv.writer(fh)
                w.writerow(cols)
                for row in rows:
                    w.writerow([_fmt(row.get(c)) for c in cols])
    print(f"CSV written to {out_dir}")


def write_sql(delta: Delta, server: str, database: str, user: str) -> None:
    import pyodbc  # imported lazily so the csv target has no dependencies

    password = os.environ["SQL_PASSWORD"]
    conn = pyodbc.connect(
        f"DRIVER={{ODBC Driver 18 for SQL Server}};SERVER={server};DATABASE={database};"
        f"UID={user};PWD={password};Encrypt=yes;TrustServerCertificate=no", autocommit=False)
    cur = conn.cursor()
    cur.fast_executemany = True
    try:
        for table in INSERT_ORDER:
            pk, cols = TABLES[table]
            ins = delta.insert[table]
            if ins:
                sql = f"INSERT INTO tf.{table} ({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})"
                cur.executemany(sql, [[row.get(c) for c in cols] for row in ins])
                print(f"{table}: inserted {len(ins)}")
            upd = delta.update[table]
            if upd:
                sets = [c for c in cols if c not in pk]
                sql = f"UPDATE tf.{table} SET {', '.join(c + ' = ?' for c in sets)} WHERE {' AND '.join(c + ' = ?' for c in pk)}"
                cur.executemany(sql, [[row.get(c) for c in sets] + [row.get(c) for c in pk] for row in upd])
                print(f"{table}: updated {len(upd)}")
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--day", type=int, choices=[1, 2], required=True)
    ap.add_argument("--day1-date", default="2025-06-30", help="business date of day 1 (YYYY-MM-DD); day 2 is +1")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--target", choices=["csv", "sql"], default="csv")
    ap.add_argument("--out-dir", default="out")
    ap.add_argument("--server", help="e.g. sql-tradefin-dev-abc12.database.windows.net")
    ap.add_argument("--database", default="tradefin_source")
    ap.add_argument("--user", default="sqladmin")
    a = ap.parse_args()

    world = World(a.seed, date.fromisoformat(a.day1_date))
    d1 = world.day_one()
    delta = d1 if a.day == 1 else world.day_two(d1)

    for t in INSERT_ORDER:
        print(f"{t:20s} insert={len(delta.insert[t]):>7} update={len(delta.update[t]):>5}")
    if a.target == "csv":
        write_csv(delta, Path(a.out_dir) / f"day{a.day}")
    else:
        if not a.server:
            ap.error("--server is required for --target sql")
        write_sql(delta, a.server, a.database, a.user)


if __name__ == "__main__":
    main()
