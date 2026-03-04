.PHONY: all build docker-build kind-create kind-load install-cert-manager install-operator deploy ui clean

CLUSTER_NAME := flink-poc
IMAGE_NAME   := hello-world-flink:latest

all: build docker-build kind-create kind-load install-cert-manager install-operator deploy

build:
	mvn package -f flink-app/pom.xml -DskipTests

docker-build:
	docker build -t $(IMAGE_NAME) .

kind-create:
	kind create cluster --name $(CLUSTER_NAME)

kind-load:
	kind load docker-image $(IMAGE_NAME) --name $(CLUSTER_NAME)

install-cert-manager:
	kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/cert-manager.yaml
	kubectl rollout status deployment/cert-manager -n cert-manager --timeout=120s
	kubectl rollout status deployment/cert-manager-webhook -n cert-manager --timeout=120s
	kubectl rollout status deployment/cert-manager-cainjector -n cert-manager --timeout=120s

install-operator:
	helm repo add flink-operator https://archive.apache.org/dist/flink/flink-kubernetes-operator-1.11.0/ || true
	helm repo update
	helm upgrade --install flink-kubernetes-operator flink-operator/flink-kubernetes-operator \
		--namespace flink-kubernetes-operator \
		--create-namespace \
		--wait

deploy:
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f k8s/service-account.yaml
	kubectl apply -f k8s/flink-deployment.yaml

ui:
	kubectl port-forward svc/hello-world-rest 8081:8081 -n flink

clean:
	kind delete cluster --name $(CLUSTER_NAME)
