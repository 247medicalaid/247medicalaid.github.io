# =====================================================================
#  Monitor 24/7 Medical Aid - Agente de actividad (Windows) - respaldo
#  Version PowerShell (se usa solo si el equipo no puede compilar el .exe).
#  Cada minuto envia: inactividad, programa activo, programas abiertos con
#  RAM, calidad de internet (latencia/perdida) y si la app de telefono esta
#  abierta. A demanda corre un test de megas. Guarda offline si no hay red.
#  Captura SOLO nombres de programa, nunca titulos de ventana ni paginas web.
#  Compatible con Windows PowerShell 5.1
# =====================================================================
$ErrorActionPreference = 'Stop'
$Version = '2.1'

$Base       = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = Join-Path $Base 'config.json'
$DataDir    = Join-Path $env:LOCALAPPDATA 'Monitor247'
$EstadoDir  = Join-Path $Base 'estado'          # lo lee el actualizador para confirmar que seguimos reportando
$UltimoFile = Join-Path $EstadoDir 'ultimo.txt'
$ColaFile   = Join-Path $DataDir 'cola.jsonl'
$LogFile    = Join-Path $DataDir 'monitor.log'
$Utf8       = New-Object System.Text.UTF8Encoding($false)
$Intervalo  = 60
$MaxCola    = 5000
$MaxLote    = 200
$TopProgs   = 12
$SpeedUrl   = 'https://speed.cloudflare.com/__down?bytes=10000000'

if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir -Force | Out-Null }

function Write-Log([string]$msg) {
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 1MB)) { Move-Item $LogFile "$LogFile.old" -Force }
        Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg)
    } catch { }
}

# Una sola copia por sesion. Si la copia anterior murio sin liberar el candado,
# WaitOne lanza AbandonedMutexException PERO igual nos da el candado: lo tomamos.
$mutex = New-Object System.Threading.Mutex($false, 'Local\Monitor247_Agente')
try { $tengoMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $tengoMutex = $true }
if (-not $tengoMutex) { exit 0 }

try { $cfg = Get-Content $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json }
catch { Write-Log "ERROR: no se pudo leer config.json: $_"; exit 1 }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class Monitor247Win {
    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    public static uint IdleSeconds() {
        LASTINPUTINFO lii = new LASTINPUTINFO();
        lii.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref lii)) return 0;
        unchecked { return ((uint)Environment.TickCount - lii.dwTime) / 1000; }
    }
    public static int ForegroundPid() {
        uint pid; GetWindowThreadProcessId(GetForegroundWindow(), out pid); return (int)pid;
    }
}
'@

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$patrones = @()
if ($cfg.app_telefono) { $patrones = @($cfg.app_telefono -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

# Correo con el que se inicio sesion en Windows. Segun el tipo de cuenta puede
# venir del dominio/Entra, de la cuenta Microsoft o de la identidad de Office.
# En equipos con cuenta local de Windows no existe y queda vacio.
$script:Correo = $null
$script:CorreoTs = [datetime]::MinValue

function Get-CorreoWindows {
    if ($script:Correo -ne $null -and ((Get-Date) - $script:CorreoTs).TotalMinutes -lt 60) { return $script:Correo }
    $mail = ''
    # 1) Dominio o Microsoft Entra ID
    try {
        $u = (& whoami /upn 2>$null)
        if ($LASTEXITCODE -eq 0 -and $u -and $u -match '@') { $mail = $u.Trim() }
    } catch { }
    # 2) Equipos registrados en Entra / Intune
    if (-not $mail) {
        try {
            $d = (& dsregcmd /status 2>$null)
            if ($d) {
                $m = $d | Select-String -Pattern '(Executing Account Name|UserPrincipalName)\s*:\s*(\S+@\S+)'
                if ($m) { $mail = ($m[0].Matches[0].Groups[2].Value).Trim() }
            }
        } catch { }
    }
    # 3) Cuenta Microsoft usada para iniciar sesion
    if (-not $mail) {
        try {
            $k = 'HKCU:\Software\Microsoft\IdentityCRL\UserExtendedProperties'
            if (Test-Path $k) {
                $n = Get-ChildItem $k -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName } | Where-Object { $_ -match '@' } | Select-Object -First 1
                if ($n) { $mail = $n.Trim() }
            }
        } catch { }
    }
    # 4) Identidad de Office / Microsoft 365 (puede ser otra cuenta)
    if (-not $mail) {
        try {
            $k = 'HKCU:\Software\Microsoft\Office\16.0\Common\Identity\Identities'
            if (Test-Path $k) {
                foreach ($i in (Get-ChildItem $k -ErrorAction SilentlyContinue)) {
                    $e = (Get-ItemProperty $i.PSPath -Name 'EmailAddress' -ErrorAction SilentlyContinue).EmailAddress
                    if ($e -and $e -match '@') { $mail = $e.Trim(); break }
                }
            }
        } catch { }
    }
    $script:Correo = $mail
    $script:CorreoTs = Get-Date
    return $mail
}

function Test-AppTelefono {
    if ($patrones.Count -eq 0) { return $null }
    try {
        foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
            foreach ($pat in $patrones) { if ($p.ProcessName -like "*$pat*") { return $true } }
        }
    } catch { }
    return $false
}

