#!/bin/bash

# 
# This script is used to backup multiple mysql instances all 
# running on the same machine, with data directories in the 
# same LVM partition.  A full backup will copy ALL data on the 
# mysql LVM partition.  An incremental backup will rsync only 
# mysql binary logs for each mysql instance into the most 
# recently created backup.
#
# This allows for point in time restores of any database.
# To restore:
# - Copy data directory of mysql instance to the restore machine.
# - Start mysql with this data directory.
# - Replay the binary logs in the binlog directory, starting 
#   at the position and binlog file listed in instance/master_status.txt
#   You may also filter the binary logs in order to leave out some
#   SQL statements.


# must run this script as root.
if [ "$(id -u)" != "0" ]; then
   echo "$0 must be run as root" 1>&2
   exit 1
fi


# Constants and Global Variables
pidfile="/var/run/dbbackup.pid"
timestamp=$(date "+%Y-%m-%d_%H.%M.%S")
backup_directory=/backup/dbbackup
current_backup_directory="$backup_directory/current"   # a symlink to the most recently created full backup
incomplete_directory="$backup_directory/incomplete"
archive_directory="$backup_directory/archive"  # store compressed old backups here
new_backup_directory="$incomplete_directory/new_$timestamp"
mysql_directory="/mysql"
lvm_snapshot_size="50GB"
lvm_volume_path="/dev/vgname/mysql"
lvm_snapshot_name="mysql_snapshot_$timestamp"
lvm_snapshot_volume_path="/dev/vgname/$lvm_snapshot_name"
lvm_snapshot_mount_directory="/mnt/$lvm_snapshot_name"
slaves_stopped=0      # true while any mysql instance slaves are stopped
tables_locked=0       # true while any mysql instance tables are locked
stale_backup_days=30  # delete backups older than this many days
report_to_email_addresses="nonya@domain.org"  # space separated list of emails to send reports to
minimum_archive_filesize=161061273600 # 150GB - No dbbackup archive should be smaller than this.  If a newly created archive is smaller than this, the archive will be considered a failure

# mysql is currently being managed by supervisor
# 'mysql:' is the name of the supervisor group
mysql_start_command="/usr/bin/supervisorctl start mysql:"  
mysql_stop_command="/usr/bin/supervisorctl stop mysql:"
mysql="/usr/local/mysql/bin/mysql" # path to mysql client binary


# List of mysql instance slaves on dbbackup.  
# These are the directory names inside of the /mysql directory.
mysql_instances=(dbcore dbgroup dbarchive dbmessage1 dbmessage2 dbmessage3 dbmessage4 dbspool ops)


function usage {
  echo "Usage:
  $0 full|incremental|archive|delete|restore|status
    full        - Creates a full backup of each mysql instance's data directory from an LVM snapshot.
    incremental - Copies new binlogs from each mysql instances.
    archive     - Looks in $backup_directory for uncompressed backups and compresses and archives them them.
    delete      - Looks in $backup directory for any compressed backups older than $stale_backup_days days and deletes them.
    restore     - This does only a very specific restore.  It will copy from each $current_backup_directroy/<instance>/data 
                  directory into $mysql_directory/<instance>/data.  This is useful for doing automated restores of 
                  the staging database.
    status      - Prints out backup status information.   
  "
}


