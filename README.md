# GetFile-Serial
A ridiculous powershell script to get files from a device using a serial port

There was a situation where I had an IoT device with a Linux OS on it. Using the serial port I could only manipulate the bootloader to boot the OS into single user mode in order to gain access to files. Also there was no write access other than in /tmp and nothing could be remounted. No SSH whatsoever running on the device. Also no tool for file transfer over serial worked for me (like minicom's file transfer). So I wrote this ridiculous, terrible script. Still fun to look at and it did the job.

Expect no fast transfers. Expect issues.

No documentation intended. But you'll definitely need to adjust some parts using the cmd arguments or in the script itself (like the mount cmd for the remote device).
