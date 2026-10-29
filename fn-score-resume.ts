// Scores a new applicant's resume with Claude and advances them (sends the "accepted" text) per settings.
// Called by the DB trigger on rp_candidates insert with { candidate_id }.
// Shared helpers for Surge Recruit edge functions
import { createClient } from "npm:@supabase/supabase-js@2";

export const admin = () => createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
export const SITE = Deno.env.get("SITE_URL") ?? "https://surge-partners.netlify.app";
export const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), { status, headers: { "Content-Type": "application/json" } });
export const e164 = (p: string) => { const d = (p || "").replace(/\D/g, ""); return d.length === 10 ? "+1" + d : d.length === 11 && d.startsWith("1") ? "+" + d : p; };
export const portalLink = (token: string) => `${SITE}/c/${token}`;
export const fill = (tpl: string, c: any, pos: any, meetingTime?: string) =>
  tpl.replace(/{first_name}/g, c.first_name ?? "").replace(/{position}/g, pos?.title ?? "Entry Level Sales Representative").replace(/{portal_link}/g, portalLink(c.token)).replace(/{meeting_time}/g, meetingTime ?? "");

// ---- Twilio ----
export async function twilioSend(to: string, body: string) {
  const sid = Deno.env.get("TWILIO_ACCOUNT_SID"), tok = Deno.env.get("TWILIO_AUTH_TOKEN"), from = Deno.env.get("TWILIO_FROM"), msid = Deno.env.get("TWILIO_MESSAGING_SERVICE_SID");
  if (!sid || !tok || (!from && !msid)) throw new Error("Twilio secrets not set");
  const form = new URLSearchParams({ To: e164(to), Body: body });
  if (msid) form.set("MessagingServiceSid", msid); else form.set("From", from!);
  const r = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, { method: "POST", headers: { Authorization: "Basic " + btoa(`${sid}:${tok}`), "Content-Type": "application/x-www-form-urlencoded" }, body: form });
  const j = await r.json();
  if (!r.ok) throw new Error(j.message || `Twilio ${r.status}`);
  return j.sid as string;
}

export async function twilioValid(req: Request, params: URLSearchParams): Promise<boolean> {
  const tok = Deno.env.get("TWILIO_AUTH_TOKEN"); const sig = req.headers.get("x-twilio-signature"); if (!tok || !sig) return false;
  const url = Deno.env.get("TWILIO_WEBHOOK_URL") ?? req.url;
  const data = url + [...params.keys()].sort().map(k => k + params.get(k)).join("");
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(tok), { name: "HMAC", hash: "SHA-1" }, false, ["sign"]);
  const mac = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  const expected = btoa(String.fromCharCode(...new Uint8Array(mac)));
  return expected === sig;
}

// ---- Claude ----
export async function claude(system: string, messages: any[], maxTokens = 600): Promise<string> {
  const key = Deno.env.get("ANTHROPIC_API_KEY"); if (!key) throw new Error("ANTHROPIC_API_KEY not set");
  const r = await fetch("https://api.anthropic.com/v1/messages", { method: "POST", headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "Content-Type": "application/json" }, body: JSON.stringify({ model: Deno.env.get("ANTHROPIC_MODEL") ?? "claude-sonnet-4-5", max_tokens: maxTokens, system, messages }) });
  const j = await r.json(); if (!r.ok) throw new Error(j.error?.message || `Claude ${r.status}`);
  return (j.content ?? []).filter((b: any) => b.type === "text").map((b: any) => b.text).join("").trim();
}

// Send the outbox row for a message id (shared by sms-send and others)
export async function drainOutbox(sb: any, limit = 20) {
  const { data: rows } = await sb.from("rp_outbox").select("*, rp_candidates(phone,dnc,sms_capable)").eq("status", "pending").order("id").limit(limit);
  const results: any[] = [];
  for (const r of rows ?? []) {
    const c = r.rp_candidates;
    if (!c?.phone || c.dnc || c.sms_capable === false) { await sb.from("rp_outbox").update({ status: "failed", error: c?.dnc ? "DNC" : "no phone" }).eq("id", r.id); await sb.from("rp_messages").update({ delivery: "failed" }).eq("id", r.message_id); results.push({ id: r.id, skipped: true }); continue; }
    try { const sid = await twilioSend(c.phone, r.body); await sb.from("rp_outbox").update({ status: "sent", provider_id: sid, sent_at: new Date().toISOString() }).eq("id", r.id); await sb.from("rp_messages").update({ delivery: "sent" }).eq("id", r.message_id); results.push({ id: r.id, sid }); }
    catch (e) { await sb.from("rp_outbox").update({ status: "failed", error: String(e.message || e) }).eq("id", r.id); await sb.from("rp_messages").update({ delivery: "failed" }).eq("id", r.message_id); results.push({ id: r.id, error: String(e.message || e) }); }
  }
  return results;
}


