-- PostgreSQL: init.sql
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

CREATE TABLE IF NOT EXISTS market_data (
    id SERIAL PRIMARY KEY,
    position_id INT,
    bookmaker VARCHAR,
    market_price FLOAT,
    volume INT,
    timestamp TIMESTAMPTZ
);

-- cdc publication
CREATE PUBLICATION betting_pub FOR TABLE positions, market_data;

-- cdc user creation
DO $$
BEGIN
   IF NOT EXISTS (
      SELECT FROM pg_catalog.pg_roles WHERE rolname = 'rw_replication'
   ) THEN
      CREATE ROLE rw_replication WITH REPLICATION LOGIN PASSWORD 'password';
   END IF;
END $$;

GRANT ALL PRIVILEGES ON DATABASE pgdb TO rw_replication;