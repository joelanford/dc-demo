#!/usr/bin/env bash

#################################################################################
#################################################################################
###                                                                           ###
### Make sure to run this demo with a build from `opm` from the following PR: ###
###    https://github.com/operator-framework/operator-registry/pull/692       ###
###                                                                           ###
#################################################################################
#################################################################################

set -e

if [ -z "$IMAGE_TAG_BASE" ]; then
	echo "IMAGE_TAG_BASE must be set (e.g. IMAGE_TAG_BASE=quay.io/<username>/demo-operator)"
	exit 1
fi

rm -rf demo-operator
kubectl operator uninstall -X demo-operator || true
kubectl operator catalog remove demo-operator-index || true

#
# Initial Release
#

export VERSION=0.1.0
export IMG=${IMAGE_TAG_BASE}:v${VERSION}

##
## 1. (Create a bundle v1 from plain kubernetes manifests using the the SDK)
##
mkdir demo-operator && pushd demo-operator
go mod init example.com/demo-operator
operator-sdk init --domain=example.com
sed -i 's/docker-build: test/docker-build:/' Makefile
yq e '(select(.kind=="Deployment") | .spec.template.spec.containers[0].imagePullPolicy)="Always"' -i config/manager/manager.yaml
operator-sdk create api --controller=true --resource=true --group=demo --version=v1 --kind=Object
operator-sdk generate kustomize manifests --interactive=false -q
make docker-build docker-push
make bundle CHANNELS=ignored
operator-sdk bundle validate ./bundle

##
## 2. Build & Push the bundle image
##
make bundle-build
make bundle-push

##
## 3. Initialize a new package
##
mkdir index
opm alpha init demo-operator --default-channel=stable -o yaml > index/index.yaml

cat << EOF >> index/index.yaml
---
schema: olm.channel
package: demo-operator
name: stable
versions:
- 0.1.0
EOF

##
## 4. Add the bundle
##
opm alpha render ${IMAGE_TAG_BASE}-bundle:v${VERSION} -o yaml >> index/index.yaml
go install github.com/joelanford/declcfg-inline-bundles@latest
# Don't prune non-heads since declcfg-inline-bundles is not aware of the experimental olm.channel schema
declcfg-inline-bundles index ${IMAGE_TAG_BASE}-bundle:v${VERSION}
yq eval-all '(select(.schema=="olm.bundle" and .name=="demo-operator.v0.1.0").version)="0.1.0"' -i index/index.yaml
opm alpha validate index

##
## 5. Build & Push a catalog image
##
cat << EOF > index.Dockerfile
FROM quay.io/joelanford/opm:covington as builder

FROM scratch
COPY --from=builder /bin/opm /bin/opm
COPY --from=builder /bin/grpc_health_probe /bin/grpc_health_probe

COPY index /configs/demo-operator
LABEL operators.operatorframework.io.index.configs.v1=/configs

EXPOSE 50051
ENTRYPOINT ["/bin/opm"]
CMD ["alpha", "serve", "/configs"]
EOF

docker build -t ${IMAGE_TAG_BASE}-index:latest -f index.Dockerfile .
docker push ${IMAGE_TAG_BASE}-index:latest

##
## 6. Create a CatalogSource on cluster, and install Operator bundle from it
##
kubectl operator catalog add demo-operator-index ${IMAGE_TAG_BASE}-index:latest
kubectl patch catalogsource demo-operator-index -p '{"spec":{"updateStrategy":{"registryPoll":{"interval": "10s"}}}}' --type=merge
sleep 10
kubectl operator install demo-operator --create-operator-group --approval Automatic


#
# Subsequent updates
#

##
## 1. Build and push successor bundle v2
##
export VERSION=0.2.0
export IMG=${IMAGE_TAG_BASE}:v${VERSION}
make docker-build docker-push
make bundle CHANNELS=ignored
operator-sdk bundle validate ./bundle
make bundle-build
make bundle-push

