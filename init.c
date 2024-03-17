#include <limits.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <dirent.h>
#include <termios.h>

#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <linux/vm_sockets.h>

#ifdef SEV
#include "tee/snp_attest.h"
#endif



#ifdef SEV
static char *sev_get_luks_passphrase(int *);
static char *snp_get_luks_passphrase(char *, char *, char *, int *);
#endif


#ifdef SEV
/*
 * The LUKS passphrase is obtained from a KBS attestation server, complete an
 * SNP attestation to get the passphrase.
 */
static char *
get_luks_passphrase(int *pass_len)
{
        int fd, ret, num_tokens, wid_found, url_found, tee_found, tee_data_found;
        uint64_t dev_size, tc_size;
        char wid[256], url[256], *tc_json, *tok_start, *tok_end;
        char footer[KRUN_FOOTER_LEN], tee[256], tee_data[256], *return_str;
        jsmn_parser parser;
        jsmntok_t *tokens;
        size_t tok_size;

        return_str = NULL;

        /*
         * If a user registered the TEE config data disk with
         * krun_set_data_disk(), it would appear as /dev/vdb in the guest.
         * Mount this device and read the config.
         */
        if (mkdir("/dev", 0755) < 0 && errno != EEXIST) {
                perror("mkdir(/dev)");
                goto finish;
        }

        if (mount("devtmpfs", "/dev", "devtmpfs", MS_RELATIME, NULL) < 0 &&
                        errno != EBUSY) {
                perror("mount(devtmpfs)");

                goto rmdir_dev;
        }

        fd = open("/dev/vda", O_RDONLY);
        if (fd < 0) {
            perror("open(/dev/vda)");

            goto umount_dev;
        }

        ret = ioctl(fd, BLKGETSIZE64, &dev_size);
        if (ret != 0) {
            perror("ioctl(BLKGETSIZE64)");

            goto close_dev;
        }

        if (lseek(fd, dev_size - KRUN_FOOTER_LEN, SEEK_SET) == -1) {
            perror("lseek(END - KRUN_FOOTER_LEN)");

            goto close_dev;
        }

        ret = read(fd, &footer[0], KRUN_FOOTER_LEN);
        if (ret != KRUN_FOOTER_LEN) {
            perror("read(KRUN_FOOTER_LEN)");

            goto close_dev;
        }

        if (memcmp(&footer[0], KRUN_MAGIC, 4) != 0) {
            printf("Couldn't find KRUN footer signature, falling back to SEV\n");
            return_str = sev_get_luks_passphrase(pass_len);

            goto close_dev;
        }

        tc_size = *(uint64_t *) &footer[4];

        if (lseek(fd, dev_size - tc_size - KRUN_FOOTER_LEN, SEEK_SET) == -1) {
            perror("lseek(END - tc_size - KRUN_FOOTER_LEN)");

            goto close_dev;
        }

        tc_json = malloc(tc_size + 1);
        if (tc_json == NULL) {
            perror("malloc(tc_size)");

            goto close_dev;
        }

        ret = read(fd, tc_json, tc_size);
        if (ret != tc_size) {
            perror("read(tc_size)");

            goto free_mem;
        }
        tc_json[tc_size] = '\0';

        /*
         * Parse the TEE config's workload_id and attestation_url field.
         */
        jsmn_init(&parser);

        tokens = (jsmntok_t *) malloc(sizeof(jsmntok_t) * MAX_TOKENS);\
        if (tokens == NULL) {
                perror("malloc(jsmntok_t)");

                goto free_mem;
        }

        num_tokens = jsmn_parse(&parser, tc_json, strlen(tc_json), tokens,
                MAX_TOKENS);
        if (num_tokens < 0) {
                printf("Unable to allocate JSON tokens\n");

                goto free_mem;
        } else if (num_tokens < 1 || tokens[0].type != JSMN_OBJECT) {
                printf("Unable to find object in TEE configuration file\n");

                goto free_mem;
        }

        wid_found = url_found = tee_found = tee_data_found = 0;

        for (int i = 1; i < num_tokens - 1; ++i) {
                tok_start = tc_json + tokens[i + 1].start;
                tok_end = tc_json + tokens[i + 1].end;
                tok_size = tok_end - tok_start;
                if (!jsoneq(tc_json, &tokens[i], "workload_id")) {
                        strncpy(wid, tok_start, tok_size);
                        wid_found = 1;
                } else if (!jsoneq(tc_json, &tokens[i], "attestation_url")) {
                        strncpy(url, tok_start, tok_size);
                        url_found = 1;
                } else if (!jsoneq(tc_json, &tokens[i], "tee")) {
                        strncpy(tee, tok_start, tok_size);
                        tee_found = 1;
                } else if (!jsoneq(tc_json, &tokens[i], "tee_data")) {
                        strncpy(tee_data, tok_start, tok_size);
                        tee_data_found = 1;
                }
        }

        if (!wid_found) {
                printf("Unable to find attestation workload ID\n");

                goto free_mem;
        } else if (!url_found) {
                printf("Unable to find attestation server URL\n");

                goto free_mem;
        } else if (!tee_found) {
                printf("Unable to find TEE generation server URL\n");

                goto free_mem;
        }

        if (strcmp(tee, "snp") == 0) {
                if (tee_data_found == 0) {
                        printf("Unable to find SNP generation\n");
                        goto free_mem;
                }

                return_str = snp_get_luks_passphrase(url, wid, tee_data, pass_len);
        } else if (strcmp(tee, "sev") == 0) {
                return_str = sev_get_luks_passphrase(pass_len);
        }

free_mem:
        free(tc_json);

close_dev:
        close(fd);

umount_dev:
        umount("/dev");

rmdir_dev:
        rmdir("/dev");

finish:
        return return_str;
}

