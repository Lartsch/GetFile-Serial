# bind parameters
[CmdletBinding()]
param (
	[string]$mode,
	[string]$path,
	[string]$port,
	[int64]$maxsize = 100000,
	[string]$targetdir = (Get-Item .).FullName,
	[switch]$help,
	[switch]$h,
	[switch]$yes,
	[string]$skip = "no",
	[string]$notmatch = "",
	[string]$mountcmd = "-t ubifs -o rw /dev/ubi0_7 /tmp"
)

# workaround for the pwsh7 recall
if ($yes) {
	$skip = "yes"
}

# create target dir if not exists
if (!(test-path $targetdir)) {
	New-Item -ItemType Directory -Force -Path $targetdir | Out-Null
}

# set some base variables - chaos
$global:triedmount = $false
$global:debug = $false					
$global:logfile = Join-Path -Path $targetdir -ChildPath "getfile_lastrun_log.txt"
"" | Out-File $global:logfile
$global:mountpoint = $mountcmd.split(" ")[-1]
if ($global:mountpoint.endsWith("/")) {
	$global:mountpoint = $global:mountpoint.substring(0,$global:mountpoint.length-1)
}

# log to console and file
function ConsoleLog {
	param (
		[string]$text
	)
	"$text" | Tee -FilePath $global:logfile -Append | Write-Host
}

# check all conditions for parameters, show help text + exit if not fulfilled
if ($help -or $h -or $mode -eq $null -or $mode -eq "" -or $port -eq $null -or $port -eq "" -or $path -eq $null -or $path -eq "" -or !(("dir","file","filelist").contains("$mode")) -or (($mode -eq "dir" -or $mode -eq "file") -and !($path.startsWith("/"))) -or ($mode -eq "filelist" -and !(test-path $path))) {
	ConsoleLog "
`nUSAGE NOTES`n
-----------`n
getfile.ps1 -path <path> -mode <dir|file|filelist> -port <COM#> [-maxsize <integer>] [-targetdir <path>] [-notmatch <regex string>] [-mountcmd <linux mount command>] [-yes] [-h] [-help]`n
-----------`n
- If mode is 'dir' the provided path needs to be an absolute path leading to an existing folder on the remote device. Changes to the downloaded filelist can be made before the actual transfer starts. Make sure the path exists on the device.
- If mode is 'file' the provided path needs to be an absolute path leading to an existing file on the remote device. Make sure the path exists on the device.
- If mode is 'filelist', the provided path needs to point to an existing local file. The file can contain absolute paths to files on the remote device (one per line).
- The maxsize parameter is optional and limits which files to transfer by their size in bytes. Default = 100000.
- The targetdir parameter is optional and used to specify the directory where files and folders will be created. Default = cwd.
- The notmatch parameter is optional and used to filter out files found in 'dir' mode that contain the pattern in the filepath. Supports regex.
- Use -h or -help to show this information.
- Use -yes if you are in 'dir' mode and want to skip the question if you want to edit the files found before starting the transfer.
- Write access to /tmp on the serial device is needed and automatically checked.
- If no write access was found and you are on a read only system, you can specify your own mount command using the mountcmd parameter (ex. '-t ubifs -o rw /dev/ubi0_7 /tmp'). Do not prefix the mount command itself. Helpful in case it is possible to mount another partition as rw.
- Make sure the device is in a ready state (e.g. serial console running and responsive)
- Folders are created as necessary on the local system
- Program might FAIL with big files or directories with lots of files when in 'dir' mode (like / dir).`n
				"
	exit
}

# check powershell version since we used Start-ThreadJob
if (!((Get-Host).Version.Major -ge 7)) {
	# powershell 7 not detected, do we have the executable?
	if(!(test-path "$env:ProgramFiles\PowerShell\7\pwsh.exe")) {
		# nope, exit
		ConsoleLog "`n>>> Please install PowerShell 7`n`nhttps://github.com/PowerShell/PowerShell/releases/download/v7.2.1/PowerShell-7.2.1-win-x64.msi`n"
		exit
	}
	# yes, restart the script in pwsh7 with all needed parameters
	ConsoleLog "`n`n>>> Restarting in Powershell 7...`n`n"
	Start-Process -FilePath "$env:ProgramFiles\PowerShell\7\pwsh.exe" -ArgumentList "`"$PSCommandPath`"", "-mode $mode", "-path `"$path`"", "-maxsize $maxsize", "-targetdir `"$targetdir`"", "-skip $skip", "-notmatch `"$notmatch`"", "-mountcmd `"$mountcmd`"", "-port `"$port`"" -NoNewWindow -Wait
	exit
}

