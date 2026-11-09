-- Хранилище файлов ответов (только в Supabase, после schema.sql).
-- Файлы доступны по ссылке всем (ответы и так видят все участники),
-- загружать может только действующий участник — в свою папку (хеш кода).

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('answers', 'answers', true, 10485760, array[
  'image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'text/plain',
  'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'audio/mpeg', 'audio/mp4', 'audio/x-m4a', 'audio/aac', 'audio/wav', 'audio/ogg', 'audio/webm'
])
on conflict (id) do update set
  public = excluded.public, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "answers upload by participant" on storage.objects;
create policy "answers upload by participant" on storage.objects
  for insert to anon
  with check (bucket_id = 'answers' and public.is_upload_prefix((storage.foldername(name))[1]));