function Get-ProgActivo {
    try {
        $procId = [Monitor247Win]::ForegroundPid()
        if ($procId -le 0) { return '' }
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($p) { if ($p.Description) { return $p.Description } else { return $p.ProcessName } } else { return '' }
    } catch { return '' }
}

function Get-Programas {
    try {
        Get-Process -ErrorAction SilentlyContinue | Group-Object ProcessName | ForEach-Object {
            $d = ($_.Group | ForEach-Object { $_.Description } | Where-Object { $_ } | Select-Object -First 1)
            $nom = if ($d) { $d } else { $_.Name }
            [pscustomobject]@{ n = $nom; mb = [int][math]::Round(((($_.Group | Measure-Object WorkingSet64 -Sum).Sum) / 1MB)) }
        } | Sort-Object mb -Descending | Select-Object -First $TopProgs
    } catch { @() }
}

function Get-Latencia {
    $tries = 3; $ok = 0; $sum = 0.0
    for ($i = 0; $i -lt $tries; $i++) {
        try {
            $c = New-Object Net.Sockets.TcpClient
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $ar = $c.BeginConnect('1.1.1.1', 443, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(2000) -and $c.Connected) { $c.EndConnect($ar); $sw.Stop(); $sum += $sw.Elapsed.TotalMilliseconds; $ok++ }
            $c.Close()
        } catch { }
        Start-Sleep -Milliseconds 120
    }
    if ($ok -gt 0) { return @{ ms = [math]::Round($sum / $ok); loss = [math]::Round(($tries - $ok) / $tries, 3) } }
    return @{ ms = -1; loss = 1 }
}

function Invoke-SpeedTest {
    try {
        $req = [Net.HttpWebRequest]::Create($SpeedUrl)
        $req.Proxy = $null   # ir directo; evita que la deteccion automatica de proxy (WPAD) cuelgue
        $req.Method = 'GET'; $req.Timeout = 20000; $req.ReadWriteTimeout = 30000; $req.KeepAlive = $false
        $sw = [Diagnostics.Stopwatch]::StartNew(); $total = 0L; $buf = New-Object byte[] 65536
        $resp = $req.GetResponse(); $st = $resp.GetResponseStream()
        while (($r = $st.Read($buf, 0, $buf.Length)) -gt 0) { $total += $r; if ($sw.Elapsed.TotalSeconds -gt 25) { break } }
        $st.Close(); $resp.Close(); $sw.Stop()
        if ($sw.Elapsed.TotalSeconds -le 0 -or $total -le 0) { return -1 }
        return [math]::Round($total * 8 / $sw.Elapsed.TotalSeconds / 1e6, 1)
    } catch { return -1 }
}

function Send-Lote([object[]]$beats) {
    $body = @{ token = $cfg.token; version = $Version; beats = $beats } | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($body)
    $req = [Net.HttpWebRequest]::Create($cfg.url)
    $req.Proxy = $null   # ir directo; evita que la deteccion automatica de proxy (WPAD) cuelgue el envio
    $req.Method = 'POST'; $req.ContentType = 'application/json; charset=utf-8'
    $req.AllowAutoRedirect = $true; $req.Timeout = 30000; $req.ContentLength = $bytes.Length   # seguir el 302 para leer la respuesta (comando de velocidad)
    $s = $req.GetRequestStream(); $s.Write($bytes, 0, $bytes.Length); $s.Close()
    $code = 0; $cuerpo = ''
    try {
        $resp = $req.GetResponse(); $code = [int]$resp.StatusCode
        $sr = New-Object IO.StreamReader($resp.GetResponseStream()); $cuerpo = $sr.ReadToEnd(); $sr.Close(); $resp.Close()
    } catch [Net.WebException] {
        if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode } else { throw }
    }
    if ($code -ne 200 -and $code -ne 302) { throw "HTTP $code" }
    return $cuerpo
}

