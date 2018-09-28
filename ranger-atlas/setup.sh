#!/usr/bin/env bash
#set -o xtrace

########################################################################
########################################################################
## variables



export HOME=${HOME:-/root}
export TERM=xterm

#overridable vars
export stack=${stack:-hdp}    #cluster name
export ambari_password=${ambari_password:-BadPass#1}  #ambari password
#export ambari_pass=${ambari_pass:-BadPass#1}  #ambari password
export ambari_services=${ambari_services:-HBASE HDFS MAPREDUCE2 PIG YARN HIVE ZOOKEEPER SLIDER AMBARI_INFRA_SOLR TEZ RANGER ATLAS KAFKA ZEPPELIN KNOX SPARK2 NIFI}   #HDP services
export ambari_stack_version=${ambari_stack_version:-3.0}  #HDP Version
export host_count=${host_count:-skip}      #number of nodes, defaults to 1
export enable_hive_acid=${enable_hive_acid:-true}   #enable Hive ACID? 
export enable_kerberos=${enable_kerberos:-true}      
export enable_knox_sso_proxy=${enable_knox_sso_proxy:-true}
export kdc_realm=${kdc_realm:-HWX.COM}      #KDC realm
export ambari_version="${ambari_version:-2.7.1.0}"   #Need Ambari 2.6.0+ to avoid Zeppelin BUG-92211

export hdf_mpack="http://public-repo-1.hortonworks.com/HDF/centos7/3.x/updates/3.2.0.0/tars/hdf_ambari_mp/hdf-ambari-mpack-3.2.0.0-520.tar.gz"
export nifi_password=${nifi_password:-StrongPassword}
export nifi_flow="https://gist.githubusercontent.com/abajwa-hw/6a2506911a1667a1b1feeb8e4341eeed/raw"
export zeppelin_pass=${zeppelin_pass:-BadPass#1} 
export knox_ldap_pass=${knox_ldap_pass:-BadPass#1} 

#internal vars
#export ambari_password="${ambari_pass}"
export ambari_pass="${ambari_password}"
export cluster_name=${stack}
export recommendation_strategy="ALWAYS_APPLY_DONT_OVERRIDE_CUSTOM_VALUES"
export install_ambari_server=true
export deploy=true

export host=$(hostname -f)
export ambari_host=$(hostname -f)
export knox_host=demo.hortonworks.com
export install_ambari_server ambari_pass host_count ambari_services
export ambari_password cluster_name recommendation_strategy

########################################################################
########################################################################
## 
cd

yum makecache fast
yum -y -q install git epel-release ntp screen mysql-connector-java postgresql-jdbc python-argparse python-configobj ack nc wget jq
yum install -y jq
curl -sSL https://raw.githubusercontent.com/seanorama/ambari-bootstrap/master/extras/deploy/install-ambari-bootstrap.sh | bash

########################################################################
########################################################################
## tutorial users

#download hortonia scripts
cd /tmp
git clone -b patch-1 https://github.com/jnowakowski/masterclass.git 

cd /tmp/masterclass/ranger-atlas/HortoniaMunichSetup
chmod +x *.sh
./04-create-os-users.sh    

#also need anonymous user for kafka Ranger policy
useradd nifi      #for nifi
useradd ANONYMOUS  #for kafka 
useradd HTTP     #for YARN in 3.0



########################################################################
########################################################################
## 

#install MySql community rpm
sudo yum localinstall -y http://dev.mysql.com/get/mysql-community-release-el7-5.noarch.rpm


#sudo wget ${ambari_repo} -P /etc/yum.repos.d/ 
#sed -i 's/gpgcheck=1/gpgcheck=0/g' /etc/yum.repos.d/ambaribn.repo
#yum --enablerepo=ambari-${ambari_build} clean metadata

curl -sSL https://raw.githubusercontent.com/abajwa-hw/ambari-bootstrap/master/ambari-bootstrap.sh | sudo -E sh

sleep 30

#sudo wget ${hdp_repo} -P /etc/yum.repos.d/ 
#sed -i 's/gpgcheck=1/gpgcheck=0/g' /etc/yum.repos.d/hdpbn.repo 
#yum --enablerepo=HDP-${hdp_build} clean metadata

yum --nogpg  -y install snappy-devel

echo "Adding HDF mpack..."
sudo ambari-server install-mpack --verbose --mpack=${hdf_mpack}


## add admin user to postgres for other services, such as Ranger
cd /tmp
sudo -u postgres createuser -U postgres -d -e -E -l -r -s admin
sudo -u postgres psql -c "ALTER USER admin PASSWORD 'BadPass#1'";
printf "\nhost\tall\tall\t0.0.0.0/0\tmd5\n" >> /var/lib/pgsql/data/pg_hba.conf
#systemctl restart postgresql
service postgresql restart

## bug workaround:
sed -i "s/\(^    total_sinks_count = \)0$/\11/" /var/lib/ambari-server/resources/stacks/HDP/2.0.6/services/stack_advisor.py
bash -c "nohup ambari-server restart" || true

while ! echo exit | nc localhost 8080; do echo "waiting for ambari to come up..."; sleep 10; done
curl -iv -u admin:admin -H "X-Requested-By: blah" -X PUT -d "{ \"Users\": { \"user_name\": \"admin\", \"old_password\": \"admin\", \"password\": \"${ambari_password}\" }}" http://localhost:8080/api/v1/users/admin

yum -y install postgresql-jdbc
ambari-server setup --jdbc-db=postgres --jdbc-driver=/usr/share/java/postgresql-jdbc.jar
ambari-server setup --jdbc-db=mysql --jdbc-driver=/usr/share/java/mysql-connector-java.jar


cd ~/ambari-bootstrap/deploy


if [ "${enable_hive_acid}" = true  ]; then
	acid_hive_env="\"hive-env\": { \"hive_txn_acid\": \"on\" }"

	acid_hive_site="\"hive.support.concurrency\": \"true\","
	acid_hive_site+="\"hive.compactor.initiator.on\": \"true\","
	acid_hive_site+="\"hive.compactor.worker.threads\": \"1\","
	acid_hive_site+="\"hive.enforce.bucketing\": \"true\","
	acid_hive_site+="\"hive.exec.dynamic.partition.mode\": \"nonstrict\","
	acid_hive_site+="\"hive.txn.manager\": \"org.apache.hadoop.hive.ql.lockmgr.DbTxnManager\","
fi

cat << EOF > configuration-custom.json
{
  "configurations" : {
    "core-site": {
        "hadoop.proxyuser.root.users" : "admin",
        "hadoop.proxyuser.knox.groups" : "*",	
        "fs.trash.interval": "4320"
    },
    "hdfs-site": {
      "dfs.namenode.safemode.threshold-pct": "0.99"
    },
    ${acid_hive_env},
    "hive-site": {
        ${acid_hive_site}
        "hive.server2.enable.doAs" : "true",
        "hive.exec.compress.output": "true",
        "hive.merge.mapfiles": "true",
        "hive.exec.post.hooks" : "org.apache.hadoop.hive.ql.hooks.ATSHook,org.apache.atlas.hive.hook.HiveHook",
	"hive.privilege.synchronizer.interval" : "30",
        "hive.server2.tez.initialize.default.sessions": "true"
    },
    "mapred-site": {
        "mapreduce.job.reduce.slowstart.completedmaps": "0.7",
        "mapreduce.map.output.compress": "true",
        "mapreduce.output.fileoutputformat.compress": "true"
    },
    "yarn-site": {
        "yarn.acl.enable" : "true"
    },
    "tez-site": {
        "tez.am.resource.memory.mb" : "1024",
        "tez.task.resource.memory.mb" : "1024"	
    },    
    "ams-site": {
      "timeline.metrics.cache.size": "100"
    },   
    "kafka-broker": {
      "offsets.topic.replication.factor": "1"
    },    
    "admin-properties": {
        "policymgr_external_url": "http://localhost:6080",
        "db_root_user": "admin",
        "db_root_password": "BadPass#1",
        "DB_FLAVOR": "POSTGRES",
        "db_user": "rangeradmin",
        "db_password": "BadPass#1",
        "db_name": "ranger",
        "db_host": "localhost"
    },
    "atlas-env": {
      "atlas.admin.password": "BadPass#1"
    }, 
    "nifi-ambari-config": {
      "nifi.security.encrypt.configuration.password": "${nifi_password}",
      "nifi.sensitive.props.key": "${nifi_password}"
    },     
    "ranger-env": {
        "ranger_admin_username": "admin",
        "ranger_admin_password": "BadPass#1",	
        "admin_password": "BadPass#1",
	"rangerusersync_user_password": "BadPass#1",
	"keyadmin_user_password": "BadPass#1",
	"rangertagsync_user_password": "BadPass#1",	
        "ranger-knox-plugin-enabled" : "Yes",
        "ranger-storm-plugin-enabled" : "No",
        "ranger-kafka-plugin-enabled" : "Yes",
        "ranger-hdfs-plugin-enabled" : "Yes",
        "ranger-hive-plugin-enabled" : "Yes",
        "ranger-hbase-plugin-enabled" : "Yes",
        "ranger-atlas-plugin-enabled" : "Yes",
        "ranger-yarn-plugin-enabled" : "Yes",
        "is_solrCloud_enabled": "true",
        "xasecure.audit.destination.solr" : "true",
        "xasecure.audit.destination.hdfs" : "true",
        "ranger_privelege_user_jdbc_url" : "jdbc:postgresql://localhost:5432/postgres",
        "create_db_dbuser": "true"
    },
    "ranger-admin-site": {
        "ranger.jpa.jdbc.driver": "org.postgresql.Driver",
        "ranger.jpa.jdbc.url": "jdbc:postgresql://localhost:5432/ranger",
        "ranger.audit.solr.zookeepers": "$(hostname -f):2181/infra-solr",
        "ranger.servicedef.enableDenyAndExceptionsInPolicies": "true"
    },
    "ranger-tagsync-site": {
        "ranger.tagsync.atlas.hdfs.instance.cl1.ranger.service": "${cluster_name}_hadoop",
        "ranger.tagsync.atlas.hive.instance.cl1.ranger.service": "${cluster_name}_hive",
        "ranger.tagsync.atlas.hbase.instance.cl1.ranger.service": "${cluster_name}_hbase",
        "ranger.tagsync.atlas.kafka.instance.cl1.ranger.service": "${cluster_name}_kafka",
        "ranger.tagsync.atlas.atlas.instance.cl1.ranger.service": "${cluster_name}_atlas",
        "ranger.tagsync.atlas.yarn.instance.cl1.ranger.service": "${cluster_name}_yarn",
        "ranger.tagsync.atlas.tag.instance.cl1.ranger.service": "tags"        
    },    
    "ranger-hive-audit" : {
        "xasecure.audit.is.enabled" : "true",
        "xasecure.audit.destination.hdfs" : "true",
        "xasecure.audit.destination.solr" : "true"
    }
  }
}
EOF



sleep 40
service ambari-server status
curl -u admin:${ambari_pass} -i -H "X-Requested-By: blah" -X GET http://localhost:8080/api/v1/hosts
./deploy-recommended-cluster.bash


#wait for install
cd ~
sleep 20
source ~/ambari-bootstrap/extras/ambari_functions.sh
ambari_configs
ambari_wait_request_complete 1
sleep 10
        
#wait until Hive is up
while ! echo exit | nc localhost 10000; do echo "waiting for hive to come up..."; sleep 10; done

sudo curl -u admin:${ambari_pass} -H 'X-Requested-By: blah' -X POST -d "
{
   \"RequestInfo\":{
      \"command\":\"RESTART\",
      \"context\":\"Restart Atlas\",
      \"operation_level\":{
         \"level\":\"HOST\",
         \"cluster_name\":\"${cluster_name}\"
      }
   },
   \"Requests/resource_filters\":[
      {
         \"service_name\":\"ATLAS\",
         \"component_name\":\"ATLAS_SERVER\",
         \"hosts\":\"${host}\"
      }
   ]
}" http://localhost:8080/api/v1/clusters/${cluster_name}/requests  


