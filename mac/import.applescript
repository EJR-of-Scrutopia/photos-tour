-- Import fallback (c) of mac-tour.sh: osascript import.applescript <file> <file> ...
-- Needs Automation permission for Photos; mac-tour.sh runs it under a timeout so a permission prompt cannot hang the job.
on run argv
	set fs to {}
	repeat with p in argv
		set end of fs to ((POSIX file (contents of p)) as alias)
	end repeat
	tell application "Photos"
		import fs skip check duplicates true
	end tell
	return (count of fs) as text
end run
