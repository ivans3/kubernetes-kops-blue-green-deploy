#!/bin/bash
#
#Note: Doesnt reapply service manifests, only adjust service selectors...

CLEAR_SELECTORS=false
BATCH_MODE=false
RELEASE_TO_SELECT=""
NAMESPACE=""

DO_ROLLOUT_STATUS=true

#Parse args:
while true; do
  case "$1" in
    --clear)  CLEAR_SELECTORS=true; shift ;;
    --batch)  BATCH_MODE=true; shift ;;
    --namespace=*)  NAMESPACE="${1#*=}"; shift ;;
    --no-verify)  DO_ROLLOUT_STATUS=false; shift ;;
    -- ) shift; break ;;
    * ) RELEASE_TO_SELECT=$1; break ;;
  esac
done

if ! $CLEAR_SELECTORS && [ "x$RELEASE_TO_SELECT" = "x" ]; then
   echo 'Usage: bash blue-green-deploy-stage2.sh --namespace=thenamespace [--batch] [--no-verify] ( --clear | RELEASE_TAG )'
   exit -1
fi

if [ "x$NAMESPACE" = "" ]; then 
   echo need to specify namespace, Aborting 
   exit -1
fi

function get_metadata_name ()
{
    YAML_FILE=$1
    #Note: requires pyyaml:
    python -c 'import yaml;print yaml.load(open("'$YAML_FILE'").read())["metadata"]["name"]'
}


KUBECTL_CURRENT_CONTEXT=$(kubectl config current-context)
if [ "$?" != "0" ]; then
    echo kubectl may not be configured correctly, Aborting!!
    exit -1
fi


if $CLEAR_SELECTORS;  then
    WARNING_TEXT="Clearing any version service selectors on cluster: $KUBECTL_CURRENT_CONTEXT"
else
    WARNING_TEXT="Update service selectors to version: $RELEASE_TO_SELECT on cluster: $KUBECTL_CURRENT_CONTEXT?"
fi

if ! $BATCH_MODE; then
    echo $WARNING_TEXT
    echo -n "Is it OK [N/y]? "
    read answer
    if [ x"${answer,,}" != x"y" ]; then
        echo Aborting!
        exit -1
    fi
fi


#0.0A Check if deployments.target folder is created, it should have been created by an 
#earlier bamboo plan...
if [ ! -d ./deployments.target ]; then
    echo Deployments target folder does not exist, Aborting...
    exit -1
fi


#0.0B Check if the services from the checkout differ from whats currently deployed: 
#TODO: Use something like this to do a deeper compare:
#https://github.com/weaveworks/kubediff
#NUM_SERVICES_IN_FOLDER=0
#for SERVICE_YAML in services/*.yaml
#do
#    NUM_SERVICES_IN_FOLDER=$((NUM_SERVICES_IN_FOLDER + 1))
#    ORIGINAL_SERVICE_NAME=`get_metadata_name $SERVICE_YAML`
#    kubectl -n$NAMESPACE get service $ORIGINAL_SERVICE_NAME
#    if [ $? != 0 ]; then
#       echo Couldnt find service $ORIGINAL_SERVICE_NAME on cluster
#       echo Aborting, and you will need to complete stage2 manually...
#       exit -1
#    fi
#done
#kubectl -n$NAMESPACE get services -o name
#if [ $? != 0 ]; then
#    echo Couldnt get services from cluster, Aborting
#    exit -1
#fi
#NUM_SERVICES_IN_CLUSTER=$(kubectl -n$NAMESPACE get services -o name|wc -l)
#if [ "$NUM_SERVICES_IN_CLUSTER" != "$NUM_SERVICES_IN_FOLDER" ]; then
#    echo The set of services differs from what is deployed
#    echo Aborting, and you will need to complete stage2 manually...
#    exit -1
#fi


#Verify/wait for the set of deployments to be ready:
if $DO_ROLLOUT_STATUS; then
    echo `date` Waiting for new set of deployments to be ready.. 
    for DEPLOYMENT_YAML in deployments.target/*.yaml
    do
        ORIGINAL_DEPLOYMENT_NAME=`get_metadata_name $DEPLOYMENT_YAML`
        if [ "$?" != "0" ]; then
            echo Couldnt get original deployment name from $DEPLOYMENT_YAML, Aborting
            exit -1
        fi
        #Note: If running from bamboo then use this line:
        #TAGGED_DEPLOYMENT_NAME="$ORIGINAL_DEPLOYMENT_NAME-${RELEASE_TO_SELECT,,}"  #tolower
        TAGGED_DEPLOYMENT_NAME="$ORIGINAL_DEPLOYMENT_NAME"
        echo Verifying rollout status for $TAGGED_DEPLOYMENT_NAME
        kubectl -n hq rollout status deployment/$TAGGED_DEPLOYMENT_NAME
        if [ "$?" != "0" ]; then
            echo Verifying rollout of image for deployment $TAGGED_DEPLOYMENT_NAME failed, Aborting script!!
            exit -1
        fi

        #Extra check: Verify that status.replicas == status.availableReplicas for deployment:
        EXPECTED_REPLICAS=$(kubectl -n$NAMESPACE get deployment $TAGGED_DEPLOYMENT_NAME -o jsonpath='{ .status.replicas }')
        if [ "$?" != "0" ]; then
            echo Couldnt verify expected replica count for $TAGGED_DEPLOYMENT_NAME, Aborting
            exit -1
        fi
        AVAILABLE_REPLICAS=$(kubectl -n$NAMESPACE get deployment $TAGGED_DEPLOYMENT_NAME -o jsonpath='{ .status.replicas }')
        if [ "$?" != "0" ]; then
            echo Couldnt verify available replica count for $TAGGED_DEPLOYMENT_NAME, Aborting
            exit -1
        fi
        if [ "$EXPECTED_REPLICAS" != "$AVAILABLE_REPLICAS" ]; then
            echo Couldnt verify that all replicas are available for deployment $TAGGED_DEPLOYMENT_NAME, Aborting
            exit -1
        fi
    done
    echo `date` New deployments rolled-out.
else
    echo Skipping pre-verification of rollout...
fi



#perform switchover
for SERVICE in $(kubectl -n$NAMESPACE get services -o jsonpath={..metadata.name})
do
    if $CLEAR_SELECTORS;  then
        kubectl -n$NAMESPACE patch svc $SERVICE --type='json' -p='[{"op": "remove", "path": "/spec/selector/version"}]'
    else
        kubectl -n$NAMESPACE patch svc $SERVICE -p "{\"spec\":{\"selector\": {\"version\": \"${RELEASE_TO_SELECT}\"}}}"
    fi
           
    if [ "$?" != "0" ]; then
        echo Couldnt patch service $SERVICE, Aborting, and you will need to rollback manually
        exit -1
    fi
done

echo sleeping 10 seconds...
sleep 10

#Output results
echo Script done, Current service selections are:
kubectl -n$NAMESPACE get services -o jsonpath='{range .items[*]}{ .metadata.name }{": "}{ .spec.selector }{"\n"}{end}' 

