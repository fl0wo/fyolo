#!/usr/bin/env python3
"""Daily fyolo download / active-user stats from Cloudflare + Telegram digest.

Pulls yesterday's numbers for downloads.fyolo.sh straight from Cloudflare's
GraphQL Analytics API (no third-party analytics, no in-app SDK), appends them to
a CSV ledger, and posts a digest to Telegram.

Why a CSV ledger: Cloudflare's free plan only retains ~7 days of zone analytics,
so "total downloads since launch" can't be fetched retroactively — it has to be
accumulated one day at a time from the day tracking starts.

Env:
  CF_ANALYTICS_TOKEN  Cloudflare API token with Zone > Analytics > Read on fyolo.sh
  CF_ZONE_ID          fyolo.sh zone id
  TELEGRAM_BOT_TOKEN  bot token from @BotFather   (optional; skips send if unset)
  TELEGRAM_CHAT_ID    chat id to post to          (optional; skips send if unset)

Usage:
  python3 scripts/download_stats.py --csv path/to/downloads.csv [--date YYYY-MM-DD]
"""
import argparse
import csv
import datetime as dt
import json
import os
import sys
import urllib.request

HOST = "downloads.fyolo.sh"
GRAPHQL = "https://api.cloudflare.com/client/v4/graphql"


def gql(token, zone, since, until, extra_filter, fields, limit=1):
    """One httpRequestsAdaptiveGroups query over a <=1d window."""
    filt = {
        "datetime_geq": since,
        "datetime_leq": until,
        "clientRequestHTTPHost": HOST,
        **extra_filter,
    }
    query = (
        "query($zone:String!,$f:filter_zones_httpRequestsAdaptiveGroups){"
        "viewer{zones(filter:{zoneTag:$zone}){"
        f"httpRequestsAdaptiveGroups(limit:{limit},filter:$f){{{fields}}}"
        "}}}"
    )
    body = json.dumps({"query": query, "variables": {"zone": zone, "f": filt}}).encode()
    req = urllib.request.Request(
        GRAPHQL,
        body,
        {"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.load(r)
    if d.get("errors"):
        raise RuntimeError(d["errors"][0]["message"])
    return d["data"]["viewer"]["zones"][0]["httpRequestsAdaptiveGroups"]


def day_bounds(date):
    since = f"{date}T00:00:00Z"
    until = (dt.datetime.strptime(date, "%Y-%m-%d") + dt.timedelta(days=1)).strftime(
        "%Y-%m-%dT00:00:00Z"
    )
    return since, until


def unique_ips(token, zone, since, until):
    rows = gql(
        token, zone, since, until,
        {"clientRequestPath": "/appcast.xml"},
        "dimensions{clientIP}",
        limit=10000,
    )
    return {r["dimensions"]["clientIP"] for r in rows}


def collect(token, zone, date):
    since, until = day_bounds(date)

    dmg_rows = gql(
        token, zone, since, until,
        {"clientRequestPath_like": "%fyolo.dmg", "edgeResponseStatus": 200},
        "count",
    )
    dmg = dmg_rows[0]["count"] if dmg_rows else 0

    appcast_rows = gql(
        token, zone, since, until,
        {"clientRequestPath": "/appcast.xml"},
        "count",
    )
    checks = appcast_rows[0]["count"] if appcast_rows else 0

    day_ips = unique_ips(token, zone, since, until)

    # Weekly-active: union of unique appcast IPs over the retained window,
    # anchored on the target date. Older days may fall past retention -> skip.
    week = set(day_ips)
    base = dt.datetime.strptime(date, "%Y-%m-%d")
    for back in range(1, 7):
        d0 = (base - dt.timedelta(days=back)).strftime("%Y-%m-%d")
        s, u = day_bounds(d0)
        try:
            week |= unique_ips(token, zone, s, u)
        except Exception:
            break

    return {
        "date": date,
        "dmg_downloads": dmg,
        "active_macs_day": len(day_ips),
        "active_macs_week": len(week),
        "update_checks": checks,
    }


FIELDS = ["date", "dmg_downloads", "active_macs_day", "active_macs_week", "update_checks"]


def upsert_csv(path, row):
    rows = []
    if os.path.exists(path):
        with open(path) as f:
            rows = [r for r in csv.DictReader(f) if r.get("date") != row["date"]]
    rows.append({k: row[k] for k in FIELDS})
    rows.sort(key=lambda r: r["date"])
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        w.writeheader()
        w.writerows(rows)
    total = sum(int(r["dmg_downloads"]) for r in rows)
    days = len(rows)
    return total, days


def send_telegram(token, chat_id, text):
    body = json.dumps(
        {"chat_id": chat_id, "text": text, "parse_mode": "Markdown",
         "disable_web_page_preview": True}
    ).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{token}/sendMessage",
        body, {"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.load(r)
    if not d.get("ok"):
        raise RuntimeError(f"telegram: {d}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--csv", required=True)
    ap.add_argument("--date", help="UTC day to report (default: yesterday)")
    args = ap.parse_args()

    token = os.environ.get("CF_ANALYTICS_TOKEN")
    zone = os.environ.get("CF_ZONE_ID")
    if not token or not zone:
        sys.exit("CF_ANALYTICS_TOKEN and CF_ZONE_ID are required")

    date = args.date or (dt.datetime.utcnow().date() - dt.timedelta(days=1)).strftime(
        "%Y-%m-%d"
    )

    row = collect(token, zone, date)
    total, days = upsert_csv(args.csv, row)

    msg = (
        f"📊 *fyolo* — {date} (UTC)\n"
        f"⬇️ Downloads: *{row['dmg_downloads']}*  ·  总计 *{total}* ({days}d)\n"
        f"👥 Active Macs: *{row['active_macs_day']}* today · "
        f"*{row['active_macs_week']}* this week\n"
        f"🔄 Update checks: {row['update_checks']}"
    )
    print(msg)

    bot = os.environ.get("TELEGRAM_BOT_TOKEN")
    chat = os.environ.get("TELEGRAM_CHAT_ID")
    if bot and chat:
        send_telegram(bot, chat, msg)
        print("-> sent to Telegram")
    else:
        print("-> Telegram skipped (no TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID)")


if __name__ == "__main__":
    main()
