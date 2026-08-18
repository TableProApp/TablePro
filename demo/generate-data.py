#!/usr/bin/env python3
"""Writes demo/data.sql, the rows every screenshot on tablepro.app is taken of.

Deterministic on purpose. A screenshot is a file people diff against the last
one, so the same checkout has to produce the same grid: no random draws, no
now(), no microseconds, and no timezone offset. The old hand-captured shots
carried `.961939+07`, which dated them and named the author's timezone.

Totals are computed, not invented: an order's total is the sum of its items, so
the order_summary and product_stats views hold up when a reader adds the column
up. Every string is short enough to render whole in its column, because a grid
full of `deliver…` sells nothing.
"""

from decimal import Decimal
from pathlib import Path

USERS = [
    ("Sarah Chen", "sarah@acmecorp.com", "enterprise", "US", "2026-01-12 09:14:00"),
    ("David Kim", "david@seoulstack.kr", "enterprise", "KR", "2026-01-19 11:02:00"),
    ("Anna Kowalski", "anna@warsawdata.pl", "pro", "PL", "2026-01-23 15:40:00"),
    ("Yuki Tanaka", "yuki@sakura.jp", "pro", "JP", "2026-02-02 08:25:00"),
    ("Olivia Brown", "olivia@cloudpeak.au", "team", "AU", "2026-02-08 22:10:00"),
    ("Elena Rodriguez", "elena@codigo.mx", "pro", "MX", "2026-02-11 17:33:00"),
    ("Nguyen Minh", "minh@techviet.vn", "team", "VN", "2026-02-15 10:05:00"),
    ("Amira Hassan", "amira@sandstorm.eg", "pro", "EG", "2026-02-19 13:47:00"),
    ("Liam O'Connor", "liam@emeralddb.ie", "pro", "IE", "2026-02-24 16:12:00"),
    ("Marta Silva", "marta@paulista.br", "team", "BR", "2026-03-01 12:00:00"),
    ("Tom Fischer", "tom@rheinquery.de", "enterprise", "DE", "2026-03-04 09:55:00"),
    ("Priya Nair", "priya@bangalore.in", "pro", "IN", "2026-03-09 07:30:00"),
    ("Hugo Martin", "hugo@seinelabs.fr", "team", "FR", "2026-03-13 14:20:00"),
    ("Sofia Rossi", "sofia@milanobyte.it", "pro", "IT", "2026-03-18 18:05:00"),
]

PRODUCTS = [
    ("TablePro Team License", "Software", "199.00", "2026-01-05 10:00:00"),
    ("TablePro Pro License", "Software", "79.00", "2026-01-05 10:00:00"),
    ("PostgreSQL Mastery", "Books", "49.99", "2026-01-06 10:00:00"),
    ("Intro to Database Design", "Courses", "69.00", "2026-01-06 10:00:00"),
    ("Redis In Action", "Books", "39.99", "2026-01-07 10:00:00"),
    ("SQL Performance Explained", "Books", "54.99", "2026-01-07 10:00:00"),
    ("Query Optimization Workshop", "Courses", "99.00", "2026-01-08 10:00:00"),
    ("Docker for Database Admins", "Books", "44.99", "2026-01-08 10:00:00"),
    ("Database Monitoring Dashboard", "Templates", "34.99", "2026-01-09 10:00:00"),
    ("Schema Documentation Generator", "Tools", "24.99", "2026-01-09 10:00:00"),
    ("Database Migration Toolkit", "Tools", "29.99", "2026-01-10 10:00:00"),
    ("SSH Key Manager", "Tools", "19.99", "2026-01-10 10:00:00"),
]

ADDRESSES = [
    ("123 Market St, San Francisco, CA 94105", "USD"),
    ("456 Broadway, New York, NY 10013", "USD"),
    ("789 Shibuya, Tokyo 150-0003", "JPY"),
    ("Av. Reforma 222, Mexico City", "USD"),
    ("321 MG Road, Bangalore 560001", "INR"),
    ("555 Gangnam-daero, Seoul", "USD"),
    ("42 Harbour St, Sydney NSW 2000", "AUD"),
    ("88 Nguyen Hue, Ho Chi Minh City", "USD"),
    ("10 O'Connell St, Dublin D01", "EUR"),
    ("15 Tahrir Square, Cairo", "USD"),
    ("ul. Marszałkowska 1, 00-624 Warsaw", "EUR"),
    ("777 Teheran-ro, Gangnam-gu, Seoul", "USD"),
    ("Rua Augusta 100, São Paulo, SP", "BRL"),
    ("Friedrichstraße 43, 10117 Berlin", "EUR"),
    ("2-1 Marunouchi, Chiyoda-ku, Tokyo", "JPY"),
    ("100 Linking Road, Bandra West, Mumbai", "INR"),
    ("12 Rue de Rivoli, 75001 Paris", "EUR"),
    ("Via Montenapoleone 8, 20121 Milan", "EUR"),
]

# Emoji on purpose. A grid of plain ASCII proves nothing about how the app
# stores or renders text; these are four byte characters in a VARCHAR.
NOTES = [
    None, "\U0001F381 Gift wrap please", None, "\U0001F9FE Include invoice", None,
    "\U0001F501 Second order", None, None, "\u2764\uFE0F Thanks for the great app!",
    "\U0001F6AB Changed my mind", "\u26A0\uFE0F Duplicate purchase", None, None,
    "\U0001F504 Team license renewal", None, None, None, "\U0001F680 Urgent delivery",
]

STATUSES = ["delivered", "shipped", "paid", "pending", "refunded", "cancelled"]


