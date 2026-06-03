# ============================================
# AZS_Mail_Robot_v3.0.ps1 - CORE SCRIPT
# Версия: 3.0
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
$LogDirectory   = "$ScriptDir\Logs"
$TargetEmail    = $Config.target_email
$PendingFile    = "$ScriptDir\pending_send.txt"
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

$UpdateServer = $Config.update_server
$CurrentVersion = $Config.current_version

if (-not (Test-Path $LogDirectory)) { New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null }
if (-not (Test-Path $ArchiveFolder)) { New-Item -Path $ArchiveFolder -ItemType Directory -Force | Out-Null }

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

function Wait-FileReady([string]$FilePath, [int]$TimeoutSeconds = 60) {
    $elapsed = 0
    while ((Test-FileLocked $FilePath) -and ($elapsed -lt $TimeoutSeconds)) {
        Start-Sleep -Milliseconds 500
        $elapsed += 0.5
    }
    return -not (Test-FileLocked $FilePath)
}

function Test-WorkTime {
    $now = Get-Date
    $ws = [DateTime]::ParseExact($WorkStartTime, "HH:mm", $null)
    $we = [DateTime]::ParseExact($WorkEndTime, "HH:mm", $null)
    return ($now.TimeOfDay -ge $ws.TimeOfDay) -and ($now.TimeOfDay -le $we.TimeOfDay)
}

function Remove-OldFiles {
    $old = Get-ChildItem $ArchiveFolder -Filter "AZS_*.xml" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) }
    if ($old) { $old | Remove-Item -Force }
    $old = Get-ChildItem $LogDirectory -Filter "log_*.txt" -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) }
    if ($old) { $old | Remove-Item -Force }
}

function Send-File([string]$FilePath) {
    $Attachment = $null
    $MailMessage = $null
    try {
        $fileName = Split-Path $FilePath -Leaf
        $Subject = "Отчет АЗС $AzsNameRu"
        
        Write-Log "MAIL: Sending $fileName..."
        
        $MailMessage = New-Object System.Net.Mail.MailMessage
        $MailMessage.From = $SenderEmail
        $MailMessage.To.Add($TargetEmail)
        $MailMessage.Subject = $Subject
        $MailMessage.Body = "Автоматический отчет во вложении."
        $MailMessage.BodyEncoding = [System.Text.Encoding]::UTF8
        $MailMessage.SubjectEncoding = [System.Text.Encoding]::UTF8
        
        $Attachment = New-Object System.Net.Mail.Attachment($FilePath)
        $Attachment.Name = $fileName
        $MailMessage.Attachments.Add($Attachment)
        
        $SMTPClient = New-Object System.Net.Mail.SmtpClient($SMTPServer, $SMTPPort)
        $SMTPClient.EnableSsl = $true
        $SMTPClient.Credentials = New-Object System.Net.NetworkCredential($SenderEmail, $Password)
        $SMTPClient.Timeout = 60000
        
        $SMTPClient.Send($MailMessage)
        Write-Log "SUCCESS: $fileName sent"
        return $true
    }
    catch {
        Write-Log "ERROR: $_"
        return $false
    }
    finally {
        if ($Attachment) { $Attachment.Dispose() }
        if ($MailMessage) { $MailMessage.Dispose() }
    }
}

# ============================================
Write-Log "===================================================="
Write-Log "AZS MAIL ROBOT v$CurrentVersion STARTED"
Write-Log "AZS: $AzsNameRu ($AzsNameEn)"
Write-Log "===================================================="

$lastCleanupDate = (Get-Date).AddDays(-1)

$uptime = (Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
if ($uptime.TotalSeconds -lt $StartupDelay) {
    $wait = $StartupDelay - $uptime.TotalSeconds
    Write-Log "Waiting $([math]::Round($wait/60)) min after boot..."
    Start-Sleep -Seconds $wait
}

while ($true) {
    
    if ((Get-Date).Date -ne $lastCleanupDate.Date) {
        Remove-OldFiles
        $lastCleanupDate = Get-Date
    }
    
    $isWorkTime = Test-WorkTime
    $hasPending = (Test-Path $PendingFile) -and (Get-Content $PendingFile -ErrorAction SilentlyContinue | Where-Object { $_ -and (Test-Path $_) })
    
    if ($isWorkTime -or $hasPending) { $checkInterval = $ActiveInterval }
    else { $checkInterval = $IdleInterval }
    
    $allFiles = @()
    
    if (Test-Path $PendingFile) {
        Get-Content $PendingFile -ErrorAction SilentlyContinue | Where-Object { $_ -and (Test-Path $_) } | ForEach-Object { $allFiles += $_ }
    }
    
    Get-ChildItem $WatchFolder -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "SesDataExport*.xml" } | ForEach-Object { $allFiles += $_.FullName }
    
    if ($allFiles.Count -gt 0) {
        $pendingList = @()
        
        foreach ($filePath in $allFiles) {
            try {
                if (Test-FileLocked $filePath) {
                    if (-not (Wait-FileReady $filePath)) { 
                        $pendingList += $filePath
                        continue 
                    }
                }
                
                $fileItem = Get-Item $filePath
                
                if ($fileItem.Name -notlike "AZS_${AzsNameEn}_*.xml") {
                    if ($fileItem.BaseName -match "SesDataExport_(.+)$") {
                        $dateTimeString = $Matches[1]
                    }
                    else {
                        $dateTimeString = (Get-Date).ToString("yy.MM.dd_HH-mm-ss")
                    }
                    
                    $newName = "AZS_${AzsNameEn}_$dateTimeString.xml"
                    $finalPath = Join-Path $WatchFolder $newName
                    Rename-Item -Path $filePath -NewName $newName -Force
                    Write-Log "RENAME: $($fileItem.Name) -> $newName"
                }
                else {
                    $finalPath = $filePath
                }
                
                if (Send-File $finalPath) {
                    $archPath = Join-Path $ArchiveFolder (Split-Path $finalPath -Leaf)
                    Move-Item -Path $finalPath -Destination $archPath -Force
                    Write-Log "ARCHIVE: OK"
                }
                else {
                    $pendingList += $finalPath
                }
            }
            catch {
                Write-Log "ERROR: $_"
                if (Test-Path $filePath) { $pendingList += $filePath }
            }
        }
        
        if ($pendingList.Count -gt 0) {
            $pendingList | Sort-Object -Unique | Out-File $PendingFile -Encoding UTF8
            $checkInterval = 5
        }
        else {
            if (Test-Path $PendingFile) { Remove-Item $PendingFile -Force }
        }
    }
    
    [System.GC]::Collect()
    Start-Sleep -Seconds $checkInterval
}
   
