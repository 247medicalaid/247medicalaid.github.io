// 247 Time Clock para Windows (versión 1.0.2: ventana más angosta y más alta; la página puede fijar el tamaño)
// ------------------------------------------------------------------------------------------------
// Muestra la versión web del Reloj (https://247medicalaid.github.io/reloj.html) dentro de una ventana
// propia (WebView2, el motor de Edge que ya trae Windows) y le agrega lo que el navegador no puede:
//   · icono en la bandeja (junto al reloj de Windows) con el estado por color:
//       gris = sin entrada · verde = trabajando · amarillo = almuerzo · azul = falta iniciar sesión
//   · menú del icono para marcar (Clock in / almuerzo / Clock out) sin abrir la ventana a buscar el botón;
//     la marca la hace la misma página (mismas confirmaciones, misma ubicación, mismas reglas)
//   · arranca con Windows (lo deja configurado el instalador) y no se cierra con la X: se va a la bandeja
//   · avisos de Windows: fin del almuerzo, horas del día cumplidas, inicio del turno, salida pendiente
// No guarda claves ni tokens: el agente entra con su correo y contraseña, igual que en la web.
//
// Escrito en C# 5 para que lo compile el csc.exe que trae Windows (.NET Framework 4.x), como el Monitor.
// Compilar (lo hace instalar.ps1):
//   csc /nologo /target:winexe /optimize+ /win32icon:app.ico /out:TimeClock247.exe
//       /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll
//       /r:Microsoft.Web.WebView2.Core.dll /r:Microsoft.Web.WebView2.WinForms.dll TimeClock247.cs
// Opciones al arrancar: --tray (arranca escondido en la bandeja, así lo inicia Windows) · --debug (herramientas de desarrollo)
// ------------------------------------------------------------------------------------------------
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;

[assembly: System.Reflection.AssemblyTitle("247 Time Clock")]
[assembly: System.Reflection.AssemblyDescription("Time Clock de 24/7 Medical Aid para Windows")]
[assembly: System.Reflection.AssemblyCompany("24/7 Medical Aid - Call Center")]
[assembly: System.Reflection.AssemblyProduct("247 Time Clock")]
[assembly: System.Reflection.AssemblyVersion("1.0.2.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.0.2.0")]

namespace TimeClock247
{
    static class Programa
    {
        public const string Version = "1.0.2";
        public const string Url = "https://247medicalaid.github.io/reloj.html?app=win";
        public const string Sitio = "247medicalaid.github.io";
        public const string Nombre = "247 Time Clock";
        public const string MutexNombre = "Local\\TimeClock247_App";
        public const string EventoMostrar = "Local\\TimeClock247_Mostrar";
        public const string DescargaWebView2 = "https://go.microsoft.com/fwlink/p/?LinkId=2124703";

        [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
        [DllImport("user32.dll")] static extern bool AllowSetForegroundWindow(int procesoId);

        [STAThread]
        static void Main(string[] args)
        {
            bool enBandeja = false, debug = false;
            foreach (string a in args)
            {
                if (string.Equals(a, "--tray", StringComparison.OrdinalIgnoreCase)) enBandeja = true;
                if (string.Equals(a, "--debug", StringComparison.OrdinalIgnoreCase)) debug = true;
            }
            // Una sola copia por usuario: si ya está abierta, se le pide que muestre su ventana y esta se cierra.
            bool nueva;
            Mutex mutex = new Mutex(true, MutexNombre, out nueva);
            if (!nueva)
            {
                if (!enBandeja)
                {
                    try { AllowSetForegroundWindow(-1); } catch { }   // deja que la copia abierta pase al frente
                    try { EventWaitHandle ev = EventWaitHandle.OpenExisting(EventoMostrar); ev.Set(); } catch { }
                }
                return;
            }
            EventWaitHandle eventoMostrar = new EventWaitHandle(false, EventResetMode.AutoReset, EventoMostrar);
            try { SetProcessDPIAware(); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.ThreadException += delegate(object s, ThreadExceptionEventArgs e) { Registro.Escribir("Error: " + e.Exception); };
            AppDomain.CurrentDomain.UnhandledException += delegate(object s, UnhandledExceptionEventArgs e) { Registro.Escribir("Error fatal: " + e.ExceptionObject); };
            Registro.Escribir("Inicio " + Version + (enBandeja ? " (bandeja)" : ""));

            if (!WebView2Instalado())
            {
                DialogResult r = MessageBox.Show(
                    "The Time Clock needs Microsoft Edge WebView2 Runtime, which is not installed on this computer.\n\n" +
                    "Click OK to open the download page. Install it and then open the Time Clock again.",
                    Nombre, MessageBoxButtons.OKCancel, MessageBoxIcon.Warning);
                if (r == DialogResult.OK) Abrir(DescargaWebView2);
                return;
            }
            Application.Run(new Contexto(enBandeja, debug, eventoMostrar));
            GC.KeepAlive(mutex);
        }

        static bool WebView2Instalado()
        {
            try
            {
                CargadorWebView2();
                string v = CoreWebView2Environment.GetAvailableBrowserVersionString();
                return !string.IsNullOrEmpty(v);
            }
            catch (Exception e) { Registro.Escribir("WebView2 no disponible: " + e.Message); return false; }
        }

        // WebView2Loader.dll va en runtimes\win-<arquitectura>\native (como lo deja NuGet); se le indica la carpeta exacta.
        static bool cargadorListo;
        public static void CargadorWebView2()
        {
            if (cargadorListo) return;
            cargadorListo = true;
            string arq = (Environment.GetEnvironmentVariable("PROCESSOR_ARCHITECTURE") ?? "").ToUpperInvariant();
            string carpeta = arq == "ARM64" ? "win-arm64" : (Environment.Is64BitProcess ? "win-x64" : "win-x86");
            string ruta = Path.Combine(Path.Combine(Path.Combine(Carpeta.Programa, "runtimes"), carpeta), "native");
            try { if (File.Exists(Path.Combine(ruta, "WebView2Loader.dll"))) CoreWebView2Environment.SetLoaderDllFolderPath(ruta); }
            catch (Exception e) { Registro.Escribir("SetLoaderDllFolderPath: " + e.Message); }
        }

        public static void Abrir(string url)
        {
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch (Exception e) { Registro.Escribir("No se pudo abrir " + url + ": " + e.Message); }
        }
    }

    static class Carpeta
    {
        public static string Programa { get { return AppDomain.CurrentDomain.BaseDirectory; } }
        // Datos de este usuario (sesión de la página, posición de la ventana, registro): %LOCALAPPDATA%\247TimeClock
        public static string Datos
        {
            get
            {
                string d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "247TimeClock");
                try { Directory.CreateDirectory(d); } catch { }
                return d;
            }
        }
    }

