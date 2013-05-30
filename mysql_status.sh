#!/bin/bash
# Script used mainly by zabbix to
# get status of MySQL servers.


usage="Usage: $0 action [name]
Where action is one of:
  ping
  uptime
  threads
  questions
  slowqueries
  qps
  version
  slaverunning (result will be 2 if both SQL and IO threads are running)
  slaveseconds
"

action=$1
name=$2

mysqladmin="/usr/bin/mysqladmin -uroot "
mysql="/usr/bin/mysql -uroot "

[ ! -e "/var/run/mysql/mysql.sock" ] && name="dbcore"

if [ -n "$name" ]; then
  socket="/mysql/$name/mysql.sock"
 
  if [ ! -e $socket ]; then
    echo "MySQL socket file $socket does not exist."
    exit -1
  fi
  
  mysqladmin="$mysqladmin -S$socket"
  mysql="$mysql -S$socket"
fi

case "$action" in
  ping)
    $mysqladmin ping | grep alive | wc -l
    ;;
  uptime)
    $mysqladmin status | awk '{print $2}'
    ;;
  threads)
    $mysqladmin status | awk '{print $4}'
    ;;
  questions)
    $mysqladmin status | awk '{print $6}'
    ;;
  slowqueries)
    $mysqladmin status | awk '{print $9}'
    ;;
  qps)
    $mysqladmin status | awk '{print $22}'
    ;;
  version)
    $mysql -V
    ;;
  slaverunning)
    $mysql -e "SHOW SLAVE STATUS\G" | grep "_Running: Yes"  | wc -l
    ;;
  slaveseconds)
    $mysql -e "SHOW SLAVE STATUS\G" | grep Seconds_Behind_Master | awk '{ print $2 }' 
    ;;
  *)
    echo $usage
    exit 1
esac