# Creates an LVM snapshot of the /mysql directory and 
# creates backups of the mysql instance data files.
function backup_full {
  /bin/mkdir -pv $new_backup_directory 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not create directory '$new_backup_directory'"
  
  # - Stop all slaves, flush binary logs, purge all old logs
  log "Stopping all mysql slaves"
  mysql_multi_command 'STOP SLAVE;'
  slaves_stopped=1
  
  log "Obtaining read lock on all mysql instances..."
  mysql_multi_command 'FLUSH TABLES WITH READ LOCK;'
  tables_locked=1
  
  log "Flushing all mysql binary logs"
  mysql_multi_command 'FLUSH LOGS;'
  
  # foreach instance, purge all old logs
  # get the newest binlog and exclude it from being rsynced
  for instance in "${mysql_instances[@]}"; do
    newest_binlog=$("${mysql}" -S /mysql/$instance/mysql.sock -e "SHOW BINARY LOGS;" | tail -n 1 | awk '{print $1}')
    # purge all old binary logs for this instance
    log "Purging binary logs on instance $instance up to $newest_binlog"
    mysql_command $instance "PURGE BINARY LOGS TO '$newest_binlog'"
  done
  
  
  # - Save master status of each mysql instance into files.
  log "Saving mysql master and slave statuses into files."
  save_multi_mysql_statuses
  
  # - create LVM snapshot of /mysql directory
  log "Creating LVM snapshot of $lvm_volume_path named $lvm_snapshot_name"
  /usr/sbin/lvcreate -L${lvm_snapshot_size} -s -n $lvm_snapshot_name $lvm_volume_path 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not create LVM snapshot of $lvm_volume_path named $lvm_snapshot_volume_path"  
  
  
  log "Unlocking all mysql instances..."
  mysql_multi_command 'UNLOCK TABLES;'
  tables_locked=0
  
  # - Start all slaves
  log "Starting all mysql slaves"
  mysql_multi_command 'START SLAVE;'
  slaves_stopped=0
  
  
  
  # - Mount LVM snapshot
  log "Mounting LVM snapshot $lvm_snapshot_volume_path at $lvm_snapshot_mount_directory"
  /bin/mkdir -pv $lvm_snapshot_mount_directory 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not create directory $lvm_snapshot_mount_directory"
  /bin/mount -t ext3 -v $lvm_snapshot_volume_path $lvm_snapshot_mount_directory 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not mount $lvm_snapshot_volume_path at $lvm_snapshot_mount_directory"
    
  # Rsync each mysql instance's data folder into
  # $current_backup_directory/$instance/data
  # We don't need to save the binary logs here because this is a full data backup.
  # Incremental backups taken later will consist only of binary logs, allowing for 
  # incremental restores.
  for instance in "${mysql_instances[@]}"; do
    sudo -u mysql /bin/mkdir -pv "$new_backup_directory/$instance" || die "Could not mkdir $new_backup_directory/$instance"
    log "Copying files from $lvm_snapshot_mount_directory/$instance/data to $new_backup_directory/$instance/"
    /bin/nice --adjustment=10 /usr/bin/rsync -avWP --exclude="lost+found" --exclude="*.pid" --exclude="mysql.sock" "$lvm_snapshot_mount_directory/$instance/data" "$new_backup_directory/$instance/" 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not copy data from $lvm_snapshot_mount_directory/$instance/data to $new_backup_directory/$instance/"
    
    # Verify that the copy was successful
    log "Verifying backup via quick checksum..."
    checksum_original=$(checksum_quick $lvm_snapshot_mount_directory/$instance/data)
    checksum_backup=$(checksum_quick $new_backup_directory/$instance/data)
    
    if [ "${checksum_original}" != "${checksum_backup}" ]; then
      die "Error when backing up $instance data.  Original ($checksum_original) and backup ($checksum_backup) checksums do not match."
    fi
    
    log "$instance data directory checksums match."
  done
  
  # - Unmount LVM snapshot
  log "Unmounting $lvm_snapshot_mount_directory"
  /bin/umount -v $lvm_snapshot_mount_directory 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not umount $lvm_snapshot_mount_directory"
  /bin/rm -rfv $lvm_snapshot_mount_directory 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not remove $lvm_snapshot_mount_directory"  # no need to die here, if this fails there will just be an extra empty diretory around
  
  # - Delete LVM snapshot
  log "Deleting LVM snapshot $lvm_snapshot_volume_path"
  /usr/sbin/lvremove -f $lvm_snapshot_volume_path 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not delete LVM snapshot $lvm_snapshot_volume_path"
  
  # Remove the 'new_' from the beginning of the new backup directory name and
  # point the current backup symlink at the new backup directory
  (/bin/mv -v $new_backup_directory $backup_directory/$timestamp && /bin/ln -sfnv $backup_directory/$timestamp $current_backup_directory) || die "Could not point the current symlink at the $backup_directory/$timestamp"
}




