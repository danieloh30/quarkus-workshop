#!/bin/bash
#
# Prereqs: a running ocp 4 cluster, logged in as kubeadmin
#
MYDIR="$( cd "$(dirname "$0")" ; pwd -P )"
function usage() {
    echo "usage: $(basename $0) [-c/--count usercount] -a/--admin-password admin_password"
}

# Defaults
USERCOUNT=10
ADMIN_PASSWORD=
OPENSHIFT_USER_PASSWORD=openshift
CHE_USER_PASSWORD=openshift

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -c|--count)
    USERCOUNT="$2"
    shift # past argument
    shift # past value
    ;;
    -a|--admin-pasword)
    ADMIN_PASSWORD="$2"
    shift # past argument
    shift # past value
    ;;
    *)    # unknown option
    echo "Unknown option: $key"
    usage
    exit 1
    ;;
esac
done
set -- "${POSITIONAL[@]}" # restore positional parameters
echo "USERCOUNT: $USERCOUNT"
echo "ADMIN_PASSWORD: $ADMIN_PASSWORD"

if [ -z "$ADMIN_PASSWORD" ] ; then
  echo "Admin password (-a) required"
  usage
  exit 1
fi

if [ ! "$(oc get clusterrolebindings)" ] ; then
  echo "not cluster-admin"
  exit 1
fi

# adjust limits for admin
oc delete userquota/default

# get routing suffix
TMP_PROJ="dummy-$RANDOM"
oc new-project $TMP_PROJ
oc create route edge dummy --service=dummy --port=8080 -n $TMP_PROJ
ROUTE=$(oc get route dummy -o=go-template --template='{{ .spec.host }}' -n $TMP_PROJ)
HOSTNAME_SUFFIX=$(echo $ROUTE | sed 's/^dummy-'${TMP_PROJ}'\.//g')
oc delete project $TMP_PROJ
MASTER_URL=$(oc whoami --show-server)
CONSOLE_URL=$(oc whoami --show-console)
TMPHTPASS=$(mktemp)

# Add openshift cluster admin user
htpasswd -b ${TMPHTPASS} admin "${ADMIN_PASSWORD}"
# create users
for i in $(eval echo "{1..$USERCOUNT}") ; do
    htpasswd -b ${TMPHTPASS} "user$i" "${OPENSHIFT_USER_PASSWORD}"
done

# Create user secret in OpenShift
! oc -n openshift-config delete secret workshop-user-secret
oc -n openshift-config create secret generic workshop-user-secret --from-file=htpasswd=${TMPHTPASS}
rm -f ${TMPHTPASS}

# Set the users to OpenShift OAuth
oc -n openshift-config get oauth cluster -o yaml | \
  yq d - spec.identityProviders | \
  yq w - -s ${MYDIR}/htpass.yaml | \
  oc apply -f -

# sleep for 30 seconds for the pods to be restarted
echo "Waiting 30s for new OAuth to take effect"
sleep 30

# Make the admin as cluster admin
oc adm policy add-cluster-role-to-user cluster-admin admin

# create projects for users
for i in $(eval echo "{1..$USERCOUNT}") ; do
    PROJ="user${i}-project"
    oc new-project $PROJ --display-name="Working Project for user${i}" >&- && \
    oc label namespace $PROJ quarkus-workshop=true  && \
    oc adm policy add-role-to-user admin user${i} -n $PROJ
done

# deploy guides
oc new-project guides
oc new-app quay.io/jamesfalkner/workshopper --name=web \
      -e MASTER_URL=${MASTER_URL} \
      -e CONSOLE_URL=${CONSOLE_URL} \
      -e CHE_URL=http://codeready-codeready.${HOSTNAME_SUFFIX} \
      -e KEYCLOAK_URL=http://keycloak-codeready.${HOSTNAME_SUFFIX} \
      -e ROUTE_SUBDOMAIN=${HOSTNAME_SUFFIX} \
      -e CONTENT_URL_PREFIX="https://raw.githubusercontent.com/RedHatWorkshops/quarkus-workshop/ocp-4.3/docs/" \
      -e WORKSHOPS_URLS="https://raw.githubusercontent.com/RedHatWorkshops/quarkus-workshop/ocp-4.3/docs/_workshop.yml" \
      -e CHE_USER_PASSWORD=${CHE_USER_PASSWORD} \
      -e OPENSHIFT_USER_PASSWORD=${OPENSHIFT_USER_PASSWORD} \
      -e LOG_TO_STDOUT=true
