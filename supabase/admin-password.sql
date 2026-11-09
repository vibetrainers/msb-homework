-- Пароль администратора. Замените ВАШ_ПАРОЛЬ (не короче 8 символов) и выполните в SQL Editor.
-- Потом пароль можно сменить в админке сайта.
insert into public.settings (key, value)
values ('admin_password', to_jsonb(extensions.crypt('ВАШ_ПАРОЛЬ', extensions.gen_salt('bf'))))
on conflict (key) do update set value = excluded.value;
