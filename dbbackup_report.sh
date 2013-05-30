#!/bin/bash

# Compiles and formats *.txt files in the dbbackup/status directory.
# These files are generated from an onsite local backup status report
# as well as several offsite backup reports.

dbbackup_status_directory='/backup/dbbackup/status'
report_to_emails='nonya@domain.org'
subject="Weekly dbbackup report"

echo "Sending ${subject} to ${report_to_emails}"
for file in /backup/dbbackup/status/*.txt; do 
  echo "Report '$file':"; 
  cat $file; 
  echo -e "\n------------------------------------------------------------------"; 
done | mail -s "${subject}" "${report_to_emails}"