# if there is no plink.exe, this will not work
if (!(Get-Command plink -ErrorAction SilentlyContinue)) {
		ConsoleLog "plink.exe not existing. Please install PuTTY with plink.`n"
		exit
	}

# log that we use default max file size
if ($maxsize -eq "100000") {
	ConsoleLog "Using default value of $maxsize bytes for max filesize."
}

# log that we use current working directory for transferred files
if ($targetdir -eq ((Get-Item .).FullName)) {
	ConsoleLog "Using working directory as target directory."
}

# helper function to kill leftover plink processes - only one can exist at a time for this to work
function killplinkjob {
	Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
	Get-Process "plink" -ErrorAction SilentlyContinue | Stop-Process -ErrorAction SilentlyContinue
}

# register kill plink function to execute on exit
Register-EngineEvent PowerShell.Exiting -Action {killplinkjob} | Out-Null

# check if we have a writable mountpoint
function CheckWritable {

	ConsoleLog "Testing if $global:mountpoint is writable on serial device..."
	
	# scriptblock for background process - all until pape will be executed on target machine - use getfile_serial profile from putty to connect
	$scriptblock = [ScriptBlock]::create("
				`"printf '\033c'; mkdir $global:mountpoint/getfiletmp; rm -r $global:mountpoint/getfiletmp`" | plink -serial `"\\.\$port`" -sercfg 115200,8,1,N,N 
			")

	killplinkjob

	# start background job
	ConsoleLog "Starting plink in background"
	$global:load = Start-ThreadJob -ScriptBlock $scriptblock

	sleep 3

	# get the console stream
	$global:compareload = Receive-Job $global:load

	killplinkjob

	# remove any new lines and spaces (since we look for base64)
	$string = [string]::join("",($global:compareload.Split("`n")))
	$string = [string]::join("", ($string.Split(" ")))

	# if we have no data at all, the device / console is likely not available, exit
	if ($string -eq $null -or $string -eq "") {
		ConsoleLog "`nCould not get any data. Is the device available?`n`n"
		exit
	}

	# if our linux commands returned something with "Read-only" to the console, mountpoint is not writable 
	if ($string -match "Read-only") {
		ConsoleLog "$global:mountpoint is not writable. Please ensure you mount a writable device to $global:mountpoint."
		# if we already tried to mount exit
		if ($global:triedmount -eq $true) {
			ConsoleLog "Automount did not work. Exiting.`n"
			exit
		}
		# otherwise ask if wanting to mount now
		$confirmation = Read-Host "Execute 'mount $mountcmd' now? (y/n)"
		if ($confirmation -eq "y") {
			# yes, mount
			MountTmp
			# set check variable to true
			$global:triedmount = $true
			# re-execute this function
			CheckWritable
		} else {
			# no, then we must exit
			exit
		}
	} else {
		# okay, we're fine!
		ConsoleLog "$global:mountpoint is writable`n"
		return $true
	}

}

# helper to execute a mount command on the target device
function MountTmp {

	ConsoleLog "Executing 'mount $mountcmd'..."
	
	$scriptblock = [ScriptBlock]::create("
				`"printf '\033c'; mount $mountcmd`" | plink -serial `"\\.\$port`" -sercfg 115200,8,1,N,N 
			")

	killplinkjob

	ConsoleLog "Starting plink in background"
	$global:load = Start-ThreadJob -ScriptBlock $scriptblock

	sleep 3

	killplinkjob

}

# download a file via serial console
function GetFileViaPlinkSerial {
	
	param (
		[string]$filepath
	)

	ConsoleLog "$filepath"

	# setup some folder/filepath related variables
	$folder = $filepath | Split-Path -Parent
	if ($folder -eq $null -or $folder -eq "") {
		ConsoleLog "WARNING: Path could not be resolved, trying to save in working directory"
	}
	$fileout = ($filepath | Split-Path -Leaf).split([IO.Path]::GetInvalidFileNameChars()) -join '_'
	$fullpath_folder_out = Join-Path -Path $targetdir -ChildPath $folder
	$fullpath_file_out = Join-Path -Path $fullpath_folder_out -ChildPath $fileout

	# scriptblock to execute in background job. this time the linux part is:
	# clear the console, make a temp dir, encode the file in base64, echo first delimiter, get the filesize of the base64 file and echo our "file too big" delimiter if too big, else cat the base64 file, lastly remove temp folder
	$scriptblock = [ScriptBlock]::create("
				'printf `"\033c`"; mkdir $global:mountpoint/getfiletmp; openssl enc -base64 -in `"$filepath`" -out `"$global:mountpoint/getfiletmp/$fileout.base64`" `&>/dev/null; echo `"#+#+#+#+#+#+#+#+#+#`"; stat -c%s `"$global:mountpoint/getfiletmp/$fileout.base64`" | { read filesize; if [[ `$filesize -gt $maxsize ]]; then echo `"FILEISTOOBIGERROR---QUIT`"; else cat $global:mountpoint/getfiletmp/$fileout.base64; fi; }; echo `"#+#+#+#+#+#+#+#+#+#`"; rm -r $global:mountpoint/getfiletmp;' | plink -serial `"\\.\$port`" -sercfg 115200,8,1,N,N 
			")

	# check if we already have this file
	if (test-path $fullpath_file_out) {
		ConsoleLog "Folder or file already exists locally, skipping transfer from serial device.`n"
		return
	}

	try {

		killplinkjob

		# start the background job
		ConsoleLog "Starting plink in background"
		$global:load = Start-ThreadJob -ScriptBlock $scriptblock

		ConsoleLog "Waiting for indicator in stream..."
		# initial wait job - wait for the first appearance of our indicator
		while ($true) {
			sleep 2
			$checkforindicator = Receive-Job -Keep $global:load
			$checkforindicator = [string]::join("",($checkforindicator.Split("`n")))
			$checkforindicator = [string]::join("", ($checkforindicator.Split(" ")))
			if ($checkforindicator -match [regex]::Escape("#+#+#+#+#+#+#+#+#+#FILEISTOOBIGERROR---QUIT#+#+#+#+#+#+#+#+#+#")) {
				ConsoleLog "File bigger than your limit of $maxsize bytes. Skipping.`n"
				return
			}
			if ($checkforindicator -match [regex]::Escape("#+#+#+#+#+#+#+#+#+#")) {
				ConsoleLog "Got indicator, waiting for stream to finish..."
				break
			}
		}

		# get the load
		$global:compareload = Receive-Job -Keep $global:load

		# this time, since the plink / serial console does not "end" (so the background process does not complete), we need to compare the received load manually to determine our process state
		# this is the second wait job
		while($true) {
			# check every second
			sleep 1
			# get the current load
			$currentload = Receive-Job -Keep $global:load
			# check if current length is equal to last one
			if($global:compareload.length -eq $currentload.length) {
				# yes, break the loop (our process is done)
				break
			} else {
				# no, set the compare / last load to the current and rerun loop
				$global:compareload = $currentload
			}
		}

		if ($global:debug) {
			ConsoleLog $global:compareload
		}

		# delete the job
		killplinkjob

	} catch {
		ConsoleLog "Something went wrong with the background job."
		return
	}

	try {

		# remove newlines and spaces from the result since we look for base64
		$string = [string]::join("",($global:compareload.Split("`n")))
		$string = [string]::join("", ($string.Split(" ")))

		# match our delimiter strings on the result
		$splits = $string -split "#+#+#+#+#+#+#+#+#+#",5,"simplematch"

		# if we still have a # in our last split, that is a leftover from the console, so we use the split before
		if ($splits[-1].contains("#")) {
			$output = [string]::join("",($splits[-2].split(" ")))
		} else {
			$output = [string]::join("",($splits[-1].split(" ")))
		}

		# we now replace our delimiters so we get pure base64
		$output = $output -replace "#+#+#+#+#+#+#+#+#+#/#", ""
		# we also replace any leftover artifacts
		$output = $output -replace "/#", ""
		$output = $output -replace "#", ""
		ConsoleLog "Extracted base64 content from stream"

	} catch {
		ConsoleLog "Something went wrong during exracting the base64"
		return
	}

	if ($global:debug) {
		ConsoleLog $output
	}

	try {
		# lets decode the base64
		$decode = [Convert]::FromBase64String("$output")
		ConsoleLog "Decoded base64"

	} catch {
		ConsoleLog "Something went wrong when decoding the base64. Is your path correct? Is the device / console in a ready state? Please try to run again.`n"
		return
	}

	try {
		# if the folder for the transferred file does not exist, create it with all subfolders
		if (!(test-path $fullpath_folder_out)) {
			New-Item -ItemType Directory -Force -Path $fullpath_folder_out | Out-Null
		}

		# write the bytes to the destination file
		[IO.File]::WriteAllBytes($fullpath_file_out, $decode)
		ConsoleLog "Successfully saved bytes to $fullpath_file_out`n"
	} catch {
		ConsoleLog "Failed writing the file."
		return
	}

}