static char *
snp_get_luks_passphrase(char *url, char *wid, char *tee_data, int *pass_len)
{
        char *pass;

        pass = (char *) malloc(MAX_PASS_SIZE);
        if (pass == NULL) {
                return NULL;
        }

        if (snp_attest(pass, url, wid, tee_data) == 0) {
                *pass_len = strlen(pass);
                return pass;
        }

        free(pass);

        return NULL;
}

static char *
sev_get_luks_passphrase(int *pass_len)
{
	char *pass = NULL;
	int len;
	int fd;

	pass = getenv("KRUN_PASS");
	if (pass) {
		*pass_len = strnlen(pass, MAX_PASS_SIZE);
		return pass;
	}
	if (mkdir("/sfs", 0755) < 0 && errno != EEXIST) {
		perror("mkdir(/sfs)");
		return NULL;
	}

	if (mount("securityfs", "/sfs", "securityfs",
		MS_NODEV | MS_NOEXEC | MS_NOSUID | MS_RELATIME, NULL) < 0) {
		perror("mount(/sfs)");
		goto cleanup_dir;
	}

        fd = open(CMDLINE_SECRET_PATH, O_RDONLY);
	if (fd < 0) {
		goto cleanup_sfs;
	}

	pass = malloc(MAX_PASS_SIZE);
	if (!pass) {
		goto cleanup_fd;
	}

	if ((len = read(fd, pass, MAX_PASS_SIZE)) < 0) {
		free(pass);
		pass = NULL;
	} else {
		*pass_len = len;
		unlink(CMDLINE_SECRET_PATH);
	}

cleanup_fd:
	close(fd);
cleanup_sfs:
	umount("/sfs");
cleanup_dir:
	rmdir("/sfs");

        return pass;
}

static int chroot_luks()
{
	char *pass;
	int pass_len;
	int pid;
	int pipefd[2];
	int wstatus;

	pass = get_luks_passphrase(&pass_len);
	if (!pass) {
		printf("Couldn't find LUKS passphrase\n");
		return -1;
	}

	printf("Unlocking LUKS root filesystem\n");
	pipe(pipefd);

	pid = fork();
	if (pid == 0) {
		close(pipefd[1]);
		dup2(pipefd[0], 0);
		close(pipefd[0]);

		if (execl("/sbin/cryptsetup", "cryptsetup", "open", "/dev/vda", "luksroot", "-", NULL) < 0) {
			perror("execl");
			return -1;
		}
	} else {
		write(pipefd[1], pass, strnlen(pass, pass_len));
		close(pipefd[1]);
		waitpid(pid, &wstatus, 0);
	}

	memset(pass, 0, pass_len);

	printf("Mounting LUKS root filesystem\n");

	if (mount("/dev/mapper/luksroot", "/luksroot", "ext4", 0, NULL) < 0) {
		perror("mount(/luksroot)");
		return -1;
	}

	chdir("/luksroot");

	if (mount(".", "/", NULL, MS_MOVE, NULL)) {
		perror("remount root");
		return -1;
	}
	chroot(".");

	return 0;
}
#endif

