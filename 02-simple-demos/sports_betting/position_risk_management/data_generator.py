import psycopg2
import random
from datetime import datetime
import time

conn_params = {
    "dbname": "pgdb",
    "user": "pguser",
    "password": "pgpass",
    "host": "localhost",
    "port": "5432"
}

# Establish a connection to PostgreSQL
conn = psycopg2.connect(**conn_params)
cursor = conn.cursor()

# Ensure CDC-compatible tables exist (with primary keys)
cursor.execute("""
CREATE TABLE IF NOT EXISTS positions (
    position_id INT PRIMARY KEY,
    league VARCHAR,
    position_name VARCHAR,
    timestamp TIMESTAMPTZ,
    stake_amount FLOAT,
    expected_return FLOAT,
    max_risk FLOAT,
    fair_value FLOAT,
    current_odds FLOAT,
    profit_loss FLOAT,
    exposure FLOAT
);
""")

cursor.execute("""
CREATE TABLE IF NOT EXISTS market_data (
    id SERIAL PRIMARY KEY,
    position_id INT,
    bookmaker VARCHAR,
    market_price FLOAT,
    volume INT,
    timestamp TIMESTAMPTZ
);
""")

conn.commit()

# Betting parameters
num_positions = 10
leagues = ["MLB", "NBA", "NFL", "NHL", "MLS", "Tennis"]
teams = ["Team A", "Team B", "Team C", "Team D", "Team E"]
bookmakers = ["DraftKings", "FanDuel", "BetMGM", "Caesars"]

try:
    while True:
        for i in range(num_positions):
            position_id = i + 1
            league = random.choice(leagues)
            team1 = random.choice(teams)
            team2 = random.choice([t for t in teams if t != team1])
            position_name = f"{team1} vs {team2}"
            stake_amount = round(random.uniform(50, 500), 2)
            expected_return = round(stake_amount * random.uniform(1.1, 2.5), 2)
            max_risk = round(stake_amount * random.uniform(1.0, 1.5), 2)
            fair_value = round(random.uniform(1.0, 5.0), 2)
            current_odds = round(fair_value + random.uniform(-0.5, 0.5), 2)
            profit_loss = round((current_odds - fair_value) * stake_amount, 2)
            exposure = round(stake_amount * random.uniform(0.8, 1.2), 2)
            timestamp = datetime.now()

            cursor.execute("""
                INSERT INTO positions (
                    position_id, league, position_name, timestamp, stake_amount, expected_return,
                    max_risk, fair_value, current_odds, profit_loss, exposure
                ) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (position_id) DO UPDATE SET
                    league = EXCLUDED.league,
                    position_name = EXCLUDED.position_name,
                    timestamp = EXCLUDED.timestamp,
                    stake_amount = EXCLUDED.stake_amount,
                    expected_return = EXCLUDED.expected_return,
                    max_risk = EXCLUDED.max_risk,
                    fair_value = EXCLUDED.fair_value,
                    current_odds = EXCLUDED.current_odds,
                    profit_loss = EXCLUDED.profit_loss,
                    exposure = EXCLUDED.exposure;
            """, (
                position_id, league, position_name, timestamp, stake_amount, expected_return,
                max_risk, fair_value, current_odds, profit_loss, exposure
            ))

        conn.commit()
        print("Inserted betting positions data.")

        for i in range(num_positions):
            position_id = i + 1
            bookmaker = random.choice(bookmakers)
            market_price = round(random.uniform(1.0, 5.0), 2)
            volume = random.randint(100, 1000)
            timestamp = datetime.now()

            cursor.execute("""
                INSERT INTO market_data (
                    position_id, bookmaker, market_price, volume, timestamp
                ) VALUES (%s, %s, %s, %s, %s)
            """, (
                position_id, bookmaker, market_price, volume, timestamp
            ))

        conn.commit()
        print("Inserted market data.")

        time.sleep(2)

except KeyboardInterrupt:
    print("Data insertion stopped.")

finally:
    cursor.close()
    conn.close()
    print("Connection closed.")