# =====================================================================
#  Monitor 24/7 Medical Aid - Actualizador remoto
#  Lo ejecuta la tarea programada "Monitor247_Actualizador" como SYSTEM
#  cada 5 minutos. En operacion normal solo consulta el servidor una vez
#  por hora; despues de una actualizacion revisa en cada ciclo, durante 12
#  ciclos CON EL EQUIPO ENCENDIDO, que el agente siga reportando, y si no,
#  devuelve la version anterior.
#  Si el panel pide actualizar un equipo, el agente deja "forzar.txt" y aqui
#  se consulta de inmediato, sin esperar la hora.
#  No toca ningun dato del agente: solo reemplaza el programa del monitor.
#  2.9: tambien instala y mantiene al dia la app "247 Time Clock" (TimeTrack)
#  en los equipos de 24/7 Medical Aid, cuando version.json trae la seccion "tc"
#  y este equipo esta incluido. Va aparte: si falla, el monitor no se toca.
#  2.14 (24 nov 2026, Fase 3) - para no tener que entrar nunca al PC de un usuario:
#   - Los archivos se bajan de timeclock.247medical-aid.com/agente/ (ya no de GitHub).
#   - Un bloqueo VENCE: una version que fallo se reintenta a las 24 h, hasta 3 veces;
#     despues queda bloqueada hasta que se publique otra o se pida desde el panel.
#   - Pedir la actualizacion desde el panel tambien quita el bloqueo de esa version.
#   - Una version recien instalada solo cuenta como fallida si, en los ciclos vigilados,
#     habia alguien con sesion abierta e internet (antes contaba cualquier ciclo).
#   - Cada ciclo deja estado\actualizador.json y lo manda al servidor (con la clave del
#     equipo): version, bloqueos, observacion, desde cuando esta atrasado y el registro.
# =====================================================================
$ErrorActionPreference = 'Stop'

$Destino      = 'C:\ProgramData\Monitor247'
$EstadoDir    = Join-Path $Destino 'estado'
$RespaldoDir  = Join-Path $Destino 'respaldo'
$ConfigFile   = Join-Path $Destino 'config.json'
$VersionFile  = Join-Path $Destino 'version.txt'
$PendienteFil = Join-Path $Destino 'pendiente.txt'
$BloqueoFile  = Join-Path $Destino 'bloqueo.txt'
$UltChequeo   = Join-Path $Destino 'ultimo-chequeo.txt'
# El aviso de "actualizar ya" lo deja el agente, que corre como usuario normal
# y solo tiene permiso de escritura dentro de 'estado'. Hasta la 2.3 se buscaba
# en la carpeta principal, donde el agente no puede escribir: por eso el boton
# del panel nunca funcionaba. Se miran las dos rutas por compatibilidad.
$ForzarFile   = Join-Path $EstadoDir 'forzar.txt'
$ForzarViejo  = Join-Path $Destino 'forzar.txt'
$LogFile      = Join-Path $Destino 'actualizar.log'
$Exe          = Join-Path $Destino 'Monitor247.exe'
$Ps1          = Join-Path $Destino 'monitor.ps1'
$Tarea        = 'Monitor247_Agente'
$BaseUrlFijo  = 'https://timeclock.247medical-aid.com/agente/'
$BaseVieja    = 'https://247medicalaid.github.io/agente/'   # 2.14: una clave vieja en config.json se traduce a la nueva
$ActVersion   = '2.14'
$SbUrl        = 'https://tftyyzoowctuhggwlgyt.supabase.co'
$SbKey        = 'sb_publishable_6hyJ-BV6detLiBszteEolQ_SiWlD8d1'   # clave publicable (la misma de las paginas)
$ReporteFile  = Join-Path $EstadoDir 'actualizador.json'
$ReporteEnv   = Join-Path $Destino 'reporte-enviado.txt'
$AtrasoFile   = Join-Path $Destino 'atrasado.txt'
$PausaFile    = Join-Path $Destino 'pausa-vigilancia.txt'
$BloqueoHoras = 24
$BloqueoMax   = 3
$MinutosRutina = 55      # en operacion normal, consultar una vez por hora
# La vigilancia de una version recien instalada se cuenta en CICLOS, no en
# minutos de reloj: este script corre cada 5 minutos, y solo corre si el equipo
# esta encendido. Contando ciclos, un equipo que se apaga o se suspende no
# parece un agente caido (el 22/9 el portatil se suspendio de noche y la 2.2 se
# devolvio sola por eso).
$CiclosGracia = 3        # ~15 min encendido antes de exigir que el agente reporte
$CiclosVigila = 12       # ~60 min encendido de vigilancia
$Utf8 = New-Object System.Text.UTF8Encoding($false)

function Log([string]$m) {
    try {
        if ((Test-Path $LogFile) -and ((Get-Item $LogFile).Length -gt 512KB)) { Move-Item $LogFile "$LogFile.old" -Force }
        Add-Content -Path $LogFile -Value ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m)
    } catch { }
}

function LeerTexto([string]$ruta) {
    if (Test-Path $ruta) { return ([IO.File]::ReadAllText($ruta, $Utf8)).Trim() }
    return ''
}

function EscribirTexto([string]$ruta, [string]$txt) { [IO.File]::WriteAllText($ruta, $txt, $Utf8) }