    // Registro corto en %LOCALAPPDATA%\247TimeClock\registro.txt (se recorta solo) para revisar problemas.
    static class Registro
    {
        static readonly object candado = new object();
        public static void Escribir(string texto)
        {
            try
            {
                lock (candado)
                {
                    string f = Path.Combine(Carpeta.Datos, "registro.txt");
                    FileInfo fi = new FileInfo(f);
                    if (fi.Exists && fi.Length > 512 * 1024)
                    {
                        string viejo = f + ".1";
                        if (File.Exists(viejo)) File.Delete(viejo);
                        File.Move(f, viejo);
                    }
                    File.AppendAllText(f, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + texto + Environment.NewLine, Encoding.UTF8);
                }
            }
            catch { }
        }
    }

    // Ajustes simples (clave=valor) en %LOCALAPPDATA%\247TimeClock\ajustes.txt
    class Ajustes
    {
        readonly Dictionary<string, string> d = new Dictionary<string, string>();
        readonly string archivo;
        public Ajustes()
        {
            archivo = Path.Combine(Carpeta.Datos, "ajustes.txt");
            try
            {
                if (File.Exists(archivo))
                    foreach (string l in File.ReadAllLines(archivo, Encoding.UTF8))
                    {
                        int i = l.IndexOf('=');
                        if (i > 0) d[l.Substring(0, i).Trim()] = l.Substring(i + 1).Trim();
                    }
            }
            catch { }
        }
        public string Leer(string k, string defecto) { string v; return d.TryGetValue(k, out v) ? v : defecto; }
        public int LeerInt(string k, int defecto) { int v; return int.TryParse(Leer(k, ""), out v) ? v : defecto; }
        public void Poner(string k, string v) { d[k] = v ?? ""; }
        public void Guardar()
        {
            try
            {
                StringBuilder sb = new StringBuilder();
                foreach (KeyValuePair<string, string> kv in d) sb.Append(kv.Key).Append('=').Append(kv.Value).Append("\r\n");
                File.WriteAllText(archivo, sb.ToString(), Encoding.UTF8);
            }
            catch { }
        }
    }

    // Un recordatorio que manda la página: «en» = segundos desde que llegó el estado.
    class Recordatorio
    {
        public string Id, Titulo, Texto;
        public int En;
    }

    // Lo que la página cuenta del agente (mensaje {tipo:'estado', ...}).
    class EstadoReloj
    {
        public bool Conectado, Empleado;
        public string Estado = "fuera", Nombre = "", DesdeTxt = "", EntradaTxt = "";
        public int MinHoy, HorasDia = 8;
        public DateTime Recibido = DateTime.UtcNow;
        public List<Recordatorio> Recordatorios = new List<Recordatorio>();

        public bool EnTurno { get { return Estado == "trabajando" || Estado == "almuerzo"; } }

        public static EstadoReloj Leer(string json)
        {
            JavaScriptSerializer js = new JavaScriptSerializer();
            Dictionary<string, object> o = js.Deserialize<Dictionary<string, object>>(json);
            if (o == null || Texto(o, "tipo") != "estado") return null;
            EstadoReloj e = new EstadoReloj();
            e.Conectado = Bool(o, "conectado");
            e.Empleado = Bool(o, "empleado");
            e.Estado = Texto(o, "estado");
            if (e.Estado != "trabajando" && e.Estado != "almuerzo") e.Estado = "fuera";
            e.Nombre = Texto(o, "nombre");
            e.DesdeTxt = Texto(o, "desdeTxt");
            e.EntradaTxt = Texto(o, "entradaTxt");
            e.MinHoy = Entero(o, "minHoy");
            e.HorasDia = Math.Max(1, Entero(o, "horasDia", 8));
            object lista;
            if (o.TryGetValue("recordatorios", out lista) && lista is System.Collections.ArrayList)
                foreach (object x in (System.Collections.ArrayList)lista)
                {
                    Dictionary<string, object> r = x as Dictionary<string, object>;
                    if (r == null) continue;
                    Recordatorio rec = new Recordatorio();
                    rec.Id = Texto(r, "id"); rec.Titulo = Texto(r, "titulo"); rec.Texto = Texto(r, "texto"); rec.En = Entero(r, "en");
                    if (rec.Id.Length > 0 && rec.Titulo.Length > 0) e.Recordatorios.Add(rec);
                }
            return e;
        }
        // Mensaje {tipo:'ventana', ancho, alto}: el tamaño que quiere el diseño de la página (en píxeles a 100 %).
        // Así se puede ajustar el tamaño desde la web sin reinstalar la app. Fuera de rango → null.
        public static int[] LeerVentana(string json)
        {
            JavaScriptSerializer js = new JavaScriptSerializer();
            Dictionary<string, object> o = js.Deserialize<Dictionary<string, object>>(json);
            if (o == null || Texto(o, "tipo") != "ventana") return null;
            int an = Entero(o, "ancho"), al = Entero(o, "alto");
            if (an < 640 || an > 1600 || al < 480 || al > 1400) return null;
            return new int[] { an, al };
        }

