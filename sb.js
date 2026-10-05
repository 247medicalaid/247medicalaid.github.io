/* ══════════════════════════════════════════════════════════════════════════
   sb.js — conexión a Supabase compartida por todas las apps del portal.
   Va en la raíz del repo 247medicalaid.github.io. Necesita cargarse después de
   https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2

   La clave de aquí es la PUBLICABLE: está hecha para ir en las páginas. Lo que
   protege los datos son las reglas de acceso (RLS) de cada tabla.
   ══════════════════════════════════════════════════════════════════════════ */
(function () {
  var SB_URL = 'https://tftyyzoowctuhggwlgyt.supabase.co';
  var SB_KEY = 'sb_publishable_6hyJ-BV6detLiBszteEolQ_SiWlD8d1';
  var DOMINIO = 'usuarios.247medical-aid.com';

  window.SB_URL = SB_URL;
  window.SB_KEY = SB_KEY;
  window.sb = (window.supabase && window.supabase.createClient)
    ? window.supabase.createClient(SB_URL, SB_KEY, {
        auth: { persistSession: true, autoRefreshToken: true, storageKey: 'portal247.sb' }
      })
    : null;

  /* Entra a Supabase con la misma clave derivada que usa el portal. Si la
     cuenta aún no existe allá, la crea portal-sync tras confirmar con el
     portal actual. Nunca lanza error: durante la transición, Supabase no debe
     impedir entrar al portal. Devuelve true si quedó conectado. */
  window.sbConectar = function (usuario, dk) {
    // La promesa queda en window.sbPendiente: el portal la espera si alguien
    // abre una app antes de que termine (salir de la página la cortaría).
    window.sbPendiente = conectar(usuario, dk).finally(function () { window.sbPendiente = null; });
    return window.sbPendiente;
  };
  async function conectar(usuario, dk) {
    if (!window.sb) return false;
    var email = String(usuario).trim().toLowerCase() + '@' + DOMINIO;
    try {
      var r = await window.sb.auth.signInWithPassword({ email: email, password: dk });
      if (!r.error) {
        // Entró. ¿Tiene perfil? Si un alta anterior quedó a medias, se repara.
        var pf = await window.sb.from('perfiles').select('usuario').eq('user_id', r.data.user.id).maybeSingle();
        if (pf.data) return true;
      }
      var f = await fetch(SB_URL + '/functions/v1/portal-sync', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', 'apikey': SB_KEY },
        body: JSON.stringify({ username: usuario, dk: dk })
      });
      if (!f.ok) { console.warn('portal-sync:', f.status, await f.text()); return false; }
      r = await window.sb.auth.signInWithPassword({ email: email, password: dk });
      if (r.error) console.warn('Supabase:', r.error.message);
      return !r.error;
    } catch (e) {
      console.warn('Supabase no disponible:', e && e.message);
      return false;
    }
  }

  /* ── Login rápido (paso 8) ───────────────────────────────────────────────
     Supabase confirma usuario y clave (~0,3 s) y la función portal-cuentas
     firma la llave de sesión del portal igual que Portal.gs. El portal sigue
     haciendo su login con Google por detrás: Google es quien manda.
     Devuelve { ok:true, token, user } o { ok:false, codigo }. Nunca lanza. */
  window.sbCuentas = async function (accion, cuerpo, jwt) {
    var h = { 'Content-Type': 'application/json', 'apikey': SB_KEY };
    if (jwt) h.Authorization = 'Bearer ' + jwt;
    var r = await fetch(SB_URL + '/functions/v1/portal-cuentas', {
      method: 'POST', headers: h, body: JSON.stringify(Object.assign({ accion: accion }, cuerpo || {}))
    });
    var j = null;
    try { j = await r.json(); } catch (e) {}
    return j || { ok: false, codigo: 'HTTP_' + r.status };
  };
  window.sbEntrarRapido = async function (usuario, dk) {
    if (!window.sb) return { ok: false, codigo: 'SIN_SUPABASE' };
    var email = String(usuario).trim().toLowerCase() + '@' + DOMINIO;
    try {
      var r = await window.sb.auth.signInWithPassword({ email: email, password: dk });
      if (r.error || !r.data.session) return { ok: false, codigo: 'SB_CLAVE' };
      var j = await window.sbCuentas('llave', {}, r.data.session.access_token);
      return (j && j.ok && j.token) ? j : { ok: false, codigo: (j && j.codigo) || 'SIN_LLAVE' };
    } catch (e) {
      return { ok: false, codigo: 'SB_RED' };
    }
  };
  /* Le pasa a Supabase la época de un token real de Google (la necesita para
     firmar llaves que Google acepte después de «cerrar todas las sesiones»). */
  window.sbRegistrarEpoca = function (token) {
    if (!token) return Promise.resolve(null);
    return window.sbCuentas('epoca', { token: token }).catch(function () { return null; });
  };

  window.sbSalir = function () {
    try { if (window.sb) window.sb.auth.signOut(); } catch (e) {}
  };
})();
