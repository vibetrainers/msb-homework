// Ставит номер версии на файлы сайта в docs/index.html (app.js?v=…), чтобы телефоны
// после обновления сразу брали новые файлы, а не сохранённые старые. Запуск: npm run stamp
import fs from "node:fs";

const file = new URL("../docs/index.html", import.meta.url);
const v = new Date().toISOString().replace(/\D/g, "").slice(0, 12);
const html = fs
  .readFileSync(file, "utf8")
  .replace(/(href|src)="(styles\.css|config\.js|app\.js)(\?v=\d+)?"/g, `$1="$2?v=${v}"`);
fs.writeFileSync(file, html);
console.log(`docs/index.html: версия ${v}`);
