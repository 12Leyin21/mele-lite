// Mele 推送中转（10-04，Mele Host 第四步）。跑在Tilia的 Cloudflare Workers 上；苹果推送钥匙（.p8）只在这里。
//
// POST /register {token, sandbox}  手机登记自己的苹果设备号 → {relay_id, relay_secret}
//                                   （存 KV：relay_id → 设备号 + 口令的哈希；口令原文只给手机，手机交给自己的 Host）
// POST /push {relay_id, sealed, sound, urgent}  Host 带着口令来推 → 照原样转给苹果
//      sealed 是 Host 用手机给的钥匙加密的推送内容，这里解不开；手机的通知扩展解开再显示。
//      苹果说这个设备没了（410）→ 删掉登记，回 410，Host 那边也删。
//
// 机密（wrangler secret put）：APNS_KEY（.p8 全文）、APNS_KEY_ID、APNS_TEAM_ID。普通变量 TOPIC（包名）。
// KV 绑定：DEVICES。

const enc = new TextEncoder();
const b64url = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const rand = (n) => b64url(crypto.getRandomValues(new Uint8Array(n)));
const sha256 = async (s) => b64url(await crypto.subtle.digest("SHA-256", enc.encode(s)));
const json = (obj, status = 200) => new Response(JSON.stringify(obj), { status, headers: { "content-type": "application/json" } });

let cachedJwt = null; // [token, issuedAtSeconds]

async function apnsJwt(env) {
  const now = Math.floor(Date.now() / 1000);
  if (cachedJwt && now - cachedJwt[1] < 50 * 60) return cachedJwt[0]; // 苹果要 20～60 分钟内换一次，别太勤
  const pem = env.APNS_KEY.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const head = b64url(enc.encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID })));
  const claims = b64url(enc.encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now })));
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(`${head}.${claims}`));
  cachedJwt = [`${head}.${claims}.${b64url(sig)}`, now];
  return cachedJwt[0];
}

async function register(req, env) {
  const body = await req.json().catch(() => ({}));
  const token = String(body.token || "");
  if (!/^[0-9a-f]{32,200}$/i.test(token)) return json({ detail: "设备号不对" }, 400);
  const relayId = rand(16);
  const secret = rand(32);
  await env.DEVICES.put(relayId, JSON.stringify({ token, sandbox: !!body.sandbox, secret: await sha256(secret) }));
  return json({ relay_id: relayId, relay_secret: secret });
}

async function push(req, env) {
  const body = await req.json().catch(() => ({}));
  const raw = await env.DEVICES.get(String(body.relay_id || ""));
  // 找不到不回 410：KV 是最终一致的，刚登记的设备在别的机房可能一分钟内还查不到，回 410 会让 Host 把它删了
  if (!raw) return json({ detail: "没有这个设备" }, 404);
  const dev = JSON.parse(raw);
  const auth = (req.headers.get("authorization") || "").replace(/^Bearer\s+/i, "");
  if (!auth || (await sha256(auth)) !== dev.secret) return json({ detail: "口令不对" }, 403);
  if (typeof body.sealed !== "string" || body.sealed.length > 3500) return json({ detail: "内容不对" }, 400);

  // 锁屏上先放一句占位，通知扩展解开以后换成真的名字和话；解不开就显示这句
  const aps = { alert: { title: "Mele", body: "有一条新消息" }, "mutable-content": 1 };
  if (body.sound) aps.sound = "default";
  if (body.urgent) aps["interruption-level"] = "time-sensitive";
  const host = dev.sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
  const res = await fetch(`${host}/3/device/${dev.token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${await apnsJwt(env)}`,
      "apns-topic": env.TOPIC,
      "apns-push-type": "alert",
      "apns-priority": "10",
    },
    body: JSON.stringify({ aps, sealed: body.sealed }),
  });
  if (res.status === 200) return json({ ok: true });
  const reason = (await res.json().catch(() => ({}))).reason || "";
  if (res.status === 410 || ["BadDeviceToken", "Unregistered", "DeviceTokenNotForTopic"].includes(reason)) {
    await env.DEVICES.delete(String(body.relay_id));
    return json({ reason: reason || "Unregistered" }, 410);
  }
  return json({ reason }, res.status >= 500 ? 502 : res.status);
}

export default {
  async fetch(req, env) {
    const { pathname } = new URL(req.url);
    if (req.method === "POST" && pathname === "/register") return register(req, env);
    if (req.method === "POST" && pathname === "/push") return push(req, env);
    if (req.method === "GET" && pathname === "/") return new Response("Mele push relay\n");
    return json({ detail: "not found" }, 404);
  },
};
