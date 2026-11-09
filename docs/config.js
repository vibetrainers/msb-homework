// Подключение к Supabase: Project Settings → API (Project URL и ключ anon/publishable).
// Ключ публичный по задумке: доступ к данным ограничен функциями в supabase/schema.sql.
// Нужен ОТДЕЛЬНЫЙ проект Supabase для МСБ (см. README).
window.APP_CONFIG = {
  supabaseUrl: "",
  supabaseKey: "",
};
