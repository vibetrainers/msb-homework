// Локальная проверка сайта без Supabase: отдаёт docs/ и повторяет нужные части API Supabase
// (вызов функций /rest/v1/rpc и хранилище /storage/v1) поверх локального PostgreSQL.
// Запуск: DATABASE_URL=postgres://localhost/domashki_msb_dev node dev/mock-supabase.mjs
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import pg from "pg";
import { fileURLToPath } from "node:url";

const PORT = Number(process.env.PORT) || 8791;
const ROOT = fileURLToPath(new URL("../docs/", import.meta.url));
const UPLOADS = fileURLToPath(new URL("./uploads/", import.meta.url));
const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL || "postgres://localhost/domashki_msb_dev" });
const MAX_UPLOAD = 10 * 1024 * 1024;
const TYPES = { ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8" };

const send = (res, status, body, type = "application/json") => {
  res.writeHead(status, { "Content-Type": type, "Access-Control-Allow-Origin": "*" });
  res.end(typeof body === "string" || Buffer.isBuffer(body) ? body : JSON.stringify(body));
};

const readBody = (req) =>
  new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => { size += c.length; if (size > MAX_UPLOAD + 1) req.destroy(); chunks.push(c); });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });

// Вызов функции от имени роли anon — как это делает PostgREST
async function asAnon(sql, params) {
  const client = await pool.connect();
  try {
    await client.query("begin; set local role anon");
    const { rows } = await client.query(sql, params);
    await client.query("commit");
    return rows[0]?.r ?? null;
  } catch (e) {
    await client.query("rollback").catch(() => {});
    throw e;
  } finally {
    client.release();
  }
}

async function handleRpc(fn, req, res) {
  if (!/^[a-z_]+$/.test(fn)) return send(res, 404, { message: "not found" });
  const args = JSON.parse((await readBody(req)).toString() || "{}");
  const names = Object.keys(args).filter((k) => /^p_[a-z_]+$/.test(k));
  const params = names.map((k) => {
    const v = args[k];
    // массивы — это text[] (продукты ответа), кроме настроек, где списки хранятся как jsonb
    if (Array.isArray(v) && fn !== "admin_save_settings") return v;
    return v !== null && typeof v === "object" ? JSON.stringify(v) : v;
  });
  const sql = `select public.${fn}(${names.map((k, i) => `${k} => $${i + 1}`).join(", ")}) as r`;
  try {
    send(res, 200, JSON.stringify(await asAnon(sql, params)));
  } catch (e) {
    send(res, 400, { code: e.code, message: e.message });
  }
}

async function handleUpload(objectPath, req, res) {
  const prefix = objectPath.split("/")[0];
  const ok = await asAnon("select public.is_upload_prefix($1) as r", [prefix]).catch(() => false);
  if (!ok) return send(res, 403, { message: "new row violates row-level security policy" });
  const body = await readBody(req);
  if (body.length > MAX_UPLOAD) return send(res, 413, { message: "The object exceeded the maximum allowed size" });
  const target = path.join(UPLOADS, objectPath);
  if (!target.startsWith(UPLOADS)) return send(res, 400, { message: "bad path" });
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.writeFileSync(target, body);
  fs.writeFileSync(target + ".type", req.headers["content-type"] || "application/octet-stream");
  send(res, 200, { Key: `answers/${objectPath}` });
}

http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://localhost:${PORT}`);
  const p = decodeURIComponent(url.pathname);
  try {
    if (req.method === "OPTIONS") {
      res.writeHead(204, { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Headers": "*", "Access-Control-Allow-Methods": "GET,POST,OPTIONS" });
      return res.end();
    }
    if (req.method === "POST" && p.startsWith("/rest/v1/rpc/")) return handleRpc(p.slice(13), req, res);
    if (req.method === "POST" && p.startsWith("/storage/v1/object/answers/")) return handleUpload(p.slice(27), req, res);
    if (req.method === "GET" && p.startsWith("/storage/v1/object/public/answers/")) {
      const file = path.join(UPLOADS, p.slice(34));
      if (!file.startsWith(UPLOADS) || !fs.existsSync(file)) return send(res, 404, "not found", "text/plain");
      return send(res, 200, fs.readFileSync(file), fs.readFileSync(file + ".type", "utf8"));
    }
    if (p === "/config.js") {
      return send(res, 200, `window.APP_CONFIG = { supabaseUrl: "http://localhost:${PORT}", supabaseKey: "local-dev" };`, TYPES[".js"]);
    }
    const file = path.join(ROOT, p === "/" ? "index.html" : p);
    if (!file.startsWith(ROOT) || !fs.existsSync(file)) return send(res, 404, "not found", "text/plain");
    send(res, 200, fs.readFileSync(file), TYPES[path.extname(file)] || "application/octet-stream");
  } catch (e) {
    console.error(e);
    send(res, 500, { message: "mock error" });
  }
}).listen(PORT, () => console.log(`Локальная версия: http://localhost:${PORT}`));
