/* ══════════════════════════════════════════════════════════════════════════
   sb.js — conexión a Supabase compartida por todas las apps del portal.
   Va en la raíz del repo 247medicalaid.github.io. Necesita cargarse después de
   https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.119.0/dist/umd/supabase.js

   La clave de aquí es la PUBLICABLE: está hecha para ir en las páginas. Lo que
   protege los datos son las reglas de acceso (RLS) de cada tabla.
   ══════════════════════════════════════════════════════════════════════════ */
(function () {
  var SB_URL = 'https://tftyyzoowctuhggwlgyt.supabase.co';
  var SB_KEY = 'sb_publishable_6hyJ-BV6detLiBszteEolQ_SiWlD8d1';
  var DOMINIO = 'usuarios.247medical-aid.com';

  window.SB_URL = SB_URL;
  window.SB_KEY = SB_KEY;
  function crearSb() {
    return window.supabase.createClient(SB_URL, SB_KEY, {
      auth: { persistSession: true, autoRefreshToken: true, storageKey: 'portal247.sb' }
    });
  }
  window.sb = (window.supabase && window.supabase.createClient) ? crearSb() : null;

  /* (12 nov 2026) Si la librería supabase-js no cargó desde jsdelivr (CDN caído o
     bloqueado en esa red), se trae de la copia propia en github.io y, si no, de unpkg.
     window.sbListo se resuelve en true cuando window.sb queda listo (o false si no hubo forma). */
  var RESPALDOS = ['https://247medicalaid.github.io/supabase-js-2.119.0.js',
                   'https://unpkg.com/@supabase/supabase-js@2.119.0/dist/umd/supabase.js'];
  window.sbListo = window.sb ? Promise.resolve(true) : new Promise(function (res) {
    (function sig(i) {
      if (window.supabase && window.supabase.createClient) {
        try { if (!window.sb) window.sb = crearSb(); } catch (e) {}
        return res(!!window.sb);
      }
      if (i >= RESPALDOS.length) return res(false);
      var sc = document.createElement('script'), hecho = false;
      var seguir = function () { if (hecho) return; hecho = true; clearTimeout(t); sig(i + 1); };
      var t = setTimeout(seguir, 10000);
      sc.src = RESPALDOS[i]; sc.onload = seguir; sc.onerror = seguir;
      (document.head || document.documentElement).appendChild(sc);
    })(0);
  });

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
    if (!window.sb) await window.sbListo;
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
    if (!window.sb) await window.sbListo;
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
  /* ── Cuenta con correo propio (19 nov 2026 · Solo 24/7) ─────────────────
     Una cuenta del portal cuyo correo NO es @usuarios (p. ej. el administrador
     con callcenter@…) la maneja Supabase, igual que en 247Punch: correo +
     contraseña tal cual (sin la llave derivada). El portal sigue pidiendo
     usuario y contraseña: con el usuario busca ese correo.
     sbCorreoPropio(usuario) → correo o null (null también si no hay red).
     sbEntrarPropio(correo, clave) → { ok:true, token, user } o { ok:false, codigo }. */
  window.sbCorreoPropio = async function (usuario) {
    if (!window.sb) await window.sbListo;
    if (!window.sb) return null;
    try {
      var r = await window.sb.rpc('portal_correo_propio', { p_usuario: String(usuario || '').trim().toLowerCase() });
      return (!r.error && typeof r.data === 'string' && r.data) ? r.data : null;
    } catch (e) { return null; }
  };
  window.sbEntrarPropio = async function (correo, clave) {
    if (!window.sb) await window.sbListo;
    if (!window.sb) return { ok: false, codigo: 'SIN_SUPABASE' };
    try {
      var r = await window.sb.auth.signInWithPassword({ email: String(correo).trim().toLowerCase(), password: clave });
      if (r.error || !r.data.session) return { ok: false, codigo: /invalid/i.test((r.error && r.error.message) || '') ? 'SB_CLAVE' : 'SB_ERROR' };
      // (20 nov 2026) Segundo paso encendido: falta el código antes de pedir la llave del portal (sbMfaVerificar).
      if (await window.sbMfaFalta()) return { ok: false, codigo: 'MFA' };
      if (await window.sbMfaConfigurarFalta()) return { ok: false, codigo: 'MFA_CONFIGURAR' };   // (v405) tras un reset
      var j = await window.sbCuentas('llave', {}, r.data.session.access_token);
      if (j && j.ok && j.token) return j;
      try { await window.sb.auth.signOut({ scope: 'local' }); } catch (e) {}
      return { ok: false, codigo: (j && j.codigo) || 'SIN_LLAVE', msg: j && j.msg };
    } catch (e) {
      return { ok: false, codigo: 'SB_RED' };
    }
  };
  /* (20 nov 2026) Segundo paso (código de una app) para administradores — paso 181.
     sbMfaFalta() → true si la cuenta tiene el segundo paso y la sesión todavía no puso el código.
     sbMfaVerificar(codigo) → { ok:true, token, user } (la llave del portal) o { ok:false, codigo }. */
  window.sbMfaFalta = async function () {
    try {
      var a = await window.sb.auth.mfa.getAuthenticatorAssuranceLevel();
      return !!(a && a.data && a.data.nextLevel === 'aal2' && a.data.currentLevel !== 'aal2');
    } catch (e) { return false; }
  };
  /* (v405, paso 182) Tras un reset o un código de respaldo, la cuenta debe configurar el segundo paso otra vez
     (eso se hace en el Time Clock). sbMfaRespaldo(codigo) usa un código de respaldo. */
  window.sbMfaConfigurarFalta = async function () {
    try {
      var r = await window.sb.rpc('reloj_mfa_estado');
      return !!(r && r.data && r.data.requerido && !r.data.factor);
    } catch (e) { return false; }
  };
  window.sbMfaRespaldo = async function (codigo) {
    try {
      var r = await window.sb.rpc('reloj_mfa_usar_respaldo', { p_codigo: String(codigo || '') });
      if (r.error) return { ok: false, codigo: /Demasiados/.test(r.error.message || '') ? 'MFA_ESPERA' : /no tiene c/.test(r.error.message || '') ? 'SIN_CODIGOS' : 'SB_ERROR' };
      return r.data && r.data.ok ? { ok: true, quedan: r.data.quedan } : { ok: false, codigo: 'RESPALDO_MAL' };
    } catch (e) { return { ok: false, codigo: 'SB_RED' }; }
  };
  window.sbMfaVerificar = async function (codigo) {
    try {
      var c = String(codigo || '').replace(/\s+/g, '');
      if (!/^\d{6}$/.test(c)) return { ok: false, codigo: 'MFA_FORMATO' };
      var l = await window.sb.auth.mfa.listFactors();
      var f = ((l && l.data && l.data.totp) || []).filter(function (x) { return x.status === 'verified'; })[0];
      if (!f) return { ok: false, codigo: 'SIN_FACTOR' };
      var v = await window.sb.auth.mfa.challengeAndVerify({ factorId: f.id, code: c });
      if (v.error) return { ok: false, codigo: 'MFA_MAL' };
      var ses = (await window.sb.auth.getSession()).data.session;
      var j = await window.sbCuentas('llave', {}, ses.access_token);
      if (j && j.ok && j.token) return j;
      return { ok: false, codigo: (j && j.codigo) || 'SIN_LLAVE', msg: j && j.msg };
    } catch (e) { return { ok: false, codigo: 'SB_RED' }; }
  };
  /* Correo propio de la sesión de Supabase abierta (o null si es cuenta interna o no hay sesión). */
  window.sbCorreoDeSesion = async function () {
    try {
      var ses = window.sb ? (await window.sb.auth.getSession()).data.session : null;
      var em = ses && ses.user && String(ses.user.email || '').toLowerCase();
      return (em && em.slice(-(DOMINIO.length + 1)) !== '@' + DOMINIO) ? em : null;
    } catch (e) { return null; }
  };

  /* Le pasa a Supabase la época de un token real de Google (la necesita para
     firmar llaves que Google acepte después de «cerrar todas las sesiones»). */
  window.sbRegistrarEpoca = function (token) {
    if (!token) return Promise.resolve(null);
    return window.sbCuentas('epoca', { token: token }).catch(function () { return null; });
  };

  window.sbSalir = function () {
    // Solo este navegador: 'global' (lo que hace signOut sin opciones) cierra la
    // sesión de Supabase en TODOS los equipos del usuario, y las apps de esos
    // equipos se quedaban sin Supabase hasta volver a entrar.
    try { if (window.sb) window.sb.auth.signOut({ scope: 'local' }); } catch (e) {}
  };
})();
