-- orders / order_items / payments / tickets (간단 버전)
CREATE TABLE IF NOT EXISTS orders (
  idempotency_key TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  event_id TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'PENDING',
  total BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_orders_event ON orders(event_id);

CREATE TABLE IF NOT EXISTS order_items (
  order_id TEXT NOT NULL,
  seat_id TEXT NOT NULL,
  price BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE(order_id, seat_id)
);

CREATE TABLE IF NOT EXISTS payments (
  order_id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  intent_id TEXT NOT NULL,
  status TEXT NOT NULL,
  amount BIGINT NOT NULL DEFAULT 0,
  approved_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS tickets (
  ticket_id TEXT PRIMARY KEY,
  order_id TEXT NOT NULL,
  event_id TEXT NOT NULL,
  seat_id TEXT NOT NULL,
  qr TEXT,
  issued_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- (옵션) 좌석 마스터
CREATE TABLE IF NOT EXISTS seats (
  event_id TEXT NOT NULL,
  seat_id TEXT PRIMARY KEY,
  status TEXT NOT NULL DEFAULT 'available'  -- available | held | sold
);

-- 간단 시드: 좌석 10,000개 (필요시 수정)
-- INSERT INTO seats(event_id, seat_id) SELECT 'EVT', 'S'||g FROM generate_series(1,10000) g;