Deno.serve(async (req) => {
  const { candidate_id } = await req.json().catch(() => ({}));
  if (!candidate_id) return json({ error: "candidate_id required" }, 400);
  const sb = admin();
  const { data: c } = await sb.from("rp_candidates").select("*").eq("id", candidate_id).single();
  if (!c) return json({ error: "not found" }, 404);
  const [{ data: pos }, { data: settings }] = await Promise.all([
    c.position_id ? sb.from("rp_positions").select("*").eq("id", c.position_id).single() : Promise.resolve({ data: null }),
    sb.from("rp_settings").select("key,value"),
  ]);
  const cfg = Object.fromEntries((settings ?? []).map((s: any) => [s.key, s.value]));
  const ai = { auto_accept: "score", accept_threshold: 50, ...(cfg.ai ?? {}) };
  let score: number | null = null, strengths: string[] = [], concerns: string[] = [], summary = "";

  if (c.resume_path && c.ai_score == null) {
    try {
      const { data: file } = await sb.storage.from("rp-resumes").download(c.resume_path);
      if (file) {
        const buf = new Uint8Array(await file.arrayBuffer());
        let b64 = ""; for (let i = 0; i < buf.length; i += 0x8000) b64 += String.fromCharCode.apply(null, buf.subarray(i, i + 0x8000) as any);
        b64 = btoa(b64);
        const isPdf = /\.pdf$/i.test(c.resume_path);
        const content: any[] = isPdf ? [{ type: "document", source: { type: "base64", media_type: "application/pdf", data: b64 } }] : [{ type: "text", text: "(resume file is not a PDF; evaluate on application data only)" }];
        content.push({ type: "text", text: `Evaluate this applicant for: ${pos?.title ?? "Entry Level Sales Representative"} (${pos?.position_type ?? "Life Insurance Sales Rep"}), ${pos?.comp_type ?? "commission only"}, ${pos?.work_arrangement ?? "remote"}, licensing: ${pos?.licensing ?? "not required"}. Entry level is welcome; we value customer service, phone/sales experience, coachability, work ethic, reliability. Respond ONLY with JSON: {"score": 0-100, "strengths": ["..."], "concerns": ["..."], "summary": "one sentence"}` });
        const out = await claude("You are a recruiting analyst for a life insurance sales team. Output strict JSON only.", [{ role: "user", content }], 700);
        const j = JSON.parse(out.replace(/^```json|```$/g, "").trim());
        score = Math.max(0, Math.min(100, Math.round(+j.score))); strengths = j.strengths ?? []; concerns = j.concerns ?? []; summary = j.summary ?? "";
        await sb.from("rp_candidates").update({ ai_score: score, ai_strengths: strengths, ai_concerns: concerns, ai_summary: summary }).eq("id", c.id);
      }
    } catch (e) { console.error("score", e); }
  }

  // ---- auto-advance: send "accepted" + scheduling link ----
  const already = await sb.from("rp_messages").select("id").eq("candidate_id", c.id).ilike("body", "%schedule a time%").limit(1);
  const accept = ai.auto_accept === "all" || (ai.auto_accept === "score" && (score == null || score >= +ai.accept_threshold));
  if (accept && c.status === "New" && !c.dnc && !(already.data?.length)) {
    const { data: t } = await sb.from("rp_templates").select("body").eq("key", "accepted").single();
    if (t) { await sb.from("rp_messages").insert({ candidate_id: c.id, direction: "out", sender: "ai", body: fill(t.body, c, pos) }); await drainOutbox(sb, 5); }
  }
  return json({ ok: true, score, accepted: accept });
});
