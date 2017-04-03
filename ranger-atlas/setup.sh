#!/usr/bin/env bash
set -o xtrace

########################################################################
########################################################################
## variables

export HOME=${HOME:-/root}
export TERM=xterm
: ${ambari_pass:="BadPass#1"}
ambari_password="${ambari_pass}"
: ${stack:="mycluster"}
: ${cluster_name:=${stack}}
: ${ambari_services:="HDFS MAPREDUCE2 PIG YARN HIVE ZOOKEEPER AMBARI_METRICS SLIDER AMBARI_INFRA TEZ RANGER ATLAS KAFKA SPARK ZEPPELIN"}
: ${install_ambari_server:=true}
: ${ambari_stack_version:=2.6}
: ${deploy:=true}
: ${host_count:=skip}
: ${recommendation_strategy:="ALWAYS_APPLY_DONT_OVERRIDE_CUSTOM_VALUES"}
: ${install_nifi:=false}
: ${nifi_version:=1.1.2}
: ${ad_ip:="172.31.28.220"}
: ${ad_host:="ad01.lab.hortonworks.net"}

## overrides
#export ambari_stack_version=2.6
#export ambari_repo=https://public-repo-1.hortonworks.com/ambari/centos7/2.x/updates/2.5.0.3/ambari.repo

export install_ambari_server ambari_pass host_count ambari_services
export ambari_password cluster_name recommendation_strategy

########################################################################
########################################################################
## 
cd

yum makecache
yum -y -q install git epel-release ntpd screen mysql-connector-java jq python-argparse python-configobj ack bzip2
curl -sSL https://raw.githubusercontent.com/seanorama/ambari-bootstrap/master/extras/deploy/install-ambari-bootstrap.sh | bash

########################################################################
########################################################################
## trust active directory
echo "${ad_ip} ${ad_host} $(echo ${ad_host} | cut -d "." -f1)" | sudo tee -a /etc/hosts
sudo yum -y install openldap-clients ca-certificates
echo | openssl s_client -connect ${ad_host}:636  2>&1 | sed -ne '/-BEGIN CERTIFICATE-/,/-END CERTIFICATE-/p' > ad.crt
cp -a ad.crt /etc/pki/ca-trust/source/anchors/

sudo update-ca-trust force-enable
sudo update-ca-trust extract
sudo update-ca-trust check

########################################################################
########################################################################
## tutorial users
users="kate-hr ivana-eu-hr joe-analyst hadoop-admin compliance-admin hadoopadmin"
for user in ${users}; do
    sudo useradd ${user}
    printf "${ambari_pass}\n${ambari_pass}" | sudo passwd --stdin ${user}
    echo "${user} ALL=(ALL) NOPASSWD:ALL" | sudo tee -a /etc/sudoers.d/99-masterclass
done
groups="hr analyst compliance us_employees eu_employees hadoop-users hadoop-admins"
for group in ${groups}; do
  groupadd ${group}
done
usermod -a -G hr kate-hr
usermod -a -G hr ivana-eu-hr
usermod -a -G analyst joe-analyst
usermod -a -G compliance compliance-admin
usermod -a -G us_employees kate-hr
usermod -a -G us_employees joe-analyst
usermod -a -G us_employees compliance-admin
usermod -a -G eu_employees ivana-eu-hr
usermod -a -G hadoop-admins hadoopadmin
usermod -a -G hadoop-admins hadoop-admin

########################################################################
########################################################################
## 
~/ambari-bootstrap/extras/deploy/prep-hosts.sh
~/ambari-bootstrap/ambari-bootstrap.sh

