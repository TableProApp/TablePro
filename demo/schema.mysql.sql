-- MariaDB mirror of schema.postgres.sql, kept in step by hand. Only three
-- things differ: SERIAL becomes AUTO_INCREMENT, NUMERIC becomes DECIMAL, and
-- the views name every selected column in GROUP BY because ONLY_FULL_GROUP_BY
-- is on by default.
--
-- Table and column names are load bearing: the marketing copy names them, so
-- renaming one here silently makes a sentence on the site wrong.

CREATE TABLE users (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(64)  NOT NULL,
    email       VARCHAR(128) NOT NULL UNIQUE,
    plan        VARCHAR(16)  NOT NULL,
    country     VARCHAR(2)   NOT NULL,
    created_at  TIMESTAMP    NOT NULL
);

CREATE TABLE products (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    name        VARCHAR(64)   NOT NULL,
    category    VARCHAR(16)   NOT NULL,
    price       DECIMAL(10,2) NOT NULL,
    created_at  TIMESTAMP     NOT NULL
);

CREATE TABLE orders (
    id                INT AUTO_INCREMENT PRIMARY KEY,
    user_id           INTEGER       NOT NULL REFERENCES users(id),
    status            VARCHAR(16)   NOT NULL,
    total             DECIMAL(10,2) NOT NULL,
    currency          CHAR(3)       NOT NULL,
    shipping_address  VARCHAR(64)   NOT NULL,
    notes             VARCHAR(64),
    paid_at           TIMESTAMP,
    shipped_at        TIMESTAMP,
    created_at        TIMESTAMP     NOT NULL
);

CREATE TABLE order_items (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    order_id    INTEGER       NOT NULL REFERENCES orders(id),
    product_id  INTEGER       NOT NULL REFERENCES products(id),
    quantity    INTEGER       NOT NULL,
    subtotal    DECIMAL(10,2) NOT NULL
);

CREATE TABLE reviews (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    product_id  INTEGER      NOT NULL REFERENCES products(id),
    user_id     INTEGER      NOT NULL REFERENCES users(id),
    rating      INTEGER      NOT NULL,
    body        VARCHAR(128) NOT NULL,
    created_at  TIMESTAMP    NOT NULL
);

CREATE TABLE tags (
    id     INT AUTO_INCREMENT PRIMARY KEY,
    name   VARCHAR(24) NOT NULL UNIQUE,
    colour VARCHAR(16) NOT NULL
);

CREATE TABLE product_tags (
    product_id INTEGER NOT NULL REFERENCES products(id),
    tag_id     INTEGER NOT NULL REFERENCES tags(id),
    PRIMARY KEY (product_id, tag_id)
);

CREATE TABLE activity_log (
    id          INT AUTO_INCREMENT PRIMARY KEY,
    user_id     INTEGER      NOT NULL REFERENCES users(id),
    action      VARCHAR(32)  NOT NULL,
    detail      VARCHAR(96)  NOT NULL,
    created_at  TIMESTAMP    NOT NULL
);

CREATE VIEW order_summary AS
SELECT u.name AS customer, u.email, COUNT(o.id) AS order_count,
       SUM(o.total) AS total, MAX(o.created_at) AS last_order
FROM users u LEFT JOIN orders o ON o.user_id = u.id
GROUP BY u.name, u.email;

CREATE VIEW product_stats AS
SELECT p.name AS product, p.category, p.price,
       COUNT(oi.id) AS times_ordered, SUM(oi.quantity) AS units_sold,
       SUM(oi.subtotal) AS revenue
FROM products p LEFT JOIN order_items oi ON oi.product_id = p.id
GROUP BY p.id, p.name, p.category, p.price;
