/* Drives a db-lib login with a federated authentication token. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <sybfront.h>
#include <sybdb.h>

static int
err_handler(DBPROCESS * dbproc, int severity, int dberr, int oserr, char *dberrstr, char *oserrstr)
{
	(void) dbproc; (void) severity; (void) dberr; (void) oserr; (void) oserrstr;
	fprintf(stderr, "db-lib error: %s\n", dberrstr ? dberrstr : "(none)");
	return INT_CANCEL;
}

int
main(int argc, char **argv)
{
	LOGINREC *login;
	DBPROCESS *dbproc;

	if (argc < 4) {
		fprintf(stderr, "usage: %s host:port fedauth <token>\n", argv[0]);
		fprintf(stderr, "       %s host:port sql <user> <password>\n", argv[0]);
		return 2;
	}

	if (dbinit() == FAIL) {
		fprintf(stderr, "dbinit failed\n");
		return 2;
	}
	dberrhandle(err_handler);

	login = dblogin();
	if (login == NULL) {
		fprintf(stderr, "dblogin failed\n");
		return 2;
	}

	dbsetlversion(login, DBVERSION_74);
	DBSETLAPP(login, "TableProSpike");
	dbsetlogintime(15);

	if (strcmp(argv[2], "fedauth") == 0) {
		if (dbsetlfedauthtoken(login, argv[3]) == FAIL) {
			fprintf(stderr, "dbsetlfedauthtoken failed for a %lu byte token\n",
				(unsigned long) strlen(argv[3]));
			dbloginfree(login);
			return 2;
		}
	} else {
		if (argc < 5) {
			fprintf(stderr, "sql mode needs a user and a password\n");
			dbloginfree(login);
			return 2;
		}
		DBSETLUSER(login, argv[3]);
		DBSETLPWD(login, argv[4]);
	}

	/* the harness never completes the login, so this is expected to fail */
	dbproc = dbopen(login, argv[1]);
	if (dbproc != NULL)
		dbclose(dbproc);
	dbloginfree(login);
	dbexit();
	return 0;
}
