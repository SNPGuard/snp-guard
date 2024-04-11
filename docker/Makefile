IMAGE ?= snp-builder
DOCKERFILE ?= snp-builder.dockerfile

image:
	docker build -t $(IMAGE) -f $(DOCKERFILE) ..

build: clean
	docker run -v /boot:/boot -d --name snp-builder $(IMAGE)

clean:
	@docker stop $(IMAGE) ||  true
	@docker rm $(IMAGE) || true