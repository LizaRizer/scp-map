-- SCP-UA Map — схема Supabase (schema as code)
-- Запускати по порядку в SQL Editor. Кожну таблицю створювати з "Run and enable RLS".
-- Зміни робимо лише SQL-командами (не кліками в Table Editor), щоб цей файл = база.
-- Стан на 21.11.2026: схема MVP ✅ (15 таблиць), pgvector ✅ (0.8.2, схема extensions).
-- Колонка ембедингів — після вибору моделі.

-- 1. Розширення ---------------------------------------------------------
create extension if not exists postgis with schema extensions;   -- точки, відстані
create extension if not exists vector  with schema extensions;   -- pgvector (ембединги)

-- 2. Довідники ----------------------------------------------------------

-- Зони й Ділянки Фонду
create table facilities (
  id         bigint generated always as identity primary key,
  name       text not null unique,
  type       text not null check (type in ('zone', 'site')),
  cover_name text,
  location   geography(Point, 4326) not null   -- POINT(довгота широта)!
);

-- МОГ (designation — для розпізнавання тієї самої групи; url без unique — сторінки-хаби)
create table mtf (
  id          bigint generated always as identity primary key,
  name        text not null unique,
  designation text unique,
  url         text
);

-- ГОІ (url nullable: ГОІ можна записати без відомої сторінки)
create table goi (
  id   bigint generated always as identity primary key,
  name text unique not null,
  url  text unique
);

-- Співробітники (name без unique: немає entity resolution)
create table persons (
  id              bigint generated always as identity primary key,
  name            text not null,
  avatar_url      text,
  position        text,
  clearance_level int check (clearance_level between 0 and 5)
);

-- Налаштування (один рядок = одне налаштування; змінюємо update ... where key = ...)
create table settings (
  key         text primary key,
  value       jsonb not null,
  description text
);
insert into settings (key, value, description) values
  ('import_range',      '{"from": 1, "to": 50}', 'Діапазон номерів для імпорту'),
  ('check_new_hours',   '24',                    'Як часто перевіряти нові статті'),
  ('simulator_minutes', '180',                   'Як часто симулятор генерує подію');

-- 3. Об'єкти ------------------------------------------------------------
-- Soft delete: об'єкти не видаляємо, а ставимо status = 'archived'
-- (мапа показує SCP-███-UA «[ДАНІ ВИДАЛЕНО]»). Без on delete cascade —
-- база сама забороняє фізичне видалення об'єкта з дочірніми рядками (23503).
create table objects (
  id bigint generated always as identity primary key,
  number text not null unique
    check (number ~ '^SCP-[0-9]{3,}-UA$'),
  number_int int not null,
  title text,
  class_raw text,
  object_class text not null
    check (object_class in ('safe', 'euclid', 'keter', 'thaumiel',
                            'apollyon', 'archon', 'esoteric', 'other')),
  secondary_class text,
  status text not null default 'active'
    check (status in ('active', 'neutralized', 'explained', 'archived')),
  tags text[] not null default '{}',
  source_url text not null unique,
  license text not null default 'CC BY-SA 3.0',
  author text,                      -- author_source прибрано (YAGNI)
  page_version int,
  image_url text,
  image_caption text,
  image_credit text,
  discovery_location geography(Point, 4326),
  discovery_location_source text
    check (discovery_location_source in ('extracted', 'approximate', 'generated')),
  discovery_place_raw text,
  current_facility_id bigint references facilities(id),
  current_location geography(Point, 4326),
  current_location_source text
    check (current_location_source in ('extracted', 'approximate', 'generated')),
  radius_m int check (radius_m > 0),
  created_at timestamptz not null default now(),
  check (current_facility_id is null or current_location is null)
);
create index objects_tags_idx               on objects using gin (tags);
create index objects_discovery_location_idx on objects using gist (discovery_location);
create index objects_current_location_idx   on objects using gist (current_location);

-- 4. Дочірні таблиці об'єкта --------------------------------------------