Write-Log "Inicio v$Version - agente '$($cfg.agente)' cuenta '$($cfg.cuenta)' usuario '$env:USERNAME'"
$fallosSeguidos = 0
$primerEnvio = $true
$primerCiclo = $true
$haceSpeed = $false

while ($true) {
    $inicioCiclo = Get-Date
    $lineas = $null; $enviados = 0
    try {
        $mbps = $null
        if ($haceSpeed) { $m = Invoke-SpeedTest; $haceSpeed = $false; if ($m -ge 0) { $mbps = $m }; Write-Log "Test de velocidad: $m Mbps" }

        if ($primerCiclo) { Write-Log "diag: midiendo internet" }
        $net = Get-Latencia
        $lat = if ($net.ms -ge 0) { $net.ms } else { $null }

        if ($primerCiclo) { Write-Log "diag: leyendo programas" }
        $idle = [int][Monitor247Win]::IdleSeconds()
        $pa   = Get-ProgActivo
        $at   = Test-AppTelefono
        $pr   = @(Get-Programas)

        $beat = [ordered]@{
            id = [guid]::NewGuid().ToString('N'); ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            agente = [string]$cfg.agente; cuenta = [string]$cfg.cuenta; equipo = $env:COMPUTERNAME; usuario = $env:USERNAME
            email = (Get-CorreoWindows)
            idle = $idle; app = $at; inicio = $primerEnvio; progActivo = $pa; lat = $lat; loss = $net.loss; mbps = $mbps; progs = $pr
        }
        $primerEnvio = $false
        [IO.File]::AppendAllText($ColaFile, ($beat | ConvertTo-Json -Depth 8 -Compress) + "`r`n", $Utf8)

        if ($primerCiclo) { Write-Log "diag: enviando al servidor" }
        $lineas = @([IO.File]::ReadAllLines($ColaFile, $Utf8) | Where-Object { $_.Trim() })
        if ($lineas.Count -gt $MaxCola) { $lineas = $lineas[($lineas.Count - $MaxCola)..($lineas.Count - 1)] }
        $respuesta = ''
        while ($enviados -lt $lineas.Count) {
            $fin = [Math]::Min($enviados + $MaxLote, $lineas.Count) - 1
            $lote = @($lineas[$enviados..$fin] | ForEach-Object { $_ | ConvertFrom-Json })
            $respuesta = Send-Lote $lote
            $enviados = $fin + 1
        }
        [IO.File]::WriteAllText($ColaFile, '', $Utf8)
        # El actualizador lee esta marca para confirmar que la version instalada funciona
        try { [IO.File]::WriteAllText($UltimoFile, ($Version + '|' + (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')), $Utf8) } catch { }
        if ($primerCiclo) { Write-Log "diag: primer envio OK" }
        if ($respuesta -and $respuesta.IndexOf('"cmd":"speedtest"') -ge 0) { $haceSpeed = $true }
        if ($fallosSeguidos -gt 0) { Write-Log "Conexion restablecida; enviados $enviados latidos pendientes" }
        $fallosSeguidos = 0
    } catch {
        $fallosSeguidos++
        try {
            if ($lineas -and $lineas.Count -gt 0 -and $enviados -lt $lineas.Count) {
                [IO.File]::WriteAllLines($ColaFile, [string[]]$lineas[$enviados..($lineas.Count - 1)], $Utf8)
            }
        } catch { }
        if ($fallosSeguidos -eq 1 -or ($fallosSeguidos % 30) -eq 0) { Write-Log "Sin conexion con el servidor ($fallosSeguidos): $($_.Exception.Message)" }
    }
    $primerCiclo = $false
    $espera = $Intervalo - ((Get-Date) - $inicioCiclo).TotalSeconds
    if ($espera -gt 1) { Start-Sleep -Seconds ([int]$espera) }
}
