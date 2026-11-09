-- Домашние задания МСБ: схема базы для Supabase (одно задание, уровень MASTER).
-- Выполняется целиком в Supabase → SQL Editor (повторный запуск безопасен).
--
-- Безопасность: таблицы закрыты (RLS без политик), сайт работает только через
-- функции ниже. Участник передаёт свой код, администратор — пароль.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
end $$;

-- ---------- Таблицы ----------

create table if not exists public.participants (
  code text primary key,
  active boolean not null default true,
  level text not null default 'master' check (level = 'master'),
  created_at timestamptz not null default now()
);

create table if not exists public.answers (
  id uuid primary key default gen_random_uuid(),
  code text not null references public.participants(code) on delete cascade,
  lesson_id int not null check (lesson_id = 1),
  branch text not null,
  products text[] not null,
  text text not null default '',
  file_path text,
  file_name text,
  file_type text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (code, lesson_id)
);

-- Лайки: один участник — один лайк на ответ коллеги
create table if not exists public.likes (
  answer_id uuid not null references public.answers(id) on delete cascade,
  code text not null references public.participants(code) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (answer_id, code)
);
create index if not exists likes_code on public.likes(code);

create table if not exists public.settings (
  key text primary key,
  value jsonb not null
);

alter table public.participants enable row level security;
alter table public.answers enable row level security;
alter table public.settings enable row level security;
alter table public.likes enable row level security;
revoke all on public.participants, public.answers, public.settings, public.likes from anon;

insert into public.settings (key, value) values
  ('branches', '[]'),
  ('products', '["Кредит", "Депозит", "Страховка", "Halyk Market", "Кредитная карта", "Другое"]'),
  ('deadlines', '{}')
on conflict (key) do nothing;

-- ---------- Внутренние помощники (недоступны сайту) ----------

create or replace function public._norm_code(p text) returns text
language sql immutable as $$ select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')) $$;

create or replace function public._file_prefix(p_code text) returns text
language sql immutable set search_path = public, extensions as $$
  select encode(digest(p_code, 'sha256'), 'hex')
$$;

create or replace function public._participant(p_code text) returns text
language plpgsql stable security definer set search_path = public, extensions as $$
declare c text := _norm_code(p_code);
begin
  if not exists (select 1 from participants where code = c and active) then
    raise exception 'invalid_code' using errcode = 'P0001';
  end if;
  return c;
end $$;