#Upload UDF jar to HDFS
sudo -u hdfs hdfs dfs -mkdir -p /apps/hive/share/udfs
cd /usr/hdp/3.*/hive/lib
sudo -u hdfs hdfs dfs -copyFromLocal hive-exec-3.*.jar /apps/hive/share/udfs/hive-exec.jar

## update zeppelin notebooks and upload to HDFS
curl -sSL https://raw.githubusercontent.com/hortonworks-gallery/zeppelin-notebooks/master/update_all_notebooks.sh | sudo -E sh 
cd /usr/hdp/current/zeppelin-server/notebook/
mv -t /tmp 2DAHF93NE 2C2HQQXVC 2C3T6AYDG 2DJVH9H46
rm * -rf
cd /tmp
mv -t /usr/hdp/current/zeppelin-server/notebook/ 2DAHF93NE 2C2HQQXVC 2C3T6AYDG 2DJVH9H46

sudo -u zeppelin hdfs dfs -rmr /user/zeppelin/notebook/*
sudo -u zeppelin hdfs dfs -put /usr/hdp/current/zeppelin-server/notebook/* /user/zeppelin/notebook/

#TODO: remove workaround to make jdbc(hive) work, as this will break jdbc(spark)
rm -f /usr/hdp/current/zeppelin-server/interpreter/jdbc/hive*1.21*.jar

echo disable anonymous login and create Hortonia users
cat << EOF > /tmp/zeppelin-env.json
{
  "properties": {
    "shiro_ini_content": "\n [users]\n etl_user = ${zeppelin_pass},admin\n ivanna_eu_hr = ${zeppelin_pass}, admin\n scott_intern = ${zeppelin_pass}, admin\n joe_analyst = ${zeppelin_pass}, admin\n \n \n [main]\n sessionManager = org.apache.shiro.web.session.mgt.DefaultWebSessionManager\n cacheManager = org.apache.shiro.cache.MemoryConstrainedCacheManager\n securityManager.cacheManager = \$cacheManager\n cookie = org.apache.shiro.web.servlet.SimpleCookie\n cookie.name = JSESSIONID\n cookie.httpOnly = true\n sessionManager.sessionIdCookie = \$cookie\n securityManager.sessionManager = \$sessionManager\n securityManager.sessionManager.globalSessionTimeout = 86400000\n shiro.loginUrl = /api/login\n \n [roles]\n role1 = *\n role2 = *\n role3 = *\n admin = *\n \n [urls]\n /api/version = anon\n #/** = anon\n /** = authc\n \n"
  }
}
EOF


/var/lib/ambari-server/resources/scripts/configs.py -u admin -p ${ambari_pass} --host localhost --port 8080 --cluster ${cluster_name} -a set -c zeppelin-shiro-ini -f /tmp/zeppelin-env.json
sleep 5

# Install shell interpreter into Zeppelin
/usr/hdp/current/zeppelin-server/bin/install-interpreter.sh --name shell

#restart Zeppelin
sudo curl -u admin:${ambari_pass} -H 'X-Requested-By: blah' -X POST -d "
{
\"RequestInfo\":{
  \"command\":\"RESTART\",
  \"context\":\"Restart Zeppelin\",
  \"operation_level\":{
	 \"level\":\"HOST\",
	 \"cluster_name\":\"${cluster_name}\"
  }
},
\"Requests/resource_filters\":[
  {
	 \"service_name\":\"ZEPPELIN\",
	 \"component_name\":\"ZEPPELIN_MASTER\",
	 \"hosts\":\"${host}\"
  }
]
}" http://localhost:8080/api/v1/clusters/${cluster_name}/requests  



#update Knox LDAP passwords
#/var/lib/ambari-server/resources/scripts/configs.py -u admin -p ${ambari_pass} --host localhost --port 8080 --cluster ${cluster_name} -a get -c users-ldif \
#  | sed -e '1,2d' \
#  -e "s/sample/test/g"  \
#  -e "s/admin-password/${knox_ldap_pass}/g"  \
#  -e "s/guest-password/${knox_ldap_pass}/g"  \
#  -e "s/sam-password/${knox_ldap_pass}/g"  \
#  -e "s/tom-password/${knox_ldap_pass}/g"  \
#  -e "s/guest/demokitadmin/g"  \
#  -e "s/sam/joe_analyst/g"  \
#  -e "s/tom/ivanna_eu_hr/g"  \
#  > /tmp/user-ldif.json
#/var/lib/ambari-server/resources/scripts/configs.py -u admin -p ${ambari_pass} --host localhost --port 8080 --cluster ${cluster_name} -a set -c users-ldif -f /tmp/user-ldif.json

#import complete ldif for Knox LDAP
ldif=$(sed 's/$/\\n/' /tmp/masterclass/ranger-atlas/HortoniaMunichSetup/demousers.ldif | tr -d '\n')
cat << EOF > /tmp/ldif.json
{
  "properties": {
    "content": "${ldif}"
  }
}
EOF
/var/lib/ambari-server/resources/scripts/configs.py -u admin -p ${ambari_pass} --host localhost --port 8080 --cluster ${cluster_name} -a set -c users-ldif -f /tmp/ldif.json


sleep 5

#restart Knox
sudo curl -u admin:${ambari_pass} -H 'X-Requested-By: blah' -X POST -d "
{
\"RequestInfo\":{
  \"command\":\"RESTART\",
  \"context\":\"Restart Knox\",
  \"operation_level\":{
	 \"level\":\"HOST\",
	 \"cluster_name\":\"${cluster_name}\"
  }
},
\"Requests/resource_filters\":[
  {
	 \"service_name\":\"KNOX\",
	 \"component_name\":\"KNOX_GATEWAY\",
	 \"hosts\":\"${host}\"
  }
]
}" http://localhost:8080/api/v1/clusters/${cluster_name}/requests 


while ! echo exit | nc localhost 21000; do echo "waiting for atlas to come up..."; sleep 10; done
sleep 30

# curl -u admin:${ambari_pass} -i -H 'X-Requested-By: blah' -X POST -d '{"RequestInfo": {"context" :"ATLAS Service Check","command":"ATLAS_SERVICE_CHECK"},"Requests/resource_filters":[{"service_name":"ATLAS"}]}' http://localhost:8080/api/v1/clusters/${cluster_name}/requests

## update ranger to support deny policies
ranger_curl="curl -u admin:BadPass#1"
ranger_url="http://localhost:6080/service"


${ranger_curl} ${ranger_url}/public/v2/api/servicedef/name/hive \
  | jq '.options = {"enableDenyAndExceptionsInPolicies":"true"}' \
  | jq '.policyConditions = [
{
	  "itemId": 1,
	  "name": "resources-accessed-together",
	  "evaluator": "org.apache.ranger.plugin.conditionevaluator.RangerHiveResourcesAccessedTogetherCondition",
	  "evaluatorOptions": {},
	  "label": "Resources Accessed Together?",
	  "description": "Resources Accessed Together?"
},{
	"itemId": 2,
	"name": "not-accessed-together",
	"evaluator": "org.apache.ranger.plugin.conditionevaluator.RangerHiveResourcesNotAccessedTogetherCondition",
	"evaluatorOptions": {},
	"label": "Resources Not Accessed Together?",
	"description": "Resources Not Accessed Together?"
}
]' > hive.json

${ranger_curl} -i \
  -X PUT -H "Accept: application/json" -H "Content-Type: application/json" \
  -d @hive.json ${ranger_url}/public/v2/api/servicedef/name/hive
sleep 10

#create tag service repo in Ranger called tags
${ranger_curl} ${ranger_url}/public/v2/api/service -X POST  -H "Content-Type: application/json"  -d @- <<EOF
{
"name":"tags",
"description":"tags service from API",
"type": "tag",
"configs":{},
"isActive":true
}
EOF


#associate tag service with Hive/Hbase/Kafka Ranger repos
for component in hive hbase kafka hdfs ; do
 echo "Adding tags service to Ranger $component repo..."
 ${ranger_curl} ${ranger_url}/public/v2/api/service | jq ".[] | select (.type==\"${component}\")"  > tmp.json
 cat tmp.json | jq '. |= .+  {"tagService":"tags"}' > tmp-updated.json
 if [ "${component}" = "hdfs" ]; then
	${ranger_curl} ${ranger_url}/public/v2/api/service/name/${cluster_name}_hadoop -X PUT  -H "Content-Type: application/json"  -d @tmp-updated.json     
 else
	${ranger_curl} ${ranger_url}/public/v2/api/service/name/${cluster_name}_${component} -X PUT  -H "Content-Type: application/json"  -d @tmp-updated.json
 fi	
done 

cd /tmp/masterclass/ranger-atlas/Scripts/
echo "importing ranger Tag policies.."
< ranger-policies-tags.json jq '.policies[].service = "tags"' > ranger-policies-tags_apply.json
${ranger_curl} -X POST \
-H "Content-Type: multipart/form-data" \
-H "Content-Type: application/json" \
-F 'file=@ranger-policies-tags_apply.json' \
		  "${ranger_url}/plugins/policies/importPoliciesFromFile?isOverride=true&serviceType=tag"
			  
echo "import ranger Hive policies..."
< ranger-policies-enabled.json jq '.policies[].service = "'${cluster_name}'_hive"' > ranger-policies-apply.json
${ranger_curl} -X POST \
-H "Content-Type: multipart/form-data" \
-H "Content-Type: application/json" \
-F 'file=@ranger-policies-apply.json' \
		  "${ranger_url}/plugins/policies/importPoliciesFromFile?isOverride=true&serviceType=hive"

echo "import ranger HDFS policies..." #to give hive access to /hive_data HDFS dir
< ranger-hdfs-policies.json jq '.policies[].service = "'${cluster_name}'_hadoop"' > ranger-hdfs-policies-apply.json
${ranger_curl} -X POST \
-H "Content-Type: multipart/form-data" \
-H "Content-Type: application/json" \
-F 'file=@ranger-hdfs-policies-apply.json' \
		  "${ranger_url}/plugins/policies/importPoliciesFromFile?isOverride=true&serviceType=hdfs"

echo "import ranger kafka policies..." #  to give ANONYMOUS access to kafka or Atlas won't work
< ranger-kafka-policies.json jq '.policies[].service = "'${cluster_name}'_kafka"' > ranger-kafka-policies-apply.json
${ranger_curl} -X POST \
-H "Content-Type: multipart/form-data" \
-H "Content-Type: application/json" \
-F 'file=@ranger-kafka-policies-apply.json' \
		  "${ranger_url}/plugins/policies/importPoliciesFromFile?isOverride=true&serviceType=kafka"


echo "import ranger hbase policies..."
< ranger-hbase-policies.json jq '.policies[].service = "'${cluster_name}'_hbase"' > ranger-hbase-policies-apply.json
${ranger_curl} -X POST \
-H "Content-Type: multipart/form-data" \
-H "Content-Type: application/json" \
-F 'file=@ranger-hbase-policies-apply.json' \
		  "${ranger_url}/plugins/policies/importPoliciesFromFile?isOverride=true&serviceType=hbase"


echo "import ranger atlas policies..."
< ranger-atlas-policies.json jq '.policies[].service = "'${cluster_name}'_atlas"' > ranger-atlas-policies-apply.json
${ranger_curl} -X POST \
-H "Content-Type: multipart/form-data" \
-H "Content-Type: application/json" \
-F 'file=@ranger-atlas-policies-apply.json' \
		  "${ranger_url}/plugins/policies/importPoliciesFromFile?isOverride=true&serviceType=atlas"


echo "import ranger yarn policies..."
< ranger-yarn-policies.json jq '.policies[].service = "'${cluster_name}'_yarn"' > ranger-yarn-policies-apply.json
${ranger_curl} -X POST \
-H "Content-Type: multipart/form-data" \
-H "Content-Type: application/json" \
-F 'file=@ranger-yarn-policies-apply.json' \
		  "${ranger_url}/plugins/policies/importPoliciesFromFile?isOverride=true&serviceType=yarn"

sleep 40    

    
cd /tmp/masterclass/ranger-atlas/HortoniaMunichSetup
sed -i.bak "s/ATLAS_PASS=admin/ATLAS_PASS=BadPass#1/g" env_atlas.sh
sed -i.bak "s/RANGER_ADMIN_PASS=admin/RANGER_ADMIN_PASS=BadPass#1/g" env_ranger.sh


./01-atlas-import-classification.sh
#./02-atlas-import-entities.sh      ## replaced with 09-associate-entities-with-tags.sh
./03-update-servicedefs.sh
./04-create-ambari-users.sh
		
cd /tmp/masterclass/ranger-atlas/HortoniaMunichSetup
su hdfs -c ./05-create-hdfs-user-folders.sh
su hdfs -c ./06-copy-data-to-hdfs.sh



	
#Enable kerberos	
if [ "${enable_kerberos}" = true  ]; then
   #export automate_kerberos=false
   ./08-enable-kerberos.sh
fi

#echo "MIT KDC setup with realm of HWX.COM and credentials user:admin/admin pass:hadoop"
#echo "You will now need to manually go through security wizard to setup kerberos using this KDC. Waiting until /etc/security/keytabs/rm.service.keytab is created by Ambari kerberos wizard before proceeding ..."

#while ! [ -f "/etc/security/keytabs/rm.service.keytab" ];
#do
#    sleep 10
#done

echo "Sleeping 30s...."
sleep 30

#wait until Hive is up
while ! echo exit | nc localhost 10000; do echo "waiting for hive to come up..."; sleep 10; done

echo "Sleeping 30s...."
sleep 30

mv /tmp/useful-scripts/ambari/*.keytab /etc/security/keytabs

#kill any previous Hive/tez apps to clear queue before creating tables

if [ "${enable_kerberos}" = true  ]; then
  kinit -kVt /etc/security/keytabs/rm.service.keytab rm/$(hostname -f)@${kdc_realm}
fi    
#kill any previous Hive/tez apps to clear queue before hading cluster to end user
for app in $(yarn application -list | awk '$2==hive && $3==TEZ && $6 == "ACCEPTED" || $6 == "RUNNING" { print $1 }')
do 
	yarn application -kill  "$app"
done    

	
#create tables
	
if [ "${enable_kerberos}" = true  ]; then
   ./07-create-hive-schema-kerberos.sh
else
   ./07-create-hive-schema.sh        
fi     


if [ "${enable_kerberos}" = true  ]; then
  kinit -kVt /etc/security/keytabs/rm.service.keytab rm/$(hostname -f)@${kdc_realm}
fi    
#kill any previous Hive/tez apps to clear queue before hading cluster to end user
for app in $(yarn application -list | awk '$2==hive && $3==TEZ && $6 == "ACCEPTED" || $6 == "RUNNING" { print $1 }')
do 
	yarn application -kill  "$app"
done


cd /tmp/masterclass/ranger-atlas/HortoniaMunichSetup

#create kafka topics and populate data - do it after kerberos to ensure Kafka Ranger plugin enabled
./08-create-hbase-kafka.sh

#restart Atlas
sudo curl -u admin:${ambari_pass} -H 'X-Requested-By: blah' -X POST -d "
{
   \"RequestInfo\":{
      \"command\":\"RESTART\",
      \"context\":\"Restart Atlas\",
      \"operation_level\":{
         \"level\":\"HOST\",
         \"cluster_name\":\"${cluster_name}\"
      }
   },
   \"Requests/resource_filters\":[
      {
         \"service_name\":\"ATLAS\",
         \"component_name\":\"ATLAS_SERVER\",
         \"hosts\":\"${host}\"
      }
   ]
}" http://localhost:8080/api/v1/clusters/${cluster_name}/requests  


sleep 30

while ! echo exit | nc localhost 21000; do echo "waiting for atlas to come up..."; sleep 10; done

 #import Atlas entities 
export atlas_pass="BadPass#1"
./01-atlas-import-classification.sh
./09-associate-entities-with-tags.sh

echo "Done."

echo "Setting up Spark/Atlas connector..."

#if using EA build, need to replace Atlas JS file to workaround bug
#cd /usr/hdp/3.0*/atlas/server/webapp/atlas/js/utils/
#mv CommonViewFunction.js CommonViewFunction.js.bak
#wget https://hipchat.hortonworks.com/files/1/592/xhXByuN10MU1RNJ/CommonViewFunction.js
#chown atlas:hadoop CommonViewFunction.js


