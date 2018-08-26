# Kops/Kubernetes Blue-Green Deploy Script

Perform a blue-green deploy with a given tag by spinning up a new Kops InstanceGroup, and assigning the new deployments to the nodes. The next step is to update the services for the application to point to the new deployments. Finally, the IG and the old deployments
are cleaned up.

Based on:
https://www.ianlewis.org/en/bluegreen-deployments-kubernetes

Features:
* Avoid starving the live traffic of CPU during container start-up ("container churn")
* Avoid setting unnecessary resource requests or resource limits only needed at release-time
* Option to keep the old deployments around for awhile in case of roll-back 

Example Usage:
1. Make a copy of your deployments folder named "deployments.target", this folder will be modified in-place
```
cp -a deployments/ deployments.target/
```


2. Get the "nodes" InstanceGroup as a yaml file to use as a template: 
```
kops get ig nodes -o yaml > nodes.yaml
```

3. Stage1 will create a new InstanceGroup, wait for it to be ready, then deploy the "deployments.target" to the InstanceGroup
```
bash blue-green-deploy-stage1.sh --kops-spec-file=nodes.yaml --namespace=mynamespace Release-147
```
![stage1.png](stage1.png)
          

4. Stage2 verifies the deployment set is ready, then transfers the traffic to it. Note: Will modify the selectors for all services in the namespace!
```
bash blue-geen-deploy-stage2.sh --namespace=mynamespace Release-147
```
![stage2.png](stage2.png)

5. Stage3 cleans up the old deployment set and the old InstanceGroup
```
bash blue-green-deploy-stage3.sh --namespace=mynamespace
```
![stage3.png](stage3.png)

6. Clean up the modified deployment artifact
```
rm -rf deployments.target/
```
  
Requirements:
  - jq
  - kubernetes 1.9.x+
  - kops 1.9.x+


Limitations:
  - Won't cover new or removed services
  - Doesn't cover changes to Configmaps, Services, Secrets, etc.

Links:
https://www.ianlewis.org/en/bluegreen-deployments-kubernetes

https://kubernetes.io/docs/concepts/configuration/assign-pod-node/

https://kubernetes.io/docs/concepts/overview/working-with-objects/labels/


