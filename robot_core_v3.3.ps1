# ============================================
# robot_core_v3.3.ps1 - FINAL
# Обновление: ежедневно в 15:00
# ============================================

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigFile = "$ScriptDir\config_azs.json"

if (-not (Test-Path $ConfigFile)) {
    Write-Host "ERROR: config_azs.json not found!"
    exit 1
}

try {
    $Config = Get-Content $ConfigFile -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Host "ERROR: Failed to read config: $_"
    exit 1
}

$WatchFolder    = $Config.watch_folder
$ArchiveFolder  = "$ScriptDir\Отчеты"
$OutboxFolder   = "$ScriptDir\НаОтправку"
$LogDirectory   = "$ScriptDir\Logs"
$TargetEmail    = $Config.target_email
$PendingFile    = "$ScriptDir\pending_send.txt"
$WatchdogFile   = "$ScriptDir\watchdog.txt"
$AzsNameRu      = $Config.azs_name_ru
$AzsNameEn      = $Config.azs_name_en

$WorkStartTime  = $Config.work_start_time
$WorkEndTime    = $Config.work_end_time
$StartupDelay   = $Config.startup_delay
$IdleInterval   = $Config.idle_interval
$ActiveInterval = $Config.active_interval

$SMTPServer  = $Config.smtp_server
$SMTPPort    = $Config.smtp_port
$SenderEmail = $Config.sender_email
$Password    = $Config.password

$UpdateServer   = $Config.update_server
$CurrentVersion = "3.3"

if (-not (Test-Path $LogDirectory))  { New-Item -Path $LogDirectory  -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $ArchiveFolder)) { New-Item -Path $ArchiveFolder -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $OutboxFolder))  { New-Item -Path $OutboxFolder  -ItemType Directory -Force | Out-Null }

# ============================================
# ФУНКЦИИ
# ============================================

function Write-Log([string]$Message) {
    $CurrentDate = Get-Date -Format "yyyy-MM-dd"
    $DailyLogFile = "$LogDirectory\log_$CurrentDate.txt"
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogLine = "[$TimeStamp] $Message"
    Add-Content -Path $DailyLogFile -Value $LogLine -Encoding UTF8
    Write-Host $LogLine
}

function Test-FileLocked([string]$FilePath) {
    try {
        $file = [System.IO.File]::Open($FilePath, 'Open', 'Read', 'None')
        $file.Close()
        return $false
    }
    catch { return $true }
}

function Test-WorkTime {
    $now = Get-Date
    $ws = [DateTime]::ParseExact($WorkStartTime, "HH:mm", $null)
    $we = [DateTime]::ParseExact($WorkEndTime, "HH:mm", $null)
    return ($now.TimeOfDay -ge $ws.TimeOfDay) -and ($now.TimeOfDay -le $we.TimeOfDay)
}

function Remove-OldFiles {
    $old = Get-ChildItem $ArchiveFolder -Filter "AZS_*.xml" -ErrorAction SilentlyContinue | 
           Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) }
    if ($old) { $old | Remove-Item -Force }
    
    $old = Get-ChildItem $LogDirectory -Filter "log_*.txt" -ErrorAction SilentlyContinue | 
           Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) }
    if ($old) { $old | Remove-Item -Force }
    
    $old = Get-ChildItem $OutboxFolder -Filter "AZS_*.xml" -ErrorAction SilentlyContinue | 
           Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) }
    if ($old) { 
        Write-Log "CLEANUP: Removing $($old.Count) old files from Outbox"
        $old | Remove-Item -Force 
    }
}

function Update-Watchdog {
    Get-Date -Format "yyyy-MM-dd HH:mm:ss" | Out-File $WatchdogFile -Encoding UTF8 -Force
}

