#
# NAS2Tape.ps1
#
# creates tape backup copies of restore points created by a given NAS backup job.
#
# v2021.04.09 M.Mehrtens, Veeam.com
#

##############################
# customization header

# NAS backup job name to be used as source for File-To-Tape job
$NASJobname = "NAS backup job"

# File-to-tape job to be used
$FileToTapeJobname = "NAS copy to tape"

# mount server used for instant file share recovery
$mountServer     = "winrepo-1.ad.local"
$FLRFolder       = "C:\VeeamFLR"

# cachje repository to be used for new file share objects in inventory (must exist, will not be used)
$cacheRepository = "NAS Cache"

# user account to be used as owner of the instant NAS recovery file shares (must exist in Veeam credential manager!)
$Owner = "AD\NAS2Tape"

# end of customization header
##############################

Write-Host "NAS-to-Tape File Copy processing"
Write-Host
Write-Host "working on NAS backup job ""$NASJobname"""
Write-Host

# get the shares and the backups of the NAS backup job
$obj_NASJob = Get-VBRNASBackupJob -Name $NASJobname
$NASJobObjects = $obj_NASJob.BackupObject
$NASBackups = Get-VBRNASBackup -Name $NASJobname

# start instant NAS recovery for each share of the NAS backup job
$recoverySessions = @()
foreach($NASobject in $NASJobObjects) {
    Write-Host "starting instant recovery of share ""$($NASobject.Path)"""
    
    # instant file share recovery only supports SMB and SMB filer shares (no NFS!)
    if(-not ($NASobject.Server.Type -in ("SMB", "SANSMB") ) )  {
            Write-Host "  unsupported share type ""$($NASobject.Server.Type)"" - share will be skipped  " -ForegroundColor Yellow -BackgroundColor DarkRed
    }
    else {
        # get latest restore point of the NAS backup job
        $restorePoint = $null
        $ErrorActionPreference = "SilentlyContinue"
        if($null -eq $restorePoint) {
            # try to get a restore point of a NFS/SMB share (will fail for filer objects!)
            $restorePoint = Get-VBRNASBackupRestorePoint -NASBackup $NASBackups -NASServer $NASobject.Server `
                            | Sort-Object –Property CreationTime –Descending | Select-Object -First 1
        }
        if($null -eq $restorePoint) {
            # if the above failed, try to get latest restore point of filer object's share
            $restorePoint = Get-VBRNASBackupRestorePoint -NASBackup $NASBackups -NASServer (Get-VBRNASServer -Name $NASobject.Path) `
                            | Sort-Object –Property CreationTime –Descending | Select-Object -First 1 -ErrorAction 
        }
        $ErrorActionPreference = "Continue"

        # do we have a valid restore point?
        if($null -ne $restorePoint) {
            # set mount options and permissions for recovery share
            $permSet = New-VBRNASPermissionSet -RestorePoint $restorePoint -Owner $Owner -AllowSelected -PermissionScope $Owner
            $mountOptions = New-VBRNASInstantRecoveryMountOptions -RestorePoint $restorePoint -MountServer $mountServer

            # start instant NAS recovery for this share and save for later
            $thisSession = Start-VBRNASInstantRecovery -RestorePoint $restorePoint -Permissions $permSet -MountOptions $mountOptions -RunAsync
            $recoverySessions += $thisSession
        } 
        else {
            # error message output
            Write-Host "  error while opening latest restore point - share will be skipped  " -ForegroundColor Yellow -BackgroundColor DarkRed
        }
    }
}
Write-Host

# check for existing recovery sessions and continue if they exist
$n_sessions = $recoverySessions.Count
if($n_sessions -gt 0) {


    #  wait for recovery sessions to complete mounting
    Write-Host "waiting for instant file share mounts to complete"
    Write-Host
    while($n_sessions -gt 0) {
        $n_sessions = $recoverySessions.Count
        foreach($thisSession in $recoverySessions) {
            try {
                if( (Get-VBRNASInstantRecovery -Id  $thisSession.Id -ErrorAction Ignore).IsMounted() ) {
                    $n_sessions--
                }
            } catch {
                Start-Sleep -Seconds 1
            }
        }
        Start-Sleep -Seconds 1
    }
    Write-Host

    # create an inventory items for each instant recovery share
    Write-Host "creating inventory items"
    $cred = Get-VBRCredentials -Name $Owner
    $IRShares = @()
    $f2tobjects = @()
    foreach($thisSession in $recoverySessions) {
        
        Write-Host "  "$thisSession.SharePath
        $invShare = Add-VBRNASSMBServer -Path $thisSession.SharePath -CacheRepository (Get-VBRBackupRepository -Name $cacheRepository) -AccessCredentials $cred -ErrorAction SilentlyContinue
        $IRShares += $invShare

        # create file-to-tape source objects for this inventory item
        $f2tobjects += New-VBRFileToTapeObject -NASServer $invShare
    }
    Write-Host

    # change the job sources and start the job
    $obj_tapeJob = Get-VBRTapeJob -Name $FileToTapeJobname
    Set-VBRFileToTapeJob -Job $obj_tapeJob -Object $f2tobjects

    Write-Host "starting job ""$FileToTapeJobname"""
    Start-VBRJob -Job $obj_tapeJob | Out-Null
    Write-Host "  job has finished"
    Write-Host

    ## revert the job source (to VeeamFLR folder)
    $f2tobjects = New-VBRFileToTapeObject -Server (Get-VBRServer -Name $mountServer) -Path $FLRFolder
    Set-VBRFileToTapeJob -Job $obj_tapeJob -Object $f2tobjects

    # delete share objects from inventory
    Write-Host "removing inventory items"
    foreach($share in $IRShares) {
        Write-Host "  "$share.Path
        Remove-VBRNASServer -Server $share
    }
    Write-Host

    # stop instant NAS recovery sessions
    Write-Host "stopping instant NAS recovery sesions"
    foreach($session in $recoverySessions) {
        Write-Host "  $($session.SharePath)"
        Stop-VBRNASInstantRecovery -InstantRecovery $session -Force -RunAsync
    }
}
else {
    Write-Host "no restore points to process"
}
Write-Host
