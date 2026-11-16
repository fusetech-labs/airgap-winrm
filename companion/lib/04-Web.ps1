# =====================================================================
#  04-Web.ps1  -  THE ONLY FILE THAT TALKS TO THE INTERNET
#  Airgap WinRM Toolkit  -  Copyright Fusetech
#  SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# ---------------------------------------------------------------------
#  Three calls: Get-WebText (a page, as text), Invoke-WebPost (a form
#  post, as text) and Invoke-FileDownload (a file, streamed to disk with
#  progress, a size check and a stop button).  TLS 1.2, the system proxy
#  with the logged-on user's credentials, one user agent, every request
#  written to the log as a CMD line.  A page read that fails for a moment
#  (no answer in time, a dropped connection, HTTP 5xx) is tried again as
#  often as a download is; no name or no route fails at once.  Nothing is
#  ever executed from what comes back; lib\06-Library.ps1 verifies every
#  file before it is kept.
# =====================================================================

function Initialize-WebClient {
    if ($script:WebReady) { return }
    try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12 } catch { }
    [System.Net.ServicePointManager]::Expect100Continue = $false
    $script:WebReady = $true
}

function New-WebRequest {
    param([string]$Url, [string]$Method = 'GET', [int]$TimeoutSec = 120)
    Initialize-WebClient
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.Method = $Method
    $req.UserAgent = [string]$script:Config.UserAgent
    $req.Timeout = $TimeoutSec * 1000
    $req.ReadWriteTimeout = $TimeoutSec * 1000
    $req.AllowAutoRedirect = $true
    $req.KeepAlive = $true
    if ($script:Config.UseSystemProxy) {
        $proxy = [System.Net.WebRequest]::GetSystemWebProxy()
        $proxy.Credentials = [System.Net.CredentialCache]::DefaultNetworkCredentials
        $req.Proxy = $proxy
    } else { $req.Proxy = $null }
    return $req
}

function Test-WebTransient {
    # A failure worth another try: the server or the line hiccuped (no answer in time, a dropped connection, HTTP 408,
    # 429 or 5xx).  No name, no route, no trust or a proxy that wants a password is not: the same answer would come
    # back, and a PC without internet must fail fast.
    param($Exception)
    if ([string]$Exception.Status -in 'Timeout', 'ReceiveFailure', 'ConnectionClosed', 'KeepAliveFailure', 'SendFailure', 'PipelineFailure') { return $true }
    try { if ($Exception.Response) { if ([int]$Exception.Response.StatusCode -in 408, 429, 500, 502, 503, 504) { return $true } } } catch { }
    return $false
}

function Get-WebTries {
    # How often a page read is tried: once, plus DownloadRetries (Settings tab) - the same number a file download gets
    return (1 + [math]::Max(0, [int]$script:Config.DownloadRetries))
}

function Wait-WebRetry {
    # The pause before another try (3 s, 6 s ...), said in the log; $script:WebRetryPauseSec, when set, replaces the pause
    param([int]$Attempt, [int]$Tries, [string]$Why)
    Write-PatchLog ("try {0} of {1} after: {2}" -f ($Attempt + 1), $Tries, $Why) 'WARN'
    $pause = 3; if ($null -ne $script:WebRetryPauseSec) { $pause = [int]$script:WebRetryPauseSec }
    if ($pause -gt 0) { Start-Sleep -Seconds ($pause * $Attempt) }
}

function Get-WebText {
    # A page as text.  A transient failure (Test-WebTransient) is tried again; then it throws with a one-line reason.
    param([Parameter(Mandatory = $true)][string]$Url, [int]$TimeoutSec = 120, [int]$MaxBytes = 20MB)
    $tries = Get-WebTries
    for ($attempt = 1; ; $attempt++) {
        Write-PatchLog ("GET {0}" -f $Url) 'CMD'
        $req = New-WebRequest -Url $Url -TimeoutSec $TimeoutSec
        $resp = $null
        try {
            $resp = $req.GetResponse()
            $stream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $sb = New-Object System.Text.StringBuilder
            $buf = New-Object char[] 65536
            while (($n = $reader.Read($buf, 0, $buf.Length)) -gt 0) { [void]$sb.Append($buf, 0, $n); if ($sb.Length -gt $MaxBytes) { throw "the page is larger than $([int]($MaxBytes / 1MB)) MB - not a page this tool reads" } }
            $reader.Dispose()
            return $sb.ToString()
        } catch [System.Net.WebException] {
            $why = Get-WebErrorText -Exception $_.Exception -Url $Url
            if ($attempt -ge $tries -or -not (Test-WebTransient -Exception $_.Exception)) { throw $why }
            Wait-WebRetry -Attempt $attempt -Tries $tries -Why $why
        } finally { if ($resp) { $resp.Dispose() } }
    }
}

