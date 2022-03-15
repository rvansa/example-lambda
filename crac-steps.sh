#!/bin/bash

CONTAINERNAME=crac

IOLIM=60m
DEV=/dev/nvme0n1
CPU=0.88

  dev() {   DEV=$1; }
iolim() { IOLIM=$1; }
  cpu() {   CPU=$1; }

s00_init() {

	if [ -z $JAVA_HOME ]; then
	       echo "No	JAVA_HOME specified"
	       return 1
	fi

	rm -rf jdk
	cp -r $JAVA_HOME jdk

	curl -L -o aws-lambda-rie https://github.com/aws/aws-lambda-runtime-interface-emulator/releases/download/v1.3/aws-lambda-rie-$(uname -m) 
	chmod +x aws-lambda-rie
}

dojlink() {
	$JAVA_HOME/bin/jlink --bind-services --output jdk --module-path $JAVA_HOME/jmods --add-modules java.base,jdk.unsupported,java.sql
}

s01_build() {
	mvn compile dependency:copy-dependencies -DincludeScope=runtime
	docker build -t crac-lambda-checkpoint -f Dockerfile.checkpoint .
}

s02_start_checkpoint() {
	docker run \
		--privileged \
		--rm \
		--name crac-checkpoint \
		-v $PWD/aws-lambda-rie:/aws-lambda-rie \
		-v $PWD/cr:/cr \
		-p 8080:8080 \
		-e AWS_REGION=us-west-2 \
		crac-lambda-checkpoint
}

rawpost() {
        local c=0
        while [ $c -lt 20 ]; do
                curl -XPOST --no-progress-meter -d "$@" http://localhost:8080/2015-03-31/functions/function/invocations && break
                sleep 0.2
                c=$(($c + 1))
        done
}

post() {
        rawpost "{ Records : [ { body : \"${1}\" } ] }"
}

s03_checkpoint() {
        post checkpoint
        sleep 2
        post fini
	docker rm -f crac-checkpoint
}

s04_prepare_restore() {
	sudo rm -f cr/dump4.log # XXX
	docker build -t crac-lambda-restore -f Dockerfile.restore .
}

dropcache() {
        sync
        echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null
}

local_test() {
	docker run \
		--rm \
		--name crac-test \
		-v $PWD/aws-lambda-rie:/aws-lambda-rie \
		-p 8080:8080 \
		--device-read-bps $DEV:$IOLIM \
		--device-write-bps $DEV:$IOLIM \
		--cpus $CPU \
		--entrypoint '' \
		"$@"
}

s05_local_restore() {
	local_test crac-lambda-restore \
		/aws-lambda-rie /bin/bash /restore.cmd.sh
}

local_baseline() {
	local_test crac-lambda-baseline \
		/aws-lambda-rie /jdk/bin/java \
			-XX:-UsePerfData \
			-cp /function:/function/lib/* \
			com.amazonaws.services.lambda.runtime.api.client.AWSLambda \
			example.Handler::handleRequest
}

s06_init_aws() {
	ACCOUNT=$(aws sts get-caller-identity | jq -r '.Account')
	echo export ACCOUNT=$ACCOUNT
	REGION=$(aws configure get region)
	echo export REGION=$REGION
	ECR=$ACCOUNT.dkr.ecr.$REGION.amazonaws.com
	echo export ECR=$ECR
	REMOTEIMG=$ECR/crac-test
	echo export REMOTEIMG=$REMOTEIMG
	aws ecr get-login-password | docker login --username AWS --password-stdin $ECR 1>&2
}

s07_deploy_aws() {
        docker tag crac-lambda-restore $REMOTEIMG
        docker push $REMOTEIMG
}

init_lambda() {
	if ! [ $LAMBDANAME ]; then
		echo "Provide LAMBDANAME= preconfigured by a container image: \
https://docs.aws.amazon.com/lambda/latest/dg/gettingstarted-images.html#gettingstarted-images-function" >&2
		exit 1
	fi
}

update_lambda() {
        local digest=$(docker inspect -f '{{ index .RepoDigests 0 }}' $REMOTEIMG)
        aws lambda update-function-code --function-name $LAMBDANAME --image $digest
        aws lambda wait function-updated --function-name $LAMBDANAME
}

s08_invoke_lambda() {
	rm -f response.json log.json

	aws lambda invoke  \
		--cli-binary-format raw-in-base64-out \
		--function-name $LAMBDANAME \
		--payload "$(< event.json) " \
		--log-type Tail \
		response.json \
		> log.json

	jq . < response.json 
	jq -r .LogResult < log.json | base64 -d
}

coldstart_lambda() {
	local mem=$(aws lambda get-function-configuration --function-name $LAMBDANAME | jq -r '.MemorySize')
	local min=256
	local max=512
	aws lambda update-function-configuration --function-name $LAMBDANAME --memory-size $(($min + (($mem + 1) % ($max - $min))))
}

for i; do
	$i || break
done
