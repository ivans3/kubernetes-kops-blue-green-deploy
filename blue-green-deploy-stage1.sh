#!/bin/bash

RELEASE=$1
DEPLOYMENT_HOME=.

DO_ROLLOUT_STATUS=true

#Parse args:
while true; do
  case "$1" in
    --no-verify)  DO_ROLLOUT_STATUS=false; shift ;;
    --namespace=*)  NAMESPACE="${1#*=}"; shift ;;	
	--kops-spec-file=*)  KOPS_SPEC_FILE="${1#*=}"; shift ;;	
    -- ) shift; break ;;
    * ) RELEASE=$1; break ;;
  esac
done

if [ x"$RELEASE" = "x" ];  then
    echo Usage: bash blue-green-deploy-stage1.sh --kops-spec-file=nodes.yaml --namespace=thenamespace [--no-verify] RELEASE_TAG_NAME
    exit -1
fi

#Verify some programs exist
jq --version >/dev/null 2>&1 || { echo "Need to install jq"; exit -1; }

function get_metadata_name ()
{
    YAML_FILE=$1
    #Note: requires pyyaml:
    python -c 'import yaml;print yaml.load(open("'$YAML_FILE'").read())["metadata"]["name"]'
}


#Check required environment variables are set:
REQUIRED_VARS="NAME KOPS_SPEC_FILE NAMESPACE"

echo Running with this configuration:
for VAR in $REQUIRED_VARS; do
    if [ "x`eval echo \\$$VAR`" = "x" ]; then
        echo Aborting! Need to set $VAR, along with $REQUIRED_VARS
        exit -1
    fi
    VAL=`eval echo \\$$VAR`
    if [ "$VAR" = "AWS_SECRET_ACCESS_KEY" ]; then VAL=redacted; fi
    echo '    '$VAR: $VAL
done

#0.0 Check if deployments.target folder is created, it should have been created earlier...
if [ ! -d $DEPLOYMENT_HOME/deployments.target ]; then
    echo Deployments target folder does not exist, Aborting...
    exit -1
fi

#0.1 Verify that there is no IG already present for the git release tag...
COUNT=$(kops get ig -o json|jq '.[] | .spec.nodeLabels.blueGreenDeploy'|grep -c $RELEASE)

if [ "$COUNT" != "0" ]; then
    echo IG already exists for Release $RELEASE,
    echo And you will have to clean up manually and re-run...
    exit -1
fi

#Modify the yaml files in "deployments.target" folder:
#-Append the release tag name to the deployment's name
#-Add a nodeSelector pointing to the newly created IG
for DEPLOYMENT_YAML in deployments.target/*.yaml
do
    python - $DEPLOYMENT_YAML <<EOF
import yaml
x=yaml.load(open("$DEPLOYMENT_YAML").read())
x['spec']['template']['metadata']['labels']['version'] = "$RELEASE"
#Change deployment name.. metadata name must be lowercase:
if not x['metadata']['name'].endswith("-$RELEASE".lower()):
    x['metadata']['name']=x['metadata']['name'] + "-" + "$RELEASE".lower()
x['spec']['template']['spec']['nodeSelector'] = {'blueGreenDeploy':'$RELEASE'}
open("$DEPLOYMENT_YAML",'w').write(yaml.dump(x, default_flow_style=False))
EOF
    if [ $? != 0 ]; then
        echo Couldnt prepare target deployment file for $DEPLOYMENT_YAML, Aborting
        exit -1
    fi
done


#1.0 create a kops IG named nodes-RELEASE-TIMESTAMP using the spec filea:
rm -rf $DEPLOYMENT_HOME/specs.target
if [ -d $DEPLOYMENT_HOME/specs.target ]; then
    echo Couldnt clear target folder, aborting
    exit -1
fi
mkdir $DEPLOYMENT_HOME/specs.target
if [ ! -d $DEPLOYMENT_HOME/specs.target ]; then
    echo Couldnt create target folder, aborting
    exit -1
fi

SOURCE_FILE=$KOPS_SPEC_FILE
TARGET_FILE=nodes2.yaml
TIMESTAMP=$(date +"%s")
IG_NAME="nodes-$RELEASE-$TIMESTAMP"
python - <<EOF
import yaml
from yaml import Loader
x=yaml.load(open("$SOURCE_FILE").read())
#metadata name must be lowercase:
x['metadata']['name']="$IG_NAME"
x['spec']['nodeLabels']={'blueGreenDeploy':'$RELEASE'}
open("$TARGET_FILE",'w').write(yaml.dump(x, default_flow_style=False))
EOF
if [ $? != 0 ]; then
    echo Couldnt prepare target deployment file for $DEPLOYMENT_YAML, Aborting
    exit -1
fi
kops create -f $TARGET_FILE
if [ "$?" != "0" ]; then
    echo Couldnt create new IG from target file $TARGET_FILE, Aborting!!
    exit -1
fi
kops update cluster --create-kube-config=false --name $NAME --yes
if [ "$?" != "0" ]; then
    echo Couldnt update cluster with new IG, Aborting!!
    exit -1
fi


#2.0 wait for new nodes ready (using node labels tags)
NODECOUNT=0
EXPECTED_NODECOUNT=$(kops get ig $IG_NAME -o json|jq .spec.minSize -r)
if [ "x$EXPECTED_NODECOUNT" = "x" ]; then
    echo Couldnt get expected nodecount, Aborting
    exit -1
fi

while [ $NODECOUNT -lt $EXPECTED_NODECOUNT ] 
do
    NODECOUNT=$(kubectl get nodes -l blueGreenDeploy==$RELEASE -o jsonpath='{ range .items[*] }{ .status.conditions[?(@.type == "Ready")].status }{"\n"}{end}'|grep -c True)
    echo Waiting for $EXPECTED_NODECOUNT nodes, got: $NODECOUNT
    sleep 10
done

#3.0 Create new set of deployments onto the new IG:
kubectl -n$NAMESPACE create -f deployments.target/
if [ $? != 0 ]; then
    echo Couldnt prepare target deployment file for $DEPLOYMENT_YAML, Aborting
    exit -1
fi

#4.0 Wait for new set of deployments to be ready
if $DO_ROLLOUT_STATUS; then
    echo `date` Waiting for new set of deployments to be ready.. 
    for DEPLOYMENT_YAML in deployments.target/*.yaml
    do
        DEPLOYMENT=`get_metadata_name $DEPLOYMENT_YAML`
        echo Verifying rollout status for $DEPLOYMENT...
        kubectl -n$NAMESPACE rollout status deployment/$DEPLOYMENT
        if [ "$?" != "0" ]; then
            echo Verifying rollout of image for deployment $DEPLOYMENT failed, Aborting update script!!
            exit -1
        fi
    done
    echo `date` New deployments rolled-out.
else
    echo Skipping verification of rollout...
fi

#Stage1 complete