cd /tmp
wget https://github.com/hortonworks-spark/spark-atlas-connector/releases/download/v0.1.0-2.3-1.0.0/spark-atlas-connector-assembly_2.11-0.1.0-SNAPSHOT.jar
chmod 777 /tmp/spark-atlas-connector-assembly_2.11-0.1.0-SNAPSHOT.jar  

#copy Atlas config to Spark conf dir
cp /etc/atlas/conf/atlas-application.properties /usr/hdp/current/spark2-client/conf/    
chmod 777 /usr/hdp/current/spark2-client/conf/atlas-application.properties


echo "Importing Nifi flow..."
cd /var/lib/nifi/conf 
mv flow.xml.gz flow.xml.gz.orig
wget https://gist.github.com/abajwa-hw/815757d9446c246ee9a1407449f7ff45/raw -O ./flow.xml
sed -i "s/demo.hortonworks.com/${host}/g; s/HWX.COM/${kdc_realm}/g;" flow.xml
gzip flow.xml
chown nifi:hadoop flow.xml.gz 

sleep 5
echo "Restarting Nifi..."
sudo curl -u admin:${ambari_pass} -H 'X-Requested-By: blah' -X POST -d "
{
   \"RequestInfo\":{
      \"command\":\"RESTART\",
      \"context\":\"Restart Nifi\",
      \"operation_level\":{
         \"level\":\"HOST\",
         \"cluster_name\":\"${cluster_name}\"
      }
   },
   \"Requests/resource_filters\":[
      {
         \"service_name\":\"NIFI\",
         \"component_name\":\"NIFI_MASTER\",
         \"hosts\":\"${host}\"
      }
   ]
}" http://localhost:8080/api/v1/clusters/${cluster_name}/requests  