function Descargar([string]$url, [string]$destino) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $u = $url + (@('?', '&')[[int]($url.Contains('?'))]) + 't=' + [DateTime]::UtcNow.Ticks
    $req = [Net.HttpWebRequest]::Create($u)
    $req.Proxy = $null                 # ir directo; evita que WPAD cuelgue la descarga
    $req.Method = 'GET'; $req.Timeout = 30000; $req.ReadWriteTimeout = 60000
    $resp = $req.GetResponse()
    try {
        $fs = [IO.File]::Create($destino)
        try { $resp.GetResponseStream().CopyTo($fs) } finally { $fs.Close() }
    } finally { $resp.Close() }
}

function Hash([string]$ruta) { return (Get-FileHash -Path $ruta -Algorithm SHA256).Hash.ToLower() }

function DetenerAgente {
    try { Stop-ScheduledTask -TaskName $Tarea -ErrorAction SilentlyContinue } catch { }
    Get-Process -Name 'Monitor247' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*Monitor247*monitor.ps1*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 2
}

function ArrancarAgente {
    try { Start-ScheduledTask -TaskName $Tarea } catch { Log "No se pudo iniciar la tarea del agente: $($_.Exception.Message)" }
}

function BuscarCsc {
    foreach ($fw in 'Framework64', 'Framework') {
        $c = Join-Path $env:WINDIR ("Microsoft.NET\$fw\v4.0.30319\csc.exe")
        if (Test-Path $c) { return $c }
    }
    return $null
}