function Invoke-WebPost {
    # A form post (application/x-www-form-urlencoded); the answer as text.
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][hashtable]$Fields, [int]$TimeoutSec = 120)
    $pairs = @()
    foreach ($k in $Fields.Keys) { $pairs += ('{0}={1}' -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Fields[$k])) }
    $body = [System.Text.Encoding]::UTF8.GetBytes($pairs -join '&')
    $tries = Get-WebTries
    for ($attempt = 1; ; $attempt++) {
        Write-PatchLog ("POST {0}  ({1})" -f $Url, (@($Fields.Keys) -join ', ')) 'CMD'
        $req = New-WebRequest -Url $Url -Method 'POST' -TimeoutSec $TimeoutSec
        $req.ContentType = 'application/x-www-form-urlencoded'
        $req.ContentLength = $body.Length
        $resp = $null
        try {
            $rs = $req.GetRequestStream(); $rs.Write($body, 0, $body.Length); $rs.Dispose()
            $resp = $req.GetResponse()
            $reader = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd(); $reader.Dispose()
            return $text
        } catch [System.Net.WebException] {
            $why = Get-WebErrorText -Exception $_.Exception -Url $Url
            if ($attempt -ge $tries -or -not (Test-WebTransient -Exception $_.Exception)) { throw $why }
            Wait-WebRetry -Attempt $attempt -Tries $tries -Why $why
        } finally { if ($resp) { $resp.Dispose() } }
    }
}

function Get-WebHead {
    # The size and date a link serves, without downloading it: @{ Length; LastModified; Url (after redirects) }.
    param([Parameter(Mandatory = $true)][string]$Url, [int]$TimeoutSec = 60)
    $tries = Get-WebTries
    for ($attempt = 1; ; $attempt++) {
        Write-PatchLog ("HEAD {0}" -f $Url) 'CMD'
        $req = New-WebRequest -Url $Url -Method 'HEAD' -TimeoutSec $TimeoutSec
        $resp = $null
        try {
            $resp = $req.GetResponse()
            $lm = ''
            try { if ($resp.Headers['Last-Modified']) { $lm = ([datetime]$resp.Headers['Last-Modified']).ToString('yyyy-MM-dd HH:mm:ss') } } catch { $lm = [string]$resp.Headers['Last-Modified'] }
            return @{ Length = [int64]$resp.ContentLength; LastModified = $lm; Url = [string]$resp.ResponseUri }
        } catch [System.Net.WebException] {
            $why = Get-WebErrorText -Exception $_.Exception -Url $Url
            if ($attempt -ge $tries -or -not (Test-WebTransient -Exception $_.Exception)) { throw $why }
            Wait-WebRetry -Attempt $attempt -Tries $tries -Why $why
        } finally { if ($resp) { $resp.Dispose() } }
    }
}

function Get-WebErrorText {
    param($Exception, [string]$Url)
    $msg = $Exception.Message
    try { if ($Exception.Response) { $msg = ('HTTP {0} {1}' -f [int]$Exception.Response.StatusCode, $Exception.Response.StatusDescription) } } catch { }
    $why = ''
    switch ([string]$Exception.Status) {
        'NameResolutionFailure' { $why = ' - the name does not resolve: no internet, or no DNS from this PC' }
        'ConnectFailure'        { $why = ' - no connection: a firewall, or no route to the internet from this PC' }
        'ProxyNameResolutionFailure' { $why = ' - the proxy name does not resolve (Internet Options on this PC)' }
        'TrustFailure'          { $why = ' - the site certificate is not trusted (an inspecting proxy? its root certificate is not in this PC''s store)' }
        'Timeout'               { $why = ' - no answer in time' }
        'SecureChannelFailure'  { $why = ' - TLS failed (the site needs TLS 1.2 or newer; a proxy may be in the way)' }
    }
    if ($msg -match 'HTTP 407') { $why = ' - the proxy wants a password this run cannot give (an S4U task has no network credentials: use Interactive on the Settings tab, or a proxy exception)' }
    return ('{0}{1} ({2})' -f $msg, $why, $Url)
}