## Ambari Server specific tasks
if [ "${install_ambari_server}" = "true" ]; then

    ## add admin user to postgres for other services, such as Ranger
    cd /tmp
    sudo -u postgres createuser -U postgres -d -e -E -l -r -s admin
    sudo -u postgres psql -c "ALTER USER admin PASSWORD 'BadPass#1'";
    printf "\nhost\tall\tall\t0.0.0.0/0\tmd5\n" >> /var/lib/pgsql/data/pg_hba.conf
    systemctl restart postgresql

    ## bug workaround:
    sed -i "s/\(^    total_sinks_count = \)0$/\11/" /var/lib/ambari-server/resources/stacks/HDP/2.0.6/services/stack_advisor.py
    bash -c "nohup ambari-server restart" || true

    sleep 60

    yum -y install postgresql-jdbc
    ambari-server setup --jdbc-db=postgres --jdbc-driver=/usr/share/java/postgresql-jdbc.jar
    ambari-server setup --jdbc-db=mysql --jdbc-driver=/usr/share/java/mysql-connector-java.jar
    ambari_pass=admin source ~/ambari-bootstrap/extras/ambari_functions.sh
    ambari_change_pass admin admin ${ambari_pass}
    sleep 1

    cd ~/ambari-bootstrap/deploy

        ## various configuration changes for demo environments, and fixes to defaults