function Send-File([string]$FilePath) {
    $Attachment = $null
    $MailMessage = $null
    $SMTPClient = $null
    
    if (-not (Test-Path $FilePath)) { return $false }
    if (Test-FileLocked $FilePath) { return $false }
    
    try {
        $fileName = Split-Path $FilePath -Leaf
        
        Write-Log "MAIL: Sending $fileName..."
        
        $MailMessage = New-Object System.Net.Mail.MailMessage
        $MailMessage.From = $SenderEmail
        $MailMessage.To.Add($TargetEmail)
        $MailMessage.Subject = "Отчет АЗС $AzsNameRu"
        $MailMessage.Body = "Автоматический отчет во вложении."
        $MailMessage.BodyEncoding = [System.Text.Encoding]::UTF8
        $MailMessage.SubjectEncoding = [System.Text.Encoding]::UTF8
        
        $Attachment = New-Object System.Net.Mail.Attachment($FilePath)
        $Attachment.Name = $fileName
        $MailMessage.Attachments.Add($Attachment)
        
        $SMTPClient = New-Object System.Net.Mail.SmtpClient($SMTPServer, $SMTPPort)
        $SMTPClient.EnableSsl = $true
        $SMTPClient.Credentials = New-Object System.Net.NetworkCredential($SenderEmail, $Password)
        $SMTPClient.Timeout = 30000
        
        $task = $SMTPClient.SendMailAsync($MailMessage)
        if (-not $task.Wait(35000)) {
            throw "SMTP timeout"
        }
        
        Write-Log "SUCCESS: $fileName sent"
        return $true
    }
    catch {
        Write-Log "ERROR: $_"
        return $false
    }
    finally {
        if ($Attachment)   { $Attachment.Dispose() }
        if ($MailMessage)  { $MailMessage.Dispose() }
        if ($SMTPClient)   { $SMTPClient.Dispose() }
    }
}

function Send-Notification([string]$Message) {
    try {
        $mail = New-Object System.Net.Mail.MailMessage
        $mail.From = $SenderEmail
        $mail.To.Add($TargetEmail)
        $mail.Subject = "AZS $AzsNameRu - $Message"
        $mail.Body = "АЗС: $AzsNameRu`n$Message`nДата: $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss')"
        $mail.BodyEncoding = [System.Text.Encoding]::UTF8
        
        $smtp = New-Object System.Net.Mail.SmtpClient($SMTPServer, $SMTPPort)
        $smtp.EnableSsl = $true
        $smtp.Credentials = New-Object System.Net.NetworkCredential($SenderEmail, $Password)
        $smtp.Timeout = 15000
        $smtp.Send($mail)
        $mail.Dispose()
        Write-Log "NOTIFY: Sent"
    }
    catch {
        Write-Log "NOTIFY: Failed"
    }
}

function Check-Update {
    Write-Log "UPDATE: Checking..."
    
    $web = $null
    
    try {
        $web = New-Object System.Net.WebClient
        $web.Encoding = [System.Text.Encoding]::UTF8
        
        $versionUrl = "$UpdateServer/versions.json"
        Write-Log "UPDATE: Fetching $versionUrl"
        
        $json = $web.DownloadString($versionUrl)
        $versionInfo = $json | ConvertFrom-Json
        
        $latestVersion = $versionInfo.latest_version
        Write-Log "UPDATE: Server: v$latestVersion, Current: v$CurrentVersion"
        
        if ($latestVersion -ne $CurrentVersion) {
            Write-Log "UPDATE: New version v$latestVersion available!"
            
            $downloadUrl = $versionInfo.files.core_script.url
            $tempFile = "$env:TEMP\robot_update.ps1"
            
            Write-Log "UPDATE: Downloading..."
            $web.DownloadFile($downloadUrl, $tempFile)
            
            if (Test-Path $tempFile) {
                $currentScript = $MyInvocation.MyCommand.Path
                $backupFile = "$currentScript.v$CurrentVersion.backup"
                
                Copy-Item $currentScript $backupFile -Force
                Write-Log "UPDATE: Backup saved"
                
                Copy-Item $tempFile $currentScript -Force
                Remove-Item $tempFile -Force
                
                Write-Log "UPDATE: Script updated to v$latestVersion!"
                Send-Notification "Обновление до v$latestVersion"
                
                Start-Sleep -Seconds 3
                schtasks /Run /TN "AZS_Mail_Robot" 2>$null
                exit 0
            }
        }
        else {
            Write-Log "UPDATE: Already latest version"
        }
    }
    catch {
        Write-Log "UPDATE: Check failed - $_"
    }
    finally {
        if ($web) { $web.Dispose() }
    }
}

# ============================================
# ГЛАВНЫЙ ЦИКЛ
# ============================================
Write-Log "===================================================="
Write-Log "ROBOT CORE v$CurrentVersion STARTED"
Write-Log "AZS: $AzsNameRu ($AzsNameEn)"
Write-Log "Update: daily at 15:00"
Write-Log "===================================================="