function AUtc([string]$t) { return [DateTime]::Parse($t, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal) }
function Ahora { return [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') }

# Base de descarga: la de config.json ("actualizaciones", p. ej. el canal piloto) o la fija.
# 2.14: si config.json todavia apunta a GitHub, se usa la misma ruta en timeclock.
function BaseActualizaciones {
    $base = $BaseUrlFijo
    $cfgTxt = LeerTexto $ConfigFile
    if ($cfgTxt) { try { $cfg = $cfgTxt | ConvertFrom-Json; if ($cfg.PSObject.Properties.Name -contains 'actualizaciones' -and $cfg.actualizaciones) { $base = [string]$cfg.actualizaciones } } catch { } }
    if (-not $base.EndsWith('/')) { $base += '/' }
    if ($base.StartsWith($BaseVieja)) { $base = $BaseUrlFijo + $base.Substring($BaseVieja.Length) }
    return $base
}

# ---- Bloqueos (2.14) ----
# bloqueo.txt: una linea por version, "<version>|<fecha UTC del ultimo fallo>|<fallos>".
# Una linea vieja (solo la version, de antes de la 2.14) cuenta como 1 fallo antiguo: vence ya.
function BloqueosLeer {
    $h = [ordered]@{}
    foreach ($l in ((LeerTexto $BloqueoFile) -split "`r?`n")) {
        $l = $l.Trim(); if (-not $l) { continue }
        $p = $l.Split('|')
        $f = [DateTime]::MinValue; $n = 1
        if ($p.Count -ge 2) { try { $f = AUtc $p[1] } catch { } }
        if ($p.Count -ge 3) { [int]::TryParse($p[2], [ref]$n) | Out-Null }
        $h[$p[0]] = @{ fecha = $f; n = $n }
    }
    return $h
}
function BloqueosGuardar($h) {
    $l = @(); foreach ($k in $h.Keys) {
        $f = '2000-01-01T00:00:00Z'; if ($h[$k].fecha -gt [DateTime]::MinValue) { $f = $h[$k].fecha.ToString('yyyy-MM-ddTHH:mm:ssZ') }
        $l += ($k + '|' + $f + '|' + $h[$k].n)
    }
    if ($l.Count) { EscribirTexto $BloqueoFile ($l -join "`r`n") } else { Remove-Item $BloqueoFile -Force -ErrorAction SilentlyContinue }
}
# '' = no bloqueada (o el bloqueo vencio); si no, el motivo para el registro
function BloqueoActivo([string]$ver) {
    $h = BloqueosLeer
    if (-not $h.Contains($ver)) { return '' }
    $b = $h[$ver]
    if ($b.n -ge $BloqueoMax) { return "fallo $($b.n) veces; queda bloqueada hasta que se publique otra o se pida desde el panel" }
    $faltan = $BloqueoHoras - ([DateTime]::UtcNow - $b.fecha).TotalHours
    if ($faltan -gt 0) { return ("fallo {0} de {1}; se reintenta en {2:0.#} h" -f $b.n, $BloqueoMax, $faltan) }
    return ''
}
function BloqueoQuitar([string]$ver) {
    $h = BloqueosLeer
    if ($h.Contains($ver)) { $h.Remove($ver); BloqueosGuardar $h; return $true }
    return $false
}
function BloqueoSumar([string]$ver) {
    $h = BloqueosLeer
    $n = 1; if ($h.Contains($ver)) { $n = $h[$ver].n + 1 }
    $h[$ver] = @{ fecha = [DateTime]::UtcNow; n = $n }
    BloqueosGuardar $h
    return $n
}

# ---- Condiciones reales para juzgar una version (2.14) ----
# Alguien con sesion abierta (explorer.exe): el agente corre en la sesion del usuario.
function HaySesion {
    try { return [bool](@(Get-Process -Name explorer -ErrorAction SilentlyContinue).Count) } catch { return $true }
}
# Internet hasta el servidor del Monitor: cualquier respuesta HTTP vale (aunque sea un error).
function HayInternet {
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [Net.HttpWebRequest]::Create($SbUrl + '/functions/v1/')
        $req.Proxy = $null; $req.Method = 'GET'; $req.Timeout = 10000
        $r = $req.GetResponse(); $r.Close(); return $true
    } catch [Net.WebException] {
        if ($_.Exception.Response) { try { $_.Exception.Response.Close() } catch { }; return $true }
        return $false
    } catch { return $false }
}

# ---------------------------------------------------------------------
# 1) Verificar una actualizacion recien aplicada
#    pendiente.txt = "<version>|<fecha UTC de la actualizacion>|<ciclos vigilados>"
#    Los ciclos solo avanzan cuando este script corre, o sea con el equipo
#    encendido: asi un equipo apagado o suspendido no cuenta como agente caido.
# ---------------------------------------------------------------------
function VerificarPendiente {
    $p = LeerTexto $PendienteFil
    if (-not $p) { return $false }
    $partes = $p.Split('|')
    if ($partes.Count -lt 2) { Remove-Item $PendienteFil -Force -ErrorAction SilentlyContinue; return $false }
    $ver = $partes[0]
    $desde = [DateTime]::Parse($partes[1], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
    $ciclos = 0
    if ($partes.Count -ge 3) { [int]::TryParse($partes[2], [ref]$ciclos) | Out-Null }
    # 2.14: un ciclo sin nadie con sesion o sin internet no dice nada de la version: no se cuenta
    if ($ciclos -ge $CiclosGracia -and -not ((HaySesion) -and (HayInternet))) {
        if (-not (Test-Path $PausaFile)) { Log "Vigilancia de $ver en pausa: no hay sesion abierta o no hay internet (no cuenta como fallo)."; EscribirTexto $PausaFile (Ahora) }
        return $true
    }
    if (Test-Path $PausaFile) { Remove-Item $PausaFile -Force -ErrorAction SilentlyContinue; Log "Vigilancia de $ver reanudada." }
    $ciclos = $ciclos + 1
    EscribirTexto $PendienteFil ($ver + '|' + $partes[1] + '|' + $ciclos)
    if ($ciclos -lt $CiclosGracia) { return $true }   # aun es pronto: se revisa en el proximo ciclo

    # El agente escribe aqui cada vez que logra enviar: "<version>|<fecha UTC>"
    $u = LeerTexto (Join-Path $EstadoDir 'ultimo.txt')
    $ok = $false
    if ($u) {
        $up = $u.Split('|')
        if ($up.Count -ge 2 -and $up[0].Replace('-net', '') -eq $ver.Replace('-net', '')) {
            try {
                $cuando = [DateTime]::Parse($up[1], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
                if ($cuando -gt $desde) { $ok = $true }
            } catch { }
        }
    }
    if ($ok) {
        Log "Version $ver confirmada: el agente esta reportando."
        Remove-Item $PendienteFil -Force -ErrorAction SilentlyContinue
        if (BloqueoQuitar $ver) { Log "Se quita el bloqueo anterior de $ver." }
        return $false
    }
    if ($ciclos -lt $CiclosVigila) { return $true }   # sigue en observacion

    Log "La version $ver no reporto en $ciclos revisiones con el equipo encendido: se devuelve la version anterior."
    Revertir $ver
    return $false
}

function Revertir([string]$verMala) {
    try {
        DetenerAgente
        $exeBk = Join-Path $RespaldoDir 'Monitor247.exe'
        $ps1Bk = Join-Path $RespaldoDir 'monitor.ps1'
        if (Test-Path $exeBk) { Copy-Item $exeBk $Exe -Force }
        if (Test-Path $ps1Bk) { Copy-Item $ps1Bk $Ps1 -Force }
        $verBk = LeerTexto (Join-Path $RespaldoDir 'version.txt')
        if ($verBk) { EscribirTexto $VersionFile $verBk }
        # 2.14: el bloqueo vence a las 24 h (hasta 3 fallos); antes era para siempre
        $n = BloqueoSumar $verMala
        if ($n -ge $BloqueoMax) { Log "La version $verMala fallo $n veces: queda bloqueada hasta que se publique otra o se pida desde el panel." }
        else { Log "La version $verMala queda en pausa $BloqueoHoras h (fallo $n de $BloqueoMax); despues se reintenta sola." }
        Remove-Item $PendienteFil -Force -ErrorAction SilentlyContinue
        ArrancarAgente
        Log "Restaurada la version $verBk."
    } catch {
        Log "ERROR al revertir: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------
# 2) Buscar e instalar una version nueva
# ---------------------------------------------------------------------
function BuscarActualizacion {
    $cfgTxt = LeerTexto $ConfigFile
    if (-not $cfgTxt) { Log 'ERROR: no se encontro config.json'; return }
    $base = BaseActualizaciones

    $tmp = Join-Path $env:TEMP ('mon247_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $manFile = Join-Path $tmp 'version.json'
        Descargar ($base + 'version.json') $manFile
        $man = (LeerTexto $manFile) | ConvertFrom-Json
        EscribirTexto $UltChequeo ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
        if (-not $man.version) { Log 'El archivo de versiones no trae version'; return }

        $actual = LeerTexto $VersionFile
        $script:verPublicada = [string]$man.version
        # Bloqueos de versiones que ya no se publican no sirven de nada: se limpian
        $hb = BloqueosLeer; $otras = @($hb.Keys | Where-Object { $_ -ne [string]$man.version })
        if ($otras.Count) { foreach ($k in $otras) { $hb.Remove($k) }; BloqueosGuardar $hb }
        if ($man.version -eq $actual) { Remove-Item $AtrasoFile -Force -ErrorAction SilentlyContinue; return }
        # Desde cuando este equipo ve una version nueva sin tenerla (lo lee el servidor para avisar)
        $atr = (LeerTexto $AtrasoFile).Split('|')
        if ($atr[0] -ne [string]$man.version) { EscribirTexto $AtrasoFile (([string]$man.version) + '|' + (Ahora)) }
        if ($script:forzado) {
            if (BloqueoQuitar ([string]$man.version)) { Log "Pedida desde el panel: se quita el bloqueo de $($man.version) y se intenta de nuevo." }
        } else {
            $motivo = BloqueoActivo ([string]$man.version)
            if ($motivo) { Log "La version $($man.version) no se instala por ahora: $motivo."; return }
        }

        $usaExe = Test-Path $Exe
        # El actualizador tambien se actualiza a si mismo cuando el manifiesto
        # trae su huella; si no viene, se deja el que ya esta.
        $actNew = $null
        if ($man.PSObject.Properties.Name -contains 'act' -and $man.act) {
            try {
                $actNew = Join-Path $tmp 'actualizar.ps1'
                Descargar ($base + 'actualizar.ps1') $actNew
                if ((Hash $actNew) -ne ([string]$man.act).ToLower()) { Log 'La huella de actualizar.ps1 no coincide; se deja el actual.'; $actNew = $null }
                # 2.14: un actualizador con errores de sintaxis dejaria al equipo sin actualizaciones: se revisa antes
                if ($actNew) {
                    $errs = $null; $tk = $null
                    [void][System.Management.Automation.Language.Parser]::ParseFile($actNew, [ref]$tk, [ref]$errs)
                    if ($errs -and @($errs).Count) { Log ('El actualizador nuevo tiene errores (' + @($errs)[0].Message + '); se deja el actual.'); $actNew = $null }
                }
            } catch { Log "No se pudo bajar actualizar.ps1: $($_.Exception.Message)"; $actNew = $null }
        }
        $ps1New = Join-Path $tmp 'monitor.ps1'
        Descargar ($base + 'monitor.ps1') $ps1New
        if ($man.ps1 -and (Hash $ps1New) -ne ([string]$man.ps1).ToLower()) { Log 'La huella de monitor.ps1 no coincide; se cancela.'; return }
        $csNew = $null
        if ($usaExe) {
            $csNew = Join-Path $tmp 'agente.cs'
            Descargar ($base + 'agente.cs') $csNew
            if ($man.cs -and (Hash $csNew) -ne ([string]$man.cs).ToLower()) { Log 'La huella de agente.cs no coincide; se cancela.'; return }
        }

        # Compilar antes de tocar nada: si falla, el equipo sigue con lo que tiene
        $exeNew = $null
        if ($usaExe) {
            $csc = BuscarCsc
            if (-not $csc) { Log 'No se encontro csc.exe; se cancela la actualizacion.'; return }
            $exeNew = Join-Path $tmp 'Monitor247.exe'
            & $csc /nologo /target:winexe /optimize+ "/out:$exeNew" $csNew 2>&1 | Out-Null
            if (-not (Test-Path $exeNew)) { Log 'No se pudo compilar la version nueva; se cancela.'; return }
        }

        Log "Actualizando de '$actual' a '$($man.version)'..."
        New-Item -ItemType Directory -Path $RespaldoDir -Force | Out-Null
        if ($usaExe -and (Test-Path $Exe)) { Copy-Item $Exe (Join-Path $RespaldoDir 'Monitor247.exe') -Force }
        if (Test-Path $Ps1) { Copy-Item $Ps1 (Join-Path $RespaldoDir 'monitor.ps1') -Force }
        $actPropio = Join-Path $Destino 'actualizar.ps1'
        if ($actNew -and (Test-Path $actPropio)) { Copy-Item $actPropio (Join-Path $RespaldoDir 'actualizar.ps1') -Force }
        EscribirTexto (Join-Path $RespaldoDir 'version.txt') $actual

        DetenerAgente
        Copy-Item $ps1New $Ps1 -Force
        if ($usaExe) { Copy-Item $exeNew $Exe -Force }
        if ($actNew) { Copy-Item $actNew $actPropio -Force; Log 'Tambien se actualizo el actualizador.' }
        EscribirTexto $VersionFile ([string]$man.version)
        EscribirTexto $PendienteFil (([string]$man.version) + '|' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
        ArrancarAgente
                Log "Instalada la version $($man.version). Queda en observacion $CiclosVigila revisiones."
        Remove-Item $AtrasoFile -Force -ErrorAction SilentlyContinue
    } catch {
        Log "No se pudo consultar/instalar la actualizacion: $($_.Exception.Message)"
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------
# 3) App "247 Time Clock" (TimeTrack) - 2.9 (equipos de 24/7 Medical Aid)
#    version.json trae:
#      "tc": { "version": "1.0.2", "todos": false, "equipos": ["PC1","PC2"], "no": [],
#              "archivos": [ ["TimeClock247.cs", "TimeClock247.cs", "<sha256>"], ... ] }
#    Cada archivo: [nombre en agente/timeclock/, ruta dentro de la carpeta del programa, huella].
#    Hace lo mismo que INSTALAR.bat: Program Files\247 Time Clock, compilado en el PC (si no se
#    puede, la copia ya compilada), WebView2 Runtime si falta, arranque con Windows, accesos
#    directos y entrada en "Aplicaciones" (se desinstala desde ahi). La primera vez se abre en la
#    sesion del agente para que entre con su correo.
#    Estado en timeclock.txt: "<version>|<fecha UTC>|ok" o "<version>|<fecha UTC>|error|<motivo>".
# ---------------------------------------------------------------------
$TcDestino   = Join-Path $env:ProgramFiles '247 Time Clock'
$TcExe       = Join-Path $TcDestino 'TimeClock247.exe'
$TcVerFile   = Join-Path $TcDestino 'version.txt'
$TcEstado    = Join-Path $Destino 'timeclock.txt'
$TcChequeo   = Join-Path $Destino 'tc-chequeo.txt'
$TcIntentos  = Join-Path $Destino 'tc-intentos.txt'
$TcNombre    = '247 Time Clock'
$TcIdWebView = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'

function TcVersionWebView2 {
    foreach ($k in @("HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$TcIdWebView",
                     "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$TcIdWebView")) {
        try { $p = (Get-ItemProperty -Path $k -ErrorAction Stop).pv; if ($p -and $p -ne '0.0.0.0') { return $p } } catch { }
    }
    return $null
}

function TcEstadoEscribir([string]$ver, [string]$txt) {
    try { EscribirTexto $TcEstado ($ver + '|' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ') + '|' + $txt) } catch { }
}

# Usuarios con sesion abierta en el PC (duenos de explorer.exe), sin repetir
function TcUsuariosEnSesion {
    $l = @()
    try {
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)) {
            try {
                $o = Invoke-CimMethod -InputObject $p -MethodName GetOwner -ErrorAction Stop
                if ($o.User) {
                    $u = $o.User; if ($o.Domain) { $u = $o.Domain + '\' + $o.User }
                    # con el SID la tarea funciona tambien con cuentas Microsoft / Azure AD
                    $id = $u
                    try { $s = Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction Stop; if ($s.Sid) { $id = [string]$s.Sid } } catch { }
                    if (-not ($l | Where-Object { $_.Id -eq $id })) { $l += [pscustomobject]@{ Nombre = $u; Id = $id } }
                }
            } catch { }
        }
    } catch { }
    return $l
}

# Abre la app en la sesion de cada usuario conectado. SYSTEM no puede mostrar ventanas en la
# sesion del usuario: se usa una tarea de una sola vez con ese usuario (interactiva) y se borra.
function TcAbrirEnSesiones([string]$argumentos) {
    $i = 0
    foreach ($s in @(TcUsuariosEnSesion)) {
        $i++; $u = $s.Nombre
        $nom = 'Monitor247_AbrirTimeClock_' + $i
        try {
            if ($argumentos) { $acc = New-ScheduledTaskAction -Execute $TcExe -Argument $argumentos -WorkingDirectory $TcDestino }
            else             { $acc = New-ScheduledTaskAction -Execute $TcExe -WorkingDirectory $TcDestino }
            $pri = New-ScheduledTaskPrincipal -UserId $s.Id -LogonType Interactive -RunLevel Limited
            $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -Priority 4
            Register-ScheduledTask -TaskName $nom -Action $acc -Principal $pri -Settings $set -Force | Out-Null
            Start-ScheduledTask -TaskName $nom
            Start-Sleep -Seconds 4
            Log "TimeClock: abierto para $u."
        } catch { Log "TimeClock: no se pudo abrir para ${u}: $($_.Exception.Message)" }
        finally { try { Unregister-ScheduledTask -TaskName $nom -Confirm:$false -ErrorAction SilentlyContinue } catch { } }
    }
}

function TcIncluido($tc) {
    $pc = ([string]$env:COMPUTERNAME).ToUpper()
    $nombres = @($tc.PSObject.Properties.Name)
    if ($nombres -contains 'no' -and $tc.no) { if (@($tc.no | ForEach-Object { ([string]$_).ToUpper() }) -contains $pc) { return $false } }
    if ($nombres -contains 'todos' -and $tc.todos -eq $true) { return $true }
    if ($nombres -contains 'equipos' -and $tc.equipos) { return (@($tc.equipos | ForEach-Object { ([string]$_).ToUpper() }) -contains $pc) }
    return $false
}

function RevisarTimeClock([bool]$forzado) {
    # Cada cuanto se consulta: 55 min si ya esta al dia; 10 min si falta instalar o actualizar
    $verInst = LeerTexto $TcVerFile
    $estado  = LeerTexto $TcEstado
    $alDia   = [bool]($estado -and $verInst -and $estado.EndsWith('|ok') -and $estado.StartsWith($verInst + '|') -and (Test-Path $TcExe))
    $ult = LeerTexto $TcChequeo
    if ($ult -and -not $forzado) {
        try {
            $cuando = [DateTime]::Parse($ult, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
            $espera = 10; if ($alDia) { $espera = 55 }
            if (([DateTime]::UtcNow - $cuando).TotalMinutes -lt $espera) { return }
        } catch { }
    }
    EscribirTexto $TcChequeo ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))

    $base = BaseActualizaciones

    $ver = $null
    $abiertos = @()
    $tmp = Join-Path $env:TEMP ('tc247_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $manFile = Join-Path $tmp 'version.json'
        Descargar ($base + 'version.json') $manFile
        $man = (LeerTexto $manFile) | ConvertFrom-Json
        # sin seccion tc o equipo fuera de la lista: la proxima consulta en 55 min (no cada 10)
        $luego = [DateTime]::UtcNow.AddMinutes(45).ToString('yyyy-MM-ddTHH:mm:ssZ')
        if (-not (@($man.PSObject.Properties.Name) -contains 'tc') -or -not $man.tc) { EscribirTexto $TcChequeo $luego; return }
        $tc = $man.tc
        if (-not (TcIncluido $tc)) { EscribirTexto $TcChequeo $luego; return }
        $ver = [string]$tc.version
        if (-not $ver -or -not $tc.archivos) { return }
        if ($verInst -eq $ver -and (Test-Path $TcExe)) {
            if (-not $alDia) { TcEstadoEscribir $ver 'ok' }
            return
        }

        # Intentos fallidos de esta version: 3 seguidos, despues uno cada 6 horas
        $int = (LeerTexto $TcIntentos).Split('|')
        $n = 0
        if ($int.Count -ge 3 -and $int[0] -eq $ver) {
            [int]::TryParse($int[1], [ref]$n) | Out-Null
            if ($n -ge 3 -and -not $forzado) {
                try {
                    $ultInt = [DateTime]::Parse($int[2], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
                    if (([DateTime]::UtcNow - $ultInt).TotalHours -lt 6) { return }
                } catch { }
            }
        }
        EscribirTexto $TcIntentos ($ver + '|' + ($n + 1) + '|' + [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))

        $primera = -not (Test-Path $TcExe)
        if ($primera) { Log "TimeClock: instalando $ver..." } else { Log "TimeClock: actualizando de '$verInst' a '$ver'..." }

        # a) Bajar y verificar cada archivo en una carpeta temporal con la estructura final
        $stage = Join-Path $tmp 'programa'
        foreach ($a in @($tc.archivos)) {
            $nombre = [string]$a[0]; $rel = [string]$a[1]; $huella = ([string]$a[2]).ToLower()
            if ($nombre -notmatch '^[A-Za-z0-9._-]+$' -or $rel -match '\.\.' -or $rel -match '^[\\/]' -or $rel -match ':') { throw "Archivo no permitido: $nombre -> $rel" }
            $dst = Join-Path $stage ($rel -replace '/', '\')
            New-Item -ItemType Directory -Path (Split-Path -Parent $dst) -Force | Out-Null
            Descargar ($base + 'timeclock/' + $nombre) $dst
            if ((Hash $dst) -ne $huella) { throw "La huella de $nombre no coincide" }
        }
        if (-not (Test-Path (Join-Path $stage 'TimeClock247.cs'))) { throw 'Falta TimeClock247.cs' }

        # b) Compilar en la carpeta temporal; si no se puede, la copia ya compilada
        $exeNuevo = Join-Path $stage 'TimeClock247.exe'
        $compilado = $false
        $csc = BuscarCsc
        if ($csc) {
            Push-Location $stage
            $prefErr = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try {
                $salida = & $csc /nologo /codepage:65001 /target:winexe /optimize+ /win32icon:app.ico /out:TimeClock247.exe `
                    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll `
                    /r:Microsoft.Web.WebView2.Core.dll /r:Microsoft.Web.WebView2.WinForms.dll TimeClock247.cs 2>&1
                if ($LASTEXITCODE -eq 0 -and (Test-Path $exeNuevo)) { $compilado = $true }
                else { Log ('TimeClock: no compilo; se usa la copia ya compilada. ' + ((($salida | Out-String).Trim()) -replace '\s+', ' ')) }
            } catch { Log "TimeClock: error al compilar: $($_.Exception.Message)" }
            finally { $ErrorActionPreference = $prefErr; Pop-Location }
        }
        if (-not $compilado) {
            $pre = Join-Path $stage 'TimeClock247-precompilado.exe'
            if (-not (Test-Path $pre)) { throw 'No se pudo compilar y no hay copia ya compilada' }
            Copy-Item $pre $exeNuevo -Force
        }

        # c) Cerrar la app donde este abierta (cualquier sesion) y copiar a Program Files
        $abiertos = @(Get-Process -Name 'TimeClock247' -ErrorAction SilentlyContinue)
        if ($abiertos.Count) { $abiertos | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }
        New-Item -ItemType Directory -Path $TcDestino -Force | Out-Null
        for ($k = 1; $k -le 3; $k++) {
            try { Copy-Item -Path (Join-Path $stage '*') -Destination $TcDestino -Recurse -Force; break }
            catch {
                if ($k -eq 3) { throw }
                Get-Process -Name 'TimeClock247' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 3
            }
        }
        Get-ChildItem -Path $TcDestino -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

        # d) Microsoft Edge WebView2 Runtime (Windows 11 lo trae; si falta se instala para todo el PC)
        $wv = TcVersionWebView2
        if (-not $wv) {
            Log 'TimeClock: falta WebView2 Runtime; se instala.'
            try {
                $wvSetup = Join-Path $tmp 'MicrosoftEdgeWebview2Setup.exe'
                Descargar 'https://go.microsoft.com/fwlink/p/?LinkId=2124703' $wvSetup
                # sin -Wait: en PowerShell 5.1 espera tambien a los procesos hijos (EdgeUpdate se queda corriendo)
                $pr = Start-Process -FilePath $wvSetup -ArgumentList '/silent /install' -PassThru
                if (-not $pr.WaitForExit(300000)) { Log 'TimeClock: el instalador de WebView2 no termino en 5 minutos; se sigue.' }
                $wv = TcVersionWebView2
                if (-not $wv) { Log "TimeClock: WebView2 no quedo instalado (codigo $($pr.ExitCode))." }
            } catch { Log "TimeClock: no se pudo instalar WebView2: $($_.Exception.Message)" }
        }

        # e) Arranque con Windows (en la bandeja), accesos directos y entrada en "Aplicaciones"
        try { Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'TimeClock247' -Value ('"' + $TcExe + '" --tray') }
        catch { Log "TimeClock: no se pudo dejar el arranque con Windows: $($_.Exception.Message)" }
        try {
            $sh = New-Object -ComObject WScript.Shell
            foreach ($lnk in @((Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\$TcNombre.lnk"),
                               (Join-Path $env:PUBLIC "Desktop\$TcNombre.lnk"))) {
                $s = $sh.CreateShortcut($lnk)
                $s.TargetPath = $TcExe; $s.WorkingDirectory = $TcDestino; $s.IconLocation = "$TcExe,0"
                $s.Description = 'Time Clock de 24/7 Medical Aid'; $s.Save()
            }
        } catch { Log "TimeClock: no se pudieron crear los accesos directos: $($_.Exception.Message)" }
        $clave = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\TimeClock247'
        try {
        New-Item -Path $clave -Force | Out-Null
        Set-ItemProperty -Path $clave -Name 'DisplayName' -Value $TcNombre
        Set-ItemProperty -Path $clave -Name 'DisplayVersion' -Value $ver
        Set-ItemProperty -Path $clave -Name 'Publisher' -Value '24/7 Medical Aid'
        Set-ItemProperty -Path $clave -Name 'DisplayIcon' -Value $TcExe
        Set-ItemProperty -Path $clave -Name 'InstallLocation' -Value $TcDestino
        Set-ItemProperty -Path $clave -Name 'UninstallString' -Value ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $TcDestino 'desinstalar.ps1') + '"')
        Set-ItemProperty -Path $clave -Name 'NoModify' -Value 1 -Type DWord
        Set-ItemProperty -Path $clave -Name 'NoRepair' -Value 1 -Type DWord
        } catch { Log "TimeClock: no se pudo registrar en Aplicaciones: $($_.Exception.Message)" }

        EscribirTexto $TcVerFile $ver
        Remove-Item $TcIntentos -Force -ErrorAction SilentlyContinue
        TcEstadoEscribir $ver 'ok'
        $como = ' (copia ya compilada).'; if ($compilado) { $como = ' (compilada en este PC).' }
        $wvTxt = ' SIN WebView2.'; if ($wv) { $wvTxt = " WebView2 $wv." }
        Log ("TimeClock: version $ver instalada" + $como + $wvTxt)

        # f) La primera vez se abre con la ventana a la vista (el agente entra con su correo);
        #    en una actualizacion, escondida en la bandeja si estaba abierta.
        if ($primera) { TcAbrirEnSesiones '' }
        elseif ($abiertos.Count) { TcAbrirEnSesiones '--tray' }
    } catch {
        $m = $_.Exception.Message
        Log "TimeClock: no se pudo instalar/actualizar: $m"
        if ($ver) { TcEstadoEscribir $ver ('error|' + ($m -replace '\|', '/')) }
        # si se cerro la app para actualizarla, se vuelve a abrir (en la bandeja) con lo que haya
        if ($abiertos.Count -and (Test-Path $TcExe)) { TcAbrirEnSesiones '--tray' }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------
# 4) Reporte al servidor (2.14): lo que antes solo se veia entrando al PC.
#    estado\actualizador.json + POST a la funcion monitor_equipo_reporte con la clave del equipo
#    (la misma que usa el agente, cifrada para esta maquina). A lo mas cada 30 min, o al cambiar.
# ---------------------------------------------------------------------
function ClaveEquipo {
    try {
        $f = Join-Path $EstadoDir 'clave.dat'
        if (-not (Test-Path $f)) { return '' }
        Add-Type -AssemblyName System.Security
        $ent = [Text.Encoding]::UTF8.GetBytes('Monitor247-clave-equipo')
        $b = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($f), $ent, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        $c = ([Text.Encoding]::UTF8.GetString($b)).Trim()
        if ($c.StartsWith('eq_')) { return $c }
    } catch { }
    return ''
}
function ArmarReporte {
    $bl = @(); $h = BloqueosLeer
    foreach ($k in $h.Keys) {
        $f = $null; if ($h[$k].fecha -gt [DateTime]::MinValue) { $f = $h[$k].fecha.ToString('yyyy-MM-ddTHH:mm:ssZ') }
        $bl += [ordered]@{ v = $k; fallos = $h[$k].n; desde = $f; permanente = [bool]($h[$k].n -ge $BloqueoMax) }
    }
    $pend = $null; $p = (LeerTexto $PendienteFil).Split('|')
    if ($p[0]) { $c = 0; if ($p.Count -ge 3) { [int]::TryParse($p[2], [ref]$c) | Out-Null }; $pend = [ordered]@{ v = $p[0]; desde = $(if ($p.Count -ge 2) { $p[1] } else { $null }); ciclos = $c; pausa = [bool](Test-Path $PausaFile) } }
    $atr = $null; $a = (LeerTexto $AtrasoFile).Split('|')
    if ($a[0] -and $a.Count -ge 2) { $atr = [ordered]@{ v = $a[0]; desde = $a[1] } }
    $log = @(); try { if (Test-Path $LogFile) { $log = @(Get-Content $LogFile -Tail 12 -ErrorAction Stop | ForEach-Object { ([string]$_).Substring(0, [Math]::Min(220, ([string]$_).Length)) }) } } catch { }
    $tcE = (LeerTexto $TcEstado).Split('|')
    $tc = [ordered]@{ v = (LeerTexto $TcVerFile); estado = $(if ($tcE.Count -ge 3) { $tcE[2] } else { $null }); detalle = $(if ($tcE.Count -ge 4) { $tcE[3] } else { $null }); intentos = (LeerTexto $TcIntentos) }
    return [ordered]@{
        act = $ActVersion; v = (LeerTexto $VersionFile); publicada = $script:verPublicada
        base = (BaseActualizaciones); ult_chequeo = (LeerTexto $UltChequeo)
        bloqueadas = $bl; observacion = $pend; atrasado = $atr; tc = $tc; log = $log; hora = (Ahora)
    }
}
function EnviarReporte {
    try {
        $rep = ArmarReporte
        $json = $rep | ConvertTo-Json -Depth 6 -Compress
        try { EscribirTexto $ReporteFile $json } catch { }
        # Mismo contenido que lo ultimo enviado (sin la hora ni el registro) y hace menos de 30 min: no se manda
        $sello = ($rep.v + '|' + $rep.publicada + '|' + (($rep.bloqueadas | ConvertTo-Json -Compress -Depth 4)) + '|' + (($rep.observacion | ConvertTo-Json -Compress)) + '|' + (($rep.atrasado | ConvertTo-Json -Compress)) + '|' + (($rep.tc | ConvertTo-Json -Compress)))
        $prev = (LeerTexto $ReporteEnv).Split([char]0x1F)
        if ($prev.Count -ge 2 -and $prev[1] -eq $sello) {
            try { if (([DateTime]::UtcNow - (AUtc $prev[0])).TotalMinutes -lt 30) { return } } catch { }
        }
        $clave = ClaveEquipo
        if (-not $clave) { return }   # sin clave aprobada no se puede identificar al equipo
        $cuerpo = @{ p_clave = $clave; p_reporte = $rep } | ConvertTo-Json -Depth 7 -Compress
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $req = [Net.HttpWebRequest]::Create($SbUrl + '/rest/v1/rpc/monitor_equipo_reporte')
        $req.Proxy = $null; $req.Method = 'POST'; $req.Timeout = 20000; $req.ContentType = 'application/json'
        $req.Headers.Add('apikey', $SbKey); $req.Headers.Add('Authorization', 'Bearer ' + $SbKey)
        $bytes = $Utf8.GetBytes($cuerpo); $req.ContentLength = $bytes.Length
        $st = $req.GetRequestStream(); try { $st.Write($bytes, 0, $bytes.Length) } finally { $st.Close() }
        $r = $req.GetResponse(); $r.Close()
        EscribirTexto $ReporteEnv ((Ahora) + [char]0x1F + $sello)
    } catch { }   # el reporte nunca frena al actualizador
}

# ---------------------------------------------------------------------
# Ciclo
# ---------------------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Global\Monitor247_Actualizador')
try { $tengo = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $tengo = $true }
if (-not $tengo) { exit 0 }

$script:forzado = $false
$script:verPublicada = $null
function CicloMonitor {
    $enObservacion = VerificarPendiente
    if ($enObservacion) { return }     # mientras se vigila una version nueva no se busca otra

    # Aviso del panel: consultar ya, sin esperar la hora. El aviso lo deja el
    # agente (corre como usuario, por eso escribe un archivo nuevo en vez de
    # borrar el del ultimo chequeo, que es de SYSTEM).
    $forzado = $false
    $avisoEn = $null
    if     (Test-Path $ForzarFile)  { $avisoEn = $ForzarFile }
    elseif (Test-Path $ForzarViejo) { $avisoEn = $ForzarViejo }
    if ($avisoEn) {
        $marca = LeerTexto $avisoEn
        Remove-Item $avisoEn -Force -ErrorAction SilentlyContinue
        Remove-Item $ForzarViejo -Force -ErrorAction SilentlyContinue
        $forzado = $true
        try {
            $cuandoF = [DateTime]::Parse($marca, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
            if (([DateTime]::UtcNow - $cuandoF).TotalMinutes -gt 60) { $forzado = $false; Log 'Aviso de actualizacion viejo; se ignora.' }
        } catch { }
        if ($forzado) { Log 'Actualizacion pedida desde el panel: se consulta ahora.' }
    }
    $script:forzado = $forzado

    # En operacion normal se consulta una vez por hora
    $ult = LeerTexto $UltChequeo
    if ($ult -and -not $forzado) {
        try {
            $cuando = [DateTime]::Parse($ult, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
            if (([DateTime]::UtcNow - $cuando).TotalMinutes -lt $MinutosRutina) { return }
        } catch { }
    }
    BuscarActualizacion
}

try {
    New-Item -ItemType Directory -Path $EstadoDir -Force | Out-Null
    CicloMonitor
} catch {
    Log "ERROR: $($_.Exception.Message)"
}
# 2.9: la app Time Clock va aparte; si algo falla aqui, el monitor ya quedo atendido arriba
try { RevisarTimeClock $script:forzado } catch { Log "TimeClock: ERROR: $($_.Exception.Message)" }
# 2.14: contarle al servidor como esta este equipo (nunca frena lo demas)
try { EnviarReporte } catch { }
try { $mutex.ReleaseMutex() } catch { }
