#include <infiniband/verbs.h>
#include <stdio.h>

/*
 * Check whether fork support is enabled on the instance by querying the rdma-core interface.
 */
int main()
{
	if (IBV_FORK_UNNEEDED != ibv_is_fork_initialized()) {
		fprintf(stderr, "Kernel space fork support is not enabled \n");
		return -1;
	}

	fprintf(stderr, "Kernel space fork support is enabled \n");
	return 0;
}
