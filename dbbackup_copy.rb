#!/usr/bin/ruby

# This ruby script looks in /var/backup/dbbackup/archive for backups
# and rsyncs 1 per month to the old backup (LS) machine.
# The backup machine is responsible for making sure there is enough
# space available for backups.  

require 'optparse'
require 'pp'
require 'date'



# Given a backup source directory, 
# this will return an array of backup 
# filenames reverse sorted by file mtime.
#
# interval can be one of 'all', 'monthly' or 'weekly'
def get_dbbackup_archive_file_paths(backup_source, interval = 'all')
  # Get an array of dbbackup archive files in the archive_directory,
  # sorted by file mtime.
  all_archive_files = Dir.glob(backup_source + "/20*.tar").sort do |file1, file2|
    File.mtime(file1) <=> File.mtime(file2)
  end

  # if the interval is 'all', then just return
  # all dbbackup archive files in this directory
  if (interval == 'all')
    return all_archive_files
  end
  
  
  # monthly_archive_files will be a hash
  # of month => archive_filepath.
  # Example:
  #   { 10 => '/path/to/october_archive.tar', 11 => '/path/to/november_archive.tar' }
  archive_files = Hash.new

  # loop through each of the dbbackup archive files
  # to build monthly_archive_files
  all_archive_files.each do |archive_file|
    filename = File.basename(archive_file)
    file_datetime = DateTime.parse(filename)
    
    # if monthly, make a key that looks like YYYY-MM
    if (interval == 'monthly')
      interval_key = "#{file_datetime.year}-#{file_datetime.month}"
    # if weekly, make a key that looks like YYYY-WW, where WW is the year week number (1-52)
    elsif (interval == 'weekly')
      interval_key = "#{file_datetime.year}-#{file_datetime.cweek}"
    end

    # Store the archive_file path in the archive_files hash
    # if we have not yet stored one for this interval
    if (!archive_files.has_key?(interval_key))
      archive_files[interval_key] = archive_file
    end
  end

  # return the values, reverse sorted by hash key 
  return archive_files.sort.reverse.collect { |a| a[1] }
end


# ================
# = ARGV parsing =
# ================

# default values, these variables
# will be replaced with any values 
# specified on the CLI.

# default values
backup_interval     = 'all'
backup_source       = "/backup/dbbackup/archive"
backup_destination  = "backup@backup:/backup/dbbackup"
dry_run             = false

parser = OptionParser.new
parser.on('-h', '--help', 'Display usage information') do
  puts parser
  exit 0
end

parser.on('-i=INTERVAL', '--interval=INTERVAL', "Interval of backups to copy, either 'all', 'weekly', or 'monthly'.  Default is '#{backup_interval}'.") do |value|
  backup_interval = value
end

parser.on('-s=SOURCE', '--source=SOURCE', "Source argument to rsync.  Default is '#{backup_source}'.") do |value|
  backup_source = value
end

parser.on('-d=DEST', '--destination=DEST', "Destination argument to rsync.  Default is '#{backup_destination}'.") do |value|
  backup_destination = value
end

parser.on('-n', '--dry-run', 'If true, rsync will be run with --dry-run flag.') do
  dry_run = true
end

begin 
  parser.parse($*)
rescue OptionParser::ParseError
  puts $!
  exit 1
end

# argument checking
if (!['all', 'weekly', 'monthly'].include?(backup_interval))
  raise ArgumentError.new("Invalid interval option '#{backup_interval}'. must be either 'all', 'weekly', or 'monthly'.") 
end


# get the dbbackup archive files we want to backup
dbbackup_archive_files = get_dbbackup_archive_file_paths(backup_source, backup_interval)

# Now loop through each of the monthly archive files and
# rsync them to the backup destination
puts "Rsyncing #{backup_interval} dbbackup archives to #{backup_destination}..."

failed = false;
dbbackup_archive_files.each do |archive_file|
  rsync_command = "rsync -av"
  if (dry_run)
    rsync_command += 'n'
  end
  rsync_command += " #{archive_file} #{backup_destination}/#{File.basename(archive_file)}"
  puts rsync_command 
  
  result = system(rsync_command)
  if (!result)
    puts "Error: Rsync of #{File.basename(archive_file)} to #{backup_destination} failed."
    failed = true
  end
end

# exit appropriately based on rsync execution status.
if (failed)
  exit(1)
else
  exit(0)
end



