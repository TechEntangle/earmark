-- Earmark launcher: start the service if needed, then open the web UI.
set earmarkDir to "__EARMARK_DIR__"
try
	do shell script "/bin/bash " & quoted form of (earmarkDir & "/run.sh")
on error errMsg
	display dialog "Earmark could not start." & return & return & errMsg buttons {"OK"} default button 1 with icon stop
	return
end try
open location "http://127.0.0.1:8765"