        static string Texto(Dictionary<string, object> o, string k) { object v; return o.TryGetValue(k, out v) && v != null ? Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture) : ""; }
        static bool Bool(Dictionary<string, object> o, string k) { object v; return o.TryGetValue(k, out v) && v is bool && (bool)v; }
        static int Entero(Dictionary<string, object> o, string k) { return Entero(o, k, 0); }
        static int Entero(Dictionary<string, object> o, string k, int defecto)
        {
            object v;
            if (!o.TryGetValue(k, out v) || v == null) return defecto;
            try { return Convert.ToInt32(Math.Round(Convert.ToDouble(v, System.Globalization.CultureInfo.InvariantCulture))); } catch { return defecto; }
        }

        // Minutos trabajados hoy, contando lo que pasó desde que llegó el estado.
        public int MinutosAhora(DateTime ahoraUtc)
        {
            if (Estado != "trabajando") return MinHoy;
            return MinHoy + (int)Math.Max(0, (ahoraUtc - Recibido).TotalMinutes);
        }

        public static string Duracion(int min) { return (min / 60) + ":" + (min % 60).ToString("00"); }

        public string TextoEstado(DateTime ahoraUtc)
        {
            if (!Conectado) return "Sign in to the Time Clock";
            if (!Empleado) return "No time clock for this account";
            if (Estado == "trabajando") return "Working · " + Duracion(MinutosAhora(ahoraUtc)) + " h today";
            if (Estado == "almuerzo") return "On lunch" + (DesdeTxt.Length > 0 ? " since " + DesdeTxt : "") + " · " + Duracion(MinHoy) + " h today";
            return MinHoy > 0 ? "Off shift · " + Duracion(MinHoy) + " h today" : "Off shift";
        }

        // El texto del icono (Windows admite como máximo 63 caracteres).
        public string TextoIcono(DateTime ahoraUtc)
        {
            string t = Programa.Nombre + "\n" + TextoEstado(ahoraUtc);
            return t.Length > 63 ? t.Substring(0, 63) : t;
        }
    }

    // Los recordatorios ya mostrados (por día), para no repetirlos al reabrir el programa.
    class Avisados
    {
        readonly Ajustes ajustes;
        readonly HashSet<string> ids = new HashSet<string>();
        string dia;
        public Avisados(Ajustes a)
        {
            ajustes = a;
            dia = DateTime.Now.ToString("yyyy-MM-dd");
            if (a.Leer("avisadosDia", "") == dia)
                foreach (string s in a.Leer("avisados", "").Split('¦')) if (s.Length > 0) ids.Add(s);
        }
        public bool Ya(string id) { Revisar(); return ids.Contains(id); }
        public void Marcar(string id)
        {
            Revisar(); ids.Add(id);
            ajustes.Poner("avisadosDia", dia); ajustes.Poner("avisados", string.Join("¦", new List<string>(ids).ToArray())); ajustes.Guardar();
        }
        void Revisar() { string hoy = DateTime.Now.ToString("yyyy-MM-dd"); if (hoy != dia) { dia = hoy; ids.Clear(); } }
    }

    // Iconos de la bandeja dibujados aquí (un círculo de color con un reloj blanco).
    static class Iconos
    {
        [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
        static readonly Dictionary<string, Icon> cache = new Dictionary<string, Icon>();

        public static Icon DeEstado(EstadoReloj e)
        {
            string clave = e == null ? "fuera" : (!e.Conectado || !e.Empleado ? "sesion" : e.Estado);
            Icon ic;
            if (cache.TryGetValue(clave, out ic)) return ic;
            Color c = clave == "trabajando" ? Color.FromArgb(46, 158, 91)
                    : clave == "almuerzo" ? Color.FromArgb(230, 160, 31)
                    : clave == "sesion" ? Color.FromArgb(23, 169, 222)
                    : Color.FromArgb(128, 141, 153);
            ic = Dibujar(c, clave == "almuerzo");
            cache[clave] = ic;
            return ic;
        }

        static Icon Dibujar(Color fondo, bool pausa)
        {
            Size t = SystemInformation.SmallIconSize;
            int n = Math.Max(16, Math.Max(t.Width, t.Height));
            using (Bitmap bmp = new Bitmap(n, n))
            {
                using (Graphics g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.Clear(Color.Transparent);
                    float m = n * 0.04f, d = n - 2 * m;
                    using (SolidBrush b = new SolidBrush(fondo)) g.FillEllipse(b, m, m, d, d);
                    float cx = n / 2f, cy = n / 2f, grosor = Math.Max(1.6f, n / 9f);
                    using (Pen p = new Pen(Color.White, grosor))
                    {
                        p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
                        if (pausa)
                        {   // almuerzo: dos barras de pausa
                            g.DrawLine(p, cx - n * 0.13f, cy - n * 0.2f, cx - n * 0.13f, cy + n * 0.2f);
                            g.DrawLine(p, cx + n * 0.13f, cy - n * 0.2f, cx + n * 0.13f, cy + n * 0.2f);
                        }
                        else
                        {   // reloj: aguja larga hacia arriba y corta hacia la derecha
                            g.DrawLine(p, cx, cy, cx, cy - n * 0.3f);
                            g.DrawLine(p, cx, cy, cx + n * 0.22f, cy + n * 0.08f);
                        }
                    }
                }
                IntPtr h = bmp.GetHicon();
                Icon temp = Icon.FromHandle(h);
                Icon copia = (Icon)temp.Clone();
                temp.Dispose();
                DestroyIcon(h);
                return copia;
            }
        }

        public static Icon DelPrograma()
        {
            try { Icon i = Icon.ExtractAssociatedIcon(Application.ExecutablePath); if (i != null) return i; } catch { }
            return DeEstado(null);
        }
    }