# Rsyncs each mysql instance's binlogs to 
# the backup directory
function backup_incremental {
  # Make sure $current_backup_directory exists 
  if [ ! -d "$current_backup_directory" ]; then
    die "Cannot do incremental backup.  Current backup directory does not exist.  You probably need to run your first full backup."
  fi
    
  # Rsync each mysql instance's binlog folder into
  # current_backup_directory/instance_name/binlog
  for instance in "${mysql_instances[@]}"; do 
    incremental_binlog_backup_directory="$current_backup_directory/$instance/binlog"
    /bin/mkdir -pv $incremental_binlog_backup_directory || die "Could not create directory $incremental_binlog_backup_directory"
  
  
    # stop this slave
    # We need to do this to get accurate information about this slave's status
    # and position for the binlog we are about to save.  This information
    # can be used to restore a backup to this binlog, and then start
    # it as a slave of this instance's master.
    log "Stopping $instance slave."
    mysql_command $instance 'stop slave;';
    slaves_stopped=1
    
    # Get the location that this instance has currently executed binlogs to.
    # This is the most recent position that our instance has executed, as 
    # well as the latest binlog file that we are about to back up.
    # This information will be included alongside the current slave
    # status, so that when restoring this instance to this position,
    # the slave status can be used to recreate a slave and point it at
    # this dbbackup instance's current master.
    current_position=$("${mysql}" -S /mysql/$instance/mysql.sock -e 'show master status;' | sed -n '2p' | awk -F "\t" '{print $1 ":" $2}') || die "Could not get current instance binlog position."
    
    # Flush the binary logs so that mysql will force start a new one
    log "Flushing $instance binary logs"
    mysql_command $instance 'flush logs;'
    
    # start this slave back up
    log "Start $instance slave."
    mysql_command $instance 'start slave;';
    slaves_stopped=0
    
    
    
    # Apped a 'CHANGE MASTER TO' statement to the $incremental_slave_status_file.  
    # This file will include statements that can be used to create a slave from
    # This incremental backup by running the backed up binary logs to this point
    # and running the relative CHANGE MASTER TO statement.
    incremental_slave_status_file="$current_backup_directory/$instance/incremental_slave_status.txt"
    log "Appending current $instance slave status as a change master SQL command into $incremental_slave_status_file."
    change_master_command=$("${mysql}" -S /mysql/$instance/mysql.sock -e "show slave status;" | sed -n '2p' | awk -F "\t" '{print "CHANGE MASTER TO master_host=\"" $2 "\", master_user=\"" $3 "\", master_password=\"XXXXXXXXX\", master_log_file=\"" $10 "\", master_log_pos=\"" $22 "\";" }') || die "Could not get incremental slave status from instance $instance"
    date=$(date '+%Y-%m-%d %H:%M:%S')
    change_master_command="/* dbbackup $instance instance at ${current_position} (${date}) */   ${change_master_command}"
    echo "$change_master_command" >> "$incremental_slave_status_file" || die "Could not append $instance slave status as a change master SQL command to $incremental_slave_status_file"



    # get the newest binlog (the one created when the logs were flushed above) and exclude it from being rsynced
    newest_binlog=$("${mysql}" -S /mysql/$instance/mysql.sock -e "SHOW BINARY LOGS;" | tail -n 1 | awk '{print $1}')
    
    # rsync binlogs to binlog backup directory
    # We ONLY want the binlog files.  We don't want any
    # relay logs or info or index files.  We also don't want the
    # binary log that was recently created by flushing the logs.
    log "Copying $instance binlogs to $incremental_binlog_backup_directory"
    /bin/nice --adjustment=10 /usr/bin/rsync -avWP --exclude="relay-*" --exclude="bin.index" --exclude="$newest_binlog" "$mysql_directory/$instance/binlog/" "$incremental_binlog_backup_directory/" 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not copy binlogs from $mysql_directory/$instance/binlog/ to $incremental_binlog_backup_direrctory/"
    
    # purge all old binary logs for this instance
    log "Purging binary logs on instance $instance up to $newest_binlog"
    mysql_command $instance "PURGE BINARY LOGS TO '$newest_binlog'"
  done
}


