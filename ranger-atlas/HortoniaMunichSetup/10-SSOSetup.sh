#!/usr/bin/env bash
export cluster_name=$1
export host=$(hostname -f)
export ambari_pass=$2
export knox_ldap_pass=$3
hostname=$(hostname -f)
current_dir=$(pwd)
cd /tmp
#Copy config-update to /tmp
cp /tmp/masterclass/ranger-atlas/HortoniaMunichSetup/config_update.py .
#Install the required
yum -y -q install xmlstarlet expect

export PYTHONIOENCODING=utf8
#Step 1 : Update the knoxsso whitelisting regex to allow everything.
#Get the current knoxsso topology
/var/lib/ambari-server/resources/scripts/configs.py -u admin -p ${ambari_pass} --host localhost --port 8080 --cluster ${cluster_name} -a get -c knoxsso-topology | sed -e '1,2d'| python -c "import sys, json; print json.load(sys.stdin)['properties']['content']" > /tmp/knoxsso-topology.xml

#Update the whitelist regex in the xml
xmlstarlet ed -L -d "/topology/service[role='KNOXSSO']/param[name='knoxsso.redirect.whitelist.regex']"  -s "/topology/service[role='KNOXSSO']" -t elem -n paramTmp -v "" -s //paramTmp -t elem -n name -v "knoxsso.redirect.whitelist.regex" -s //paramTmp -t elem -n value -v ".*"  -r //paramTmp -v param /tmp/knoxsso-topology.xml

# convert the XML to json to upload
cat <<EOF > convert-knoxsso-json.py
import json;
with open('/tmp/knoxsso-topology.xml', 'r') as myfile:
    content=myfile.read();

data={};
data['properties']={}
data['properties']['content']=content;
json_data=json.dumps(data);
print json_data
EOF

python convert-knoxsso-json.py > knoxsso.json

#Upload updated knoxsso topology json to ambari.
/var/lib/ambari-server/resources/scripts/configs.py -u admin -p ${ambari_pass} --host localhost --port 8080 --cluster ${cluster_name} -a set -c knoxsso-topology -f /tmp/knoxsso.json


