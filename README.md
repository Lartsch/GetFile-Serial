# GetFile-Serial
A ridiculous powershell script to get files from a device using a serial port

There was a situation where I had an IoT device with a Linux OS on it. Using the serial port I could only manipulate the bootloader to boot the OS into single user mode in order to gain access to files. Also there was no write access other than in /tmp and nothing could be remounted. No SSH whatsoever running on the device. Also no tool for file transfer over serial worked for me (like minicom's file transfer). So I wrote this ridiculous script that does the job but is terrible over complicated and impractical. Still fun to look at.

No documentation intended.