##
## 2. Add it to the package definition
##
opm alpha render ${IMAGE_TAG_BASE}-bundle:v${VERSION} -o yaml >> index/index.yaml
declcfg-inline-bundles index ${IMAGE_TAG_BASE}-bundle:v${VERSION}
yq eval-all '(select(.schema=="olm.bundle" and .name=="demo-operator.v0.1.0").version)="0.1.0"' -i index/index.yaml
yq eval-all '(select(.schema=="olm.bundle" and .name=="demo-operator.v0.2.0").version)="0.2.0"' -i index/index.yaml
yq eval-all '(select(.schema=="olm.channel" and .name=="stable").versions)+="0.2.0"' -i index/index.yaml
opm alpha validate index

##
## 3. Rebuild and push the catalog image
##
docker build -t ${IMAGE_TAG_BASE}-index:latest -f index.Dockerfile .
docker push ${IMAGE_TAG_BASE}-index:latest

##
## 4. Observe update on cluster
##
timeout 2m bash -c -- 'until kubectl get csv demo-operator.v0.2.0 -o jsonpath="{.status.phase}" | grep Succeeded; do sleep 1; done'

#
# Freshmaker use case
#

##
## 1. Prepare a v1 installation (upgrade manual, observe available update to v2)
##
kubectl operator uninstall demo-operator -X
sleep 5
kubectl operator install demo-operator --create-operator-group --approval=Manual --version 0.1.0

### !!!!!! WARNING: It seems like the catalog-operator cache is somehow not refreshing to
###                 see the 0.2.0 upgrade that is available. Deleting the catalog-operator
###                 pod seems to fix it. It's possible there are other ways to fix this.
kubectl delete pod -n olm -l app=catalog-operator
kubectl wait --for=condition=Ready pod -n olm -l app=catalog-operator

timeout 1m bash -c -- 'until kubectl get subscription demo-operator -o jsonpath="{.status.currentCSV}" | grep demo-operator.v0.2.0; do sleep 1; done'


##
## 2. Build & Push a z-stream bundle v1.1 to sit in between v1 and v2
##
export VERSION=0.1.1
export IMG=${IMAGE_TAG_BASE}:v${VERSION}
make docker-build docker-push
make bundle CHANNELS=ignored
operator-sdk bundle validate ./bundle
make bundle-build
make bundle-push

##
## 3. Add it to the package definition
##
opm alpha render ${IMAGE_TAG_BASE}-bundle:v${VERSION} -o yaml >> index/index.yaml
declcfg-inline-bundles index ${IMAGE_TAG_BASE}-bundle:v${VERSION}
yq eval-all '(select(.schema=="olm.bundle" and .name=="demo-operator.v0.1.0").version)="0.1.0"' -i index/index.yaml
yq eval-all '(select(.schema=="olm.bundle" and .name=="demo-operator.v0.1.1").version)="0.1.1"' -i index/index.yaml
yq eval-all '(select(.schema=="olm.bundle" and .name=="demo-operator.v0.2.0").version)="0.2.0"' -i index/index.yaml
yq eval-all '(select(.schema=="olm.channel" and .name=="stable").versions)=["0.1.0","0.1.1","0.2.0"]' -i index/index.yaml
opm alpha validate index

##
## 4. Rebuild and push the catalog image
##
docker build -t ${IMAGE_TAG_BASE}-index:latest -f index.Dockerfile .
docker push ${IMAGE_TAG_BASE}-index:latest

##
## 5. Observe available update to v0.1.1
##
kubectl operator catalog remove demo-operator-index
kubectl operator catalog add demo-operator-index ${IMAGE_TAG_BASE}-index:latest
kubectl patch catalogsource demo-operator-index -p '{"spec":{"updateStrategy":{"registryPoll":{"interval": "10s"}}}}' --type=merge

### !!!!!! WARNING: It seems like the existing install plans for 0.2.0 need to be deleted
###                 Before OLM will detect the new 0.1.1 upgrade path!
kubectl get installplan | grep 'demo-operator.v0.2.0' | awk '{print $1}' | xargs -n1 kubectl delete installplan

timeout 2m bash -c -- 'until kubectl get subscription demo-operator -o jsonpath="{.status.currentCSV}" | grep demo-operator.v0.1.1; do sleep 1; done'

##
## 6. Apply the update
##
kubectl operator upgrade demo-operator
timeout 1m bash -c -- 'until kubectl get csv demo-operator.v0.1.1 -o jsonpath="{.status.phase}" | grep Succeeded; do sleep 1; done'

##
## 7. Observe available update to v0.2.0
##

