IMAGE ?= snp-builder
DOCKERFILE ?= snp-builder.dockerfile
NAME ?= snp-builder
OUTPUT_PATH ?= ..

image:
	docker build -t $(IMAGE) -f $(DOCKERFILE) ..

build: clean
	docker run -v /boot:/boot -d --name $(NAME) $(IMAGE)

get_files:
	docker cp $(NAME):/usr/src/app/snp-release.tar.gz $(OUTPUT_PATH)

clean:
	@docker stop $(IMAGE) ||  true
	@docker rm $(IMAGE) || true