$lastCleanupDate = (Get-Date).AddDays(-1)
$lastUpdateCheck = (Get-Date).AddDays(-1)

$uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
if ($uptime.TotalSeconds -lt $StartupDelay) {
    $wait = $StartupDelay - $uptime.TotalSeconds
    Write-Log "Waiting $([math]::Round($wait/60)) min after boot..."
    Start-Sleep -Seconds $wait
}

while ($true) {
    
    Update-Watchdog
    
    # Ежедневная очистка
    if ((Get-Date).Date -ne $lastCleanupDate.Date) {
        Remove-OldFiles
        $lastCleanupDate = Get-Date
    }
    
    # Проверка обновлений в 15:00
    $currentHour = (Get-Date).Hour
    if ($currentHour -eq 15 -and (Get-Date).Date -ne $lastUpdateCheck.Date) {
        Check-Update
        $lastUpdateCheck = Get-Date
    }
    
    # Режим работы
    $isWorkTime = Test-WorkTime
    $hasPending = (Test-Path $PendingFile) -and (Get-Content $PendingFile -ErrorAction SilentlyContinue | Where-Object { $_ -and (Test-Path $_) })
    
    if ($isWorkTime -or $hasPending) { $checkInterval = $ActiveInterval }
    else { $checkInterval = $IdleInterval }
    
    # Копируем новые файлы в Отчеты и НаОтправку
    $newFiles = @(Get-ChildItem $WatchFolder -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "SesDataExport*.xml" })
    
    foreach ($file in $newFiles) {
        try {
            if (Test-FileLocked $file.FullName) { continue }
            
            if ($file.BaseName -match "SesDataExport_(.+)$") {
                $dateTimeString = $Matches[1]
            }
            else {
                $dateTimeString = (Get-Date).ToString("yy.MM.dd_HH-mm-ss")
            }
            
            $newName = "AZS_${AzsNameEn}_$dateTimeString.xml"
            $reportPath = Join-Path $ArchiveFolder $newName
            $outboxPath = Join-Path $OutboxFolder $newName
            
            if (Test-Path $reportPath) {
                $newName = "AZS_${AzsNameEn}_$dateTimeString`_$(Get-Random -Minimum 1000 -Maximum 9999).xml"
                $reportPath = Join-Path $ArchiveFolder $newName
                $outboxPath = Join-Path $OutboxFolder $newName
            }
            
            Copy-Item $file.FullName $reportPath -Force
            Copy-Item $file.FullName $outboxPath -Force
            Remove-Item $file.FullName -Force
            
            Write-Log "NEW: $($file.Name) -> $newName"
        }
        catch {
            Write-Log "ERROR (copy): $_"
        }
    }
    
    # Отправляем из НаОтправку
    $outboxFiles = @(Get-ChildItem $OutboxFolder -Filter "AZS_*.xml" -ErrorAction SilentlyContinue)
    
    $pendingList = @()
    if (Test-Path $PendingFile) {
        $pendingList = @(Get-Content $PendingFile -ErrorAction SilentlyContinue | Where-Object { $_ -and (Test-Path $_) })
    }
    
    foreach ($file in $outboxFiles) {
        if ($pendingList -contains $file.FullName) { continue }
        
        Update-Watchdog
        
        $sent = Send-File $file.FullName
        
        if ($sent) {
            Remove-Item $file.FullName -Force
            Write-Log "SENT: $($file.Name) removed from Outbox"
        }
        else {
            if ($pendingList -notcontains $file.FullName) {
                $pendingList += $file.FullName
            }
        }
    }
    
    # Обновляем pending
    if ($pendingList.Count -gt 0) {
        $pendingList | Sort-Object -Unique | Out-File $PendingFile -Encoding UTF8
        $checkInterval = [Math]::Min($checkInterval, 10)
    }
    else {
        if (Test-Path $PendingFile) { Remove-Item $PendingFile -Force }
    }
    
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    
    # Ожидание с проверкой сигнала перезапуска
    for ($i = 0; $i -lt $checkInterval; $i++) {
        Start-Sleep -Seconds 1
        if (Test-Path "$ScriptDir\restart.signal") {
            Write-Log "RESTART SIGNAL"
            Remove-Item "$ScriptDir\restart.signal" -Force
            exit 0
        }
    }
}