def quote(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def nullable(value):
    return "NULL" if value is None else quote(value)


def build_orders():
    orders, items = [], []
    item_id = 0
    for index in range(60):
        order_id = index + 1
        user = (index * 5 + 3) % len(USERS) + 1
        status = STATUSES[index % len(STATUSES)]
        address, currency = ADDRESSES[index % len(ADDRESSES)]
        note = NOTES[index % len(NOTES)]

        day = index % 28 + 1
        month = 3 if index < 30 else 4
        created = f"2026-{month:02d}-{day:02d} {(index % 12) + 8:02d}:{(index * 7) % 60:02d}:00"
        paid = None if status == "pending" else created
        shipped = created if status in ("delivered", "shipped") else None

        total = Decimal("0.00")
        for slot in range(index % 3 + 1):
            item_id += 1
            product_index = (index * 3 + slot * 5) % len(PRODUCTS)
            price = Decimal(PRODUCTS[product_index][2])
            quantity = (index + slot) % 3 + 1
            subtotal = price * quantity
            total += subtotal
            items.append((item_id, order_id, product_index + 1, quantity, subtotal))

        orders.append((order_id, user, status, total, currency, address, note, paid, shipped, created))
    return orders, items


def main() -> None:
    orders, items = build_orders()
    out = ["-- Generated by demo/generate-data.py. Do not edit by hand.", ""]

    out.append("INSERT INTO users (name, email, plan, country, created_at) VALUES")
    out.append(",\n".join(
        f"    ({quote(n)}, {quote(e)}, {quote(p)}, {quote(c)}, {quote(t)})" for n, e, p, c, t in USERS
    ) + ";")
    out.append("")

    out.append("INSERT INTO products (name, category, price, created_at) VALUES")
    out.append(",\n".join(
        f"    ({quote(n)}, {quote(c)}, {p}, {quote(t)})" for n, c, p, t in PRODUCTS
    ) + ";")
    out.append("")

    out.append("INSERT INTO orders (user_id, status, total, currency, shipping_address, notes, paid_at, shipped_at, created_at) VALUES")
    out.append(",\n".join(
        f"    ({u}, {quote(s)}, {t}, {quote(c)}, {quote(a)}, {nullable(n)}, {nullable(pa)}, {nullable(sh)}, {quote(cr)})"
        for _, u, s, t, c, a, n, pa, sh, cr in orders
    ) + ";")
    out.append("")

    out.append("INSERT INTO order_items (order_id, product_id, quantity, subtotal) VALUES")
    out.append(",\n".join(f"    ({o}, {p}, {q}, {s})" for _, o, p, q, s in items) + ";")
    out.append("")

    reviews = [
        (3, 1, 5, "Replaced three tools on day one."),
        (1, 2, 5, "Opens faster than the terminal client I was using."),
        (6, 3, 4, "Wish the EXPLAIN diagram exported to SVG."),
        (2, 4, 5, "The deferred commit is the whole reason I switched."),
        (4, 5, 4, "Good course, assumes you know joins already."),
        (5, 6, 3, "Solid book, a little dated on clustering."),
        (7, 7, 5, "Worth it for the index chapter alone."),
        (9, 8, 4, "Does what it says, no subscription."),
        (11, 9, 5, "Migrations that finally survive review."),
        (12, 10, 4, "Small tool, saves a real chore."),
        (8, 11, 5, "Every DBA on the team bought a copy."),
        (10, 12, 3, "Fine, but I already had most of this scripted."),
    ]
    out.append("INSERT INTO reviews (product_id, user_id, rating, body, created_at) VALUES")
    out.append(",\n".join(
        f"    ({p}, {u}, {r}, {quote(b)}, {quote(f'2026-04-{i + 1:02d} 09:00:00')})"
        for i, (p, u, r, b) in enumerate(reviews)
    ) + ";")
    out.append("")

    tags = [
        ("bestseller", "amber"), ("new", "green"), ("bundle", "blue"),
        ("deprecated", "grey"), ("beta", "purple"), ("free", "teal"),
        ("enterprise", "red"), ("archived", "slate"),
    ]
    out.append("INSERT INTO tags (name, colour) VALUES")
    out.append(",\n".join(f"    ({quote(n)}, {quote(c)})" for n, c in tags) + ";")
    out.append("")

    out.append("INSERT INTO product_tags (product_id, tag_id) VALUES")
    out.append(",\n".join(
        f"    ({p}, {(p * 3) % len(tags) + 1})" for p in range(1, len(PRODUCTS) + 1)
    ) + ";")
    out.append("")

    actions = ["signed_in", "ran_query", "exported_csv", "opened_connection", "saved_favorite"]
    details = [
        "SELECT * FROM orders WHERE status = 'pending'",
        "orders.csv, 60 rows",
        "tablepro_demo on localhost",
        "Top customers by lifetime value",
        "Session opened from macOS 27.0",
    ]
    out.append("INSERT INTO activity_log (user_id, action, detail, created_at) VALUES")
    out.append(",\n".join(
        f"    ({i % len(USERS) + 1}, {quote(actions[i % len(actions)])}, "
        f"{quote(details[i % len(details)])}, {quote(f'2026-04-{i % 28 + 1:02d} {i % 12 + 8:02d}:30:00')})"
        for i in range(25)
    ) + ";")
    out.append("")

    Path(__file__).with_name("data.sql").write_text("\n".join(out))
    print(f"wrote data.sql: {len(orders)} orders, {len(items)} order items, {len(USERS)} users")


if __name__ == "__main__":
    main()