#Step 2: Create the public certificate for KNOX sso 
#Update the master key and existing keystores since current master key is unknown.
#Setup knox master secret and prepare keystores
echo "Prepare Keystores folder"
mkdir /usr/hdp/current/knox-server/data/security/keystores_backup 
mv /usr/hdp/current/knox-server/data/security/keystores/* /usr/hdp/current/knox-server/data/security/keystores_backup/
echo "Changing master secret"
/usr/hdp/current/knox-server/bin/knoxcli.sh create-master --force --master knoxsecret  

echo "Restarting Knox"
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
	 \"hosts\":\"${hostname}\"
  }
]
}" http://localhost:8080/api/v1/clusters/${cluster_name}/requests 
sleep 10
while ! echo exit | nc localhost 8443; do echo "waiting for knox to come up..."; sleep 10; done
sleep 20

echo "Generating the certificate"

keytool -genkey -alias knoxidentity -keyalg RSA -keysize 1024 -dname CN=knoxidentity,OU=hw,O=hw,L=paloalto,ST=ca,C=us -keypass knoxsecret -keystore knoxidentity.jks -storepass knoxsecret
keytool -export -alias knoxidentity -keystore /tmp/knoxidentity.jks -rfc -file knox.cert -storepass knoxsecret
#Certificate to distribute to services
knox_cert=$(cat /tmp/knox.cert | grep -v "BEGIN CERTIFICATE" | grep -v "END CERTIFICATE"|sed 's/\r//g' )
knox_hostname=demo.hortonworks.com
#Provider URL for SSO
knox_sso_url="https://${knox_hostname}:8443/gateway/knoxsso/api/v1/websso"

echo "Create knoxidentity alias"
/usr/hdp/current/knox-server/bin/knoxcli.sh create-alias knoxidentity --value knoxsecret       
cp /tmp/knoxidentity.jks /usr/hdp/current/knox-server/data/security/keystores/

#Start the LDAP for SSO authentication
/usr/hdp/current/knox-server/bin/ldap.sh start

#Update signing alias in KNOX
echo "Update signing alias in KNOX"
python /tmp/config_update.py hdp KNOX gateway-site "gateway.signing.keystore.name" "knoxidentity.jks" admin "${ambari_pass}"
python /tmp/config_update.py hdp KNOX gateway-site "gateway.signing.key.alias" "knoxidentity" admin "${ambari_pass}"

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
	 \"hosts\":\"${hostname}\"
  }
]
}" http://localhost:8080/api/v1/clusters/${cluster_name}/requests
sleep 10
while ! echo exit | nc localhost 8443; do echo "waiting for knox to come up..."; sleep 10; done
sleep 30

#Step 3: Setup SSO for ambari server
cat << EOF > setupambarisso-helper.sh
#!/usr/bin/expect
set providerUrl [lindex \$argv 0]
set cert [lindex \$argv 1]
set ambari_pass [lindex \$argv 2]
spawn ambari-server setup-sso  --ambari-admin-username=admin --ambari-admin-password=\$ambari_pass --sso-enabled-ambari=true --sso-manage-services=false --sso-jwt-cookie-name=hadoop-jwt --sso-jwt-audience-list=
expect {
  timeout {
      exit 1
    }
  eof {
      exit 0
    }
  "Do you want to configure SSO authentication" {
      send "y\r"
      exp_continue
    }
  "Provider URL" {
      send "\$providerUrl\r"
      exp_continue
    }
  "Public Certificate PEM" {
      send "\$cert\r\r\r"
      exp_continue
    }
  "Do you want to configure advanced properties" {
      send "n\r"
      exp_continue
   }
}
interact
EOF

expect setupambarisso-helper.sh "$knox_sso_url" "$knox_cert" "$ambari_pass"

ambari-server setup-ldap --ldap-url=$hostname:33389 --ldap-user-class=person --ldap-user-attr=uid --ldap-group-class=groupofnames --ldap-ssl=false --ldap-secondary-url="" --ldap-referral="" --ldap-group-attr=cn --ldap-member-attr=member --ldap-dn=dn --ldap-base-dn=dc=hadoop,dc=apache,dc=org --ldap-bind-anonym=false --ldap-manager-dn=uid=admin,ou=people,dc=hadoop,dc=apache,dc=org --ldap-manager-password=${knox_ldap_pass} --ldap-save-settings --ldap-sync-username-collisions-behavior=convert  --ldap-force-setup --ldap-secondary-host="" --ldap-secondary-port=33389 --ldap-force-lowercase-usernames=true --ldap-pagination-enabled=false --ambari-admin-username=admin --ambari-admin-password=$ambari_pass << EOF
Generic LDAP
EOF

echo "Restarting ambari server"
ambari-server restart

echo "Sync Ldap"
ambari-server sync-ldap --ldap-sync-admin-name=admin --ldap-sync-admin-password=$ambari_pass --all

ambari-server sync-ldap --ldap-sync-admin-name=admin --ldap-sync-admin-password=${knox_ldap_pass} --all

echo "Restarting ambari server"
ambari-server restart

#STEP 4: Update SSO settings for RANGER
echo "Update sso configs for ranger"
python /tmp/config_update.py hdp RANGER ranger-admin-site "ranger.sso.enabled" "true" admin "${ambari_pass}"
python /tmp/config_update.py hdp RANGER ranger-admin-site "ranger.sso.publicKey" "$knox_cert" admin "${ambari_pass}"
python /tmp/config_update.py hdp RANGER ranger-admin-site "ranger.sso.providerurl" "$knox_sso_url" admin "${ambari_pass}"

echo "restart ranger"
sleep 10
curl -u admin:${ambari_pass} -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Stop RANGER via REST"}, "Body": {"ServiceInfo": {"state": "INSTALLED"}}}' http://localhost:8080/api/v1/clusters/${cluster_name}/services/RANGER
sleep 10
while echo exit | nc localhost 6080; do echo "waiting for Ranger to go down..."; sleep 10; done
sleep 15
curl -u admin:${ambari_pass} -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Start RANGER via REST"}, "Body": {"ServiceInfo": {"state": "STARTED"}}}' http://localhost:8080/api/v1/clusters/${cluster_name}/services/RANGER
sleep 5
while ! echo exit | nc localhost 6080; do echo "waiting for ranger to come up..."; sleep 10; done

#Step 5: setup SSO for Atlas
echo "Update sso configs for atlas"
python /tmp/config_update.py hdp ATLAS application-properties "atlas.sso.knox.enabled" "true" admin "${ambari_pass}"
python /tmp/config_update.py hdp ATLAS application-properties "atlas.sso.knox.publicKey" "$knox_cert" admin "${ambari_pass}"
python /tmp/config_update.py hdp ATLAS application-properties "atlas.sso.knox.providerurl" "$knox_sso_url" admin "${ambari_pass}"
python /tmp/config_update.py hdp ATLAS application-properties "atlas.sso.knox.browser.useragent" "Mozilla,Chrome,Opera" admin "${ambari_pass}"

sleep 10
echo "restart Atlas"

curl -u admin:${ambari_pass} -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Stop ATLAS via REST"}, "Body": {"ServiceInfo": {"state": "INSTALLED"}}}' http://localhost:8080/api/v1/clusters/${cluster_name}/services/ATLAS
sleep 10
while echo exit | nc localhost 21000; do echo "waiting for Atlas to go down..."; sleep 10; done
sleep 15
curl -u admin:${ambari_pass} -i -H 'X-Requested-By: ambari' -X PUT -d '{"RequestInfo": {"context" :"Start ATLAS via REST"}, "Body": {"ServiceInfo": {"state": "STARTED"}}}' http://localhost:8080/api/v1/clusters/${cluster_name}/services/ATLAS
sleep 5
while ! echo exit | nc localhost 21000; do echo "waiting for Atlas to come up..."; sleep 10; done
sleep 5

cd ${current_dir}
