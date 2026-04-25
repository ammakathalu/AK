// supabase/functions/verify-pin/index.ts
// Deploy: supabase functions deploy verify-pin

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import * as bcrypt from "https://deno.land/x/bcrypt@v0.4.1/mod.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const { phone, pin } = await req.json();

    if (!phone || !pin || pin.length !== 6 || !/^\d+$/.test(pin)) {
      return new Response(JSON.stringify({ error: "Invalid input" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Use SERVICE ROLE key for server-side operations — never expose to client
    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Fetch user by phone
    const { data: user, error } = await sb
      .from("users")
      .select("id, pin_hash, mother_name, child_name, child_age, lang_code, subscription_status, subscription_end, elevenlabs_voice_id, streak_days")
      .eq("phone", phone)
      .eq("is_active", true)
      .single();

    if (error || !user) {
      return new Response(JSON.stringify({ error: "User not found" }), {
        status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Verify PIN against bcrypt hash
    const valid = await bcrypt.compare(pin, user.pin_hash);
    if (!valid) {
      return new Response(JSON.stringify({ error: "Invalid PIN" }), {
        status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Create session token
    const token = crypto.randomUUID() + "-" + Date.now();
    const tokenHash = await bcrypt.hash(token);

    // Get device info from headers
    const deviceInfo = {
      userAgent: req.headers.get("user-agent") || "",
      language: req.headers.get("accept-language") || "",
    };

    // Store session
    await sb.from("login_sessions").insert({
      user_id: user.id,
      token_hash: tokenHash,
      device_info: deviceInfo,
      ip_address: req.headers.get("x-forwarded-for") || null,
      expires_at: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString(),
    });

    // Update last login
    await sb.from("users").update({ updated_at: new Date().toISOString() }).eq("id", user.id);

    // Return token + safe user data (never return pin_hash)
    const { pin_hash, ...safeUser } = user;

    return new Response(
      JSON.stringify({ token, user: safeUser }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    return new Response(JSON.stringify({ error: "Server error" }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