# helper to get all files in a folder on the target device
function GetFilesInFolder{

	param (
		[string]$folderpath
	)

	# again, a scriptblock for execution on the target device
	# this time: execute find -type f on the requested folder and save to file, then cat it as base64 like for other files above
	$scriptblock = [ScriptBlock]::create("
		'printf `"\033c`"; mkdir $global:mountpoint/getfiletmp; find $folderpath -type f > $global:mountpoint/getfiletmp/filesearch.txt; openssl enc -base64 -in $global:mountpoint/getfiletmp/filesearch.txt -out $global:mountpoint/getfiletmp/filesearch.txt.base64 `&>/dev/null; echo `"#+#+#+#+#+#+#+#+#+#`"; stat -c%s `"$global:mountpoint/getfiletmp/filesearch.txt.base64`" | { read filesize; if [[ `$filesize -gt $maxsize ]]; then echo `"FILEISTOOBIGERROR---QUIT`"; else cat $global:mountpoint/getfiletmp/filesearch.txt.base64; fi; }; echo `"#+#+#+#+#+#+#+#+#+#`"; rm -r $global:mountpoint/getfiletmp;' | plink -serial `"\\.\$port`" -sercfg 115200,8,1,N,N 
	")

	ConsoleLog "Getting all filenames in folder $folderpath on serial device recursively"

	try {

		killplinkjob

		# same as above
		ConsoleLog "Starting plink in background"
		$global:load = Start-ThreadJob -ScriptBlock $scriptblock

		ConsoleLog "Waiting for indicator..."

		# same as above
		while ($true) {
			sleep 2
			$checkforindicator = Receive-Job -Keep $global:load
			$checkforindicator = [string]::join("",($checkforindicator.Split("`n")))
			$checkforindicator = [string]::join("", ($checkforindicator.Split(" ")))
			if ($checkforindicator -match [regex]::Escape("#+#+#+#+#+#+#+#+#+#FILEISTOOBIGERROR---QUIT#+#+#+#+#+#+#+#+#+#")) {
				ConsoleLog "Results bigger than your limit of $maxsize bytes. Skipping transfer of found files.`n"
				exit
			}
			if ($checkforindicator -match [regex]::Escape("#+#+#+#+#+#+#+#+#+#")) {
				ConsoleLog "Got indicator, waiting for stream to finish..."
				break
			}
		}

		# same as above
		$global:compareload = Receive-Job -Keep $global:load

		# same as above
		while($true) {
			sleep 1
			$currentload = Receive-Job -Keep $global:load
			if($global:compareload.length -eq $currentload.length) {
				break
			} else {
				$global:compareload = $currentload
			}
		}

		if ($global:debug) {
			ConsoleLog $global:compareload
		}

		killplinkjob

	} catch {
		ConsoleLog "Something went wrong with the background job.`n"
		exit
	}

	try {
		# remove newlines and spaces from the result since we look for base64
		$string = [string]::join("",($global:compareload.Split("`n")))
		$string = [string]::join("", ($string.Split(" ")))

		# match our delimiter strings on the result
		$splits = $string -split "#+#+#+#+#+#+#+#+#+#",5,"simplematch"

		# if we still have a # in our last split, that is a leftover from the console, so we use the split before
		if ($splits[-1].contains("#")) {
			$output = [string]::join("",($splits[-2].split(" ")))
		} else {
			$output = [string]::join("",($splits[-1].split(" ")))
		}

		# we now replace our delimiters so we get pure base64
		$output = $output -replace "#+#+#+#+#+#+#+#+#+#/#", ""
		# we also replace any leftover artifacts
		$output = $output -replace "/#", ""
		$output = $output -replace "#", ""
		ConsoleLog "Extracted base64 content from stream"
	} catch {
		ConsoleLog "Something went wrong during exracting the base64.`n"
		exit
	}

	if ($global:debug) {
		ConsoleLog $output
	}

	try {
		# same as above
		$decode = [Convert]::FromBase64String("$output")
		ConsoleLog "Decoded base64`n"
	} catch {
		ConsoleLog "Something went wrong when decoding the base64. Is your path correct? Is the device / console in a ready state? Please try to run again.`n"
		exit
	}

	try {
		# same as above
		[IO.File]::WriteAllBytes($(Join-Path -Path $targetdir -ChildPath "filesearch.txt"), $decode)
	} catch {
		ConsoleLog "Failed writing the file.`n"
		exit
	}

	$prestage = Get-Content (Join-Path -Path $targetdir -ChildPath "filesearch.txt") | select-string -notmatch "/tmp/getfiletmp/filesearch.txt"
	if ($prestage.length -lt 1) {
		ConsoleLog "Found no files in the specified directory. Does it exist?`n"
		exit
	}

	# if user wants to edit results file with found files on device, now is the time. wait to continue until confirms
	if ($skip -eq "no") {
		$confirmation = $null
		while ($confirmation -ne "y") {
			$confirmation = Read-Host "Got $($prestage.length) files. Make changes to ./filesearch.txt now if wanted. Optional notmatch pattern is applied AFTER this step.`nEnter y to continue"
		}
	}

	# get the results file content and filter out our filesearch.txt
	$content = Get-Content (Join-Path -Path $targetdir -ChildPath "filesearch.txt") | select-string -notmatch "/tmp/getfiletmp/filesearch.txt"

	# if a notmatch value was given, match it against the result contents
	if (!($notmatch -eq $null) -and !($notmatch -eq "")) {
		$content = $content | select-string -notmatch -pattern "$notmatch"
	}

	# remove the temporary file and return
	rm (Join-Path -Path $targetdir -ChildPath "filesearch.txt")

	return $content

}


# -----------------------------------------------------


try {
	
	# kill leftover processes
	killplinkjob

	ConsoleLog

	ConsoleLog "--- NOTE ---`nBig files or folder transfers with lots of file inside the specified folder (like /) may take`nreally long to transfer or FAIL due to memory limitations.`nIf you interrupt or cancel the program you might need to restart the serial device before retrying.`nWait for 5 minutes after reboots to have a better chance of less interrupting console messages.`nUse .\getfile.ps1 -h or -help to get command help.`n`n"

	# check if we have write access
	CheckWritable | Out-Null

	# if in dir mode...
	if ($mode -eq "dir") {
			
		# get all files for given path on the seria ldevice
		$filelist = GetFilesInFolder -folderpath $path
		$length = $filelist.length
		$counter = 1

		# transfer each file and continue on errors
		foreach ($line in $filelist) {

			ConsoleLog "Now at file $counter of $length"
			$counter++

			try {
				GetFileViaPlinkSerial -filepath $line
			} catch {
				continue
			}
			
		}

	# filelist mode
	} elseif ($mode -eq "filelist") {

		# get content of given file at path
		$filelist = Get-Content $path
		$length = $filelist.length
		$counter = 1

		# get each file and continue on errors
		foreach ($line in $filelist) {

			ConsoleLog "Now at file $counter of $length"
			$counter++

			try {
				GetFileViaPlinkSerial -filepath $line
			} catch {
				continue
			}
			
		}

	# single file mode
	} elseif ($mode -eq "file") {

		# get the file
		GetFileViaPlinkSerial -filepath $path

	}

	killplinkjob
	
} finally {
	
	# kill plink processes on exit
	killplinkjob
	
}