### !!!!!! WARNING: It seems like the catalog-operator cache is somehow not refreshing to
###                 see the 0.2.0 upgrade that is available. Deleting the catalog-operator
###                 pod seems to fix it. It's possible there are other ways to fix this.
kubectl delete pod -n olm -l app=catalog-operator
kubectl wait --for=condition=Ready pod -n olm -l app=catalog-operator

timeout 1m bash -c -- 'until kubectl get subscription demo-operator -o jsonpath="{.status.currentCSV}" | grep demo-operator.v0.2.0; do sleep 1; done'

##
## 8. Apply the update
##
kubectl operator upgrade demo-operator

timeout 1m bash -c -- 'until kubectl get csv demo-operator.v0.2.0 -o jsonpath="{.status.phase}" | grep Succeeded; do sleep 1; done'

#
# CNV Use case
#

##
## 1. Release a v3 bundle into a separate channel with connection the previously released bundles
##
export VERSION=0.3.0
export IMG=${IMAGE_TAG_BASE}:v${VERSION}
make docker-build docker-push
make bundle CHANNELS=ignored
operator-sdk bundle validate ./bundle

##
## 2. Build and push v3 bundle image
##
make bundle-build
make bundle-push

##
## 3. Add it to the package definition
##
opm alpha render ${IMAGE_TAG_BASE}-bundle:v${VERSION} -o yaml >> index/index.yaml
declcfg-inline-bundles index ${IMAGE_TAG_BASE}-bundle:v${VERSION}
yq eval-all '(select(.schema=="olm.bundle" and .name=="demo-operator.v0.1.0").version)="0.1.0"' -i index/index.yaml
yq eval-all '(select(.schema=="olm.bundle" and .name=="demo-operator.v0.1.1").version)="0.1.1"' -i index/index.yaml
yq eval-all '(select(.schema=="olm.bundle" and .name=="demo-operator.v0.2.0").version)="0.2.0"' -i index/index.yaml
yq eval-all '(select(.schema=="olm.bundle" and .name=="demo-operator.v0.3.0").version)="0.3.0"' -i index/index.yaml
yq eval-all '(select(.schema=="olm.channel" and .name=="stable").versions)=["0.1.0","0.1.1","0.2.0"]' -i index/index.yaml
cat << EOF >> index/index.yaml
---
schema: olm.channel
package: demo-operator
name: beta
versions:
- 0.3.0
EOF
opm alpha validate index

##
## 4. Rebuild and push the catalog image
##
docker build -t ${IMAGE_TAG_BASE}-index:latest -f index.Dockerfile .
docker push ${IMAGE_TAG_BASE}-index:latest

##
## 5. Observe availability of new channel / bundle
##
timeout 1m bash -c -- 'until kubectl operator list-available -c demo-operator-index | grep demo-operator.v0.3.0; do sleep 1; done'

##
## 6. Observe no update is advertise for existing installed v2 when changing channels
##
kubectl patch subscription demo-operator --type=merge -p '{"spec":{"channel":"beta"}}'
sleep 5
kubectl get subscription demo-operator -o json | jq '{channel: .spec.channel, installedCSV: .status.installedCSV, currentCSV: .status.currentCSV, state: .status.state}'

##
## 7. Add update edge in DC from v2 to v3
##
yq eval-all '(select(.schema=="olm.channel" and .name=="beta").versions)=["0.2.0","0.3.0"]' -i index/index.yaml
yq eval-all '(select(.schema=="olm.channel" and .name=="beta").tombstones)=["0.2.0"]' -i index/index.yaml

##
## 8. Rebuild and push the catalog
##
docker build -t ${IMAGE_TAG_BASE}-index:latest -f index.Dockerfile .
docker push ${IMAGE_TAG_BASE}-index:latest

##
## 9. Observe availability of update to v3 when changing channels
##
timeout 1m bash -c -- 'until kubectl get subscription demo-operator -o jsonpath="{.status.currentCSV}" | grep demo-operator.v0.3.0; do sleep 1; done'

##
## 10. Apply the update
##
kubectl operator upgrade demo-operator

timeout 1m bash -c -- 'until kubectl get csv demo-operator.v0.3.0 -o jsonpath="{.status.phase}" | grep Succeeded; do sleep 1; done'

