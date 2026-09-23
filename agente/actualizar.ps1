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
$ForzarFile   = Join-Path $Destino 'forzar.txt'
$LogFile      = Join-Path $Destino 'actualizar.log'
$Exe          = Join-Path $Destino 'Monitor247.exe'
$Ps1          = Join-Path $Destino 'monitor.ps1'
$Tarea        = 'Monitor247_Agente'
$BaseUrlFijo  = 'https://247medicalaid.github.io/agente/'
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
        # No volver a instalar esa version hasta que se publique una mas nueva
        Add-Content -Path $BloqueoFile -Value $verMala
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
    $cfg = $cfgTxt | ConvertFrom-Json
    $base = $BaseUrlFijo
    if ($cfg.PSObject.Properties.Name -contains 'actualizaciones' -and $cfg.actualizaciones) { $base = [string]$cfg.actualizaciones }
    if (-not $base.EndsWith('/')) { $base += '/' }

    $tmp = Join-Path $env:TEMP ('mon247_' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        $manFile = Join-Path $tmp 'version.json'
        Descargar ($base + 'version.json') $manFile
        $man = (LeerTexto $manFile) | ConvertFrom-Json
        EscribirTexto $UltChequeo ([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ'))
        if (-not $man.version) { Log 'El archivo de versiones no trae version'; return }

        $actual = LeerTexto $VersionFile
        if ($man.version -eq $actual) { return }
        if ((LeerTexto $BloqueoFile) -split "`r?`n" -contains $man.version) {
            Log "La version $($man.version) esta bloqueada (fallo antes); no se reinstala."
            return
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
        Log "Instalada la version $($man.version). Queda en observacion $MinutosVigila minutos."
    } catch {
        Log "No se pudo consultar/instalar la actualizacion: $($_.Exception.Message)"
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------
# Ciclo
# ---------------------------------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Global\Monitor247_Actualizador')
try { $tengo = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $tengo = $true }
if (-not $tengo) { exit 0 }

try {
    New-Item -ItemType Directory -Path $EstadoDir -Force | Out-Null
    $enObservacion = VerificarPendiente
    if ($enObservacion) { exit 0 }     # mientras se vigila una version nueva no se busca otra

    # Aviso del panel: consultar ya, sin esperar la hora. El aviso lo deja el
    # agente (corre como usuario, por eso escribe un archivo nuevo en vez de
    # borrar el del ultimo chequeo, que es de SYSTEM).
    $forzado = $false
    if (Test-Path $ForzarFile) {
        $marca = LeerTexto $ForzarFile
        Remove-Item $ForzarFile -Force -ErrorAction SilentlyContinue
        $forzado = $true
        try {
            $cuandoF = [DateTime]::Parse($marca, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
            if (([DateTime]::UtcNow - $cuandoF).TotalMinutes -gt 60) { $forzado = $false; Log 'Aviso de actualizacion viejo; se ignora.' }
        } catch { }
        if ($forzado) { Log 'Actualizacion pedida desde el panel: se consulta ahora.' }
    }

    # En operacion normal se consulta una vez por hora
    $ult = LeerTexto $UltChequeo
    if ($ult -and -not $forzado) {
        try {
            $cuando = [DateTime]::Parse($ult, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
            if (([DateTime]::UtcNow - $cuando).TotalMinutes -lt $MinutosRutina) { exit 0 }
        } catch { }
    }
    BuscarActualizacion
} catch {
    Log "ERROR: $($_.Exception.Message)"
} finally {
    try { $mutex.ReleaseMutex() } catch { }
}