create or replace function public._admin(p_password text) returns void
language plpgsql stable security definer set search_path = public, extensions as $$
declare h text := (select value #>> '{}' from settings where key = 'admin_password');
begin
  if h is null or crypt(coalesce(p_password, ''), h) <> h then
    raise exception 'invalid_password' using errcode = 'P0001';
  end if;
end $$;

create or replace function public._lesson_level(p_lesson int) returns text
language sql immutable as $$ select case when p_lesson = 1 then 'master' end $$;

create or replace function public._setting(p_key text) returns jsonb
language sql stable security definer set search_path = public as $$
  select value from settings where key = p_key
$$;

create or replace function public._deadline_passed(p_lesson int) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(now() > (_setting('deadlines') ->> p_lesson::text)::timestamptz, false)
$$;

create or replace function public._answer_json(a public.answers, p_me text) returns jsonb
language sql stable as $$
  select jsonb_build_object(
    'id', a.id, 'lesson_id', a.lesson_id, 'branch', a.branch, 'products', to_jsonb(a.products),
    'text', a.text, 'file_path', a.file_path, 'file_name', a.file_name, 'file_type', a.file_type,
    'created_at', a.created_at, 'updated_at', a.updated_at, 'is_mine', a.code = p_me,
    'likes', (select count(*) from likes l where l.answer_id = a.id),
    'liked', p_me is not null and exists (select 1 from likes l where l.answer_id = a.id and l.code = p_me))
$$;

-- ---------- Для участников ----------

create or replace function public.get_config() returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('branches', _setting('branches'), 'products', _setting('products'), 'deadlines', _setting('deadlines'))
$$;

create or replace function public.login(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare c text := _participant(p_code);
begin
  return jsonb_build_object('code', c, 'file_prefix', _file_prefix(c), 'level', (select level from participants where code = c));
end $$;

-- Все ответы без кодов авторов: другие видят филиал, продукты и сам ответ
create or replace function public.list_answers(p_code text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
declare c text := _participant(p_code);
begin
  return coalesce((select jsonb_agg(_answer_json(a, c) order by a.updated_at desc) from answers a), '[]');
end $$;

create or replace function public.save_answer(
  p_code text, p_lesson int, p_branch text, p_products text[], p_text text,
  p_file jsonb default null, p_remove_file boolean default false
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  c text := _participant(p_code);
  t text := btrim(coalesce(p_text, ''));
  old answers;
  f_path text; f_name text; f_type text;
  saved answers;
begin
  if _lesson_level(p_lesson) is null then raise exception 'bad_lesson'; end if;
  if _deadline_passed(p_lesson) then raise exception 'deadline_passed'; end if;
  if not (_setting('branches') ? coalesce(p_branch, '')) then raise exception 'bad_branch'; end if;
  if coalesce(cardinality(p_products), 0) = 0
     or exists (select 1 from unnest(p_products) p where not (_setting('products') ? p)) then
    raise exception 'bad_products';
  end if;
  if length(t) > 20000 then raise exception 'text_too_long'; end if;

  select * into old from answers where code = c and lesson_id = p_lesson;
  if p_file is not null then
    f_path := p_file ->> 'path'; f_name := left(p_file ->> 'name', 200); f_type := left(p_file ->> 'type', 100);
    if f_path is null or split_part(f_path, '/', 1) <> _file_prefix(c) then raise exception 'bad_file'; end if;
  elsif not p_remove_file and old.id is not null then
    f_path := old.file_path; f_name := old.file_name; f_type := old.file_type;
  end if;

  if t = '' and f_path is null then raise exception 'empty_answer'; end if;

  insert into answers (code, lesson_id, branch, products, text, file_path, file_name, file_type)
  values (c, p_lesson, p_branch, p_products, t, f_path, f_name, f_type)
  on conflict (code, lesson_id) do update set
    branch = excluded.branch, products = excluded.products, text = excluded.text,
    file_path = excluded.file_path, file_name = excluded.file_name, file_type = excluded.file_type,
    updated_at = now()
  returning * into saved;
  return _answer_json(saved, c);
end $$;

create or replace function public.delete_answer(p_code text, p_lesson int) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare c text := _participant(p_code);
begin
  if _deadline_passed(p_lesson) then raise exception 'deadline_passed'; end if;
  delete from answers where code = c and lesson_id = p_lesson;
end $$;

-- Поставить или снять лайк. Свой ответ лайкнуть нельзя.
create or replace function public.toggle_like(p_code text, p_answer uuid) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  c text := _participant(p_code);
  author text := (select code from answers where id = p_answer);
  now_liked boolean;
begin
  if author is null then raise exception 'bad_answer'; end if;
  if author = c then raise exception 'own_answer'; end if;
  delete from likes where answer_id = p_answer and code = c;
  now_liked := not found;
  if now_liked then insert into likes (answer_id, code) values (p_answer, c); end if;
  return jsonb_build_object('liked', now_liked, 'likes', (select count(*) from likes where answer_id = p_answer));
end $$;

-- Для политики загрузки файлов: папка = хеш действующего кода
create or replace function public.is_upload_prefix(p_prefix text) returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from participants where active and _file_prefix(code) = p_prefix)
$$;

-- ---------- Для администратора ----------

create or replace function public.admin_login(p_password text) returns boolean
language plpgsql stable security definer set search_path = public, extensions as $$
begin perform _admin(p_password); return true; end $$;

create or replace function public.admin_overview(p_password text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _admin(p_password);
  return jsonb_build_object(
    'participants', coalesce((
      select jsonb_agg(jsonb_build_object(
        'code', p.code, 'active', p.active, 'level', p.level, 'created_at', p.created_at,
        'lessons', coalesce((select jsonb_agg(a.lesson_id order by a.lesson_id) from answers a where a.code = p.code), '[]'),
        'branch', (select a.branch from answers a where a.code = p.code order by a.updated_at desc limit 1)
      ) order by p.created_at, p.code) from participants p), '[]'),
    'answers', (select count(*) from answers),
    'settings', get_config()
  );
end $$;

create or replace function public.admin_answers(p_password text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _admin(p_password);
  return coalesce((
    select jsonb_agg(_answer_json(a, null) || jsonb_build_object('code', a.code) order by a.lesson_id, a.updated_at)
    from answers a), '[]');
end $$;

-- Аналитика лайков: кто и сколько поставил (у ответов количество приходит в admin_answers)
create or replace function public.admin_likes(p_password text) returns jsonb
language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform _admin(p_password);
  return jsonb_build_object(
    'total', (select count(*) from likes),
    'givers', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'given', n) order by n desc)
      from (select code, count(*) n from likes group by code) g), '[]'));
end $$;

drop function if exists public.admin_generate_codes(text, int);
create or replace function public.admin_generate_codes(p_password text, p_count int, p_level text default 'master') returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  made text[] := '{}';
  c text;
begin
  perform _admin(p_password);
  if p_count is null or p_count not between 1 and 500 then raise exception 'bad_count'; end if;
  if p_level <> 'master' then raise exception 'bad_level'; end if;
  while cardinality(made) < p_count loop
    select string_agg(substr(alphabet, 1 + (get_byte(b, i) % length(alphabet)), 1), '')
      into c from (select gen_random_bytes(8) b) r, generate_series(0, 7) i;
    insert into participants (code, level) values (c, p_level) on conflict do nothing;
    if found then made := made || c; end if;
  end loop;
  return to_jsonb(made);
end $$;

create or replace function public.admin_set_active(p_password text, p_code text, p_active boolean) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_password);
  update participants set active = p_active where code = _norm_code(p_code);