    // El programa: icono de la bandeja + ventana con la página.
    class Contexto : ApplicationContext
    {
        readonly NotifyIcon icono = new NotifyIcon();
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly ToolStripMenuItem miTitulo, miAbrir, miEntrada, miAlmIni, miAlmFin, miSalida, miEntrar, miRecargar, miAcerca, miSalir;
        readonly ToolStripSeparator sepMarcas;
        readonly System.Windows.Forms.Timer reloj = new System.Windows.Forms.Timer();
        readonly Ventana ventana;
        readonly Ajustes ajustes = new Ajustes();
        readonly Avisados avisados;
        readonly EventWaitHandle eventoMostrar;
        EstadoReloj estado;
        DateTime ultimoPedido = DateTime.MinValue;
        bool saliendo, avisoBandejaMostrado, pidioEntrar;

        public Contexto(bool enBandeja, bool debug, EventWaitHandle evMostrar)
        {
            eventoMostrar = evMostrar;
            avisados = new Avisados(ajustes);
            avisoBandejaMostrado = ajustes.Leer("avisoBandeja", "") == "1";

            Font negrita = new Font(menu.Font, FontStyle.Bold);
            miTitulo = new ToolStripMenuItem(Programa.Nombre) { Enabled = false };
            miAbrir = new ToolStripMenuItem("Open Time Clock", null, delegate { Mostrar(); }) { Font = negrita };
            miEntrada = new ToolStripMenuItem("Clock in", null, delegate { Marcar("entrada"); });
            miAlmIni = new ToolStripMenuItem("Start lunch", null, delegate { Marcar("almuerzo_ini"); });
            miAlmFin = new ToolStripMenuItem("End lunch", null, delegate { Marcar("almuerzo_fin"); });
            miSalida = new ToolStripMenuItem("Clock out", null, delegate { Marcar("salida"); });
            miEntrar = new ToolStripMenuItem("Sign in…", null, delegate { Mostrar(); });
            miRecargar = new ToolStripMenuItem("Reload", null, delegate { ventana.Recargar(); });
            miAcerca = new ToolStripMenuItem("About " + Programa.Nombre, null, delegate { Acerca(); });
            miSalir = new ToolStripMenuItem("Exit", null, delegate { Salir(); });
            sepMarcas = new ToolStripSeparator();
            menu.Items.AddRange(new ToolStripItem[] { miTitulo, new ToolStripSeparator(), miAbrir, sepMarcas,
                miEntrada, miAlmIni, miAlmFin, miSalida, miEntrar, new ToolStripSeparator(), miRecargar, miAcerca, miSalir });
            menu.Opening += delegate { PintarMenu(); };

            icono.ContextMenuStrip = menu;
            icono.Icon = Iconos.DeEstado(null);
            icono.Text = Programa.Nombre;
            icono.Visible = true;
            icono.MouseClick += delegate(object s, MouseEventArgs e) { if (e.Button == MouseButtons.Left) Mostrar(); };
            icono.BalloonTipClicked += delegate { Mostrar(); };

            ventana = new Ventana(ajustes, debug);
            ventana.EstadoRecibido += AlRecibirEstado;
            ventana.CerrarPedido += AlCerrarVentana;
            ventana.TerminarPedido += delegate { Terminar(); };
            ventana.PaginaLista += delegate { PedirEstado(); };
            if (enBandeja) ventana.IniciarEscondida(); else ventana.Mostrar();

            // si abren el programa otra vez (acceso directo), la copia que ya corre muestra su ventana
            Thread hilo = new Thread(delegate()
            {
                while (true)
                {
                    try { eventoMostrar.WaitOne(); } catch { return; }
                    try { ventana.BeginInvoke(new MethodInvoker(Mostrar)); } catch { }
                }
            });
            hilo.IsBackground = true;
            hilo.Start();

            reloj.Interval = 15000;
            reloj.Tick += delegate { Tic(); };
            reloj.Start();
            SystemEventsHelper.AlDespertar(delegate { ventana.BeginInvoke(new MethodInvoker(delegate { PedirEstado(); })); });
            // al cerrar sesión o apagar Windows (de verdad, no si se canceló): se quita el icono y se termina sin preguntar
            Microsoft.Win32.SystemEvents.SessionEnded += delegate { try { Terminar(); } catch { } };   // (llega en el hilo de la ventana)
        }

        void Mostrar() { ventana.Mostrar(); }

        void PedirEstado()
        {
            ultimoPedido = DateTime.UtcNow;
            ventana.Enviar("{\"accion\":\"estado\"}");
        }

