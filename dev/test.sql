-- Проверка логики базы от лица сайта (роль anon). Запуск: psql -d domashki_msb_dev -f dev/test.sql
-- Перед запуском: schema.sql и пароль администратора 'testpass1' (см. README).
\set ON_ERROR_STOP 0
\pset tuples_only on
set role anon;

\echo '--- администратор: 23 кода, списки'
select public.admin_login('testpass1') as admin_ok;
select jsonb_array_length(public.admin_generate_codes('testpass1', 23)) as new_codes;
select public.admin_generate_codes('testpass1', 1, 'expert');
select public.admin_save_settings('testpass1', '["Алматы","Астана"]', '["Кредит для бизнеса","Эквайринг"]', '{}')::text as settings;

reset role;
select code as c1 from participants order by created_at, code limit 1 \gset
select code as c2 from participants order by created_at, code offset 1 limit 1 \gset
select public._file_prefix(:'c1') as p1, public._file_prefix(:'c2') as p2 \gset
set role anon;

\echo '--- вход (регистр и дефисы не важны), чужой код'
select public.login(lower(:'c1'))->>'code' = :'c1' as login_ok;
select public.login('XXXX-XXXX');

\echo '--- проверки: только задание 1, филиал, продукт, пустой ответ, чужая папка файла'
select public.save_answer(:'c1', 2, 'Алматы', '{Эквайринг}', 'x');
select public.save_answer(:'c1', 1, 'Караганда', '{Эквайринг}', 'x');
select public.save_answer(:'c1', 1, 'Алматы', '{Ипотека}', 'x');
select public.save_answer(:'c1', 1, 'Алматы', '{Эквайринг}', '   ');
select public.save_answer(:'c1', 1, 'Алматы', '{Эквайринг}', 'x', '{"path":"deadbeef/a.pdf"}');

\echo '--- файл, потом правка текста с сохранением файла, потом удаление файла'
select public.save_answer(:'c1', 1, 'Астана', '{Эквайринг}', '',
  jsonb_build_object('path', :'p1' || '/f1.pdf', 'name', 'Возражения.pdf', 'type', 'application/pdf'))->>'file_name' as with_file;
select public.save_answer(:'c1', 1, 'Астана', '{Эквайринг,Кредит для бизнеса}', 'Возражение 1: дорого')->>'file_name' as file_kept;
select public.save_answer(:'c1', 1, 'Астана', '{Эквайринг}', 'Только текст', null, true)->>'file_name' is null as file_removed;

\echo '--- второй участник видит ответ без кода автора и ставит лайк'
select jsonb_array_length(public.list_answers(:'c2')) as visible, public.list_answers(:'c2')::text like '%' || :'c1' || '%' as code_leaked;
select public.toggle_like(:'c2', (public.list_answers(:'c2')->0->>'id')::uuid)::text as liked;
select public.toggle_like(:'c1', (public.list_answers(:'c1')->0->>'id')::uuid);

\echo '--- срок прошёл'
select public.admin_save_settings('testpass1', '["Алматы","Астана"]', '["Кредит для бизнеса","Эквайринг"]',
  jsonb_build_object('1', (now() - interval '1 day')::text)) is not null as deadline_set;
select public.save_answer(:'c2', 1, 'Алматы', '{Эквайринг}', 'после срока');
select public.delete_answer(:'c1', 1);

\echo '--- блокировка кода, выгрузка'
select jsonb_array_length(public.admin_answers('testpass1')) as total;
select public.admin_set_active('testpass1', :'c2', false);
select public.list_answers(:'c2');
select public.is_upload_prefix(:'p1') as upload_ok, not public.is_upload_prefix(:'p2') as blocked_code_cannot_upload;

\echo '--- прямой доступ к таблицам закрыт'
select count(*) from answers;
reset role;
