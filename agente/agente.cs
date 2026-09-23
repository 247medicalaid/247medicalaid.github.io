// =====================================================================
//  Monitor 24/7 Medical Aid - Agente nativo (Windows, .NET Framework)
//  Cada minuto envia al servidor:
//    - segundos sin teclado/mouse (actividad del equipo)
//    - programa en primer plano (activo) y programas abiertos con su RAM
//    - calidad de internet: latencia y perdida (conexion TCP a 1.1.1.1)
//    - si la app de telefono de la cuenta esta abierta
//  A demanda (boton del panel) corre un test de megas (descarga).
//  Si no hay internet, guarda los latidos y los envia cuando vuelva.
//  Captura SOLO nombres de programa, nunca titulos de ventana ni paginas
//  web, para no arrastrar datos de pacientes. El instalador lo compila
//  con el csc.exe que ya trae Windows.
// =====================================================================
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using Microsoft.Win32;
using System.Threading;

[assembly: System.Reflection.AssemblyTitle("Monitor 24-7 Medical Aid")]
[assembly: System.Reflection.AssemblyProduct("Monitor 24-7 Medical Aid")]
[assembly: System.Reflection.AssemblyCompany("24/7 Medical Aid")]
[assembly: System.Reflection.AssemblyFileVersion("2.1.0.0")]

namespace Monitor247
{
    static class Programa
    {
        const string Version = "2.5";
        const int IntervaloSeg = 60;
        const int MaxCola = 5000;
        const int MaxLote = 200;
        const int TopProgramas = 12;
        const string PingHost = "1.1.1.1";
        const int PingPuerto = 443;
        const string SpeedUrl = "https://speed.cloudflare.com/__down?bytes=10000000"; // 10 MB

        static string DataDir, ColaFile, LogFile, UltimoFile, BaseDir;
        static string correoCache = null;
        static DateTime correoCacheTs = DateTime.MinValue;
        static readonly UTF8Encoding Utf8 = new UTF8Encoding(false);

        [StructLayout(LayoutKind.Sequential)]
        struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
        [DllImport("user32.dll")]
        static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
        [DllImport("user32.dll")]
        static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        static uint IdleSeconds()
        {
            LASTINPUTINFO lii = new LASTINPUTINFO();
            lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
            if (!GetLastInputInfo(ref lii)) return 0;
            return unchecked(((uint)Environment.TickCount - lii.dwTime) / 1000);
        }


        // ---------------- Pantallas y energia (nuevo en la 2.5) ----------------
        // Pantallas ACTIVAS del escritorio. Ojo: si el agente cierra la tapa y usa
        // solo el monitor externo, Windows reporta 1. Se decidio contar asi, a
        // sabiendas, y revisar a mano los pocos casos de tapa cerrada.
        delegate bool EnumMonitorsProc(IntPtr hMonitor, IntPtr hdc, IntPtr lprc, IntPtr dwData);
        [DllImport("user32.dll")]
        static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, EnumMonitorsProc lpfn, IntPtr dwData);