        void Marcar(string tipo)
        {
            // se muestra la ventana: la página pide confirmación (salida) y la ubicación como siempre
            ventana.Mostrar();
            // nunca se deja «para después»: una marca tardía sería peor que ninguna
            if (!ventana.EnviarAhora("{\"accion\":\"marcar\",\"tipo\":\"" + tipo + "\"}"))
                Avisar("The Time Clock isn't loaded yet", "Wait until the page shows your clock and try again.");
        }

        void AlRecibirEstado(EstadoReloj e)
        {
            string antes = estado == null ? "" : estado.Estado + (estado.Conectado ? "1" : "0");
            estado = e;
            Pintar();
            if (antes != e.Estado + (e.Conectado ? "1" : "0")) Registro.Escribir("Estado: " + (e.Conectado ? e.Estado : "sin sesión"));
            // la primera vez que falta iniciar sesión, se muestra la ventana (al arrancar escondido con Windows)
            if (!e.Conectado && !pidioEntrar)
            {
                pidioEntrar = true;
                if (!ventana.Visible) Avisar("Sign in to the Time Clock", "Click here to sign in with your email and password.");
            }
            if (e.Conectado) pidioEntrar = false;
            RevisarRecordatorios();
        }

        void Pintar()
        {
            DateTime ahora = DateTime.UtcNow;
            icono.Icon = Iconos.DeEstado(estado);
            string t = estado == null ? Programa.Nombre : estado.TextoIcono(ahora);
            if (estado != null && (ahora - estado.Recibido).TotalMinutes > 15) t = Programa.Nombre + "\nNot updated (offline?)";
            icono.Text = t.Length > 63 ? t.Substring(0, 63) : t;
        }

        void PintarMenu()
        {
            DateTime ahora = DateTime.UtcNow;
            bool con = estado != null && estado.Conectado && estado.Empleado;
            miTitulo.Text = estado != null && estado.Nombre.Length > 0 ? estado.Nombre + " — " + estado.TextoEstado(ahora) : Programa.Nombre;
            miEntrada.Visible = con && estado.Estado == "fuera";
            miAlmIni.Visible = con && estado.Estado == "trabajando";
            miSalida.Visible = con && estado.Estado == "trabajando";
            miAlmFin.Visible = con && estado.Estado == "almuerzo";
            miEntrar.Visible = estado != null && !estado.Conectado;
            sepMarcas.Visible = miEntrada.Visible || miAlmIni.Visible || miAlmFin.Visible || miEntrar.Visible;
        }

        void Tic()
        {
            Pintar();
            RevisarRecordatorios();
            // cada 2 minutos se le pide a la página que vuelva a leer (lo que cambió en otro equipo o lo que aprobó el administrador)
            if ((DateTime.UtcNow - ultimoPedido).TotalMinutes >= 2) PedirEstado();
        }

        void RevisarRecordatorios()
        {
            if (estado == null || !estado.Conectado) return;
            DateTime ahora = DateTime.UtcNow;
            foreach (Recordatorio r in estado.Recordatorios)
            {
                if (avisados.Ya(r.Id)) continue;
                DateTime cuando = estado.Recibido.AddSeconds(r.En);
                if (ahora < cuando) continue;
                if ((ahora - cuando).TotalMinutes > 30) { avisados.Marcar(r.Id); continue; }   // muy viejo (el PC estaba dormido)
                Avisar(r.Titulo, string.IsNullOrEmpty(r.Texto) ? r.Titulo : r.Texto);
                avisados.Marcar(r.Id);
                Registro.Escribir("Aviso: " + r.Id);
                break;   // uno a la vez
            }
        }

        // Aviso de Windows junto al icono; al hacerle clic se abre la ventana.
        void Avisar(string titulo, string texto)
        {
            if (string.IsNullOrEmpty(texto)) texto = titulo;
            try { icono.ShowBalloonTip(15000, titulo, texto, ToolTipIcon.Info); } catch (Exception e) { Registro.Escribir("Aviso: " + e.Message); }
        }

        void AlCerrarVentana()
        {
            if (!avisoBandejaMostrado)
            {
                avisoBandejaMostrado = true;
                ajustes.Poner("avisoBandeja", "1"); ajustes.Guardar();
                Avisar(Programa.Nombre + " is still running", "It stays here next to the clock. Click the icon to open it, right-click for options.");
            }
        }

        void Acerca()
        {
            MessageBox.Show(Programa.Nombre + " " + Programa.Version + "\n24/7 Medical Aid - Call Center\n\n" +
                "Shows the Time Clock (" + Programa.Sitio + ") and keeps it next to the clock.\n\n" +
                "Settings and log: " + Carpeta.Datos, Programa.Nombre, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        void Salir()
        {
            if (estado != null && estado.Conectado && estado.EnTurno)
            {
                string que = estado.Estado == "almuerzo" ? "on lunch" : "clocked in";
                DialogResult r = MessageBox.Show("You're still " + que + ".\n\nIf you exit, the Time Clock won't remind you to " +
                    (estado.Estado == "almuerzo" ? "end your lunch" : "clock out") + ". Exit anyway?",
                    Programa.Nombre, MessageBoxButtons.YesNo, MessageBoxIcon.Warning, MessageBoxDefaultButton.Button2);
                if (r != DialogResult.Yes) return;
            }
            Terminar();
        }

        void Terminar()
        {
            if (saliendo) return;
            saliendo = true;
            Registro.Escribir("Salir");
            reloj.Stop();
            icono.Visible = false;
            icono.Dispose();
            try { ventana.CerrarDeVerdad(); } catch { }
            ExitThread();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) { try { icono.Dispose(); menu.Dispose(); reloj.Dispose(); } catch { } }
            base.Dispose(disposing);
        }
    }

