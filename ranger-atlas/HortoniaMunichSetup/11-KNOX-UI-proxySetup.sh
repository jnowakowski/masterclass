#!/usr/bin/env bash
export cluster_name=$1
export knox_host=demo.hortonworks.com
export host=$(hostname -f)
export ambari_pass=$2

echo "Enable service discovery for knox" ##new feature in HDP 3.0
python /tmp/config_update.py hdp KNOX gateway-site "gateway.cluster.config.monitor.ambari.enabled" "true" admin "${ambari_pass}"
python /tmp/config_update.py hdp KNOX gateway-site "gateway.remote.config.monitor.client" "sandbox-zookeeper-client" admin "${ambari_pass}"

#restart Knox
echo "restart Knox"
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
while ! echo exit | nc localhost 8443; do echo "waiting for knox to come up..."; sleep 10; done
sleep 30

#create alias for discovery password
/usr/hdp/current/knox-server/bin/knoxcli.sh create-alias ambari.discovery.password --value "${ambari_pass}"

#descriptor file with all services
#knox will auto detect service end points from ambari APIs
cd /tmp
cat << EOF > ui.json
{
  "discovery-address":"http://${host}:8080",
  "provider-config-ref":"cookieprovider",
  "discovery-user":"admin",
  "cluster":"${cluster_name}",
  "services":[
    {"name":"NAMENODE"},
    {"name":"JOBTRACKER"},
    {"name":"YARNUI"},
    {"name":"YARNUIV2"},
    {"name":"WEBHDFS"},
    {"name":"WEBHCAT"},
    {"name":"OOZIE"},
    {"name":"ATLAS"},
    {"name":"ATLAS-API"},
    {"name":"WEBHBASE"},
    {"name":"HDFSUI"},
    {"name":"RESOURCEMANAGER"},
    {"name":"HIVE"},
    {"name":"LOGSEARCH"},
    {"name":"RANGER"},
    {"name":"RANGERUI"},
    {"name":"ZEPPELIN"},
    {"name":"ZEPPELINUI"},
    {"name":"ZEPPELINWS"},
    {"name":"SPARKHISTORYUI"},
    {"name":"AMBARI","urls":["http://${host}:8080"]},
    {"name":"AMBARIUI","urls":["http://${host}:8080"]},
    {"name":"AMBARIWS","urls":["ws://${host}:8080"]}
  ]
}
EOF

##delta provider to be added
cat << EOF > cookieprovider.xml
<gateway>
    <provider>
        <role>federation</role>
        <name>SSOCookieProvider</name>
        <enabled>true</enabled>
        <param>
            <name>sso.authentication.provider.url</name>
            <value>https://${knox_host}:8443/gateway/knoxsso/api/v1/websso</value>
        </param>
    </provider>
    <provider>
        <role>identity-assertion</role>
        <name>Default</name>
        <enabled>true</enabled>
    </provider>
</gateway>
EOF

cp /tmp/cookieprovider.xml /etc/knox/conf/shared-providers/
cp /tmp/ui.json /etc/knox/conf/descriptors/

sleep 30

##Knox watcher will pick up these changes - no restart required