        static int Pantallas()
        {
            try
            {
                int n = 0;
                EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero,
                    delegate (IntPtr h, IntPtr dc, IntPtr r, IntPtr d) { n++; return true; }, IntPtr.Zero);
                return n;
            }
            catch { return -1; }
        }

        [StructLayout(LayoutKind.Sequential)]
        struct SYSTEM_POWER_STATUS
        {
            public byte ACLineStatus;      // 0 = bateria, 1 = enchufado, 255 = desconocido
            public byte BatteryFlag;       // 128 = no hay bateria (equipo de escritorio)
            public byte BatteryLifePercent;
            public byte SystemStatusFlag;
            public int BatteryLifeTime;
            public int BatteryFullLifeTime;
        }
        [DllImport("kernel32.dll")]
        static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS s);

        // Devuelve "ac" (enchufado), "bat" (en bateria), "fijo" (sin bateria) o "" si no se sabe.
        static string Energia(out int porcentaje)
        {
            porcentaje = -1;
            try
            {
                SYSTEM_POWER_STATUS s;
                if (!GetSystemPowerStatus(out s)) return "";
                if (s.BatteryLifePercent <= 100) porcentaje = s.BatteryLifePercent;
                if ((s.BatteryFlag & 128) != 0) return "fijo";   // no tiene bateria
                if (s.ACLineStatus == 1) return "ac";
                if (s.ACLineStatus == 0) return "bat";
                return "";
            }
            catch { return ""; }
        }

        // ---------------- Inventario del equipo (nuevo en la 2.5) ----------------
        // Se arma una vez y se guarda en estado\equipo.json; se rehace si el archivo
        // falta o tiene mas de 7 dias. Solo viaja en el latido de arranque, no en
        // todos, porque cambia muy poco.
        [StructLayout(LayoutKind.Sequential)]
        class MEMORYSTATUSEX
        {
            public uint dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            public uint dwMemoryLoad;
            public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile;
            public ulong ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
        }
        [DllImport("kernel32.dll")]
        static extern bool GlobalMemoryStatusEx([In, Out] MEMORYSTATUSEX m);

        static string RegLeer(string ruta, string nombre)
        {
            try
            {
                using (RegistryKey k = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64).OpenSubKey(ruta))
                {
                    if (k == null) return "";
                    object v = k.GetValue(nombre);
                    return v == null ? "" : v.ToString().Trim();
                }
            }
            catch { return ""; }
        }

        // El numero de serie no esta en el registro; hay que preguntarselo al BIOS.
        // Es la unica consulta que necesita lanzar un proceso, y pasa una vez por semana.
        static string SerieBios()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("powershell.exe",
                    "-NoProfile -ExecutionPolicy Bypass -Command \"(Get-CimInstance -ClassName Win32_BIOS).SerialNumber\"");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                using (Process p = Process.Start(psi))
                {
                    string s = p.StandardOutput.ReadToEnd();
                    if (!p.WaitForExit(20000)) { try { p.Kill(); } catch { } return ""; }
                    s = (s == null ? "" : s.Trim());
                    // Algunos equipos devuelven relleno del fabricante en vez de una serie
                    if (s.Length > 64) s = s.Substring(0, 64);
                    string b = s.ToLowerInvariant();
                    if (b == "none" || b == "default string" || b == "to be filled by o.e.m." || b == "system serial number") return "";
                    return s;
                }
            }
            catch { return ""; }
        }

        static string InventarioJson()
        {
            const string RUTA_BIOS = @"HARDWARE\DESCRIPTION\System\BIOS";
            const string RUTA_WIN = @"SOFTWARE\Microsoft\Windows NT\CurrentVersion";

            string marca = RegLeer(RUTA_BIOS, "SystemManufacturer");
            string modelo = RegLeer(RUTA_BIOS, "SystemProductName");
            string familia = RegLeer(RUTA_BIOS, "SystemFamily");
            if (modelo.Length == 0) modelo = familia;
            string serie = SerieBios();

            string winNombre = RegLeer(RUTA_WIN, "ProductName");
            string winVer = RegLeer(RUTA_WIN, "DisplayVersion");
            string winBuild = RegLeer(RUTA_WIN, "CurrentBuild");
            // Windows 11 sigue diciendo "Windows 10" en ProductName; la compilacion lo delata
            int build = 0;
            int.TryParse(winBuild, out build);
            if (build >= 22000 && winNombre.IndexOf("Windows 10", StringComparison.OrdinalIgnoreCase) >= 0)
                winNombre = winNombre.Replace("Windows 10", "Windows 11");
            string windows = (winNombre + " " + winVer).Trim() + (winBuild.Length > 0 ? " (" + winBuild + ")" : "");

            string instalado = "";
            try
            {
                object v = null;
                using (RegistryKey k = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64).OpenSubKey(RUTA_WIN))
                    if (k != null) v = k.GetValue("InstallDate");
                if (v != null)
                {
                    long seg = Convert.ToInt64(v);
                    instalado = new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(seg)
                        .ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                }
            }
            catch { }

            int ramGb = 0;
            try
            {
                MEMORYSTATUSEX m = new MEMORYSTATUSEX();
                if (GlobalMemoryStatusEx(m)) ramGb = (int)Math.Round(m.ullTotalPhys / 1073741824.0);
            }
            catch { }

            int discoGb = 0, libreGb = 0;
            try
            {
                DriveInfo d = new DriveInfo(Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.System)));
                discoGb = (int)Math.Round(d.TotalSize / 1073741824.0);
                libreGb = (int)Math.Round(d.TotalFreeSpace / 1073741824.0);
            }
            catch { }

            StringBuilder sb = new StringBuilder();
            sb.Append("{");
            sb.Append("\"marca\":\"").Append(Esc(marca)).Append("\",");
            sb.Append("\"modelo\":\"").Append(Esc(modelo)).Append("\",");
            sb.Append("\"serie\":\"").Append(Esc(serie)).Append("\",");
            sb.Append("\"windows\":\"").Append(Esc(windows)).Append("\",");
            sb.Append("\"instalado\":\"").Append(Esc(instalado)).Append("\",");
            sb.Append("\"ramGb\":").Append(ramGb.ToString(CultureInfo.InvariantCulture)).Append(",");
            sb.Append("\"discoGb\":").Append(discoGb.ToString(CultureInfo.InvariantCulture)).Append(",");
            sb.Append("\"libreGb\":").Append(libreGb.ToString(CultureInfo.InvariantCulture));
            sb.Append("}");
            return sb.ToString();
        }

        static string InventarioCache()
        {
            string f = Path.Combine(Path.Combine(BaseDir, "estado"), "equipo.json");
            try
            {
                if (File.Exists(f) && (DateTime.UtcNow - File.GetLastWriteTimeUtc(f)).TotalDays < 7)
                {
                    string viejo = File.ReadAllText(f, Utf8).Trim();
                    if (viejo.StartsWith("{") && viejo.EndsWith("}")) return viejo;
                }
            }
            catch { }
            string nuevo = InventarioJson();
            try { File.WriteAllText(f, nuevo, Utf8); } catch { }
            return nuevo;
        }

        static void Main()
        {
            bool creado;
            using (Mutex mutex = new Mutex(false, "Local\\Monitor247_Agente", out creado))
            {
                bool tengo = false;
                try { tengo = mutex.WaitOne(0); } catch (AbandonedMutexException) { tengo = true; }
                if (!tengo) return;
                try { Correr(); }
                catch (Exception ex) { Log("ERROR fatal: " + ex.Message); }
            }
        }

        static void Correr()
        {
            string baseDir = AppDomain.CurrentDomain.BaseDirectory;
            BaseDir = baseDir;
            string configFile = Path.Combine(baseDir, "config.json");
            DataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Monitor247");
            Directory.CreateDirectory(DataDir);
            ColaFile = Path.Combine(DataDir, "cola.jsonl");
            LogFile = Path.Combine(DataDir, "monitor.log");
            // Marca que lee el actualizador para confirmar que esta version funciona
            string estadoDir = Path.Combine(baseDir, "estado");
            try { Directory.CreateDirectory(estadoDir); } catch { }
            UltimoFile = Path.Combine(estadoDir, "ultimo.txt");

            string txt = File.ReadAllText(configFile, Encoding.UTF8);
            string url = Json(txt, "url");
            string token = Json(txt, "token");
            string agente = Json(txt, "agente");
            string cuenta = Json(txt, "cuenta");
            string apps = Json(txt, "app_telefono");
            if (url.Length == 0 || token.Length == 0 || agente.Length == 0) { Log("ERROR: config.json incompleto"); return; }

            List<string> patrones = new List<string>();
            foreach (string a in apps.Split(','))
            {
                string t = a.Trim().ToLowerInvariant();
                if (t.Length > 0) patrones.Add(t);
            }

            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            ServicePointManager.DefaultConnectionLimit = 10;
            string equipo = Environment.MachineName;
            string usuario = Environment.UserName;

            Log("Inicio v" + Version + " - agente '" + agente + "' cuenta '" + cuenta + "' usuario '" + usuario + "'");
            bool primerEnvio = true;
            bool haceSpeed = false;
            int fallos = 0;

            while (true)
            {
                DateTime inicio = DateTime.UtcNow;
                List<string> lineas = null;
                int enviados = 0;
                try
                {
                    // Test de megas a demanda: si el servidor lo pidio en el ciclo anterior
                    double mbps = -1;
                    if (haceSpeed) { mbps = SpeedTest(); haceSpeed = false; Log("Test de velocidad: " + (mbps >= 0 ? mbps + " Mbps" : "fallo")); }

                    double lat, loss;
                    Latencia(out lat, out loss);

                    string beat = ConstruirBeat(agente, cuenta, equipo, usuario, IdleSeconds(),
                        AppAbierta(patrones), primerEnvio, ProgramaActivo(), ProgramasAbiertos(), lat, loss, mbps);
                    File.AppendAllText(ColaFile, beat + "\r\n", Utf8);
                    primerEnvio = false;

                    lineas = LeerCola();
                    string respuesta = "";
                    while (enviados < lineas.Count)
                    {
                        int fin = Math.Min(enviados + MaxLote, lineas.Count);
                        respuesta = Enviar(url, token, lineas.GetRange(enviados, fin - enviados));
                        enviados = fin;
                    }
                    File.WriteAllText(ColaFile, "", Utf8);
                    try { File.WriteAllText(UltimoFile, Version + "|" + DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture), Utf8); } catch { }
                    if (respuesta.IndexOf("\"cmd\":\"speedtest\"") >= 0) haceSpeed = true;
                    if (respuesta.IndexOf("\"actualizar\":true") >= 0) PedirActualizacion();
                    if (fallos > 0) Log("Conexion restablecida; enviados " + enviados + " latidos pendientes");
                    fallos = 0;
                }
                catch (Exception ex)
                {
                    fallos++;
                    try
                    {
                        if (lineas != null && enviados > 0 && enviados < lineas.Count)
                            File.WriteAllLines(ColaFile, lineas.GetRange(enviados, lineas.Count - enviados).ToArray(), Utf8);
                    }
                    catch { }
                    if (fallos == 1 || fallos % 30 == 0) Log("Sin conexion con el servidor (" + fallos + "): " + ex.Message);
                }

                double resto = IntervaloSeg - (DateTime.UtcNow - inicio).TotalSeconds;
                if (resto > 1) Thread.Sleep((int)(resto * 1000));
            }
        }

        static List<string> LeerCola()
        {
            List<string> outl = new List<string>();
            foreach (string l in File.ReadAllLines(ColaFile, Utf8))
                if (l.Trim().Length > 0) outl.Add(l);
            if (outl.Count > MaxCola) outl = outl.GetRange(outl.Count - MaxCola, MaxCola);
            return outl;
        }

        // true = alguna app de telefono abierta, false = ninguna, null = no configurada
        static object AppAbierta(List<string> patrones)
        {
            if (patrones.Count == 0) return null;
            try
            {
                foreach (Process p in Process.GetProcesses())
                {
                    string n;
                    try { n = p.ProcessName.ToLowerInvariant(); } catch { continue; }
                    foreach (string pat in patrones)
                        if (n.IndexOf(pat) >= 0) return true;
                }
            }
            catch { }
            return false;
        }

        // Nombre descriptivo del programa (el que Windows muestra), sin titulo de ventana.
        static string Amigable(Process p, string nombre)
        {
            try { string d = p.MainModule.FileVersionInfo.FileDescription; if (!string.IsNullOrEmpty(d)) return d.Trim(); } catch { }
            return nombre;
        }

        // Nombre del programa en primer plano (sin titulo de ventana).
        static string ProgramaActivo()
        {
            try
            {
                IntPtr h = GetForegroundWindow();
                if (h == IntPtr.Zero) return "";
                uint pid;
                GetWindowThreadProcessId(h, out pid);
                if (pid == 0) return "";
                using (Process p = Process.GetProcessById((int)pid)) return Amigable(p, p.ProcessName);
            }
            catch { return ""; }
        }

        // Programas abiertos agrupados por nombre, con su RAM (MB). Top por consumo.
        static List<object[]> ProgramasAbiertos()
        {
            Dictionary<string, long> mapa = new Dictionary<string, long>();
            Dictionary<string, Process> muestra = new Dictionary<string, Process>();
            try
            {
                foreach (Process p in Process.GetProcesses())
                {
                    string n; long ws;
                    try { n = p.ProcessName; ws = p.WorkingSet64; } catch { continue; }
                    if (string.IsNullOrEmpty(n)) continue;
                    if (mapa.ContainsKey(n)) mapa[n] += ws; else { mapa[n] = ws; muestra[n] = p; }
                }
            }
            catch { }
            List<KeyValuePair<string, long>> lista = new List<KeyValuePair<string, long>>(mapa);
            lista.Sort(delegate (KeyValuePair<string, long> a, KeyValuePair<string, long> b) { return b.Value.CompareTo(a.Value); });
            List<object[]> outl = new List<object[]>();
            for (int i = 0; i < lista.Count && i < TopProgramas; i++)
            {
                string nombre = lista[i].Key;
                Process pm; if (muestra.TryGetValue(lista[i].Key, out pm)) nombre = Amigable(pm, lista[i].Key);
                outl.Add(new object[] { nombre, (int)Math.Round(lista[i].Value / 1048576.0) });
            }
            return outl;
        }

        // Calidad de internet: latencia media (ms) y perdida (0..1) por conexion TCP.
        static void Latencia(out double ms, out double loss)
        {
            int intentos = 3, ok = 0;
            double suma = 0;
            for (int i = 0; i < intentos; i++)
            {
                Stopwatch sw = Stopwatch.StartNew();
                try
                {
                    using (TcpClient c = new TcpClient())
                    {
                        IAsyncResult ar = c.BeginConnect(PingHost, PingPuerto, null, null);
                        if (ar.AsyncWaitHandle.WaitOne(2000) && c.Connected)
                        {
                            c.EndConnect(ar);
                            sw.Stop();
                            suma += sw.Elapsed.TotalMilliseconds;
                            ok++;
                        }
                    }
                }
                catch { }
                Thread.Sleep(120);
            }
            ms = ok > 0 ? Math.Round(suma / ok) : -1;
            loss = (double)(intentos - ok) / intentos;
        }

        // Descarga ~10 MB y calcula Mbps. -1 si falla.
        static double SpeedTest()
        {
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(SpeedUrl);
                req.Proxy = null;
                req.Method = "GET";
                req.Timeout = 20000;
                req.ReadWriteTimeout = 30000;
                req.AllowAutoRedirect = true;
                req.KeepAlive = false;
                long total = 0;
                Stopwatch sw = Stopwatch.StartNew();
                using (WebResponse resp = req.GetResponse())
                using (Stream st = resp.GetResponseStream())
                {
                    byte[] buf = new byte[65536];
                    int r;
                    while ((r = st.Read(buf, 0, buf.Length)) > 0)
                    {
                        total += r;
                        if (sw.Elapsed.TotalSeconds > 25) break;
                    }
                }
                sw.Stop();
                double seg = sw.Elapsed.TotalSeconds;
                if (seg <= 0 || total <= 0) return -1;
                return Math.Round(total * 8.0 / seg / 1e6, 1);
            }
            catch { return -1; }
        }

        static string ConstruirBeat(string ag, string cu, string eq, string us, uint idle, object app,
            bool inicio, string progActivo, List<object[]> progs, double lat, double loss, double mbps)
        {
            int bat;
            string energia = Energia(out bat);
            int pantallas = Pantallas();
            string appTxt = (app == null) ? "null" : (((bool)app) ? "true" : "false");
            StringBuilder sb = new StringBuilder();
            sb.Append("{");
            sb.Append("\"id\":\"").Append(Guid.NewGuid().ToString("N")).Append("\",");
            sb.Append("\"ts\":\"").Append(DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture)).Append("\",");
            sb.Append("\"agente\":\"").Append(Esc(ag)).Append("\",");
            sb.Append("\"cuenta\":\"").Append(Esc(cu)).Append("\",");
            sb.Append("\"equipo\":\"").Append(Esc(eq)).Append("\",");
            sb.Append("\"usuario\":\"").Append(Esc(us)).Append("\",");
            sb.Append("\"email\":\"").Append(Esc(CorreoWindows())).Append("\",");
            sb.Append("\"idle\":").Append(idle.ToString(CultureInfo.InvariantCulture)).Append(",");
            sb.Append("\"app\":").Append(appTxt).Append(",");
            sb.Append("\"inicio\":").Append(inicio ? "true" : "false").Append(",");
            sb.Append("\"progActivo\":\"").Append(Esc(progActivo)).Append("\",");
            sb.Append("\"lat\":").Append(lat < 0 ? "null" : lat.ToString(CultureInfo.InvariantCulture)).Append(",");
            sb.Append("\"loss\":").Append(loss.ToString("0.###", CultureInfo.InvariantCulture)).Append(",");
            sb.Append("\"mbps\":").Append(mbps < 0 ? "null" : mbps.ToString(CultureInfo.InvariantCulture)).Append(",");
            sb.Append("\"pantallas\":").Append(pantallas < 0 ? "null" : pantallas.ToString(CultureInfo.InvariantCulture)).Append(",");
            sb.Append("\"energia\":\"").Append(Esc(energia)).Append("\",");
            sb.Append("\"bateria\":").Append(bat < 0 ? "null" : bat.ToString(CultureInfo.InvariantCulture)).Append(",");
            sb.Append("\"progs\":[");
            for (int i = 0; i < progs.Count; i++)
            {
                if (i > 0) sb.Append(",");
                sb.Append("{\"n\":\"").Append(Esc((string)progs[i][0])).Append("\",\"mb\":").Append(((int)progs[i][1]).ToString(CultureInfo.InvariantCulture)).Append("}");
            }
            sb.Append("]}");
            // El inventario del equipo solo viaja en el latido de arranque: cambia muy
            // poco y no tiene sentido repetirlo cada minuto.
            if (inicio) {
                string inv = InventarioCache();
                sb.Insert(sb.Length - 1, ",\"equipo_info\":" + inv);
            }
            return sb.ToString();
        }

        // Devuelve el cuerpo de la respuesta del ultimo lote (para leer comandos del servidor).
        static string Enviar(string url, string token, List<string> beats)
        {
            StringBuilder sb = new StringBuilder();
            sb.Append("{\"token\":\"").Append(Esc(token)).Append("\",\"version\":\"").Append(Version).Append("\",\"beats\":[");
            for (int i = 0; i < beats.Count; i++) { if (i > 0) sb.Append(","); sb.Append(beats[i]); }
            sb.Append("]}");
            byte[] bytes = Utf8.GetBytes(sb.ToString());

            HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
            req.Method = "POST";
            req.ContentType = "application/json; charset=utf-8";
            req.Proxy = null;   // ir directo; evita que WPAD (deteccion de proxy) cuelgue el envio
            req.AllowAutoRedirect = true;   // seguir el 302 para leer la respuesta (comando de velocidad)
            req.Timeout = 30000;
            req.ContentLength = bytes.Length;
            using (Stream s = req.GetRequestStream()) s.Write(bytes, 0, bytes.Length);

            int code = 0;
            string cuerpo = "";
            HttpWebResponse resp = null;
            try { resp = (HttpWebResponse)req.GetResponse(); }
            catch (WebException we) { resp = (HttpWebResponse)we.Response; if (resp == null) throw; }
            using (resp)
            {
                code = (int)resp.StatusCode;
                if (code == 200)
                {
                    using (Stream rs = resp.GetResponseStream())
                    using (StreamReader sr = new StreamReader(rs, Encoding.UTF8))
                        cuerpo = sr.ReadToEnd();
                }
            }
            if (code != 200 && code != 302) throw new Exception("HTTP " + code);
            return cuerpo;
        }

        // Correo con el que se inicio sesion en Windows. En equipos con cuenta
        // local de Windows no existe y queda vacio. Se recalcula cada hora.
        static string CorreoWindows()
        {
            if (correoCache != null && (DateTime.UtcNow - correoCacheTs).TotalMinutes < 60) return correoCache;
            string mail = "";
            // 1) Cuenta Microsoft usada para iniciar sesion
            try
            {
                using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\IdentityCRL\UserExtendedProperties"))
                {
                    if (k != null)
                        foreach (string n in k.GetSubKeyNames())
                            if (n.IndexOf('@') > 0) { mail = n.Trim(); break; }
                }
            }
            catch { }
            // 2) Dominio o Microsoft Entra ID
            if (mail.Length == 0)
            {
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo("whoami.exe", "/upn");
                    psi.UseShellExecute = false; psi.RedirectStandardOutput = true; psi.RedirectStandardError = true;
                    psi.CreateNoWindow = true;
                    using (Process p = Process.Start(psi))
                    {
                        string salida = p.StandardOutput.ReadToEnd();
                        p.WaitForExit(8000);
                        if (p.ExitCode == 0 && salida != null && salida.IndexOf('@') > 0) mail = salida.Trim();
                    }
                }
                catch { }
            }
            // 3) Identidad de Office / Microsoft 365 (puede ser otra cuenta)
            if (mail.Length == 0)
            {
                try
                {
                    using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Office\16.0\Common\Identity\Identities"))
                    {
                        if (k != null)
                            foreach (string n in k.GetSubKeyNames())
                                using (RegistryKey sk = k.OpenSubKey(n))
                                {
                                    object v = (sk == null) ? null : sk.GetValue("EmailAddress");
                                    if (v != null && v.ToString().IndexOf('@') > 0) { mail = v.ToString().Trim(); break; }
                                }
                    }
                }
                catch { }
            }
            correoCache = mail;
            correoCacheTs = DateTime.UtcNow;
            return mail;
        }

        static string Json(string txt, string key)
        {
            Match m = Regex.Match(txt, "\"" + key + "\"\\s*:\\s*\"((?:\\\\.|[^\"\\\\])*)\"");
            if (!m.Success) return "";
            return m.Groups[1].Value.Replace("\\\"", "\"").Replace("\\\\", "\\");
        }

        static string Esc(string s)
        {
            if (s == null) return "";
            return s.Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\r", " ").Replace("\n", " ");
        }

        // El panel pidio actualizar este equipo sin esperar la revision de cada
        // hora. Aqui no se actualiza nada: solo se deja el aviso y, si se puede,
        // se despierta al actualizador, que es quien descarga, verifica la
        // huella, compila, respalda y reinicia. Si no se puede despertar (el
        // agente corre como usuario normal), el actualizador vera el aviso en su
        // ciclo de cinco minutos.
        static void PedirActualizacion()
        {
            try
            {
                // Dentro de "estado": es la unica carpeta donde el agente tiene
                // permiso de escritura. Hasta la 2.3 se escribia en la carpeta
                // principal y Windows lo rechazaba, asi que el boton del panel
                // nunca despertaba al actualizador.
                File.WriteAllText(Path.Combine(Path.Combine(BaseDir, "estado"), "forzar.txt"),
                    DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture), Utf8);
            }
            catch (Exception ex) { Log("No se pudo dejar el aviso de actualizacion: " + ex.Message); return; }
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo("schtasks.exe", "/Run /TN \"Monitor247_Actualizador\"");
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                Process.Start(psi);
                Log("Actualizacion pedida desde el panel: actualizador lanzado");
            }
            catch (Exception ex)
            {
                Log("Actualizacion pedida desde el panel; el actualizador la tomara en su proximo ciclo (" + ex.Message + ")");
            }
        }

        static void Log(string msg)
        {
            try
            {
                FileInfo fi = new FileInfo(LogFile);
                if (fi.Exists && fi.Length > 1048576)
                {
                    string old = LogFile + ".old";
                    if (File.Exists(old)) File.Delete(old);
                    File.Move(LogFile, old);
                }
                File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "  " + msg + "\r\n", Utf8);
            }
            catch { }
        }
    }
}
