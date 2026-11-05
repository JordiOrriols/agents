import { readdir, readFile } from "node:fs/promises";
import { PGlite } from "@electric-sql/pglite";

const migrations = new URL("../../../../supabase/migrations/", import.meta.url);

export type TestAccount = { id: string; email: string };

async function migrationFiles() {
  return (await readdir(migrations)).filter((file) => file.endsWith(".sql")).sort();
}

/** Applies, in order, every migration from `from` (inclusive) up to `until` (exclusive). */
export async function applyMigrations(db: PGlite, { from = "", until = "~" } = {}) {
  for (const file of await migrationFiles()) {
    if (file < from || file >= until) continue;
    const sql = await readFile(new URL(file, migrations), "utf8");
    // PGlite provides core gen_random_uuid(), but not Supabase's pgcrypto extension.
    await db.exec(sql.replace("create extension if not exists pgcrypto;", ""));
  }
}

/**
 * PGlite with Supabase's auth stand-ins and the migrations applied in order. Pass `until`
 * to stop before a migration, seed data, and then finish with `applyMigrations`.
 */
export async function createMigratedDatabase(accounts: TestAccount[], { until = "~" } = {}) {
  const db = new PGlite();
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth;
    create table auth.users(id uuid primary key, email varchar(255), email_confirmed_at timestamptz);
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
    $$;
    grant usage on schema auth, public to authenticated, anon;
    grant execute on function auth.uid() to authenticated, anon;
  `);
  for (const account of accounts)
    await db.query("insert into auth.users values($1, $2, now())", [account.id, account.email]);
  await applyMigrations(db, { until });
  return db;
}