oc expose svc/web

# Install Che
oc new-project codeready
cat <<EOF | oc apply -n codeready -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: codeready-
  annotations:
    olm.providedAPIs: CheCluster.v1.org.eclipse.che
  name: codeready-operator-group
  namespace: codeready
spec:
  targetNamespaces:
    - codeready
EOF

cat <<EOF | oc apply -n codeready -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: codeready-workspaces
  namespace: codeready
spec:
  channel: latest
  installPlanApproval: Automatic
  name: codeready-workspaces
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for checluster to be a thing
echo "Waiting for CheCluster CRDs"
while [ true ] ; do
  if [ "$(oc explain checluster -n codeready)" ] ; then
    break
  fi
  echo -n .
  sleep 10
done

cat <<EOF | oc apply -n codeready -f -
apiVersion: org.eclipse.che/v1
kind: CheCluster
metadata:
  name: codeready-workspaces
  namespace: codeready
spec:
  server:
    cheImageTag: ''
    cheFlavor: codeready
    devfileRegistryImage: ''
    pluginRegistryImage: ''
    tlsSupport: true
    selfSignedCert: false
    serverMemoryRequest: '2Gi'
    serverMemoryLimit: '6Gi'
    customCheProperties:
      CHE_LIMITS_WORKSPACE_IDLE_TIMEOUT: "0"
  database:
    externalDb: false
    chePostgresHostName: ''
    chePostgresPort: ''
    chePostgresUser: ''
    chePostgresPassword: ''
    chePostgresDb: ''
  auth:
    openShiftoAuth: false
    identityProviderImage: ''
    externalIdentityProvider: false
    identityProviderURL: ''
    identityProviderRealm: ''
    identityProviderClientId: ''
  storage:
    pvcStrategy: per-workspace
    pvcClaimSize: 1Gi
    preCreateSubPaths: true
EOF

