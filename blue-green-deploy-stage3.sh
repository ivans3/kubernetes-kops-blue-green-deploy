#!/bin/bash
#set -x

BATCH_MODE=false

#Parse args:
while true; do
  case "$1" in
    --batch)  BATCH_MODE=true; shift ;;
	--namespace=*)  NAMESPACE="${1#*=}"; shift ;;
    -- ) shift; break ;;
    * ) break ;;
  esac
done


#Check required environment variables are set:
REQUIRED_VARS="NAME AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION NAMESPACE"

echo Running with this configuration:
for VAR in $REQUIRED_VARS; do
    if [ "x`eval echo \\$$VAR`" = "x" ]; then
        echo Aborting! Need to set $VAR, along with $REQUIRED_VARS
        exit -1
    fi
    VAL=`eval echo \\$$VAR`
    if [ "$VAR" = "AWS_SECRET_ACCESS_KEY" ]; then VAL=redacted; fi
    if [ "$VAR" = "CLOUDFLARE_KEY" ]; then VAL=redacted; fi
    echo '    '$VAR: $VAL
done

#Verify some programs exist
jq --version >/dev/null 2>&1 || { echo "Need to install jq"; exit -1; }

#1 delete old deployments:

echo Trying to determine which deployments are not selected by the services and may be deleted...

DEPLOYMENTS_TO_DELETE=""

for SERVICE in $(kubectl -n$NAMESPACE get services -o jsonpath={..metadata.name})
do
    APP_NAME=$(kubectl -n$NAMESPACE get service $SERVICE -o jsonpath='{ ..spec.selector.app }')
    LIVE_VERSION=$(kubectl -n$NAMESPACE get service $SERVICE -o jsonpath='{ ..spec.selector.version }')
    if [ x"$LIVE_VERSION" = "x" ]; then
        echo couldnt get version info, Aborting
        exit -1
    fi
    for DEPLOYMENT_INFO in $(kubectl -n$NAMESPACE get deployments -l app=$APP_NAME -o jsonpath='{range .items[*]}{@.metadata.name}/{@.metadata.labels.version}{"\n"}{end}')
    do
          DEPLOYMENT_NAME=${DEPLOYMENT_INFO%%/*}
          VERSION=${DEPLOYMENT_INFO##*/}
          if [ x"$VERSION" = "x" ]; then
              echo couldnt get version info, Aborting
              exit -1
          fi
          if [ x"$VERSION" != x"$LIVE_VERSION" ]; then
             DEPLOYMENTS_TO_DELETE="$DEPLOYMENTS_TO_DELETE $DEPLOYMENT_NAME"
          fi
    done
done

if [ x"$DEPLOYMENTS_TO_DELETE" = "x" ]; then
    echo Couldnt find any deployments to Delete, Aborting
    exit -1
fi
DEPLOYMENTS_TO_DELETE_DEDUPED=$(echo $DEPLOYMENTS_TO_DELETE | tr ' ' '\n' | sort -u) 



#1.1 Determine the "version" annotations for the set of deployments:
#TODO - delete the IG(s) associated with the version annotation from the deployments... 
#for now just abort if it doesnt match the "oldest IG"
VERSIONS=$(kubectl -n$NAMESPACE get deployments $DEPLOYMENTS_TO_DELETE_DEDUPED -o jsonpath='{ range .items[*] }{ .metadata.labels.version }{"\n"}{end}')
if [ "1" != "$(echo "$VERSIONS"|uniq|wc -l)" ]; then
   echo Found some inconsistent deployments, please clean up manually, Aborting
   exit -1
fi

VERSION_TO_DELETE=$(echo "$VERSIONS"|head -n1)

#2.1 get oldest "nodes"-type IG:
OLDEST_IG=$(kops get ig -o json |jq '[ .[] | select ( .spec.role=="Node") ] | sort_by( .metadata.creationTimestamp )[0].metadata.name' -r)

echo OLDEST_IG is $OLDEST_IG

if [ "x$OLDEST_IG" = "x" ] || [ "$OLDEST_IG" = "null" ]; then
    echo couldnt figure out which IG to delete, Aborting
    exit -1
fi

#2.2 Get oldest IG label and verify everything is as expected...
NODE_LABEL=$(kops get ig -o json $OLDEST_IG |jq .spec.nodeLabels.blueGreenDeploy -r)
if [ "$NODE_LABEL" != "$VERSION_TO_DELETE" ]; then
    echo couldnt verify which IG to delete, Aborting
    exit -1
fi

echo The following deployments are not selected by the services and will be deleted: 
echo "  "$DEPLOYMENTS_TO_DELETE_DEDUPED
echo
echo Next, the oldest IG will be deleted: $OLDEST_IG

if ! $BATCH_MODE; then
    echo -n "Is it OK [N/y]? "
    read answer
    if [ x"${answer,,}" != x"y" ]; then
        echo Aborting!
        exit -1
    fi
fi
    
for DEPLOYMENT in $DEPLOYMENTS_TO_DELETE_DEDUPED
do
    echo Deleting deployment $DEPLOYMENT
    kubectl -n$NAMESPACE delete deployment $DEPLOYMENT
    if [ $? != 0 ]; then
        echo Couldnt delete deployment $DEPLOYMENT, Aborting!!
        exit -1
    fi
done


#2.2 get the IP addresses of the nodes from the IG:
NODE_IP_ADDRESSES=$(kops toolbox dump -o json|jq ".resources[] | select(.raw.Tags[] | (.Key == \"Name\" and .Value == \"$OLDEST_IG.$NAME\")) | select(.type == \"instance\") .raw.PrivateIpAddress" -r)
if [ "x$NODE_IP_ADDRESSES" = "x" ]; then
    echo couldnt figure out the IP addresses of the nodes in the IG $OLDEST_IG, Aborting
    exit -1
fi


for IP_ADDRESS in $NODE_IP_ADDRESSES
do
    echo Verifying that there are no pods scheduled on $IP_ADDRESS...
    REMAINING_PODS="x"
    while [ "$REMAINING_PODS" != "" ]
    do
        REMAINING_PODS=$(kubectl -n$NAMESPACE get pods -l name!=fluentd-sumologic,app!=efs-provisioner -o jsonpath="{ .items[?(@.status.hostIP==\"$IP_ADDRESS\")].metadata.name }")
        if [ "$?" != "0" ]; then
            echo Coudlnt get list of remaining pods for $IP_ADDRESS, Aborting
            exit -1
        fi
        echo "  "$IP_ADDRESS: waiting for pods to terminate: $REMAINING_PODS
        sleep 1
    done
done
    
#4. delete old IG
echo Deleting IG
kops delete ig $OLDEST_IG --name $NAME --yes
if [ "$?" != "0" ]; then
    echo Couldnt delete IG, Aborting
    exit -1
fi

exit 0