    // Avisa cuando el computador despierta (para volver a leer el estado enseguida).
    static class SystemEventsHelper
    {
        public static void AlDespertar(MethodInvoker accion)
        {
            Microsoft.Win32.SystemEvents.PowerModeChanged += delegate(object s, Microsoft.Win32.PowerModeChangedEventArgs e)
            {
                if (e.Mode == Microsoft.Win32.PowerModes.Resume) { try { accion(); } catch { } }
            };
        }
    }

    // La ventana con la página del Reloj.
    class Ventana : Form
    {
        public event Action<EstadoReloj> EstadoRecibido;
        public event Action CerrarPedido;
        public event Action PaginaLista;
        public event Action TerminarPedido;

        WebView2 web;   // se vuelve a crear si el motor de WebView2 se cae o no arranca
        readonly Ajustes ajustes;
        readonly bool debug;
        readonly System.Windows.Forms.Timer reintento = new System.Windows.Forms.Timer();
        bool listo, cerrarDeVerdad;
        readonly Queue<string> pendientes = new Queue<string>();
        readonly Label cargando = new Label();

        public Ventana(Ajustes a, bool dbg)
        {
            ajustes = a; debug = dbg;
            Text = "Time Clock · 24/7 Medical Aid";
            Icon = Iconos.DelPrograma();
            StartPosition = FormStartPosition.Manual;
            BackColor = Color.FromArgb(245, 248, 249);
            using (Graphics g = Graphics.FromHwnd(IntPtr.Zero)) escala = g.DpiX / 96f;   // DPI de la pantalla (sin crear la ventana todavía)
            // Tamaño fijo (pedido de Carlos): nunca más alta que la pantalla, sin cambiar de tamaño ni maximizar.
            // 1.0.2: más angosta y más alta (900 × 780). La página puede mandar otro tamaño ({tipo:'ventana'}), que se recuerda.
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;
            Rectangle area = Screen.PrimaryScreen.WorkingArea;
            ClientSize = Medida(ajustes.LeerInt("ancho", AnchoBase), ajustes.LeerInt("alto", AltoBase), area);
            int w = Width, h = Height;
            int x = ajustes.LeerInt("x", area.Left + (area.Width - w) / 2), y = ajustes.LeerInt("y", area.Top + (area.Height - h) / 2);
            Rectangle r = new Rectangle(x, y, w, h);
            bool visible = false;
            foreach (Screen s in Screen.AllScreens) if (s.WorkingArea.Contains(r)) { visible = true; break; }
            if (!visible) r = new Rectangle(area.Left + (area.Width - w) / 2, Math.Max(area.Top, area.Top + (area.Height - h) / 2), w, h);
            Location = r.Location;

            cargando.Text = "Loading the Time Clock…";
            cargando.Dock = DockStyle.Fill;
            cargando.TextAlign = ContentAlignment.MiddleCenter;
            cargando.ForeColor = Color.FromArgb(74, 100, 120);
            cargando.Font = new Font("Segoe UI", 11f);
            Controls.Add(cargando);
            CrearWeb();

            reintento.Interval = 30000;
            reintento.Tick += delegate { reintento.Stop(); if (rehacer) Rehacer(); else Recargar(); };

            ResizeEnd += delegate { GuardarPosicion(); };   // (al terminar de moverla)
            FormClosing += AlCerrar;
            Iniciar();
        }

        const int AnchoBase = 900, AltoBase = 780;
        float escala = 1f;

        // Tamaño del área de la página: el pedido × DPI, sin pasar del área útil de la pantalla
        // (lo alto deja lugar a la barra de título, para que la ventana entera quepa).
        Size Medida(int ancho, int alto, Rectangle area)
        {
            int marcoAlto = Height - ClientSize.Height, marcoAncho = Width - ClientSize.Width;
            if (marcoAlto <= 0) marcoAlto = (int)(40 * escala);
            if (marcoAncho <= 0) marcoAncho = (int)(16 * escala);
            int cw = Math.Min((int)(ancho * escala), area.Width - marcoAncho - 20);
            int ch = Math.Min((int)(alto * escala), area.Height - marcoAlto - 10);
            return new Size(Math.Max(cw, 480), Math.Max(ch, 360));
        }

        // La página pidió otro tamaño: se cambia manteniendo el centro y dentro de la pantalla donde está.
        void CambiarTamano(int ancho, int alto)
        {
            if (ajustes.LeerInt("ancho", AnchoBase) == ancho && ajustes.LeerInt("alto", AltoBase) == alto) return;
            ajustes.Poner("ancho", ancho.ToString()); ajustes.Poner("alto", alto.ToString());
            ajustes.Guardar();
            Rectangle area = Screen.FromControl(this).WorkingArea;
            Size nuevo = Medida(ancho, alto, area);
            if (nuevo == ClientSize) return;
            Point centro = new Point(Left + Width / 2, Top + Height / 2);
            ClientSize = nuevo;
            int x = Math.Max(area.Left, Math.Min(centro.X - Width / 2, area.Right - Width));
            int y = Math.Max(area.Top, Math.Min(centro.Y - Height / 2, area.Bottom - Height));
            Location = new Point(x, y);
            Registro.Escribir("Tamaño pedido por la página: " + ancho + " × " + alto);
            GuardarPosicion();
        }

        bool rehacer;   // el próximo reintento vuelve a crear el control (motor caído o que no arrancó)

