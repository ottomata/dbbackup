#!/bin/bash

# converts a byte filesize into a human readable format
function format_filesize {
  size=$1
  
  mega=$(( 1024 * 1024 ))
  giga=$(( 1024 * 1024 * 1024))
  
  # print size of file copied
  if [[ $size -le 1024 ]]; then
      printf "%d B" $size;
  elif [[ $size -le $mega ]]; then
      printf "%d kB" $(( $size / 1024  ));
  elif [[ $size -le $giga ]]; then
      printf "%d MB" $(( $size / $mega ));
  else
      printf "%d GB" $(( $size / $giga ));
  fi
}

dbbackup_dir=/backup/dbbackup
archive_dir=$dbbackup_dir/archive
current_dir=$dbbackup_dir/current

echo "Onsite dbbackup report for $(hostname) at $(date +%c)"
echo ""
echo "Disk Space for backups:"

df_out=$(/bin/df  ${dbbackup_dir} | sed '1,2d' | awk '{size=$1*1024; used=$2*1024; free=$3*1024; print size " " used " " free;}')
size=$(echo $df_out | cut -d ' ' -f 1);
used=$(echo $df_out | cut -d ' ' -f 2);
free=$(echo $df_out | cut -d ' ' -f 3);

echo "Size: $(format_filesize $size) ($size)"
echo "Used: $(format_filesize $used) ($used)"
echo "Free: $(format_filesize $free) ($free)"

echo ""
echo "Current live backup:"
current=$(readlink -f ${current_dir})
/usr/bin/du -h --max-depth=0 $current

echo ""
echo "Archived backups:"
/bin/ls -laht --time-style='+%a %Y-%m-%d %T' ${archive_dir} | sed '1d' | egrep -v '\.$' | awk '{printf "%-30s %5s    %s\n", $9, $5, $6 " " $7 " " $8}'





