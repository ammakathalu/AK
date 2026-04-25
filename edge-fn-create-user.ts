// supabase/functions/create-user/index.ts
// Deploy: supabase functions deploy create-user
// Only callable by admins (check Supabase auth role)

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
    const sb = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    // Verify caller is an authenticated admin
    const authHeader = req.headers.get("authorization");
    if (authHeader) {
      const token = authHeader.replace("Bearer ", "");
      const { data: { user }, error } = await createClient(
        Deno.env.get("SUPABASE_URL")!,
        Deno.env.get("SUPABASE_ANON_KEY")!
      ).auth.getUser(token);

      if (error || !user) {
        return new Response(JSON.stringify({ error: "Unauthorized" }), {
          status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }

      // Check admin table
      const { data: admin } = await sb.from("admins").select("id,role").eq("email", user.email).eq("is_active", true).single();
      if (!admin) {
        return new Response(JSON.stringify({ error: "Not an admin" }), {
          status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    }

    const body = await req.json();
    const {
      phone, pin, mother_name, child_name,
      child_age, lang_code, subscription_plan,
      subscription_status, subscription_end
    } = body;

    // Validate
    if (!phone || !pin || !mother_name) {
      return new Response(JSON.stringify({ error: "phone, pin, mother_name required" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }
    if (pin.length !== 6 || !/^\d+$/.test(pin)) {
      return new Response(JSON.stringify({ error: "PIN must be exactly 6 digits" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Normalize phone to E.164
    const normalizedPhone = phone.startsWith("+") ? phone : "+91" + phone.replace(/\D/g, "");

    // Check for duplicate
    const { data: existing } = await sb.from("users").select("id").eq("phone", normalizedPhone).single();
    if (existing) {
      return new Response(JSON.stringify({ error: "Phone already registered" }), {
        status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // Hash PIN with bcrypt (cost factor 12)
    const pin_hash = await bcrypt.hash(pin, 12);

    // Insert user
    const { data: newUser, error: insertError } = await sb.from("users").insert({
      phone: normalizedPhone,
      pin_hash,
      mother_name: mother_name.trim(),
      child_name: child_name?.trim() || null,
      child_age: child_age ? parseInt(child_age) : null,
      lang_code: lang_code || "te",
      subscription_status: subscription_status || "free",
      subscription_plan: subscription_plan || null,
      subscription_end: subscription_end || null,
      subscription_start: subscription_plan ? new Date().toISOString() : null,
      is_active: true,
    }).select("id, phone, mother_name, child_name, lang_code, subscription_status").single();

    if (insertError) throw insertError;

    return new Response(
      JSON.stringify({ success: true, user: newUser }),
      { status: 201, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error(err);
    return new Response(JSON.stringify({ error: err.message || "Server error" }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