# Wait for che to be up
echo "Waiting for Che to come up..."
while [ 1 ]; do
  STAT=$(curl -s -w '%{http_code}' -o /dev/null http://codeready-codeready.$HOSTNAME_SUFFIX/dashboard/)
  if [ "$STAT" = 200 ] ; then
    break
  fi
  echo -n .
  sleep 10
done

# get keycloak admin password
KEYCLOAK_USER="$(oc set env deployment/keycloak --list |grep SSO_ADMIN_USERNAME | cut -d= -f2)"
KEYCLOAK_PASSWORD="$(oc set env deployment/keycloak --list |grep SSO_ADMIN_PASSWORD | cut -d= -f2)"

echo "Keycloak credentials: ${KEYCLOAK_USER} / ${KEYCLOAK_PASSWORD}"
echo "URL: http://keycloak-codeready.${HOSTNAME_SUFFIX}"

# Enable script upload
oc set env -n codeready deployment/keycloak JAVA_OPTS_APPEND="-Dkeycloak.profile.feature.scripts=enabled -Dkeycloak.profile.feature.upload_scripts=enabled"

# Wait for keycloak to return
echo "Wait for keycloak to return"
while [ true ] ; do
  if [ "$(oc rollout -n codeready status --timeout=3m -w deployment/keycloak)" ] ; then
    break
  fi
  echo -n .
  sleep 10
done

# Get keycloak pod
echo "Get keycloak pod"
while [ true ] ; do
  if [ "$(oc get pod -n codeready -l app=codeready,component=keycloak)" ] ; then
    break
  fi
  echo -n .
  sleep 10
done

echo -e "Waiting 60s for keycloak to be ready... \n"
sleep 60

# Import realm
wget https://raw.githubusercontent.com/redhat-cop/agnosticd/development/ansible/roles/ocp4-workload-quarkus-workshop/files/quarkus-realm.json
SSO_TOKEN=$(curl -s -d "username=${KEYCLOAK_USER}&password=${KEYCLOAK_PASSWORD}&grant_type=password&client_id=admin-cli" \
  -X POST http://keycloak-codeready.$HOSTNAME_SUFFIX/auth/realms/master/protocol/openid-connect/token | \
  jq  -r '.access_token')
curl -v -H "Authorization: Bearer ${SSO_TOKEN}" -H "Content-Type:application/json" -d @quarkus-realm.json \
  -X POST "http://keycloak-codeready.${HOSTNAME_SUFFIX}/auth/admin/realms"
rm -f quarkus-realm.json

# Create Che users, let them view che namespace
for i in $(eval echo "{1..$USERCOUNT}") ; do
    SSO_TOKEN=$(curl -s -d "username=${KEYCLOAK_USER}&password=${KEYCLOAK_PASSWORD}&grant_type=password&client_id=admin-cli" \
    -X POST http://keycloak-codeready.$HOSTNAME_SUFFIX/auth/realms/master/protocol/openid-connect/token | \
    jq  -r '.access_token')
    USERNAME=user${i}
    FIRSTNAME=User${i}
    LASTNAME=Developer
    curl -v -H "Authorization: Bearer ${SSO_TOKEN}" -H "Content-Type:application/json" -d '{"username":"user'${i}'","enabled":true,"emailVerified": true,"firstName": "User'${i}'","lastName": "Developer","email": "user'${i}'@no-reply.com", "credentials":[{"type":"password","value":"'${CHE_USER_PASSWORD}'","temporary":false}]}' -X POST "http://keycloak-codeready.${HOSTNAME_SUFFIX}/auth/admin/realms/codeready/users"
done

# Get CRW SSO admin token
SSO_TOKEN=$(curl -s -d "username=${KEYCLOAK_USER}&password=${KEYCLOAK_PASSWORD}&grant_type=password&client_id=admin-cli" \
  -X POST http://keycloak-codeready.${HOSTNAME_SUFFIX}/auth/realms/master/protocol/openid-connect/token | \
  jq  -r '.access_token')

# Increase codeready access token lifespans
curl -v -H "Authorization: Bearer ${SSO_TOKEN}" -H "Content-Type:application/json" -d '{"accessTokenLifespan": 28800,"accessTokenLifespanForImplicitFlow": 28800,"actionTokenGeneratedByUserLifespan": 28800,"ssoSessionIdleTimeout": 28800,"ssoSessionMaxLifespan": 28800}' \
  -X PUT "http://keycloak-codeready.${HOSTNAME_SUFFIX}/auth/admin/realms/codeready"

# Scale the cluster
WORKERCOUNT=$(oc get nodes|grep worker | wc -l)
if [ "$WORKERCOUNT" -lt 10 ] ; then
    for i in $(oc get machinesets -n openshift-machine-api -o name | grep worker| cut -d'/' -f 2) ; do
      echo "Scaling $i to 3 replicas"
      oc patch -n openshift-machine-api machineset/$i -p '{"spec":{"replicas": 3}}' --type=merge
    done
fi

# import stack image
oc create -n openshift -f $MYDIR/../files/stack.imagestream.yaml
oc import-image --all quarkus-stack -n openshift

# Pre-create workspaces for users
wget -O devfile.json https://raw.githubusercontent.com/redhat-cop/agnosticd/development/ansible/roles/ocp4-workload-quarkus-workshop/templates/devfile.json.j2 
for i in $(eval echo "{1..$USERCOUNT}") ; do
    SSO_CHE_TOKEN=$(curl -s -d "username=user${i}&password=${CHE_USER_PASSWORD}&grant_type=password&client_id=admin-cli" \
        -X POST http://keycloak-codeready.${HOSTNAME_SUFFIX}/auth/realms/codeready/protocol/openid-connect/token | jq  -r '.access_token')  

    TMPWORK=$(mktemp)
    sed 's/{{ user }}/user'${i}'/g' devfile.json > $TMPWORK

    curl -v -X POST --header 'Content-Type: application/json' --header 'Accept: application/json' \
    --header "Authorization: Bearer ${SSO_CHE_TOKEN}" -d @${TMPWORK}  \
    "http://codeready-codeready.${HOSTNAME_SUFFIX}/api/workspace/devfile?start-after-create=true&namespace=user${i}"
    rm -f $TMPWORK
done
rm -f devfile.json

# Install the AMQ Streams operator for all namespaces
cat <<EOF | oc apply -n openshift-operators -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: amq-streams
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: amq-streams
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Install Jaeger operator for all namespaces
cat <<EOF | oc apply -n openshift-operators -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: jaeger-product
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: jaeger-product
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF