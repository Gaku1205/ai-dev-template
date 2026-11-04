// ログアウト（フォームの POST で呼ぶ）
import { NextResponse } from "next/server";
import { authEnabled } from "@/lib/env";
import { supabaseServer } from "@/lib/supabase/server";

export async function POST(request: Request) {
  if (authEnabled()) {
    const supabase = await supabaseServer();
    await supabase.auth.signOut();
  }
  return NextResponse.redirect(new URL("/", request.url), 303);
}
