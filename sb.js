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
  window.sbConectar = async function (usuario, dk) {
    if (!window.sb) return false;
    var email = String(usuario).trim().toLowerCase() + '@' + DOMINIO;
    try {
      var r = await window.sb.auth.signInWithPassword({ email: email, password: dk });
      if (!r.error) return true;
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
  };

  window.sbSalir = function () {
    try { if (window.sb) window.sb.auth.signOut(); } catch (e) {}
  };
})();