        void CrearWeb()
        {
            web = new WebView2();
            web.Dock = DockStyle.Fill;
            web.DefaultBackgroundColor = BackColor;
            Controls.Add(web);
            cargando.BringToFront();
            if (IsHandleCreated) { IntPtr h = web.Handle; GC.KeepAlive(h); }
        }

        // El motor de WebView2 se cerró o no pudo arrancar: se descarta el control y se crea uno nuevo.
        void Rehacer()
        {
            rehacer = false;
            listo = false;
            Registro.Escribir("Se vuelve a crear la vista de la página");
            try { if (web != null) { Controls.Remove(web); web.Dispose(); } } catch (Exception e) { Registro.Escribir("Descartar WebView2: " + e.Message); }
            cargando.Text = "Loading the Time Clock…";
            cargando.Visible = true;
            CrearWeb();
            Iniciar();
        }

        void ReintentarEn(int ms, bool crearDeNuevo)
        {
            rehacer = rehacer || crearDeNuevo;
            reintento.Stop();
            reintento.Interval = ms;
            reintento.Start();
        }

        // Crea la ventana sin mostrarla (arranque con Windows): la página carga igual y el icono funciona.
        public void IniciarEscondida()
        {
            // se crean las ventanas internas (la de la página incluida) sin mostrar nada en pantalla
            IntPtr h1 = Handle, h2 = web.Handle;
            GC.KeepAlive(h1); GC.KeepAlive(h2);
        }

        public void Mostrar()
        {
            if (!Visible) Show();
            if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
            Activate();
            BringToFront();
            // a veces Windows no deja traer la ventana al frente desde la bandeja: un truco conocido
            TopMost = true; TopMost = false;
            if (listo) Enviar("{\"accion\":\"estado\"}");
        }

        async void Iniciar()
        {
            WebView2 w = web;   // si mientras tanto se vuelve a crear el control, este arranque se abandona
            try
            {
                Programa.CargadorWebView2();
                CoreWebView2EnvironmentOptions opciones = new CoreWebView2EnvironmentOptions();
                opciones.AdditionalBrowserArguments = "--disable-http-cache";
                CoreWebView2Environment env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(Carpeta.Datos, "WebView2"), opciones);
                if (w != web) return;
                await w.EnsureCoreWebView2Async(env);
                if (w != web) return;
                CoreWebView2 cw = w.CoreWebView2;
                cw.Settings.AreDevToolsEnabled = debug;
                cw.Settings.IsStatusBarEnabled = false;
                cw.Settings.AreDefaultScriptDialogsEnabled = true;
                cw.Settings.IsGeneralAutofillEnabled = true;
                cw.Settings.IsPasswordAutosaveEnabled = false;
                cw.WebMessageReceived += AlMensaje;
                cw.NavigationStarting += AlNavegar;
                cw.NewWindowRequested += delegate(object s, CoreWebView2NewWindowRequestedEventArgs e) { e.Handled = true; Programa.Abrir(e.Uri); };
                cw.PermissionRequested += AlPermiso;
                cw.NavigationCompleted += AlTerminarCarga;
                cw.ProcessFailed += delegate(object s, CoreWebView2ProcessFailedEventArgs e)
                {
                    Registro.Escribir("WebView2 ProcessFailed: " + e.ProcessFailedKind);
                    CoreWebView2ProcessFailedKind k = e.ProcessFailedKind;
                    try
                    {
                        BeginInvoke(new MethodInvoker(delegate
                        {
                            if (k == CoreWebView2ProcessFailedKind.BrowserProcessExited) { listo = false; ReintentarEn(5000, true); }
                            else if (k == CoreWebView2ProcessFailedKind.RenderProcessExited || k == CoreWebView2ProcessFailedKind.FrameRenderProcessExited
                                  || k == CoreWebView2ProcessFailedKind.RenderProcessUnresponsive) { listo = false; ReintentarEn(3000, false); }
                            // (otros procesos auxiliares, como el de gráficos, se recuperan solos)
                        }));
                    }
                    catch { }
                };
                cw.Navigate(Programa.Url);
            }
            catch (Exception e)
            {
                if (w != web) return;
                Registro.Escribir("No se pudo iniciar WebView2: " + e);
                cargando.Text = "The Time Clock couldn't start. Trying again…\n\n" + e.Message;
                cargando.Visible = true;
                ReintentarEn(30000, true);
            }
        }

        void AlTerminarCarga(object s, CoreWebView2NavigationCompletedEventArgs e)
        {
            if (e.IsSuccess)
            {
                cargando.Visible = false;
                reintento.Stop(); rehacer = false;
                listo = true;
                while (pendientes.Count > 0) { if (!EnviarAhora(pendientes.Peek())) break; pendientes.Dequeue(); }
                if (PaginaLista != null) PaginaLista();
            }
            else
            {
                // una navegación que se canceló a propósito (enlace externo, se agregó ?app=win) no es una falla
                if (e.WebErrorStatus == CoreWebView2WebErrorStatus.OperationCanceled)
                {
                    // si quedó a medias una navegación propia (no la que se canceló a propósito), se recarga en 30 s
                    if (!listo) ReintentarEn(30000, false);
                    return;
                }
                // sin internet u otro problema: WebView2 muestra su página de error; se reintenta cada 30 s
                Registro.Escribir("No cargó la página: " + e.WebErrorStatus);
                listo = false;
                cargando.Visible = false;
                ReintentarEn(30000, false);
            }
        }