cat << EOF > configuration-custom.json
{
  "configurations" : {
    "core-site": {
        "hadoop.proxyuser.root.users" : "admin",
        "fs.trash.interval": "4320"
    },
    "hdfs-site": {
      "dfs.namenode.safemode.threshold-pct": "0.99"
    },
    "hive-site": {
        "hive.server2.transport.mode": "http",
        "hive.exec.compress.output": "true",
        "hive.merge.mapfiles": "true",
        "hive.server2.tez.initialize.default.sessions": "true",
        "hive.exec.post.hooks" : "org.apache.hadoop.hive.ql.hooks.ATSHook,org.apache.atlas.hive.hook.HiveHook",
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
    "ams-site": {
      "timeline.metrics.cache.size": "100"
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
    "ranger-env": {
        "ranger_admin_username": "admin",
        "ranger_admin_password": "admin",
          "ranger-knox-plugin-enabled" : "No",
          "ranger-storm-plugin-enabled" : "No",
          "ranger-kafka-plugin-enabled" : "No",
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
    "ranger-tagsync-site": {
        "ranger.tagsync.atlas.default.cluster.name.off":"mycluster"
    },
    "ranger-admin-site": {
        "ranger.jpa.jdbc.driver": "org.postgresql.Driver",
        "ranger.jpa.jdbc.url": "jdbc:postgresql://localhost:5432/ranger"
    },
    "ranger-hdfs-security" : {
        "ranger.plugin.hdfs.service.name" : "hdfs"
    },
    "ranger-hive-security" : {
        "ranger.plugin.hive.service.name" : "hive"
    },
    "ranger-hive-audit" : {
        "xasecure.audit.is.enabled" : "true",
        "xasecure.audit.destination.hdfs" : "true",
        "xasecure.audit.destination.solr" : "true",
        "xasecure.audit.destination.solr.zookeepers" : "localhost:2181/infra-solr"
    },
    "ranger-ugsync-site": {
          "ranger.usersync.enabled" : "true",
          "ranger.usersync.unix.minUserId":"1000",
          "ranger.usersync.source.impl.class" : "org.apache.ranger.ldapusersync.process.LdapUserGroupBuilder",
          "ranger.usersync.group.memberattributename" : "member",
          "ranger.usersync.group.nameattribute" : "cn",
          "ranger.usersync.group.objectclass" : "group",
          "ranger.usersync.group.search.first.enabled" : "false",
          "ranger.usersync.group.searchbase" : "dc=lab,dc=hortonworks,dc=net",
          "ranger.usersync.group.searchenabled" : "false",
          "ranger.usersync.group.searchfilter" : "(|(cn=sales)(cn=hadoop-admins)(cn=hadoop-users)(cn=hadoop-user)(cn=hr)(cn=compliance)(cn=analyst)(cn=us_employees)(cn=eu_employees))",
          "ranger.usersync.group.usermapsyncenabled" : "true",
          "ranger.usersync.ldap.binddn" : "cn=ldap-reader,ou=ServiceUsers,dc=lab,dc=hortonworks,dc=net",
          "ranger.usersync.ldap.ldapbindpassword":"BadPass#1",
          "ranger.usersync.ldap.groupname.caseconversion" : "none",
          "ranger.usersync.ldap.searchBase" : "ou=CorpUsers,dc=lab,dc=hortonworks,dc=net",
          "ranger.usersync.ldap.url" : "ldap://ad01.lab.hortonworks.net",
          "ranger.usersync.ldap.user.nameattribute" : "sAMAccountName",
          "ranger.usersync.ldap.user.objectclass" : "user",
          "ranger.usersync.ldap.user.searchbase" : "ou=CorpUsers,dc=lab,dc=hortonworks,dc=net",
          "ranger.usersync.ldap.user.searchfilter" : "(objectcategory=person)"
    },
    "application-properties": {
        "atlas.cluster.name.off":"mycluster",
        "atlas.feature.taxonomy.enable":"true",
        "atlas.kafka.bootstrap.servers": "localhost:6667",
        "atlas.kafka.zookeeper.connect": "localhost:2181",
        "atlas.kafka.zookeeper.connection.timeout.ms": "20000",
        "atlas.kafka.zookeeper.session.timeout.ms": "40000",
        "atlas.rest.address": "http://localhost:21000",
        "atlas.graph.storage.backend": "berkeleyje",
        "atlas.graph.storage.hostname": "localhost",
        "atlas.graph.storage.directory": "/tmp/data/berkeley",
        "atlas.EntityAuditRepository.impl": "org.apache.atlas.repository.audit.NoopEntityAuditRepository",
        "atlas.graph.index.search.backend": "elasticsearch",
        "atlas.graph.index.search.directory": "/tmp/data/es",
        "atlas.graph.index.search.elasticsearch.client-only": "false",
        "atlas.graph.index.search.elasticsearch.local-mode": "true",
        "atlas.graph.index.search.elasticsearch.create.sleep": "2000",
        "atlas.notification.embedded": "false",
        "atlas.graph.index.search.solr.zookeeper-url": "localhost:2181/infra-solr",
        "atlas.audit.hbase.zookeeper.quorum": "localhost",
        "atlas.graph.storage.hostname": "localhost",
        "atlas.kafka.data": "/tmp/data/kafka"
    },
    "atlas-env" : {
        "content" : "\n      # The java implementation to use. If JAVA_HOME is not found we expect java and jar to be in path\n      export JAVA_HOME={{java64_home}}\n\n      # any additional java opts you want to set. This will apply to both client and server operations\n      {% if security_enabled %}\n      export ATLAS_OPTS=\"{{metadata_opts}} -Djava.security.auth.login.config={{atlas_jaas_file}}\"\n      {% else %}\n      export ATLAS_OPTS=\"{{metadata_opts}}\"\n      {% endif %}\n\n      # metadata configuration directory\n      export ATLAS_CONF={{conf_dir}}\n\n      # Where log files are stored. Defatult is logs directory under the base install location\n      export ATLAS_LOG_DIR={{log_dir}}\n\n      # additional classpath entries\n      export ATLASCPPATH={{metadata_classpath}}\n\n      # data dir\n      export ATLAS_DATA_DIR={{data_dir}}\n\n      # pid dir\n      export ATLAS_PID_DIR={{pid_dir}}\n\n      # hbase conf dir\n      export MANAGE_LOCAL_HBASE=false\n export MANAGE_LOCAL_SOLR=false\n\n\n      # Where do you want to expand the war file. By Default it is in /server/webapp dir under the base install dir.\n      export ATLAS_EXPANDED_WEBAPP_DIR={{expanded_war_dir}}\n      export ATLAS_SERVER_OPTS=\"-server -XX:SoftRefLRUPolicyMSPerMB=0 -XX:+CMSClassUnloadingEnabled -XX:+UseConcMarkSweepGC -XX:+CMSParallelRemarkEnabled -XX:+PrintTenuringDistribution -XX:+HeapDumpOnOutOfMemoryError -XX:HeapDumpPath=$ATLAS_LOG_DIR/atlas_server.hprof -Xloggc:$ATLAS_LOG_DIRgc-worker.log -verbose:gc -XX:+UseGCLogFileRotation -XX:NumberOfGCLogFiles=10 -XX:GCLogFileSize=1m -XX:+PrintGCDetails -XX:+PrintHeapAtGC -XX:+PrintGCTimeStamps\"\n      {% if java_version == 8 %}\n      export ATLAS_SERVER_HEAP=\"-Xms{{atlas_server_xmx}}m -Xmx{{atlas_server_xmx}}m -XX:MaxNewSize={{atlas_server_max_new_size}}m -XX:MetaspaceSize=100m -XX:MaxMetaspaceSize=512m\"\n      {% else %}\n      export ATLAS_SERVER_HEAP=\"-Xms{{atlas_server_xmx}}m -Xmx{{atlas_server_xmx}}m -XX:MaxNewSize={{atlas_server_max_new_size}}m -XX:MaxPermSize=512m\"\n      {% endif %}"
    }
  }
}
EOF

    ./deploy-recommended-cluster.bash

    if [ "${deploy}" = "true" ]; then


        if [ "${install_nifi}" = "true" ]; then
            cd /opt
            curl -ssLO http://mirrors.ukfast.co.uk/sites/ftp.apache.org/nifi/${nifi_version}/nifi-${nifi_version}-bin.tar.gz
            tar -xzvf nifi-${nifi_version}-bin.tar.gz
            sed -i 's/^\(nifi.web.http.port=\).*/\19090/' nifi-${nifi_version}/conf/nifi.properties
            /opt/nifi-${nifi_version}/bin/nifi.sh start
        fi

        cd ~
        sleep 5
        source ~/ambari-bootstrap/extras/ambari_functions.sh
        ambari_configs
        ambari_wait_request_complete 1
        cd ~
        sleep 10

        usermod -a -G users ${USER}
        usermod -a -G users admin
        echo "${ambari_pass}" | passwd admin --stdin
        sudo sudo -u hdfs bash -c "
            hadoop fs -mkdir /user/admin;
            hadoop fs -chown admin /user/admin;
            hdfs dfsadmin -refreshUserToGroupsMappings"

        UID_MIN=$(awk '$1=="UID_MIN" {print $2}' /etc/login.defs)
        users="$(getent passwd|awk -v UID_MIN="${UID_MIN}" -F: '$3>=UID_MIN{print $1}')"
        for user in ${users}; do sudo usermod -a -G users ${user}; done
        for user in ${users}; do sudo usermod -a -G hadoop-users ${user}; done
        ~/ambari-bootstrap/extras/onboarding.sh

        cd ~/
        git clone https://github.com/seanorama/masterclass
        cd ~/masterclass/ranger-atlas/Scripts/
        ./create-secgovdemo-hortoniabank-userfolders.sh
        ./load-secgovdemo-hortoniabank-files.sh

        ## update ranger to support deny policies
        ranger_curl="curl -u admin:admin"
        ranger_url="http://localhost:6080/service"
        ${ranger_curl} ${ranger_url}/public/v2/servicedef/name/hive \
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
          -X PUT -H "Accept: application/json" -H "Content-Type: application/json" --d @hive.json ${url}/public/v2/servicedef/name/hive

        sleep 30

        ## import ranger policies
        ${ranger_curl} -X POST \
        -H "Content-Type: multipart/form-data" \
        -H "Content-Type: application/json" \
        -F 'file=@ranger-policies.json' \
                  "${ranger_url}/plugins/policies/importPoliciesFromFile?isOverride=true&serviceType=hdfs,hive"

        sleep 30
        ./create-secgovdemo-hortoniabank-tables.sh

        # TODO

        #ad_host="ad01.lab.hortonworks.net"
        #ad_root="ou=CorpUsers,dc=lab,dc=hortonworks,dc=net"
        #ad_user="cn=ldap-reader,ou=ServiceUsers,dc=lab,dc=hortonworks,dc=net"

        #sudo ambari-server setup-ldap \
          #--ldap-url=${ad_host}:389 \
          #--ldap-secondary-url= \
          #--ldap-ssl=false \
          #--ldap-base-dn=${ad_root} \
          #--ldap-manager-dn=${ad_user} \
          #--ldap-bind-anonym=false \
          #--ldap-dn=distinguishedName \
          #--ldap-member-attr=member \
          #--ldap-group-attr=cn \
          #--ldap-group-class=group \
          #--ldap-user-class=user \
          #--ldap-user-attr=sAMAccountName \
          #--ldap-save-settings \
          #--ldap-bind-anonym=false \
          #--ldap-referral=

        #echo hadoop-users,hr,sales,legal,hadoop-admins,compliance,analyst,eu_employees,us_employees > groups.txt
        #sudo ambari-server restart
        #sudo ambari-server sync-ldap --groups groups.txt

    fi
fi