function archive_old_backups {
  /usr/bin/test -d $incomplete_directory || /bin/mkdir -p $incomplete_directory || die "Could not create directory $incomplete_directory"
  /usr/bin/test -d $archive_directory || /bin/mkdir -p $archive_directory || die "Could not create directory $archive_directory"
  
  result=0
  # get list of old uncompressed backups
  old_backup_directories=$(/bin/ls -d $backup_directory/20* | grep -v 'tar' | grep -v $(/usr/bin/readlink $current_backup_directory)) || die "Could not find any old backups in $backup_directory that need compressing."
  for old_backup_directory in $old_backup_directories; do 
    log "Archiving $old_backup_directory..."
    archive_backup $old_backup_directory
    if [ $? -ne 0 ]; then
      log "Failed archive of $old_backup_directory"
      result=$?
    fi
  done
  
  return $result
}


# We want to keep individual .tar.gz files of each data and binlog
# directory.  This will allow us faster decompression times when we
# need to restore data from a certain mysql instance backup.
# This function:
# - loops through each mysql instance in the backup
# - creates a temporary archive directory inside of the $incomplete_directory
# - creates .tar.gz files of the data and binlog directories inside the $incomplete_archive_directory
# - after the compression is completed the data and binlog directories are removed from the original location (to save space)
# - Copies master and slave status files to the instance directory in the $incomplete_archive_directory
# - Once done looping though instances, a .tar file is made of the $incomplete_archive_directory.
# - This .tar file is moved into the $archive_directory
# - The original $old_backup_directory and the $incomplete_archive_directories are then removed permanently
function archive_backup {
  retval=0
  
  # the original directory to compress and archive
  old_backup_directory=$1   
  old_backup_filename=$(/bin/basename $old_backup_directory)
  
  # This is the directory in which archives will be kept while they are being compressed
  incomplete_archive_directory="$incomplete_directory/$old_backup_filename"
  # Once the individual data/ and binlog/ directories are tar-ed and compressed,
  # they will all be tar-ed into this single file
  incomplete_archive_file="${incomplete_directory}/$(/bin/basename $old_backup_directory).tar"
  # Once the $incomplete_archive_file has been created, it will be moved to
  # final_archive_file.
  final_archive_file=$archive_directory/$(/bin/basename $incomplete_archive_file)

  # if $final_archive_file already exists, do not attempt to archive this.
  if [ -e $final_archive_file ]; then
    log "Not attempting to archive $old_backup_directory.  An archive of this backup already exists at $final_archive_file."
    return 0
  fi
  
  # Create a temporary incomplete directory to create the archive in
  /bin/mkdir -pv $incomplete_archive_directory || die "Could not create directory $incomplete_archive_directory"
  
  
  # Loop through each mysql instance and compress each binlog and data directory
  for instance in "${mysql_instances[@]}"; do
    if [ ! -d "${old_backup_directory}/${instance}" ]; then
      echo "$instance directory does not exist in $old_backup_directory, not attempting to archive."
      continue;
    fi
    
    /bin/mkdir -pv $incomplete_archive_directory/$instance || die "Could not create directory $incomplete_archive_directory/$instance"
    
    # Compress both data and binlog directories
    subdirectories_to_compress=(data binlog)
    for subdirectory_name in "${subdirectories_to_compress[@]}"; do
      directory_to_compress="$old_backup_directory/$instance/$subdirectory_name"
      compressed_filename="$incomplete_archive_directory/$instance/$subdirectory_name.tar.gz"
      cmd="/bin/tar -C $old_backup_directory/$instance -czf $compressed_filename $subdirectory_name"
      log "Compressing $directory_to_compress at $compressed_filename"
      log "$cmd"
      $cmd 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not create archive of $directory_to_compress" 
      # Need to save space.  Once the archive of this directory is complete, remove the original
      # This line is commented since jumbo is BIIIG.  Uncomment it if you need to save space while compressing backups.
      # /bin/rm -rfv $directory_to_compress 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not remove $directory_to_compress after compressing it"
    done
   
    # copy master and slave status text files
    log "Including $instance master and slave status files in archive"
    /bin/cp -v $old_backup_directory/$instance/{master,slave}_status.txt $incomplete_archive_directory/$instance/  2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not copy master and slave status files to archive."
  done
  
  # Now that we've compressed all of the individual instance data and binlog directories, 
  # create a a .tar file of the whole backup
  cmd="/bin/tar -C $incomplete_directory -cvf $incomplete_archive_file $old_backup_filename"
  log "$cmd"
  $cmd 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not create archive of $old_backup_directory at $incomplete_archive_file"
  
  # Let's double check to make sure the archive we just created is big enough.
  # if it's not, die (and don't delete the original $old_backup_directory)
  incomplete_archive_filesize=$(/usr/bin/stat -c%s ${incomplete_archive_file})
  if [ "${incomplete_archive_filesize}" -lt "${minimum_archive_filesize}" ]; then
    log "Archiving $old_backup_filename at $incomplete_archive_file failed.  Filesize ($incomplete_archive_filesize bytes) is less than minimum archive filesize ($minimum_archive_filesize bytes)."
    retval=1
  fi
  
  # Archiving is complete! 
  # move the incomplete archive file to the archive directory
  /bin/mv -v $incomplete_archive_file $final_archive_file 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not move $archive_filename into $archive_directory"
  
  # Delete the and the incomplete archive directory old backup directory
  /bin/rm -rfv $incomplete_archive_directory 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not remove $incomplete_archive_directory after creating archive $final_archive_file."
  /bin/rm -rfv $old_backup_directory 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not remove $old_backup_directory after creating archive $final_archive_file."
  
  log "Finished creating backup archive $final_archive_file."
  return $retval
}


