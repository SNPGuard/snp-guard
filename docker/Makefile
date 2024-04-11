IMAGE ?= snp-builder
DOCKERFILE ?= snp-builder.dockerfile

image:
	docker build -t $(IMAGE) -f $(DOCKERFILE) .

build:
	docker run -v /boot:/boot -d --name snp-builder $(IMAGE)