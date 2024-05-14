IMAGE ?= snp-builder
DOCKERFILE ?= snp-builder.dockerfile
NAME ?= snp-builder
OUTPUT_PATH ?= ../build

STATUS = $(shell docker inspect $(NAME) | grep Status | cut -d':' -f2 | sed 's/,//g' | xargs)
EXIT_CODE = $(shell docker inspect $(NAME) | grep ExitCode | cut -d':' -f2 | sed 's/,//g' | xargs)

USE_STABLE_SNAPSHOTS ?= 0

image:
	docker build -t $(IMAGE) -f $(DOCKERFILE) .

build: clean
	docker run -v /boot:/boot -d --name $(NAME) -e USE_STABLE_SNAPSHOTS=$(USE_STABLE_SNAPSHOTS) $(IMAGE)

get_files: check_status
	docker cp $(NAME):/usr/src/app/snp-release.tar.gz $(OUTPUT_PATH)

check_status:
	@echo $(STATUS) | grep -q exited && echo $(EXIT_CODE) | grep -q 0 || (echo "Error! Status: $(STATUS) ExitCode: $(EXIT_CODE)" && exit 1)

clean:
	@docker stop $(IMAGE) ||  true
	@docker rm $(IMAGE) || true