function Get-WebException {
    # The WebException inside an error, if there is one.  A .NET call that throws inside a script arrives wrapped (a
    # MethodInvocationException), so the type of the outer exception says nothing.
    param($ErrorRecord)
    $inner = $null
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $inner = $ErrorRecord.Exception } elseif ($ErrorRecord -is [System.Exception]) { $inner = $ErrorRecord }
    while ($inner) { if ($inner -is [System.Net.WebException]) { return $inner }; $inner = $inner.InnerException }
    return $null
}

function Get-WebLimitText {
    return ('still not finished after {0} minute(s), the limit for one download (DownloadTimeoutMin: "Give up on one download after" on the Settings tab)' -f $script:Config.DownloadTimeoutMin)
}

function Get-WebResponsePumped {
    # The server's answer to a download request, waited for without freezing the window: the message queue is pumped,
    # the Stop button is honoured and the time limit counts from the first moment.
    param($Request, [double]$LimitSec, $Clock)
    $pending = $Request.BeginGetResponse($null, $null)
    while (-not $pending.AsyncWaitHandle.WaitOne(200)) {
        if ($script:Gui['Form']) { [System.Windows.Forms.Application]::DoEvents() }
        $giveUp = ''
        if ($script:Gui['StopRequested']) { $giveUp = 'stopped by the operator (Stop download)' }
        elseif ($Clock.Elapsed.TotalSeconds -ge $LimitSec) { $giveUp = Get-WebLimitText }
        if ($giveUp) { $Request.Abort(); try { $null = $Request.EndGetResponse($pending) } catch { }; throw $giveUp }
    }
    return $Request.EndGetResponse($pending)
}

