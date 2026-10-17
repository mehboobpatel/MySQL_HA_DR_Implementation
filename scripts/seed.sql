CREATE TABLE IF NOT EXISTS appdb.orders (
  id          BIGINT AUTO_INCREMENT PRIMARY KEY,
  customer_id INT NOT NULL,
  amount      DECIMAL(10,2) NOT NULL,
  source      VARCHAR(16) NOT NULL DEFAULT 'seed',
  created_at  TIMESTAMP(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)
);
SET SESSION cte_max_recursion_depth = 10000;
INSERT INTO appdb.orders (customer_id, amount)
WITH RECURSIVE seq(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM seq WHERE n < 5000)
SELECT FLOOR(1 + RAND() * 1000), ROUND(RAND() * 500, 2) FROM seq;
SELECT COUNT(*) AS rows_loaded FROM appdb.orders;