#wait until Nifi is up
while ! echo exit | nc $(hostname -f) 9090; do echo "waiting for Nifi to come up..."; sleep 10; done


sudo curl -u admin:${ambari_pass} -H 'X-Requested-By: blah' -X POST -d "
{
   \"RequestInfo\":{
      \"command\":\"RESTART\",
      \"context\":\"Restart Hive\",
      \"operation_level\":{
         \"level\":\"HOST\",
         \"cluster_name\":\"${cluster_name}\"
      }
   },
   \"Requests/resource_filters\":[
      {
         \"service_name\":\"HIVE\",
         \"component_name\":\"HIVE_SERVER\",
         \"hosts\":\"${host}\"
      }
   ]
}" http://localhost:8080/api/v1/clusters/${cluster_name}/requests 

#wait until hive is up
while ! echo exit | nc $(hostname -f) 10000; do echo "waiting for Hive to come up..."; sleep 10; done

if [ "${enable_knox_sso_proxy}" = true  ]; then
  cd /tmp/masterclass/ranger-atlas/HortoniaMunichSetup
  echo "Setting up KNOX SSO"
  ./10-SSOSetup.sh ${cluster_name} ${ambari_pass} ${knox_ldap_pass}

  echo "Setting up UI proxy"
  ./11-KNOX-UI-proxySetup.sh ${cluster_name} ${ambari_pass}

  #echo "Setting up Zeppelin SSO"
  ./12-enable-zeppelin_SSO.sh ${cluster_name} ${ambari_pass} "https://${knox_host}:8443/gateway/knoxsso/api/v1/websso"
  
  #when using SSO, startup script shouldn't change Ambari pass
  touch /root/.firstbootdone
fi




echo "--------------------------"
echo "--------------------------"
echo "Automated portion of setup is complete. Next, check and run manual steps from https://github.com/abajwa-hw/masterclass/blob/master/ranger-atlas/README.md"
echo "Once complete, see here for walk through of demo: https://community.hortonworks.com/articles/151939/hdp-securitygovernance-demo-kit.html"
##echo "To test Atlas/Spark connector, run scenarios from here: Run scenarios from https://docs.google.com/document/d/1zpCX6CB6BB-O-aJZTl4yEMJMt-3c9-T_0SmLvd6brQE/"