end $$;

create or replace function public.admin_delete_answer(p_password text, p_id uuid) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_password);
  delete from answers where id = p_id;
end $$;

create or replace function public.admin_save_settings(
  p_password text, p_branches jsonb, p_products jsonb, p_deadlines jsonb
) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_password);
  if jsonb_typeof(p_branches) <> 'array' or jsonb_typeof(p_products) <> 'array' or jsonb_typeof(p_deadlines) <> 'object' then
    raise exception 'bad_settings';
  end if;
  update settings set value = p_branches where key = 'branches';
  update settings set value = p_products where key = 'products';
  update settings set value = p_deadlines where key = 'deadlines';
  return get_config();
end $$;

create or replace function public.admin_set_password(p_password text, p_new text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _admin(p_password);
  if length(coalesce(p_new, '')) < 8 then raise exception 'password_too_short'; end if;
  update settings set value = to_jsonb(crypt(p_new, gen_salt('bf'))) where key = 'admin_password';
end $$;

-- ---------- Доступ сайта: только к этим функциям ----------

revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.get_config(), public.login(text), public.list_answers(text),
  public.save_answer(text, int, text, text[], text, jsonb, boolean), public.delete_answer(text, int),
  public.is_upload_prefix(text), public.toggle_like(text, uuid), public.admin_likes(text),
  public.admin_login(text), public.admin_overview(text), public.admin_answers(text),
  public.admin_generate_codes(text, int, text), public.admin_set_active(text, text, boolean),
  public.admin_delete_answer(text, uuid), public.admin_save_settings(text, jsonb, jsonb, jsonb),
  public.admin_set_password(text, text)
to anon;