        static bool Permitida(Uri u)
        {
            if (u == null) return false;
            if (u.Scheme == "about" || u.Scheme == "data") return true;
            return u.Scheme == "https" && string.Equals(u.Host, Programa.Sitio, StringComparison.OrdinalIgnoreCase)
                && u.AbsolutePath.StartsWith("/reloj", StringComparison.OrdinalIgnoreCase);
        }

        // Dentro de la ventana solo se abre el Reloj; cualquier otro enlace (portal, correo, etc.) va al navegador normal.
        void AlNavegar(object s, CoreWebView2NavigationStartingEventArgs e)
        {
            Uri u;
            if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out u)) { e.Cancel = true; return; }
            if (Permitida(u))
            {
                // la página a veces recarga sin ?app=win (por ejemplo al cerrar sesión): se le vuelve a poner
                if (u.Scheme == "https" && u.Query.IndexOf("app=win", StringComparison.OrdinalIgnoreCase) < 0 && u.AbsolutePath.EndsWith("reloj.html", StringComparison.OrdinalIgnoreCase))
                {
                    e.Cancel = true;
                    string q = u.Query.Length > 1 ? u.Query + "&app=win" : "?app=win";
                    string nueva = u.GetLeftPart(UriPartial.Path) + q + u.Fragment;
                    BeginInvoke(new MethodInvoker(delegate { try { web.CoreWebView2.Navigate(nueva); } catch (Exception ex) { Registro.Escribir("Navegar: " + ex.Message); } }));
                    return;
                }
                listo = false;   // la página se está cambiando: los mensajes esperan a que cargue
                return;
            }
            e.Cancel = true;
            if (u.Scheme == "https" || u.Scheme == "http" || u.Scheme == "mailto") Programa.Abrir(u.AbsoluteUri);
        }

        void AlPermiso(object s, CoreWebView2PermissionRequestedEventArgs e)
        {
            // (el Uri de un permiso es el origen —https://247medicalaid.github.io/—, sin la ruta)
            Uri u;
            bool nuestro = Uri.TryCreate(e.Uri, UriKind.Absolute, out u) && u.Scheme == "https" && string.Equals(u.Host, Programa.Sitio, StringComparison.OrdinalIgnoreCase);
            Registro.Escribir("Permiso " + e.PermissionKind + " de " + e.Uri + ": " + (nuestro ? "sí" : "no"));
            if (e.PermissionKind == CoreWebView2PermissionKind.Geolocation && nuestro) e.State = CoreWebView2PermissionState.Allow;
            else if (e.PermissionKind == CoreWebView2PermissionKind.ClipboardRead && nuestro) e.State = CoreWebView2PermissionState.Allow;
            else e.State = CoreWebView2PermissionState.Deny;
        }

        void AlMensaje(object s, CoreWebView2WebMessageReceivedEventArgs e)
        {
            Uri u;
            if (!Uri.TryCreate(e.Source, UriKind.Absolute, out u) || !Permitida(u)) return;
            string json;
            try { json = e.TryGetWebMessageAsString(); } catch { return; }
            try
            {
                int[] tam = EstadoReloj.LeerVentana(json);
                if (tam != null) { CambiarTamano(tam[0], tam[1]); return; }
                EstadoReloj est = EstadoReloj.Leer(json);
                if (est != null && EstadoRecibido != null) EstadoRecibido(est);
            }
            catch (Exception ex) { Registro.Escribir("Mensaje no válido: " + ex.Message); }
        }

        // Pedido de «estado»: si la página no está lista, queda uno solo pendiente para cuando cargue.
        public void Enviar(string json)
        {
            if (EnviarAhora(json)) return;
            if (!pendientes.Contains(json) && pendientes.Count < 3) pendientes.Enqueue(json);
        }

        public bool EnviarAhora(string json)
        {
            if (!listo || web == null || web.CoreWebView2 == null) return false;
            try { web.CoreWebView2.PostWebMessageAsString(json); return true; }
            catch (Exception e) { Registro.Escribir("Enviar: " + e.Message); return false; }
        }

        public void Recargar()
        {
            try
            {
                if (web == null || web.CoreWebView2 == null) { Rehacer(); return; }
                Uri u;
                if (Uri.TryCreate(web.CoreWebView2.Source, UriKind.Absolute, out u) && Permitida(u) && u.Scheme == "https") web.CoreWebView2.Reload();
                else web.CoreWebView2.Navigate(Programa.Url);
            }
            catch (Exception e) { Registro.Escribir("Recargar: " + e.Message); }
        }

        void AlCerrar(object s, FormClosingEventArgs e)
        {
            if (cerrarDeVerdad) return;
            if (e.CloseReason == CloseReason.WindowsShutDown) { cerrarDeVerdad = true; return; }   // nunca frenar el apagado
            if (e.CloseReason == CloseReason.TaskManagerClosing)
            {
                // se cierra todo el programa (no solo la ventana), si no el icono quedaría sin ventana
                e.Cancel = true;
                if (TerminarPedido != null) BeginInvoke(new MethodInvoker(delegate { TerminarPedido(); }));
                return;
            }
            // la X (o Alt+F4) no cierra: la ventana se va a la bandeja
            e.Cancel = true;
            GuardarPosicion();
            Hide();
            if (CerrarPedido != null) CerrarPedido();
        }

        public void CerrarDeVerdad()
        {
            cerrarDeVerdad = true;
            GuardarPosicion();
            try { Close(); } catch { }
            try { web.Dispose(); } catch { }
        }

        void GuardarPosicion()
        {
            if (WindowState != FormWindowState.Normal || !Visible) return;
            ajustes.Poner("x", Left.ToString()); ajustes.Poner("y", Top.ToString());
            ajustes.Guardar();
        }

    }
}