# Deletes any compressed backups older than $stale_backup_days
function delete_stale_backups {
  log "Deleting compressed backups older than $stale_backup_days days."
  cd $archive_directory
  # Bah, date parsing and calculation sucks in bash.  Gotta use something else...ruby it is!
  # This command gets the list of files in $archive_directory that match 20*.tar.gz,
  # converts the date-time part of the filename to a ruby DateTime Object, and then
  # prints out each file that was created more than $stale_backup_days ago.
  stale_backups=$(/usr/bin/ruby -e "require 'date'; Dir::chdir('$archive_directory'); puts Dir::glob(\"20*.tar\").select { |f| DateTime::parse(f.delete('.tar.gz')) < (DateTime::now - $stale_backup_days) }.join(' ')") || die "Failed trying to find backups to delete."
  log "Deleting $stale_backups..."
  /bin/rm -fv $stale_backups 2>&1 | log
}


# Restores mysql instance data directories from the current backup
# to $mysql_directory/<instance>/data.  This is useful for restoring
# the staging database.  
function restore_full {
  log "Beginning full restore from $current_backup_directory..."
  # Stop all mysql instances
  log "Stopping all mysql instances..."
  ${mysql_stop_command} 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not stop all mysql instances."
  # give mysql some time to stop
  sleep 5
  
  # For each mysql instance, delete the data directory 
  # (so that we can be sure there is enough disk space to 
  # copy the new data directory), then copy the data directory
  # to its restored location.
  for instance in "${mysql_instances[@]}"; do
    restore_instance $instance || die "Could not restore instance $instance."
  done
  
  log "Starting all mysql instances..."
  ${mysql_start_command} start 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not start all mysql instances."
  log "Done restoring $current_backup_directory/<instance>/data directories to $mysql_directory instance data directories." 
}