create table object_designations (
  id          bigint generated always as identity primary key,
  object_id   bigint not null references objects(id),
  designation text not null unique,          -- SCP-038-18-UA, SCP-020-UA №27
  alias       text,                          -- «Лікар»
  kind        text check (kind in ('instance', 'manifestation', 'media', 'other'))
);

create table sections (
  id                 bigint generated always as identity primary key,
  object_id          bigint not null references objects(id),
  raw_heading        text,
  section_type       text not null default 'other'
    check (section_type in ('containment', 'description', 'discovery', 'addendum',
                            'document', 'experiment', 'interview', 'note', 'update', 'other')),
  content            text not null,
  position           int not null,
  required_clearance int check (required_clearance between 0 and 5),
  unique (object_id, position)
);
-- ⏳ після вибору моделі ембедингів (тиждень 6), N = розмір вектора моделі:
-- alter table sections add column embedding vector(N);
-- (якщо N не збігається з розміром вектора моделі — помилка 22000)

create table footnotes (
  id        bigint generated always as identity primary key,
  object_id bigint not null references objects(id),
  n         int not null,
  content   text not null,
  unique (object_id, n)
);

-- 5. Події --------------------------------------------------------------
-- Telegram — і вихід (алерти в канал), і (пізніше) вхід заявок: source 'telegram'.
create table events (
  id                   bigint generated always as identity primary key,
  type                 text not null check (type in ('check', 'sos', 'report')),
  source               text not null,
  content              text,
  location             geography(Point, 4326),
  similar_to_object_id bigint references objects(id),   -- nullable FK
  status               text not null default 'pending'
    check (status in ('pending', 'important', 'rejected')),
  agent_reason         text,
  created_at           timestamptz not null default now(),
  notified_at          timestamptz,                     -- idempotency сповіщень
  constraint events_source_check
    check (source in ('generator', 'form', 'telegram')),
  constraint events_report_source_check
    check ((type = 'report') = (source in ('form', 'telegram')))
);
-- (в живій базі ці два check змінено через alter table drop/add constraint)
create index events_created_at_idx on events (created_at desc);
create index events_location_idx   on events using gist (location);

-- 6. Містки (складений primary key) -------------------------------------

create table object_mtf (
  object_id bigint references objects(id),
  mtf_id    bigint references mtf(id),
  primary key (object_id, mtf_id)
);

create table object_goi (          -- будь-який рядок → попап «увага» на картці
  object_id bigint references objects(id),
  goi_id    bigint references goi(id),
  primary key (object_id, goi_id)
);

create table object_persons (
  object_id bigint references objects(id),
  person_id bigint references persons(id),
  role      text check (role in ('curator', 'participant', 'note_author', 'other')),
  primary key (object_id, person_id, role)
);

create table object_links (
  object_id         bigint references objects(id),   -- хто згадує
  related_object_id bigint references objects(id),   -- кого згадано
  note              text,
  primary key (object_id, related_object_id),
  check (object_id <> related_object_id)
);

-- 7. Корисне -------------------------------------------------------------
-- Підзапит замість вгадування id:
--   (select id from objects where number = 'SCP-022-UA')
-- Join через місток (попап «увага»):
--   select o.number, o.title, g.name as goi
--   from objects o
--   join object_goi og on og.object_id = o.id
--   join goi g on g.id = og.goi_id;
-- Left join — всі об'єкти, навіть без Зони (для Map API):
--   select o.number, f.name as facility
--   from objects o
--   left join facilities f on f.id = o.current_facility_id;
-- Встановлені розширення і їхні схеми:
--   select e.extname, e.extversion, n.nspname as schema
--   from pg_extension e
--   join pg_namespace n on n.oid = e.extnamespace;
-- Список check-обмежень таблиці:
--   select conname, pg_get_constraintdef(oid) from pg_constraint
--   where conrelid = 'events'::regclass and contype = 'c';
-- Коди помилок: 23505 unique, 23502 not null, 23514 check, 23503 foreign key,
--               42601 syntax error, 22000 data exception (напр. не та к-сть вимірів vector).
