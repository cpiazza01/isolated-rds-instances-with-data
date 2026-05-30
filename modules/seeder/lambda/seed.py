import os
import json
import random
import boto3

DB_ENGINE      = os.environ["DB_ENGINE"]
DB_HOST        = os.environ["DB_HOST"]
DB_PORT        = int(os.environ["DB_PORT"])
DB_NAME        = os.environ["DB_NAME"]
DB_USER        = os.environ["DB_USER"]
DB_SECRET_ARN  = os.environ["DB_SECRET_ARN"]
ROW_COUNT      = int(os.environ["ROW_COUNT"])


def get_password():
    # boto3 is pre-installed in all Lambda runtimes — no extra dependency needed.
    # The Secrets Manager VPC endpoint routes this call privately within the VPC
    # so no internet access is required. The Lambda's IAM role is scoped to
    # GetSecretValue on this one secret ARN only.
    client = boto3.client("secretsmanager")
    response = client.get_secret_value(SecretId=DB_SECRET_ARN)
    return json.loads(response["SecretString"])["password"]

FIRST_NAMES = [
    "Alice", "Bob", "Carol", "Dave", "Eve", "Frank", "Grace", "Hank",
    "Iris", "Jack", "Karen", "Liam", "Mia", "Noah", "Olivia", "Pete",
    "Quinn", "Rosa", "Sam", "Tara", "Uma", "Victor", "Wendy", "Xander",
]
LAST_NAMES = [
    "Smith", "Jones", "Williams", "Brown", "Davis", "Miller", "Wilson",
    "Moore", "Taylor", "Anderson", "Thomas", "Jackson", "White", "Harris",
    "Martin", "Thompson", "Garcia", "Martinez", "Robinson", "Clark",
]
DOMAINS = ["example.com", "test.org", "demo.net", "sample.io", "fake.dev"]

BATCH_SIZE = 500

CREATE_POSTGRES = """
CREATE TABLE IF NOT EXISTS users (
    id         SERIAL PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    email      VARCHAR(200) NOT NULL UNIQUE,
    created_at TIMESTAMP DEFAULT NOW()
)
"""

CREATE_MYSQL = """
CREATE TABLE IF NOT EXISTS users (
    id         INT AUTO_INCREMENT PRIMARY KEY,
    name       VARCHAR(100) NOT NULL,
    email      VARCHAR(200) NOT NULL UNIQUE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
)
"""

# TRUNCATE empties the table and resets the auto-increment counter so IDs
# always start from 1. RESTART IDENTITY handles the PostgreSQL sequence reset.
# This ensures re-seeds (triggered by row_count or code changes) produce an
# exact, predictable dataset rather than appending to existing rows.
TRUNCATE_POSTGRES = "TRUNCATE TABLE users RESTART IDENTITY"
TRUNCATE_MYSQL    = "TRUNCATE TABLE users"


def gen_rows(start_idx, count):
    rows = []
    for i in range(count):
        first = random.choice(FIRST_NAMES)
        last  = random.choice(LAST_NAMES)
        name  = f"{first} {last}"
        email = f"{first.lower()}.{last.lower()}.{start_idx + i}@{random.choice(DOMAINS)}"
        rows.append((name, email))
    return rows


def seed(conn, create_sql, truncate_sql):
    cur = conn.cursor()
    cur.execute(create_sql)
    cur.execute(truncate_sql)
    conn.commit()

    inserted = 0
    while inserted < ROW_COUNT:
        batch = min(BATCH_SIZE, ROW_COUNT - inserted)
        rows = gen_rows(inserted, batch)
        cur.executemany("INSERT INTO users (name, email) VALUES (%s, %s)", rows)
        conn.commit()
        inserted += batch
        print(f"Progress: {inserted}/{ROW_COUNT} rows")

    cur.close()
    conn.close()


def handler(event, context):
    print(f"Seeding {ROW_COUNT} rows — engine={DB_ENGINE} host={DB_HOST}:{DB_PORT}/{DB_NAME}")

    password = get_password()

    if DB_ENGINE == "postgres":
        import pg8000
        conn = pg8000.connect(
            host=DB_HOST, port=DB_PORT, database=DB_NAME,
            user=DB_USER, password=password,
            timeout=30,
        )
        seed(conn, CREATE_POSTGRES, TRUNCATE_POSTGRES)
    else:
        import pymysql
        conn = pymysql.connect(
            host=DB_HOST, port=DB_PORT, database=DB_NAME,
            user=DB_USER, password=password,
            connect_timeout=30,
        )
        seed(conn, CREATE_MYSQL, TRUNCATE_MYSQL)

    print(f"Done — {ROW_COUNT} rows seeded successfully")
    return {"statusCode": 200, "body": f"Seeded {ROW_COUNT} rows"}