function Invoke-FileDownload {
    # Streams $Url to $Path.part, then renames it to $Path.  Progress goes to the status bar and the log; the Stop
    # button on the status bar gives up (the part file is deleted).  Returns @{ Bytes; Seconds; LastModified }.
    # Three limits: the whole download may take DownloadTimeoutMin (Settings tab); a connection that sends nothing for
    # two minutes is broken ($script:WebStallSec, when set, replaces the two minutes); and MaxDownloadMB caps the size
    # whether or not the server announces one.  The wait for the server's answer is pumped, so the window stays alive
    # and Stop works before the first byte.  A failure that would come back the same (no such file, no name, no route,
    # a proxy that refuses) fails at once; a broken connection is tried again.
    param([Parameter(Mandatory = $true)][string]$Url, [Parameter(Mandatory = $true)][string]$Path, [int64]$ExpectedBytes = 0, [string]$What = '')
    $part = $Path + '.part'
    $folder = Split-Path -Path $Path -Parent
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
    $label = $What; if (-not $label) { $label = Split-Path -Path $Path -Leaf }
    $tries = Get-WebTries
    $limitSec = [double]$script:Config.DownloadTimeoutMin * 60
    $stallSec = 120; if ($null -ne $script:WebStallSec) { $stallSec = [int]$script:WebStallSec }
    $maxBytes = [int64]$script:Config.MaxDownloadMB * 1MB
    $lastError = ''
    for ($attempt = 1; $attempt -le $tries; $attempt++) {
        if ($attempt -gt 1) {
            Write-PatchLog ("{0}: try {1} of {2} after: {3}" -f $label, $attempt, $tries, $lastError) 'WARN'
            $pause = 5; if ($null -ne $script:WebRetryPauseSec) { $pause = [int]$script:WebRetryPauseSec }
            if ($pause -gt 0) { Start-Sleep -Seconds $pause }
        }
        Write-PatchLog ("GET {0}  -> {1}" -f $Url, $part) 'CMD'
        $req = New-WebRequest -Url $Url -TimeoutSec $stallSec
        $resp = $null; $in = $null; $out = $null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $script:Gui['StopRequested'] = $false; $script:Gui['Downloading'] = $true
        if ($script:Gui['StopButton']) { $script:Gui['StopButton'].Visible = $true; $script:Gui['StopButton'].Enabled = $true; $script:Gui['StopButton'].Text = 'Stop download' }
        try {
            $resp = Get-WebResponsePumped -Request $req -LimitSec $limitSec -Clock $sw
            $total = [int64]$resp.ContentLength
            $lm = ''
            try { if ($resp.Headers['Last-Modified']) { $lm = ([datetime]$resp.Headers['Last-Modified']).ToString('yyyy-MM-dd HH:mm:ss') } } catch { }
            if ($total -gt $maxBytes) { throw ("the server announces {0}, over the MaxDownloadMB limit of {1} MB (Settings tab) - not downloaded" -f (Format-ByteSize $total), $script:Config.MaxDownloadMB) }
            if ($ExpectedBytes -gt 0 -and $total -gt 0 -and $total -ne $ExpectedBytes) { throw ("the link now serves {0} bytes, the check saw {1} - the file changed since the check: check for updates again (size mismatch)" -f $total, $ExpectedBytes) }
            $in = $resp.GetResponseStream()
            $out = [System.IO.File]::Open($part, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
            $buf = New-Object byte[] 1MB
            $done = [int64]0; $lastSaid = 0; $lastShown = 0; $lastPct = -1
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n); $done += $n
                if ($script:Gui['StopRequested']) { throw 'stopped by the operator (Stop download)' }
                if ($done -gt $maxBytes) { throw ("{0} arrived and the server announced no size: over the MaxDownloadMB limit of {1} MB (Settings tab) - stopped" -f (Format-ByteSize $done), $script:Config.MaxDownloadMB) }
                $elapsed = $sw.Elapsed.TotalSeconds
                if ($elapsed -ge $limitSec) { throw (Get-WebLimitText) }
                $pct = -1; if ($total -gt 0) { $pct = [int](100 * $done / $total) }
                if ($pct -ne $lastPct -or $elapsed - $lastShown -ge 1) {
                    $lastShown = $elapsed; $lastPct = $pct
                    $rate = 0; if ($elapsed -gt 0) { $rate = $done / $elapsed }
                    Set-GuiStatus ("{0}: {1} of {2}{3} at {4}/s" -f $label, (Format-ByteSize $done), $(if ($total -gt 0) { Format-ByteSize $total } else { '?' }), $(if ($pct -ge 0) { ' (' + $pct + '%)' } else { '' }), (Format-ByteSize $rate))
                    if ($pct -ge 0) { Set-GuiProgress -Percent $pct }
                }
                if ($elapsed - $lastSaid -ge 30) { $lastSaid = $elapsed; Write-PatchLog ("{0}: {1} of {2} so far ({3:N0} s)" -f $label, (Format-ByteSize $done), $(if ($total -gt 0) { Format-ByteSize $total } else { '?' }), $elapsed) 'INFO' }
                if ($script:Gui['Form']) { [System.Windows.Forms.Application]::DoEvents() }
            }
            $out.Dispose(); $out = $null; $in.Dispose(); $in = $null
            if ($total -gt 0 -and $done -ne $total) { throw ("the connection ended after {0} of {1} bytes" -f $done, $total) }
            if ($done -eq 0) { throw 'the server sent no bytes' }
            if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
            Move-Item -LiteralPath $part -Destination $Path -Force
            Write-PatchLog ("{0}: {1} in {2:N0} s ({3}/s)" -f $label, (Format-ByteSize $done), $sw.Elapsed.TotalSeconds, (Format-ByteSize ($done / [math]::Max(0.001, $sw.Elapsed.TotalSeconds)))) 'OK'
            return @{ Bytes = $done; Seconds = [int]$sw.Elapsed.TotalSeconds; LastModified = $lm }
        } catch {
            $failure = $_
            try { $req.Abort() } catch { }   # the connection is given up, not read to its end
            if ($out) { $out.Dispose() }; if ($in) { try { $in.Dispose() } catch { } }
            if (Test-Path -LiteralPath $part) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
            $web = Get-WebException $failure
            if ($web) { $lastError = Get-WebErrorText -Exception $web -Url $Url } else { $lastError = Get-ShortError $failure }
            if ($lastError -match 'stopped by the operator|MaxDownloadMB|size mismatch|DownloadTimeoutMin') { throw $lastError }   # no retry: the next try would end the same
            if ($web -and -not (Test-WebTransient -Exception $web)) { throw $lastError }   # no such file, no name, no route, a proxy that refuses: the same answer would come back
        } finally {
            if ($resp) { $resp.Dispose() }
            $script:Gui['Downloading'] = $false
            if ($script:Gui['StopButton']) { $script:Gui['StopButton'].Visible = $false }
            Set-GuiProgress -Marquee
        }
    }
    throw ("{0}: given up after {1} attempt(s): {2}" -f $label, $tries, $lastError)
}