# Copies from $current_backup_directory/instance/data to $mysql_direcotry/instance/data
# $1    instance
function restore_instance {
  instance=$1
  
  log "Restoring $instance mysql instance from $current_backup_directory/$instance/data to $mysql_directory/$instance/data..."
  
  log "Deleting mysql instance $instance's data and binlog files."
  # delete the old data directory
  test -d $mysql_directory/$instance/data && /bin/rm -rfv $mysql_directory/$instance/data || die "Could not remove old data direcotry $mysql_directory/$instance/data"
  # remove all old binlogs
  test -d $mysql_directory/$instance/binlog && /bin/rm -fv $mysql_directory/$instance/binlog/* || die "Could not remove binlogs from $mysql_directory/$instance/binlog/*"
  
  # copy the new data directory (excluding master.info, we don't want the restored instance to try to start up a slave)
  /usr/bin/rsync -avWP --exclude='master.info' $current_backup_directory/$instance/data $mysql_directory/$instance/ 2>&1 | log; [ ${PIPESTATUS[0]} -eq 0 ] || die "Could not copy data from $current_backup_directory/$instance/data to $mysql_directory/$instance/data"
  return $?
}


# Prints out a status message about the latest archived backup
function status_archive {
  # check up on the latest archived backup
  latest_archive_file="$archive_directory/$(ls -t $archive_directory | sed -n '1p')"
  if [ -z "$latest_archive_file" ]; then
    echo "Zero archived backups."
  else
    latest_archive_filesize=$(/usr/bin/stat -c%s $latest_archive_file)
    latest_archive_file_mtime=$(/usr/bin/stat -c%Y $latest_archive_file)
    latest_archive_file_date=$(timestamp_to_date $latest_archive_file_mtime)
    echo "Latest archived backup: $latest_archive_file"
    echo "  Size: $latest_archive_filesize ($(format_filesize $latest_archive_filesize))"
    echo "  mtime: $latest_archive_file_mtime ($latest_archive_file_date)"
  fi
}

# prints out a status message about the current backup
function status_current {
  # check up on the current backup
   if [ ! -d "$current_backup_directory" ]; then
     echo "Current backup directory does not exist.  You probably need to run your first full backup."
     exit 1;
   fi

   latest_backup_directory=$(/usr/bin/readlink $current_backup_directory)
   latest_backup_size=$(/usr/bin/du -b --max-depth=0 $latest_backup_directory | cut -f 1)

   echo ""
   echo "Current backup status:"
   echo "  $latest_backup_directory"
   echo "  Size: $latest_backup_size ($(format_filesize $latest_backup_size))"
   echo ""
}

# prints out a status message about a particular instance inside the current backup
function status_instance {
  instance=$1
  
  if [ ! -d "$current_backup_directory/$instance" ]; then
     echo "Backup instance '$instance' does not exist.  You probably need to run your first full backup."
     exit 1
   fi
  
  latest_backup_directory=$(/usr/bin/readlink $current_backup_directory)
  backup_instance_size=$(/usr/bin/du -b --max-depth=0 $latest_backup_directory/$instance | cut -f 1)

  echo "  $instance Size: $backup_instance_size ($(format_filesize $backup_instance_size))"      
  latest_incremental_backup_binlog=$(ls -t $latest_backup_directory/$instance/binlog/bin.* | sed -n '1p')
  latest_incremental_backup_binlog_filesize=$(/usr/bin/stat -c%s $latest_incremental_backup_binlog)
  latest_incremental_backup_binlog_mtime=$(/usr/bin/stat -c%Y $latest_incremental_backup_binlog)
  latest_incremental_backup_binlog_date=$(timestamp_to_date $latest_incremental_backup_binlog_mtime)

  echo "    Latest incremental binlog: $latest_incremental_backup_binlog"
  echo "    Size:  $latest_incremental_backup_binlog_filesize ($(format_filesize $latest_incremental_backup_binlog_filesize))"
  echo "    mtime: $latest_incremental_backup_binlog_mtime ($latest_incremental_backup_binlog_date)"
  echo ""
}

# prints out backup status information.
# Usage:
#   status archive|current|instances|all|<instance_name>
function status {  
  case "$1" in 
    'archive' )
      status_archive
      ;;
    'current' )
      status_current
      ;;
    'instances' )
      for instance in "${mysql_instances[@]}"; do 
        status_instance $instance
      done
      ;;
    * )
      if [ "$1" == 'all' ] || [ -z "$1" ]; then
        status_archive
        status_current
        # loop through each mysql instance and print out a status for each
        for instance in "${mysql_instances[@]}"; do 
          status_instance $instance
        done
      else
        status_instance $1
      fi
      ;;
  esac
}


# Compresses a directory with tar and bzip2.
function compress_directory {
  directory=$1
  
  if [ ! -d $directory ]; then
    die "Cannot compress '$directory', it is not a directory"
  fi
  
  # while compressing, create file in an incomplete directory
  /usr/bin/test -d $incomplete_directory || /bin/mkdir -p $incomplete_directory || die "Could not create directory $incomplete_directory"
  incomplete_compressed_file="$incomplete_directory/$(/bin/basename $directory).tar.gz"
  
  cmd="/bin/tar -czf $incomplete_compressed_file $directory"
  log $cmd
  # compress the directory, move it out of the incomplete directory and the remove the original directory.
  ($cmd && /bin/mv -v $incomplete_compressed_file $backup_directory/ && /bin/rm -rfv $directory) 2>&1 | log 
  return $?
}



# Finds every file in the directory, 
# truncates the output of ls -l to 
# print out size and timestamp of each file,
# and then generates an md5sum from this output.
function checksum_quick {
  directory=$1
  /usr/bin/find $directory -type f | xargs /bin/ls -l --time-style="+%Y%m%d%H%M%S" | grep -v '.pid' | grep -v 'mysql.sock' | grep -v 'lost+found' | /bin/awk '{print $5 " " $6}' | /usr/bin/md5sum - | /bin/awk '{print $1}'
}


# logs an error message, 
# removes any mounts or LVM snapshots that this script created, 
# and then exit 1
function die {
  log "${1}"
  
  # if an LVM snapshot is mounted and we are dying, then unmount it
  /bin/mount | /bin/grep -q $lvm_snapshot_mount_directory && (/bin/umount -v $lvm_snapshot_mount_directory 2>&1 | log)
  # if an LVM snapshot exists, delete it.
  /usr/sbin/lvscan | /bin/grep -q $lvm_snapshot_volume_path && (/usr/sbin/lvremove -f $lvm_snapshot_volume_path 2>&1 | log)
  
  # if die was called while tables_locked == 1, then run unlock tables on all instances
  if [ $tables_locked -eq 1 ]; then
    log "Unlocking tables on all mysql instances"
    mysql_multi_command 'UNLOCK TABLES;';
  fi
  
  # if die was called while slaves_stopped == 1, then run start slave on all instances
  if [ $slaves_stopped -eq 1 ]; then
    log "Starting slaves on all mysql instance..."
    mysql_multi_command 'START SLAVE;'
  fi

  # if the mount directory exists, remove it
  /usr/bin/test -d $lvm_snapshot_mount_directory && (rm -rfv $lvm_snapshot_mount_directory 2>&1 | log)
  
  # remove pid file
  /bin/rm $pidfile
  
  # send an email notifying that this script has died
  report "$0 $action failed" "$(date '+%Y-%m-%d %H:%M:%S')  ${1}"
  exit 1
}


# Executes the same SQL statement on all mysql_instances.
function mysql_multi_command {
  command=$1
  
  for instance in "${mysql_instances[@]}"; do 
    mysql_command "${instance}" "${command}"
  done
}


# Executes a command on a mysql instance
function mysql_command {
  instance=$1
  command=$2
  
  log "Running '$command' on $instance"
  "${mysql}" -S /mysql/$instance/mysql.sock -e "$command" 2>&1 | log
  if [ $? -ne 0 ]; then
    die "Running '$command' on mysql instance $instance failed." 
  fi
}

# saves master status for each mysql instance into files
function save_multi_mysql_statuses {  
  master_status_command='show master status\G'
  slave_status_command='show slave status\G'
  
  for instance in "${mysql_instances[@]}"; do 
    /bin/mkdir -pv "$new_backup_directory/${instance}" || die "Could not create directory '$new_backup_directory/${instance}'"
  
    master_status_file="$new_backup_directory/${instance}/master_status.txt"
    slave_status_file="$new_backup_directory/${instance}/slave_status.txt"
        
    # Save master status
    log "Running '$master_status_command' on $instance"
    "${mysql}" -S /mysql/$instance/mysql.sock -e "$master_status_command" > $master_status_file  || die "Could not save master status for mysql instance $instance into $master_status_file"
    
    # Save slave status
    log "Running '$slave_status_command' on $instance"
    "${mysql}" -S /mysql/$instance/mysql.sock -e "$slave_status_command" > $slave_status_file || die "Could not save slave status for mysql instance $instance into $slave_status_file"
  done
}

# Echoes $1 or stdin to stdout and sends the message to scribe logger
# in the category 'dbbackup'.
function log {
  message=$1
  scribe_category='dbbackup'
  
  # if message was not passed in, read message from stdin
  if [ -z "${message}" ]; then
    while read data; do
      header="[$HOSTNAME] [$$] [$(date '+%Y-%m-%d %H:%M:%S')] [$scribe_category] [$0]"
      echo "$header $data"
      echo "$header $data" | /usr/bin/scribe_cat $scribe_category
    done
  # else just echo the message
  else
    header="[$HOSTNAME] [$$] [$(date '+%Y-%m-%d %H:%M:%S')] [$scribe_category] [$0]"
    echo "$header $message"
    echo "$header $message" | /usr/bin/scribe_cat $scribe_category
  fi
}


function report {
  subject="${1}"
  body="${2}"
  email "${report_to_email_addresses}" "${subject}" "${body}"
}

# sends an email! 
function email {
  to="${1}"
  subject="${2}"
  body="${3}"
  /bin/echo "${body}" | /bin/mail -s "${subject}" "${to}" 
}

# converts a unix timestamp into a human readable date
function timestamp_to_date {
  timestamp=$1
  echo $timestamp | /bin/awk '{print strftime("%Y-%m-%d %H:%M:%S",$1)}'
}


# converts a byte filesize into a human readable format
function format_filesize {
  size=${1}
  
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

# Catch Control-C so we can clean up properly
trap 'die "Caught SIGINT, exiting..."' SIGINT


# Parse command line for action.
action="${1}"


# make sure this script isn't already running.  
if [ -f $pidfile ]; then
  pid=$(cat $pidfile)
  log "dbbackup script is already running with PID $pid. Aborting."
  exit 1
fi

# store the current PID in the pidfile (if not getting status)
if [ "$1" != 'status' ]; then
  echo $$ > $pidfile
fi


exitval=0

case "$action" in 
  'full' )
    time backup_full
    ;;
  'incremental' )
    time backup_incremental
    ;;
  'delete' )
    time delete_stale_backups
    ;;
  'restore' )
    time restore_full
    sleep 5
    grant_alpha_permissions
    ;;
  'archive' )
    time archive_old_backups
    exitval=$?
    ;;
  'status' )
    status $2
    exit 0;
    ;;
  'grant_alpha_permissions' )
    time grant_alpha_permissions
    exitval=$?
    ;;
  * )
    echo "'$1' is not a valid command."
    usage
    /bin/rm $pidfile
    exit 1;
    ;;
esac

log "Done."
echo ""
echo ""

# remove the pidfile
/bin/rm $pidfile

exit $exitval
