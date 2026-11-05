import type { SupabaseClient } from "@supabase/supabase-js";
import {
  createSharedSupabaseClient,
  redirectAuthCallback,
  takeAuthCallback,
} from "@jordiorriols/ui";

const redirecting = redirectAuthCallback("agents");
/** Taken out of the URL before the hash router reads it; completed by useSupabaseAuth. */
export const authCallback = redirecting ? null : takeAuthCallback();

const url = import.meta.env["VITE_SUPABASE_URL"] as string | undefined;
const publishableKey = import.meta.env["VITE_SUPABASE_PUBLISHABLE_KEY"] as string | undefined;

/** Null when the app is built without Supabase config, or while an auth callback is handed on. */
export const supabase: SupabaseClient | null =
  url && publishableKey && !redirecting ? createSharedSupabaseClient(url, publishableKey) : null;