static int mount_filesystems()
{
	char *const DIRS_LEVEL1[] = {"/dev", "/proc", "/sys"};
	char *const DIRS_LEVEL2[] = {"/dev/pts", "/dev/shm"};
	int i;

	for (i = 0; i < 3; ++i) {
		if (mkdir(DIRS_LEVEL1[i], 0755) < 0 && errno != EEXIST) {
			printf("Error creating directory (%s)\n", DIRS_LEVEL1[i]);
			return -1;
		}
	}

	if (mount("devtmpfs", "/dev", "devtmpfs",
		  MS_RELATIME, NULL) < 0 && errno != EBUSY ) {
		perror("mount(/dev)");
		return -1;
	}

	if (mount("proc", "/proc", "proc",
		  MS_NODEV | MS_NOEXEC | MS_NOSUID | MS_RELATIME, NULL) < 0) {
		perror("mount(/proc)");
		return -1;
	}

	if (mount("sysfs", "/sys", "sysfs",
		  MS_NODEV | MS_NOEXEC | MS_NOSUID | MS_RELATIME, NULL) < 0) {
		perror("mount(/sys)");
		return -1;
	}

	if (mount("cgroup2", "/sys/fs/cgroup", "cgroup2",
		  MS_NODEV | MS_NOEXEC | MS_NOSUID | MS_RELATIME, NULL) < 0) {
		perror("mount(/sys/fs/cgroup)");
		return -1;
	}

	for (i = 0; i < 2; ++i) {
		if (mkdir(DIRS_LEVEL2[i], 0755) < 0 && errno != EEXIST) {
			printf("Error creating directory (%s)\n", DIRS_LEVEL2[i]);
			return -1;
		}
	}

	if (mount("devpts", "/dev/pts", "devpts",
		  MS_NOEXEC | MS_NOSUID | MS_RELATIME, NULL) < 0) {
		perror("mount(/dev/pts)");
		return -1;
	}

	if (mount("tmpfs", "/dev/shm", "tmpfs",
		  MS_NOEXEC | MS_NOSUID | MS_RELATIME, NULL) < 0) {
		perror("mount(/dev/shm)");
		return -1;
	}

	/* May fail if already exists and that's fine. */
	symlink("/proc/self/fd", "/dev/fd");

	return 0;
}


int main(int argc, char **argv)
{
	(void)argc;
	(void)argv;

#ifdef SEV
	if (chroot_luks() < 0) {
		printf("Couldn't switch to LUKS volume, bailing out\n");
		exit(-1);
	}
#endif
	if (mount_filesystems() < 0) {
		printf("Couldn't mount filesystems, bailing out\n");
		exit(-2);
	}

	printf("Mounting virtio driver\n");
	if(system("modprobe virtio_scsi")) {
		printf("Failed to load disk driver\n");
		exit(-1);
	}

	// printf("Mounting new root\n");
	// if(system("mount /dev/sda2 /mnt")) {
	// 	printf("Failed to mount /dev/sda2\n");
	// 	exit(-1);
	// }

	// if(system("mount --move /sys /mnt/sys")) {
	// 	printf("Failed to move /sys\n");
	// 	exit(-1);
	// }
	
	// if(system("mount --move /proc /mnt/proc")) {
	// 	printf("Failed to move /proc\n");
	// 	exit(-1);
	// }
	// if(system("mount --move /dev /mnt/dev")) {
	// 	printf("Failed to move /dev\n");
	// 	exit(-1);
	// }

	// printf("Executing switch_root...\n");
	// if(execl("./switch_to_new_root.sh", "", NULL)) {
	// 	printf("Failed to execute init\n");
	// 	//exit(1);
	// }
	execl("/bin/bash","",NULL);


	return 0;
}
